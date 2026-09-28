// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PerformanceFee} from "../../src/libraries/PerformanceFee.sol";

/// @dev The four worked examples are normative: the fee specification requires the
///      results to match to the cent. Figures are USDC 6-decimals.
contract PerformanceFeeTest is Test {
    uint256 internal constant USDC = 1e6;

    function test_FullWithdrawalWithProfit() public pure {
        // Basis $10,000 / NAV $13,000 / withdraw 100% -> fee $900, net $12,100.
        (uint256 gross, uint256 fee, uint256 net) = PerformanceFee.quote(10_000 * USDC, 13_000 * USDC, 10_000);
        assertEq(gross, 13_000 * USDC);
        assertEq(fee, 900 * USDC);
        assertEq(net, 12_100 * USDC);
    }

    function test_FullWithdrawalWithLoss() public pure {
        // Basis $10,000 / NAV $8,500 / withdraw 100% -> fee $0, net $8,500.
        (uint256 gross, uint256 fee, uint256 net) = PerformanceFee.quote(10_000 * USDC, 8_500 * USDC, 10_000);
        assertEq(gross, 8_500 * USDC);
        assertEq(fee, 0);
        assertEq(net, 8_500 * USDC);
    }

    function test_PartialWithdrawalWithProfit() public pure {
        // Basis $10,000 / NAV $13,000 / withdraw 50% -> gross $6,500, fee $450, net $6,050.
        (uint256 gross, uint256 fee, uint256 net) = PerformanceFee.quote(10_000 * USDC, 13_000 * USDC, 5_000);
        assertEq(gross, 6_500 * USDC);
        assertEq(fee, 450 * USDC);
        assertEq(net, 6_050 * USDC);
        // Basis reduces pro-rata to $5,000.
        assertEq(PerformanceFee.reducedBasis(10_000 * USDC, 5_000), 5_000 * USDC);
    }

    function test_PartialWithdrawalWithLoss() public pure {
        // Basis $10,000 / NAV $8,500 / withdraw 50% -> gross $4,250, fee $0, net $4,250.
        (uint256 gross, uint256 fee, uint256 net) = PerformanceFee.quote(10_000 * USDC, 8_500 * USDC, 5_000);
        assertEq(gross, 4_250 * USDC);
        assertEq(fee, 0);
        assertEq(net, 4_250 * USDC);
        assertEq(PerformanceFee.reducedBasis(10_000 * USDC, 5_000), 5_000 * USDC);
    }

    function test_BreakEvenChargesNoFee() public pure {
        (, uint256 fee,) = PerformanceFee.quote(10_000 * USDC, 10_000 * USDC, 10_000);
        assertEq(fee, 0);
    }

    function test_ZeroNavQuotesZero() public pure {
        (uint256 gross, uint256 fee, uint256 net) = PerformanceFee.quote(10_000 * USDC, 0, 10_000);
        assertEq(gross, 0);
        assertEq(fee, 0);
        assertEq(net, 0);
    }

    function test_FeeRoundsDownInUsersFavor() public pure {
        // Profit of 1 unit (1e-6 USDC), 100%: fee floor(1 * 0.3) = 0.
        (, uint256 fee,) = PerformanceFee.quote(0, 1, 10_000);
        assertEq(fee, 0);
        // Profit of 3 units, 100%: fee floor(0.9) = 0; profit of 4 -> floor(1.2) = 1.
        (, fee,) = PerformanceFee.quote(0, 3, 10_000);
        assertEq(fee, 0);
        (, fee,) = PerformanceFee.quote(0, 4, 10_000);
        assertEq(fee, 1);
    }

    function test_FullWithdrawalReducesBasisToZero() public pure {
        assertEq(PerformanceFee.reducedBasis(10_000 * USDC, 10_000), 0);
    }

    /// @dev gross == fee + net by construction, fee only on profit, fee never exceeds
    ///      30% of the withdrawn share, basis reduction is monotone.
    function testFuzz_QuoteInvariants(uint256 basis, uint256 nav, uint16 sharesBps) public pure {
        basis = bound(basis, 0, 1e18); // up to $1T in USDC 6-decimals
        nav = bound(nav, 0, 1e18);
        sharesBps = uint16(bound(sharesBps, 1, 10_000));

        (uint256 gross, uint256 fee, uint256 net) = PerformanceFee.quote(basis, nav, sharesBps);

        assertEq(gross, fee + net, "gross must equal fee + net");
        assertLe(gross, nav, "gross cannot exceed NAV");
        if (nav <= basis) {
            assertEq(fee, 0, "no fee without profit");
        } else {
            // Fee never exceeds 30% of the withdrawn profit share (flooring only shrinks it).
            uint256 profitShareCeil = ((nav - basis) * sharesBps) / 10_000 + 1;
            assertLe(fee, (profitShareCeil * 3_000) / 10_000, "fee above 30% of profit share");
        }

        uint256 newBasis = PerformanceFee.reducedBasis(basis, sharesBps);
        assertLe(newBasis, basis, "basis must not grow");
        if (sharesBps == 10_000) assertEq(newBasis, 0, "full exit clears basis");
    }
}
