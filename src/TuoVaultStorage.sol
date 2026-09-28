// SPDX-License-Identifier: LicenseRef-BUSL-1.1
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {ITuoVault} from "./interfaces/ITuoVault.sol";
import {INonfungiblePositionManager} from "./interfaces/external/INonfungiblePositionManager.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";
import {TuoPositionNFT} from "./TuoPositionNFT.sol";
import {TuoSwapRouter} from "./TuoSwapRouter.sol";
import {TuoConstants} from "./libraries/TuoConstants.sol";

/// @title TuoVaultStorage - types, state and shared state setters for TuoVault
/// @author Tuo Team
/// @dev The reentrancy guard keeps its flag in transient storage, so this deploys only to a
///      chain with EIP-1153: Arbitrum One since ArbOS 20, per foundry.toml's cancun target.
abstract contract TuoVaultStorage is ITuoVault, AccessControl, Pausable, ReentrancyGuardTransient {
    /// @notice Everything the vault knows about one position. This is the struct the
    ///         customer owns; {KeeperBudget} is what the operator has spent against it.
    /// @dev Exposed through {ITuoVault.PositionView}; the storage layout stays internal so
    ///      the packing can change without breaking a consumer.
    struct Position {
        uint16 productCode;
        bool active;
        /// @dev Hyperliquid finality, tracked apart from the nominal `hlMarginBridged`: a
        ///      return can repay the nominal while proceeds are still at the venue. Set by
        ///      every bridgeToHl; cleared only by a final return or by finalizeHlClaim.
        bool hlLifecycleOpen;
        uint40 createdAt;
        uint40 withdrawalRequestedAt;
        uint16 withdrawalSharesBps;
        uint256 basisUsdc;
        uint256 hlMarginBridged;
        /// @dev The four claim fields are the emergency exit's retained accounting: the margin
        ///      that became the claim, what has come back, the on-chain NAV the exit was valued
        ///      at and the fee charged so far. Meaningful only while a claim is open, which is
        ///      `!active && hlLifecycleOpen`: the principal itself may be zero. The fee on each
        ///      return is computed from them, so `basisUsdc` survives until finalization.
        uint256 hlClaimUsdc;
        uint256 hlClaimReturnedUsdc;
        uint256 hlClaimExitNavUsdc;
        uint256 hlClaimFeeChargedUsdc;
        /// @dev The allowlisted operator this position bridged to, written on the FIRST
        ///      bridge and never cleared or rewritten; both inbound legs pull from it.
        ///      Zero until the position bridges. {hlOperatorPositionOf} is the reverse
        ///      record, so the pair is one-to-one.
        address hlOperator;
        uint256[] lpTokenIds;
    }

    /// @notice Leaky-bucket keeper budget for one position, in a single slot.
    /// @dev Both counters refill toward zero over their window, so the SUSTAINED rate is one
    ///      capacity per window. A burst can exceed that inside a closed window, because
    ///      capacity is free again before the call that spent it is a window old: a full
    ///      bucket plus a window of refill is twice capacity. TuoConstants carries the
    ///      figures. Deliberately NOT packed into `Position`: that struct is what the
    ///      customer owns, this is what the operator has spent.
    struct KeeperBudget {
        uint40 updatedAt; // last metered action
        uint56 actionUnits; // KEEPER_ACTION_UNIT per action
        uint96 lossUsdc; // attributed value loss, USDC 6 decimals
    }

    /// @notice Constructor seed for one product; see ITuoVault.Product.
    struct ProductInit {
        uint16 code;
        bytes32 label;
        uint16 maxHedgeBps;
        uint8 maxLpCount;
    }

    /// @notice The whole deployment configuration, in one struct.
    struct InitConfig {
        address usdc;
        address weth;
        address positionManager;
        address[] hlOperators;
        address treasury;
        address keeper;
        address pauser;
        address[] pools;
        address[] depositTokens;
        address[] aggregators;
        ProductInit[] products;
        uint256 perNftCapUsdc;
        uint16 keeperSwapSlippageBps;
        string nftBaseURI;
    }

    IERC20 public immutable USDC;
    IWETH9 public immutable WETH;
    INonfungiblePositionManager public immutable POSITION_MANAGER;
    // forge-lint: disable-next-line(mixed-case-variable)
    TuoPositionNFT public NFT; // solhint-disable-line var-name-mixedcase
    // forge-lint: disable-next-line(mixed-case-variable)
    TuoSwapRouter public SWAP_ROUTER; // solhint-disable-line var-name-mixedcase

    mapping(uint256 nftId => Position position) internal _positions;
    mapping(uint256 nftId => mapping(address token => uint256 amount) idleByToken) internal _idle;
    mapping(uint256 nftId => KeeperBudget budget) internal _keeperBudget;
    mapping(uint16 productCode => Product product) internal _products;

    mapping(uint256 lpTokenId => uint256 nftId) public lpOwnerOf;
    mapping(uint256 lpTokenId => address pool) public lpPoolOf;

    mapping(address pool => bool allowed) internal _allowedPools;
    mapping(address token => address pool) internal _valuationPools;
    mapping(address token => bool allowed) internal _depositTokens;
    address[] internal _poolTokens; // every non-USDC token an allowlisted pool trades

    uint256 public nextNftId = 1;
    uint256 public perNftCapUsdc;
    address public feeRecipient;
    /// @notice Tolerance under the mean-tick quote for the keeper's idle swaps, in bps. Set by
    ///         the treasury, at most TuoConstants.MAX_KEEPER_SWAP_SLIPPAGE_BPS. The owner's exit
    ///         floor is the compiled EXIT_FLOOR_BPS and does not follow it.
    uint16 public keeperSwapSlippageBps;

    /// @notice The addresses bridged margin may leave toward (Tuo's KMS-held HL operator
    ///         EOAs). Hyperliquid's bridge credits the *sending* address and contract
    ///         addresses cannot sign HL actions, so the vault cannot deposit to the
    ///         bridge itself without stranding funds; it pays an EOA that then does.
    /// @dev Seeded by the constructor and maintained by setHlOperator (TuoVaultAdmin
    ///      layer). This is the destination gate only: which position an operator serves
    ///      is fixed by {hlOperatorPositionOf}, never by the allowlist bit.
    mapping(address operator => bool allowed) public isHlOperator;

    /// @notice The position an operator is bound to, zero while unbound. Written once by
    ///         the first bridge toward it and never cleared: retiring the operator, settling
    ///         the position home, finalizing its claim or burning its NFT all leave the
    ///         record in place, so an operator serves one position in its whole life. The inbound legs credit the
    ///         named position with whatever its operator returns, which is only safe when
    ///         nothing else ever sat there.
    mapping(address operator => uint256 nftId) public hlOperatorPositionOf;

    /// @notice Performance fees taken from positions and not yet claimed by the treasury,
    ///         per token. Held by the vault and deliberately NOT attributed to any
    ///         position: `token.balanceOf(vault) == sum(idle) + accruedTokenFees[token]`.
    /// @dev Per token rather than USDC-only because {ITuoVault.emergencyWithdraw} pays out
    ///      in kind and so must withhold its fee in kind - charging it against the USDC leg
    ///      alone let a position holding its value in a pool token exit paying nothing.
    ///      Pull payment; {ITuoVault.claimFees} explains why the fee is never pushed inside
    ///      an exit: the customer's exit must not depend on Tuo's own ability to receive
    ///      funds.
    mapping(address token => uint256 amount) public accruedTokenFees;

    /// @dev An immutable must be assigned in the constructor of its declaring contract,
    ///      so the three immutable system bindings are seeded here; everything else,
    ///      including the zero-address checks that would abort the deployment, stays in
    ///      the TuoVault constructor.
    constructor(address usdc, address weth, address positionManager) {
        USDC = IERC20(usdc);
        WETH = IWETH9(weth);
        POSITION_MANAGER = INonfungiblePositionManager(positionManager);
    }

    /// @dev Shared by the constructor seed and {setHlOperator}. Idempotent: a no-op write
    ///      emits nothing, so an indexer never sees a state change that did not happen.
    ///      Touches the allowlist bit only; {hlOperatorPositionOf} is never written here.
    function _setHlOperator(address operator, bool allowed) internal {
        if (operator == address(0)) revert ZeroAddress();
        // An operator is paid by {ITuoVault.bridgeToHl} and pulled from by both inbound legs,
        // so it has to be an account that can hold USDC and approve the vault. None of the
        // three protocol-owned contracts can approve one: a bridge to the vault itself debits
        // the position and records the margin while transferring nothing, and the inbound
        // `safeTransferFrom` then has no allowance to draw on. One-directional on purpose -
        // retirement is never refused, so this can never freeze the allowlist it protects.
        if (allowed) _requireNotProtocolOwned(operator);
        if (isHlOperator[operator] == allowed) return;
        isHlOperator[operator] = allowed;
        emit HlOperatorUpdated(operator, allowed);
    }

    /// @dev Shared by the constructor seed and {setKeeperSwapSlippageBps}.
    function _setKeeperSwapSlippageBps(uint16 bps) internal {
        if (bps > TuoConstants.MAX_KEEPER_SWAP_SLIPPAGE_BPS) revert InvalidKeeperSwapSlippage();
        keeperSwapSlippageBps = bps;
        emit KeeperSwapSlippageUpdated(bps);
    }

    function _registerProduct(uint16 productCode, bytes32 label, uint16 maxHedgeBps, uint8 maxLpCount) internal {
        if (productCode == 0) revert InvalidProductCode(productCode);
        if (label == bytes32(0)) revert InvalidProductCode(productCode);
        if (_products[productCode].label != bytes32(0)) {
            revert ProductAlreadyRegistered(productCode);
        }
        if (maxHedgeBps > TuoConstants.BPS_DENOMINATOR) {
            revert InvalidProductCode(productCode);
        }
        // The upper bound is the emergency exit's: it closes every open LP in one
        // transaction and each closure scans the LP array, so an unbounded ceiling here
        // could put the customer's guaranteed exit past a block.
        if (maxLpCount == 0 || maxLpCount > TuoConstants.MAX_LP_COUNT) {
            revert InvalidProductCode(productCode);
        }

        _products[productCode] =
            Product({label: label, openForDeposits: true, maxHedgeBps: maxHedgeBps, maxLpCount: maxLpCount});
        emit ProductRegistered(productCode, label, maxHedgeBps, maxLpCount);
    }

    /// @dev The three addresses the protocol owns: the vault, its position NFT, its swap
    ///      router. None can approve a spender, and the only balance any of them pays out is
    ///      the router's measured swap delta back to the vault, so naming one as a payee
    ///      orphans whatever is sent to it. Shared by {TuoVaultAdmin.setFeeRecipient} and
    ///      {_setHlOperator} so the comparison and its revert are emitted once.
    function _requireNotProtocolOwned(address account) internal view {
        if (account == address(this) || account == address(NFT) || account == address(SWAP_ROUTER)) {
            revert ProtocolOwnedAddress(account);
        }
    }
}
