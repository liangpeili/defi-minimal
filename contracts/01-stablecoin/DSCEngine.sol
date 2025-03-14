// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./DecentralizedStableCoin.sol";
import "./PriceFeed.sol";

error DSCEngine__NeedsMoreThanZero();
error DSCEngine__TransferFailed();
error DSCEngine__BreaksHealthFactor();
error DSCEngine__MintFailed();
error DSCEngine__HealthFactorOk();

contract DSCEngine is ReentrancyGuard {
    uint256 public constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 public constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    DecentralizedStableCoin public immutable i_dsc;
    address public immutable i_ethToken; // ETH token address
    PriceFeed public immutable i_priceFeed;

    // user -> amount of ETH deposited
    mapping(address => uint256) public s_userToEthDeposited;
    // user -> amount of DSC minted
    mapping(address => uint256) public s_userToDscMinted;

    event CollateralDeposited(address indexed user, uint256 indexed amount);

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    constructor(
        address ethToken,
        address dscAddress,
        address priceFeedAddress
    ) {
        i_ethToken = ethToken;
        i_dsc = DecentralizedStableCoin(dscAddress);
        i_priceFeed = PriceFeed(priceFeedAddress);
    }

    function depositCollateralAndMintDsc(
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        _depositCollateral(amountCollateral);
        _mintDsc(amountDscToMint);
    }

    function _depositCollateral(
        uint256 amountCollateral
    ) private moreThanZero(amountCollateral) nonReentrant {
        s_userToEthDeposited[msg.sender] += amountCollateral;
        bool success = IERC20(i_ethToken).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        emit CollateralDeposited(msg.sender, amountCollateral);
    }

    function _mintDsc(
        uint256 amountDscToMint
    ) private moreThanZero(amountDscToMint) nonReentrant {
        s_userToDscMinted[msg.sender] += amountDscToMint;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (minted != true) {
            revert DSCEngine__MintFailed();
        }
    }

    function redeemCollateralForDsc(
        uint256 amountCollateral,
        uint256 amountDscToBurn
    ) external {
        burnDsc(amountDscToBurn);
        redeemCollateral(amountCollateral);
    }

    function redeemCollateral(
        uint256 amountCollateral
    ) public moreThanZero(amountCollateral) nonReentrant {
        _redeemCollateral(amountCollateral, msg.sender, msg.sender);
    }

    function _redeemCollateral(
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_userToEthDeposited[from] -= amountCollateral;
        bool success = IERC20(i_ethToken).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // Don't call this function directly, you will just lose money!
    function burnDsc(
        uint256 amountDscToBurn
    ) public moreThanZero(amountDscToBurn) nonReentrant {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_userToDscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function getAccountInformation(
        address user
    )
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_userToDscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function healthFactor(address user) public view returns (uint256) {
        (
            uint256 totalDscMinted,
            uint256 collateralValueInUsd
        ) = getAccountInformation(user);
        if (totalDscMinted == 0) return 100e18;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * 1e18) / totalDscMinted;
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 collateralValueInUsd) {
        uint256 ethAmount = s_userToEthDeposited[user];
        return getUsdValue(ethAmount);
    }

    function getUsdValue(uint256 amount) public view returns (uint256) {
        // 使用 PriceFeed 合约获取 ETH 价格
        uint256 price = i_priceFeed.getLatestPrice();
        // 确保价格是正数
        if (price <= 0) return 0;
        // 计算 ETH 的美元价值
        return (uint256(price) * amount) / 1e18;
    }

    function getEthAmountFromUsd(
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        uint256 price = i_priceFeed.getLatestPrice();
        // 确保价格是正数
        if (price <= 0) return 0;
        // 计算等值的 ETH 数量
        return (usdAmountInWei * 1e18) / uint256(price);
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor();
        }
    }

    function liquidate(address user, uint256 debtToCover) external {
        uint256 startingUserHealthFactor = healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 ethAmountFromDebtCovered = getEthAmountFromUsd(debtToCover);
        uint256 bonusCollateral = (ethAmountFromDebtCovered *
            LIQUIDATION_BONUS) / 100;
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(
            ethAmountFromDebtCovered + bonusCollateral,
            user,
            msg.sender
        );
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = healthFactor(user);
        require(startingUserHealthFactor < endingUserHealthFactor);
    }
}
