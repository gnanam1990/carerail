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
/// Release model (v2 — threshold-gated optimistic release):
///   The constructor sets an immutable `ackThreshold` (USDC micro-units). A
///   service whose locked `amount` is <= ackThreshold keeps the v1 optimistic
///   flow: after the review window with no dispute, anyone may call
///   claimOptimistic to release to the provider. A service whose amount is
///   ABOVE the threshold CANNOT be released optimistically — the provider's
///   self-attestation alone is insufficient for a high-value claim. Such a
///   service reaches `Released` only via payer `ack` or arbitrator
///   `resolveDispute(release=true)` after a payer `dispute`. If the payer
///   neither acks nor disputes, the funds remain locked until `expiry`, after
///   which `refundExpired` returns them to the payer — the patient's silence
///   never pays the provider above the threshold.
///
/// State machine (per serviceId):
///
///   None ──lockFunds──▶ Locked
///   Locked ──submitAttestation──▶ Attested          (provider-only)
///   Attested ──ack──▶ Released                        (payer-only, instant)
///   Attested ──dispute──▶ Held                        (payer-only, within window)
///   Held ──resolveDispute(release=true)──▶ Released   (arbitrator)
///   Held ──resolveDispute(release=false)──▶ Refunded  (arbitrator)
///   Attested ──claimOptimistic──▶ Released            (anyone, after review
///                              window, no dispute, AND amount <= ackThreshold)
///   Locked ──refundExpired──▶ Refunded                (anyone, after expiry)
///   Attested ──refundExpired──▶ Refunded              (anyone, after expiry;
///                              for above-threshold services this is the
///                              patient-silence path — payer recovers funds)
///
/// Risk allocation (above threshold): the contract protects the PATIENT and
/// does NOT protect the provider. On payer silence, refundExpired returns the
/// full amount to the payer — the payer keeps both any care already delivered
/// and the funds; the patient has no skin in the game in the silent case.
/// `dispute` is payer-only, so a provider who delivered care to a silent payer
/// has NO on-chain recourse in this version: they cannot force release or
/// force arbitration. Providers must require `ack` before delivering
/// high-value care, or rely on off-chain remedies. (Future item, NOT in v2:
/// provider-initiated escalation Attested→Held after the window, so an
/// unacked-but-delivered claim can be adjudicated instead of refunded.)
///
/// Threshold-split vector (known, accepted): ackThreshold is checked per
/// serviceId, so a high-value obligation split into many sub-threshold locks
/// is fully optimistically releasable. A provider cannot split unilaterally —
/// lockFunds is payer-initiated (payer picks serviceId + amount, signs the
/// transferFrom). Residual risk is a payer who doesn't understand the
/// threshold being talked into splitting. A per-provider rolling-window
/// aggregate would close it structurally but is a larger change than this
/// fix warrants; recorded as a future item, not implemented.
///
/// Provider allowlist: NOT enforced on-chain. v1 vetting is an off-chain concern
/// (see services/providers.json + services/attest.ts). The contract's control is
/// `msg.sender == s.provider` for submitAttestation; the payer chooses the
/// provider address at lockFunds and bears the vetting responsibility. There is
/// deliberately no on-chain allowlist mapping: a control that looks live but is
/// never read is worse than none. See docs/PRD.md §4.
///
/// Invariants encoded as tests in test/ServiceEscrow.t.sol:
///   1. Funds release ONLY to the registered provider, or refund ONLY to the
///      original payer — never a free-text destination.
///   2. A service reaches exactly one terminal state (Released | Refunded).
///      No double-release, no double-refund.
///   3. Optimistic release is reachable only if (a) no dispute was raised in
///      the review window AND (b) amount <= ackThreshold. Above-threshold
///      services can never be optimistically released.
///   4. Auto-refund is reachable only if no attestation was submitted before
///      expiry, OR an attestation was submitted but not acked/disputed and
///      expiry has passed (last-resort safety; for above-threshold services
///      this is the payer-silence recovery path).
///   5. Amounts are 6dp USDC; reviewWindow has a floor of MIN_REVIEW_WINDOW;
///      Arc timestamp comparisons are inclusive (non-decreasing timestamps).
contract ServiceEscrow {
    using SafeTransferLib for IERC20;

    /// @dev Floor for the payer-set review window. A window shorter than this is
    ///      not a real defence — the patient would have no time to notice the
    ///      attestation and act — so lockFunds refuses it. 3 days balances a
    ///      genuine dispute opportunity against settlement speed for micro-claims.
    uint64 public constant MIN_REVIEW_WINDOW = 3 days;

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

    /// @dev Services with amount > ackThreshold cannot be released via
    ///      claimOptimistic. Set once at construction. 0 disables optimistic
    ///      release for every service (strict mode).
    uint96 public immutable ackThreshold;

    mapping(bytes32 => Service) public services;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

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
    error ExpiryMustBeFuture();
    error ReviewWindowTooShort();
    error OptimisticReleaseBlocked(); // amount > ackThreshold

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    constructor(IERC20 _usdc, address _arbitrator, uint96 _ackThreshold) {
        if (address(_usdc) == address(0) || _arbitrator == address(0)) revert ZeroAddress();
        usdc = _usdc;
        arbitrator = _arbitrator;
        ackThreshold = _ackThreshold; // 0 is allowed => strict mode (no optimistic release)
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
        if (reviewWindow < MIN_REVIEW_WINDOW) revert ReviewWindowTooShort();

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
    /// @dev On-chain allowlisting is intentionally NOT enforced here — vetting is
    ///      off-chain (see docs). The contract gates on msg.sender == s.provider,
    ///      i.e. the provider address the payer chose at lockFunds.
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

    /// @notice Optimistic release — anyone can call after the review window, iff
    ///         no dispute AND the service amount is at or below ackThreshold.
    ///         Above-threshold services revert: high-value release requires payer
    ///         ack or arbitrator resolution, never provider self-release.
    function claimOptimistic(bytes32 serviceId) external {
        Service storage s = services[serviceId];
        if (s.state != State.Attested) revert WrongState();
        if (s.attestationTime == 0) revert WrongState();

        // High-value services are exempt from optimistic release by design.
        if (uint256(s.amount) > uint256(ackThreshold)) revert OptimisticReleaseBlocked();

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
    function resolveDispute(bytes32 serviceId, bool releaseToProvider) external {
        if (msg.sender != arbitrator) revert NotArbitrator();
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
    ///         (b) an attestation was submitted but not acked/disputed and expiry
    ///             has elapsed (state == Attested) — last-resort safety so funds
    ///             are never permanently stranded. For above-threshold services
    ///             this is the payer-silence recovery path: if the patient neither
    ///             acked nor disputed, the patient recovers the funds after expiry.
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
