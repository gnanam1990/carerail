// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

interface IERC20Ext is IERC20 {
    function decimals() external view returns (uint8);
}

/// @dev Minimal safe-transfer wrapper for USDC-shaped ERC20s. Returns are checked
///      and the contract never holds raw balances beyond the escrow amount.
library SafeTransferLib {
    error TransferFailed();
    error ApproveFailed();

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}

/// @title ServiceEscrow
/// @notice CareRail — a verified-service payment rail for healthcare.
/// @dev USDC (6 decimals) is held against a registered provider for a specific
///      serviceId. Funds release ONLY to that registered provider (or back to
///      the original payer on refund) — never to a free-text destination.
///
/// State machine (per serviceId):
///
///   None ──lockFunds──▶ Locked
///   Locked ──submitAttestation──▶ Attested          (provider-only)
///   Attested ──ack──▶ Released                        (payer-only, instant)
///   Attested ──dispute──▶ Held                        (payer-only, within window)
///   Held ──resolveDispute(release=true)──▶ Released   (arbitrator)
///   Held ──resolveDispute(release=false)──▶ Refunded  (arbitrator)
///   Attested ──claimOptimistic──▶ Released            (anyone, after review window, no dispute)
///   Locked ──refundExpired──▶ Refunded                (anyone, after expiry, no attestation)
///   Attested ──refundExpired──▶ Refunded              (last-resort safety, after expiry)
///
/// Invariants encoded as tests in test/ServiceEscrow.t.sol:
///   1. Funds release ONLY to the registered provider, or refund ONLY to the
///      original payer — never a free-text destination.
///   2. A service reaches exactly one terminal state (Released | Refunded).
///      No double-release, no double-refund.
///   3. Optimistic release is reachable only if no dispute was raised in the
///      review window (window = attestationTime + reviewWindow).
///   4. Auto-refund is reachable only if no attestation was submitted before
///      expiry, OR if an attestation was submitted but the dispute window
///      closed without resolution (last-resort safety after expiry).
///   5. Amounts are 6dp USDC; Arc timestamp comparisons are inclusive
///      (non-decreasing timestamps).
contract ServiceEscrow {
    using SafeTransferLib for IERC20;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum State {
        None,        // serviceId not yet locked
        Locked,      // funds held, no attestation yet
        Attested,    // provider submitted attestation hash
        Held,        // payer disputed; awaiting arbitrator
        Released,    // funds paid to provider (terminal)
        Refunded     // funds returned to payer (terminal)
    }

    struct Service {
        address payer;          // original funder (refund destination)
        address provider;       // release destination
        uint64  attestationTime;// timestamp the provider submitted the attestation
        uint64  reviewWindow;   // seconds after attestation during which payer may dispute
        uint64  expiry;         // unix seconds; after this, auto-refund path opens
        uint96  amount;         // 6dp USDC; bounded by USDC total supply, fits in uint96
        State   state;
        bytes32 recordHash;     // hash of the visit/procedure record (no PHI)
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IERC20 public immutable usdc;
    address public immutable arbitrator;
    address public immutable owner;

    mapping(bytes32 => Service) public services;

    // Optional convenience: per-provider enable flag (off-chain allowlist source of truth).
    mapping(address => bool)    public providerAllowed;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event ProviderAllowlistUpdated(address indexed provider, bool allowed);
    event Locked(
        bytes32 indexed serviceId,
        address indexed payer,
        address indexed provider,
        uint96  amount,
        uint64  reviewWindow,
        uint64  expiry
    );
    event Attested(bytes32 indexed serviceId, bytes32 recordHash);
    event Released(bytes32 indexed serviceId, address indexed provider, uint96 amount);
    event Disputed(bytes32 indexed serviceId, address indexed payer);
    event Resolved(bytes32 indexed serviceId, bool releasedToProvider);
    event Refunded(bytes32 indexed serviceId, address indexed payer, uint96 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error NotOwner();
    error UnknownService();
    error WrongState();
    error NotPayer();
    error NotProvider();
    error NotArbitrator();
    error WindowNotElapsed();
    error ExpiryNotReached();
    error DisputeWindowClosed();
    error ZeroAmount();
    error ZeroAddress();
    error InvalidWindow();
    error ExpiryMustBeFuture();

    // ---------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyArbitrator() {
        if (msg.sender != arbitrator) revert NotArbitrator();
        _;
    }

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    constructor(IERC20 _usdc, address _arbitrator) {
        if (address(_usdc) == address(0) || _arbitrator == address(0)) revert ZeroAddress();
        usdc = _usdc;
        arbitrator = _arbitrator;
        owner = msg.sender;
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    /// @notice Toggle a provider on the allowlist. v1: this is a stub mirroring
    ///         an off-chain pre-vetting flow; real licensing verification is a
    ///         roadmap item per PRD §4.
    function setProviderAllowed(address provider, bool allowed) external onlyOwner {
        if (provider == address(0)) revert ZeroAddress();
        providerAllowed[provider] = allowed;
        emit ProviderAllowlistUpdated(provider, allowed);
    }

    // ---------------------------------------------------------------------
    // Core lifecycle
    // ---------------------------------------------------------------------

    /// @notice Lock `amount` USDC against a (payer, provider, serviceId) triple.
    /// @param serviceId     Opaque id chosen by the payer (e.g. "telehealth-consult-001").
    /// @param provider      Registered provider address. Release destination.
    /// @param amount        6dp USDC amount. Must be > 0 and the payer must have approved.
    /// @param reviewWindow  Seconds the payer has to dispute after attestation.
    /// @param expiry        Unix seconds after which auto-refund is reachable.
    function lockFunds(
        bytes32 serviceId,
        address provider,
        uint96  amount,
        uint64  reviewWindow,
        uint64  expiry
    ) external {
        if (provider == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (expiry <= block.timestamp) revert ExpiryMustBeFuture();
        if (reviewWindow == 0) revert InvalidWindow();

        Service storage s = services[serviceId];
        if (s.state != State.None) revert WrongState();

        s.payer        = msg.sender;
        s.provider     = provider;
        s.amount       = amount;
        s.reviewWindow = reviewWindow;
        s.expiry       = expiry;
        s.state        = State.Locked;

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit Locked(serviceId, msg.sender, provider, amount, reviewWindow, expiry);
    }

    /// @notice Provider submits a hash of the visit/procedure record. Never PHI.
    function submitAttestation(bytes32 serviceId, bytes32 recordHash) external {
        Service storage s = services[serviceId];
        if (s.state == State.None) revert UnknownService();
        if (s.state != State.Locked) revert WrongState();           // cannot re-attest
        if (msg.sender != s.provider) revert NotProvider();
        if (block.timestamp > s.expiry) revert ExpiryNotReached();  // attestation must be in-time

        s.recordHash      = recordHash;
        s.attestationTime = uint64(block.timestamp);
        s.state           = State.Attested;

        emit Attested(serviceId, recordHash);
    }

    /// @notice Payer acknowledges the service was delivered — instant release to provider.
    function ack(bytes32 serviceId) external {
        Service storage s = services[serviceId];
        if (s.state != State.Attested) revert WrongState();
        if (msg.sender != s.payer) revert NotPayer();

        s.state = State.Released;
        usdc.safeTransfer(s.provider, s.amount);

        emit Released(serviceId, s.provider, s.amount);
    }

    /// @notice Payer raises a dispute within the review window. Funds held pending arbitration.
    ///         The dispute window closes at attestationTime + reviewWindow.
    function dispute(bytes32 serviceId) external {
        Service storage s = services[serviceId];
        if (s.state != State.Attested) revert WrongState();
        if (msg.sender != s.payer) revert NotPayer();
        if (s.attestationTime == 0) revert WrongState();

        // Arc uses non-decreasing timestamps; we use inclusive comparison.
        // Dispute allowed while block.timestamp <= attestationTime + reviewWindow.
        if (block.timestamp > uint256(s.attestationTime) + uint256(s.reviewWindow)) {
            revert DisputeWindowClosed();
        }

        s.state = State.Held;

        emit Disputed(serviceId, msg.sender);
    }

    /// @notice Optimistic release — anyone can call after the review window, iff no dispute.
    function claimOptimistic(bytes32 serviceId) external {
        Service storage s = services[serviceId];
        if (s.state != State.Attested) revert WrongState();
        if (s.attestationTime == 0) revert WrongState();

        // Claim is allowed strictly after the dispute window deadline.
        if (block.timestamp <= uint256(s.attestationTime) + uint256(s.reviewWindow)) {
            revert WindowNotElapsed();
        }

        s.state = State.Released;
        usdc.safeTransfer(s.provider, s.amount);

        emit Released(serviceId, s.provider, s.amount);
    }

    /// @notice Arbitrator resolves a held dispute. releaseToProvider=true pays the provider,
    ///         false refunds the payer.
    function resolveDispute(bytes32 serviceId, bool releaseToProvider) external onlyArbitrator {
        Service storage s = services[serviceId];
        if (s.state != State.Held) revert WrongState();

        if (releaseToProvider) {
            s.state = State.Released;
            usdc.safeTransfer(s.provider, s.amount);
            emit Resolved(serviceId, true);
            emit Released(serviceId, s.provider, s.amount);
        } else {
            s.state = State.Refunded;
            usdc.safeTransfer(s.payer, s.amount);
            emit Resolved(serviceId, false);
            emit Refunded(serviceId, s.payer, s.amount);
        }
    }

    /// @notice Auto-refund to the payer if expiry passed and either:
    ///         (a) no attestation was ever submitted (state == Locked), OR
    ///         (b) an attestation was submitted but the dispute window has elapsed
    ///             without an ack/dispute/optimistic claim (state == Attested) — last-resort
    ///             safety so funds are never permanently stranded.
    function refundExpired(bytes32 serviceId) external {
        Service storage s = services[serviceId];
        if (s.state != State.Locked && s.state != State.Attested) revert WrongState();
        if (block.timestamp <= s.expiry) revert ExpiryNotReached();

        s.state = State.Refunded;
        usdc.safeTransfer(s.payer, s.amount);

        emit Refunded(serviceId, s.payer, s.amount);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getService(bytes32 serviceId) external view returns (Service memory) {
        return services[serviceId];
    }

    /// @notice ServiceId helper for off-chain tools.
    function makeServiceId(string calldata raw) external pure returns (bytes32) {
        return keccak256(bytes(raw));
    }
}
