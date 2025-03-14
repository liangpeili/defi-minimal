// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

contract PriceFeed {
    constructor() {}

    uint256 public PRICE_FEED_PRECISION = 2000 * 1e18;

    /**
     * Returns the latest price.
     */
    // 抵押品的价格，比如1 ETH = 2000 USD
    function getLatestPrice() public view returns (uint price) {
        return PRICE_FEED_PRECISION;
    }

    function setPriceFeedPrecision(uint256 _priceFeedPrecision) external {
        PRICE_FEED_PRECISION = _priceFeedPrecision;
    }
}
