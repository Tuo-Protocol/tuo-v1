// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPoint128} from "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";
import {FullMath} from "@uniswap/v3-core/contracts/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

import {INonfungiblePositionManager} from "../../src/interfaces/external/INonfungiblePositionManager.sol";
import {LiquidityAmounts} from "../../src/vendor/uniswap/LiquidityAmounts.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockUniswapV3Pool} from "./MockUniswapV3Pool.sol";

/// @dev NPM stand-in driven by REAL Uniswap V3 liquidity math against a registered mock
///      pool's live price. Every amount is derived from `liquidity` and the price, exactly
///      as the real NPM does; nothing is stored as a fixed pair of amounts.
///
///      The previous version returned `desired - haircutBps` on both legs, which is
///      price-independent and cannot happen in V3. That is structurally why 146 green
///      tests coexisted with a live slippage-floor bug: no mock-based test could express
///      the thing that breaks, namely the pool consuming a RATIO the caller does not
///      choose.
///
///      `setMintDriftTicks` / `setBurnDriftTicks` replace the haircut: they make the mock
///      execute at `poolTick + drift` while the vault quoted at `poolTick`, which is the
///      only faithful way to unit-test a between-quote-and-inclusion price move.
///
///      Two fidelity caveats, both in the safe direction for the vault's floors:
///      - the real NPM rounds the amounts it PULLS up (`SqrtPriceMath.getAmount0Delta`
///        with `roundUp = true`) while `getAmountsForLiquidity` floors, so this mock is
///        up to 1 wei per leg optimistic;
///      - it is not solvent across positions the way the real NPM is - `collect` pays
///        from whatever this contract happens to hold.
contract MockPositionManager {
    using SafeERC20 for IERC20;

    struct Stored {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address pool;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint256 owed0;
        uint256 owed1;
    }

    uint256 public nextTokenId = 100;

    /// @dev Price drift the mock applies between the vault's quote and its own execution.
    int24 public mintDriftTicks;
    int24 public burnDriftTicks;

    /// @dev Share of the unwind the mock silently withholds. Price movement alone can
    ///      never push a burn under the vault's combined-value floor (an LP is worth
    ///      MORE, not less, measured at a price it has moved away from), so this is the
    ///      knob that models what the floor actually guards: an NPM returning less than
    ///      the position's liquidity implies.
    uint16 public burnShortfallBps;

    mapping(bytes32 poolKey => address pool) public poolFor;
    mapping(uint256 tokenId => Stored) public stored;

    function setPool(address token0, address token1, uint24 fee, address pool) external {
        poolFor[_key(token0, token1, fee)] = pool;
    }

    function setMintDriftTicks(int24 ticks) external {
        mintDriftTicks = ticks;
    }

    function setBurnDriftTicks(int24 ticks) external {
        burnDriftTicks = ticks;
    }

    function setBurnShortfallBps(uint16 bps) external {
        burnShortfallBps = bps;
    }

    /// @dev Seed accrued swap fees for a position; mints the tokens to this contract so
    ///      collect can pay them out.
    function accrueFees(uint256 tokenId, uint256 fee0, uint256 fee1) external {
        Stored storage s = stored[tokenId];
        s.owed0 += fee0;
        s.owed1 += fee1;
        MockERC20(s.token0).mint(address(this), fee0);
        MockERC20(s.token1).mint(address(this), fee1);
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address pool = poolFor[_key(p.token0, p.token1, p.fee)];
        require(pool != address(0), "mock: pool not registered");

        uint160 sqrtExec = _execPrice(pool, mintDriftTicks);
        uint160 sqrtA = TickMath.getSqrtRatioAtTick(p.tickLower);
        uint160 sqrtB = TickMath.getSqrtRatioAtTick(p.tickUpper);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(sqrtExec, sqrtA, sqrtB, p.amount0Desired, p.amount1Desired);
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtExec, sqrtA, sqrtB, liquidity);
        require(amount0 >= p.amount0Min, "Price slippage check");
        require(amount1 >= p.amount1Min, "Price slippage check");

        IERC20(p.token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(p.token1).safeTransferFrom(msg.sender, address(this), amount1);

        tokenId = nextTokenId++;
        (uint256 inside0, uint256 inside1) = MockUniswapV3Pool(pool).feeGrowthInside(p.tickLower, p.tickUpper);
        stored[tokenId] = Stored({
            token0: p.token0,
            token1: p.token1,
            fee: p.fee,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidity: liquidity,
            pool: pool,
            feeGrowthInside0LastX128: inside0,
            feeGrowthInside1LastX128: inside1,
            owed0: 0,
            owed1: 0
        });
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata p)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Stored storage s = stored[p.tokenId];
        require(p.liquidity == s.liquidity, "partial not modeled");
        _checkpoint(s);

        uint160 sqrtExec = _execPrice(s.pool, burnDriftTicks);
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtExec, TickMath.getSqrtRatioAtTick(s.tickLower), TickMath.getSqrtRatioAtTick(s.tickUpper), s.liquidity
        );
        amount0 -= (amount0 * burnShortfallBps) / 10_000;
        amount1 -= (amount1 * burnShortfallBps) / 10_000;
        require(amount0 >= p.amount0Min, "Price slippage check");
        require(amount1 >= p.amount1Min, "Price slippage check");

        s.liquidity = 0;
        s.owed0 += amount0;
        s.owed1 += amount1;

        // A drifted burn returns a different SPLIT than the mint pulled, and this mock
        // holds only what it pulled. The real NPM draws on the pool's aggregate
        // liquidity; standing in for that is the point of the top-up. It only ever
        // triggers when a drift knob is set, so the invariant suite (which runs at drift
        // zero) never mints behind the value-conservation ghosts.
        _topUp(s.token0, amount0);
        _topUp(s.token1, amount1);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Stored storage s = stored[p.tokenId];
        _checkpoint(s);
        amount0 = s.owed0;
        amount1 = s.owed1;
        s.owed0 = 0;
        s.owed1 = 0;
        IERC20(s.token0).safeTransfer(p.recipient, amount0);
        IERC20(s.token1).safeTransfer(p.recipient, amount1);
    }

    function burn(uint256 tokenId) external {
        require(stored[tokenId].liquidity == 0, "Not cleared");
        delete stored[tokenId];
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
            uint256,
            uint256,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Stored memory s = stored[tokenId];
        return (
            0,
            address(0),
            s.token0,
            s.token1,
            s.fee,
            s.tickLower,
            s.tickUpper,
            s.liquidity,
            s.feeGrowthInside0LastX128,
            s.feeGrowthInside1LastX128,
            uint128(s.owed0),
            uint128(s.owed1)
        );
    }

    function factory() external view returns (address) {
        return address(this);
    }

    /// @dev What the real NPM does on every touch: move the fee growth the pool has accrued to
    ///      the range since the last snapshot into `tokensOwed`, then advance the snapshot. The
    ///      deltas wrap on purpose, exactly as `Position.update` does.
    function _checkpoint(Stored storage s) private {
        if (s.liquidity == 0) return;
        (uint256 inside0, uint256 inside1) = MockUniswapV3Pool(s.pool).feeGrowthInside(s.tickLower, s.tickUpper);
        uint256 fee0;
        uint256 fee1;
        unchecked {
            fee0 = FullMath.mulDiv(s.liquidity, inside0 - s.feeGrowthInside0LastX128, FixedPoint128.Q128);
            fee1 = FullMath.mulDiv(s.liquidity, inside1 - s.feeGrowthInside1LastX128, FixedPoint128.Q128);
        }
        s.feeGrowthInside0LastX128 = inside0;
        s.feeGrowthInside1LastX128 = inside1;
        if (fee0 == 0 && fee1 == 0) return;
        s.owed0 += fee0;
        s.owed1 += fee1;
        MockERC20(s.token0).mint(address(this), fee0);
        MockERC20(s.token1).mint(address(this), fee1);
    }

    /// @dev Cover a shortfall against what this position is owed; see decreaseLiquidity.
    function _topUp(address token, uint256 owed) private {
        uint256 held = IERC20(token).balanceOf(address(this));
        if (held < owed) MockERC20(token).mint(address(this), owed - held);
    }

    /// @dev The vault quoted at the pool's tick; the mock executes `drift` ticks away.
    function _execPrice(address pool, int24 drift) private view returns (uint160) {
        (, int24 poolTick,,,,,) = MockUniswapV3Pool(pool).slot0();
        return TickMath.getSqrtRatioAtTick(poolTick + drift);
    }

    function _key(address token0, address token1, uint24 fee) private pure returns (bytes32) {
        return keccak256(abi.encode(token0, token1, fee));
    }
}
