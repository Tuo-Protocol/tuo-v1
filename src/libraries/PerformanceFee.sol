// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

import {TuoConstants} from "./TuoConstants.sol";

/// @title PerformanceFee - stateless 30%-of-profit fee math
/// @author Tuo Team
/// @notice The fee applies to the withdrawn share of profit only, never to deposited
///         capital. Profit is settlement NAV minus basis; a partial withdrawal charges
///         the pro-rata share and reduces basis pro-rata, which acts as an automatic
///         high-water mark across re-deposits.
/// @dev All figures are USDC with 6 decimals. Division floors throughout; the fee is
///      computed in a single mul/div chain so no intermediate flooring inflates it,
///      and net is defined as gross - fee so gross == fee + net holds exactly.
library PerformanceFee {
    uint256 private constant BPS = TuoConstants.BPS_DENOMINATOR;

    /// @notice Quote a withdrawal of `sharesBps` of a position.
    /// @param basisUsdc remaining deposited-capital basis
    /// @param navUsdc settlement NAV of the whole position
    /// @param sharesBps share being withdrawn, 1..10_000
    /// @return grossUsdc NAV share being withdrawn
    /// @return feeUsdc 30% of the withdrawn profit share (0 when navUsdc <= basisUsdc)
    /// @return netUsdc amount owed to the position owner
    function quote(uint256 basisUsdc, uint256 navUsdc, uint16 sharesBps)
        internal
        pure
        returns (uint256 grossUsdc, uint256 feeUsdc, uint256 netUsdc)
    {
        grossUsdc = (navUsdc * sharesBps) / BPS;
        if (navUsdc > basisUsdc) {
            feeUsdc = ((navUsdc - basisUsdc) * sharesBps * TuoConstants.PERFORMANCE_FEE_BPS) / (BPS * BPS);
        }
        netUsdc = grossUsdc - feeUsdc;
    }

    /// @notice Pro-rata basis remaining after withdrawing `sharesBps`.
    /// @dev Reducing basis in step with the withdrawal is what makes the fee an automatic
    ///      high-water mark: profit already charged for cannot be charged for again.
    /// @param basisUsdc the position's basis before the withdrawal
    /// @param sharesBps share being withdrawn, 1..10_000
    /// @return the basis remaining afterwards
    function reducedBasis(uint256 basisUsdc, uint16 sharesBps) internal pure returns (uint256) {
        return basisUsdc - (basisUsdc * sharesBps) / BPS;
    }
}
