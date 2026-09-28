// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

/// @dev Configurable stand-in for a Uniswap V3 pool: observe() replays a constant
///      TWAP tick, slot0 returns a settable spot tick together with the sqrt price
///      that tick actually implies. Token ordering is caller-chosen so tests can cover
///      USDC-as-token0 and USDC-as-token1 pools.
///
///      slot0's sqrtPriceX96 used to be hardcoded to 0, which is why the mock suite could
///      not see the LP slippage floors were broken: every LP amount the vault derives
///      comes from that price, so with a zero price the whole LP lifecycle was tested
///      against nonsense.
contract MockUniswapV3Pool {
    struct FeeGrowthOutside {
        uint256 fee0;
        uint256 fee1;
    }

    address public token0;
    address public token1;
    uint24 public fee;

    int24 internal _twapTick;
    int24 internal _spotTick;

    /// @dev Defaults clear TuoConstants.MIN_OBSERVATION_CARDINALITY so the ordinary
    ///      fixtures construct; the setter exists so the deployment guard can be tested.
    uint16 internal _cardinalityNext = 2_000;

    /// @dev When set, `observe` reverts exactly as a real pool does when its observation
    ///      ring cannot span the requested window. This is the state the whole TWAP
    ///      surface has to survive: without it the mock answers unconditionally and no
    ///      test can tell an oracle-dependent path from an oracle-free one.
    bool internal _oracleBricked;

    /// @dev Fee growth state, settable so a test can model fees the pool has accrued to a
    ///      range that nothing has touched yet: the figure `tokensOwed` cannot see.
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    mapping(int24 => FeeGrowthOutside) internal _feeGrowthOutside;

    constructor(address token0_, address token1_, uint24 fee_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    function setTwapTick(int24 tick) external {
        _twapTick = tick;
    }

    function setSpotTick(int24 tick) external {
        _spotTick = tick;
    }

    function setObservationCardinalityNext(uint16 next) external {
        _cardinalityNext = next;
    }

    function setOracleBricked(bool bricked) external {
        _oracleBricked = bricked;
    }

    function setFeeGrowthGlobal(uint256 fee0, uint256 fee1) external {
        feeGrowthGlobal0X128 = fee0;
        feeGrowthGlobal1X128 = fee1;
    }

    function setTickFeeGrowthOutside(int24 tick, uint256 fee0, uint256 fee1) external {
        _feeGrowthOutside[tick] = FeeGrowthOutside({fee0: fee0, fee1: fee1});
    }

    /// @dev Only the two fee growth words carry state; everything else a real pool packs into
    ///      a tick is zero here.
    function ticks(int24 tick)
        external
        view
        returns (
            uint128,
            int128,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56,
            uint160,
            uint32,
            bool
        )
    {
        FeeGrowthOutside memory o = _feeGrowthOutside[tick];
        return (0, 0, o.fee0, o.fee1, 0, 0, 0, false);
    }

    /// @dev Mock-only convenience: the pool's own `Tick.getFeeGrowthInside` over this mock's
    ///      state, at the spot tick, so the NPM mock can checkpoint a position the same way
    ///      the real one does. Wraps on purpose, as the pool's does.
    function feeGrowthInside(int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256 inside0, uint256 inside1)
    {
        FeeGrowthOutside memory lower = _feeGrowthOutside[tickLower];
        FeeGrowthOutside memory upper = _feeGrowthOutside[tickUpper];
        unchecked {
            (uint256 below0, uint256 below1) = _spotTick >= tickLower
                ? (lower.fee0, lower.fee1)
                : (feeGrowthGlobal0X128 - lower.fee0, feeGrowthGlobal1X128 - lower.fee1);
            (uint256 above0, uint256 above1) = _spotTick < tickUpper
                ? (upper.fee0, upper.fee1)
                : (feeGrowthGlobal0X128 - upper.fee0, feeGrowthGlobal1X128 - upper.fee1);
            inside0 = feeGrowthGlobal0X128 - below0 - above0;
            inside1 = feeGrowthGlobal1X128 - below1 - above1;
        }
    }

    /// @dev Constant-tick history: cumulative(t) = tick * t, so any window's arithmetic
    ///      mean equals `_twapTick` exactly.
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        // The revert string a real Uniswap V3 pool uses when the window predates its
        // oldest observation.
        require(!_oracleBricked, "OLD");
        tickCumulatives = new int56[](secondsAgos.length);
        secondsPerLiquidityCumulativeX128s = new uint160[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; i++) {
            uint256 t = block.timestamp - secondsAgos[i];
            // Mock arithmetic on a test timestamp: `t` is a block time the harness sets
            // (vm.warp(30 days) upward), orders of magnitude below the uint56/uint160
            // ceilings, so neither narrowing can truncate here.
            // forge-lint: disable-next-line(unsafe-typecast)
            tickCumulatives[i] = int56(_twapTick) * int56(uint56(t));
            // forge-lint: disable-next-line(unsafe-typecast)
            secondsPerLiquidityCumulativeX128s[i] = uint160(t) << 32;
        }
    }

    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        )
    {
        return (TickMath.getSqrtRatioAtTick(_spotTick), _spotTick, 0, 1, _cardinalityNext, 0, true);
    }

    /// @dev Mirrors the real pool's spacing for the 0.05% fee tier so range-width
    ///      checks and tick alignment behave the same way in unit tests.
    function tickSpacing() external pure returns (int24) {
        return 10;
    }
}
