// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal NPM stub for valuation unit tests: positions() replays configured
///      state. The mint/decrease/collect/burn surface is unimplemented here; vault
///      integration tests use a fuller mock and fork tests use the real NPM.
contract MockNonfungiblePositionManager {
    struct StoredPosition {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 => StoredPosition) internal _positions;

    function setPosition(uint256 tokenId, StoredPosition calldata p) external {
        _positions[tokenId] = p;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        StoredPosition memory p = _positions[tokenId];
        return (
            0,
            address(0),
            p.token0,
            p.token1,
            p.fee,
            p.tickLower,
            p.tickUpper,
            p.liquidity,
            p.feeGrowthInside0LastX128,
            p.feeGrowthInside1LastX128,
            p.tokensOwed0,
            p.tokensOwed1
        );
    }
}
