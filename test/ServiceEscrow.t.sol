// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ServiceEscrow} from "../src/ServiceEscrow.sol";

/// @notice Minimal USDC-like mock. 6 decimals, plain ERC20.
contract MockUSDC is IERC20 {
    string public override name = "USD Coin";
    string public override symbol = "USDC";
    uint8  public override decimals = 6;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}

contract ServiceEscrowTest is Test {
    ServiceEscrow public escrow;
    MockUSDC      public usdc;

    address public payer;
    address public provider;
    address public arbitrator;
    address public attacker;

    bytes32 public constant SID = keccak256("telehealth-consult-001");

    uint64  public reviewWindow = 7 days;
    uint64  public expiry;
    uint96  public amount = 40_000_000; // 40.00 USDC (6dp) — below ackThreshold
    uint96  public ackThreshold = 50_000_000; // 50.00 USDC; amount (40) stays under it

    function setUp() public {
        usdc       = new MockUSDC();
        arbitrator = makeAddr("arbitrator");
        escrow     = new ServiceEscrow(usdc, arbitrator, ackThreshold);

        payer    = makeAddr("payer");
        provider = makeAddr("provider");
        attacker = makeAddr("attacker");

        // Mint test funds and approve the escrow for the payer.
        usdc.mint(payer, 1_000_000_000_000); // 1B USDC
        vm.prank(payer);
        usdc.approve(address(escrow), type(uint256).max);

        // Use a future expiry so lockFunds succeeds.
        expiry = uint64(block.timestamp + 30 days);
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    function _lock(address _payer, address _provider, uint96 _amount, uint64 _window, uint64 _exp) internal {
        vm.prank(_payer);
        escrow.lockFunds(SID, _provider, _amount, _window, _exp);
    }

    // -----------------------------------------------------------------------
    // Invariant 1: funds release ONLY to registered provider / refund ONLY to payer
    // -----------------------------------------------------------------------

    function test_invariant1_releaseGoesToRegisteredProvider() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));

        vm.prank(payer);
        escrow.ack(SID);

        // Funds left escrow and went to the registered provider.
        assertEq(usdc.balanceOf(provider), amount, "provider did not receive funds");
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow still holds funds");
        assertEq(uint256(escrow.getService(SID).state), uint256(ServiceEscrow.State.Released));
    }

    function test_invariant1_refundGoesToOriginalPayer() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        // No attestation; jump past expiry.
        vm.warp(expiry + 1);
        escrow.refundExpired(SID);

        assertEq(usdc.balanceOf(payer), 1_000_000_000_000, "payer did not get refund");
        assertEq(uint256(escrow.getService(SID).state), uint256(ServiceEscrow.State.Refunded));
    }

    function test_invariant1_cannotPayoutToAttacker() public {
        // Attacker cannot trick any function into paying them: the only release path
        // goes through usdc.safeTransfer(s.provider, ...) using the registered provider.
        _lock(payer, provider, amount, reviewWindow, expiry);

        // Attacker tries ack, dispute, claimOptimistic, resolveDispute — none should pay them.
        vm.prank(attacker);
        vm.expectRevert(ServiceEscrow.WrongState.selector);
        escrow.ack(SID);

        vm.prank(attacker);
        vm.expectRevert(ServiceEscrow.WrongState.selector);
        escrow.dispute(SID);

        vm.prank(attacker);
        vm.expectRevert(ServiceEscrow.WrongState.selector);
        escrow.claimOptimistic(SID);

        vm.prank(attacker);
        vm.expectRevert(ServiceEscrow.NotArbitrator.selector);
        escrow.resolveDispute(SID, true);

        // No funds moved to attacker.
        assertEq(usdc.balanceOf(attacker), 0, "attacker somehow received funds");
        assertEq(usdc.balanceOf(payer), 1_000_000_000_000 - amount, "payer was debited twice");
    }

    function test_invariant1_arbitratorResolutionPaysExactlyOneParty() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));
        vm.prank(payer);
        escrow.dispute(SID);

        uint256 payerBefore = usdc.balanceOf(payer);
        uint256 providerBefore = usdc.balanceOf(provider);

        vm.prank(arbitrator);
        escrow.resolveDispute(SID, true);
        assertEq(usdc.balanceOf(provider), providerBefore + amount, "provider not paid");
        assertEq(usdc.balanceOf(payer), payerBefore, "payer balance changed");

        // Cannot resolve twice.
        vm.prank(arbitrator);
        vm.expectRevert(ServiceEscrow.WrongState.selector);
        escrow.resolveDispute(SID, false);
    }

    // -----------------------------------------------------------------------
    // Invariant 2: state machine — exactly one terminal state, no double-release
    // -----------------------------------------------------------------------

    function test_invariant2_ackAfterOptimisticClaim_reverts() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));

        // Fast-forward past the dispute window.
        vm.warp(block.timestamp + reviewWindow + 1);
        escrow.claimOptimistic(SID);

        // ack after optimistic release must revert (state is Released, not Attested).
        vm.prank(payer);
        vm.expectRevert(ServiceEscrow.WrongState.selector);
        escrow.ack(SID);
    }

    function test_invariant2_disputeThenClaimOptimistic_reverts() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));
        vm.prank(payer);
        escrow.dispute(SID);

        // State is Held. Even after the review window, optimistic claim must not be reachable.
        vm.warp(block.timestamp + reviewWindow + 10);
        vm.expectRevert(ServiceEscrow.WrongState.selector);
        escrow.claimOptimistic(SID);
    }

    function test_invariant2_refundExpiredOnReleased_reverts() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));
        vm.prank(payer);
        escrow.ack(SID);

        vm.warp(expiry + 1);
        vm.expectRevert(ServiceEscrow.WrongState.selector);
        escrow.refundExpired(SID);
    }

    // -----------------------------------------------------------------------
    // Invariant 3: optimistic release only if no dispute was raised
    // -----------------------------------------------------------------------

    function test_invariant3_optimisticReleaseBeforeWindow_reverts() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));

        // Same block as attestation: claimOptimistic must revert (window not elapsed).
        vm.expectRevert(ServiceEscrow.WindowNotElapsed.selector);
        escrow.claimOptimistic(SID);
    }

    function test_invariant3_optimisticReleaseAfterWindow_pays() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));

        uint256 providerBefore = usdc.balanceOf(provider);
        vm.warp(block.timestamp + reviewWindow + 1);
        escrow.claimOptimistic(SID);

        assertEq(usdc.balanceOf(provider), providerBefore + amount, "provider not paid");
        assertEq(uint256(escrow.getService(SID).state), uint256(ServiceEscrow.State.Released));
    }

    function test_invariant3_disputeAfterWindow_reverts() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));

        vm.warp(block.timestamp + reviewWindow + 1);
        vm.prank(payer);
        vm.expectRevert(ServiceEscrow.DisputeWindowClosed.selector);
        escrow.dispute(SID);
    }

    // -----------------------------------------------------------------------
    // Invariant 4: auto-refund only if no attestation (or last-resort after expiry)
    // -----------------------------------------------------------------------

    function test_invariant4_refundExpiredBeforeExpiry_reverts() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        // Same block: not yet expired.
        vm.expectRevert(ServiceEscrow.ExpiryNotReached.selector);
        escrow.refundExpired(SID);
    }

    function test_invariant4_refundExpiredAfterExpiry_noAttestation_pays() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        uint256 payerBefore = usdc.balanceOf(payer);

        vm.warp(expiry + 1);
        escrow.refundExpired(SID);

        assertEq(usdc.balanceOf(payer), payerBefore + amount, "payer not refunded");
        assertEq(uint256(escrow.getService(SID).state), uint256(ServiceEscrow.State.Refunded));
    }

    function test_invariant4_attestationAfterExpiry_reverts() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.warp(expiry + 1);
        vm.prank(provider);
        vm.expectRevert(ServiceEscrow.ExpiryNotReached.selector);
        escrow.submitAttestation(SID, keccak256("record"));
    }

    function test_invariant4_attestationPayerAcked_thenExpiry_refundReverts() public {
        // If a service was acknowledged before expiry, the contract is in Released and
        // refundExpired must not move it.
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));
        vm.prank(payer);
        escrow.ack(SID);
        vm.warp(expiry + 1);
        vm.expectRevert(ServiceEscrow.WrongState.selector);
        escrow.refundExpired(SID);
    }

    // -----------------------------------------------------------------------
    // Invariant 5: 6dp amounts; inclusive timestamp comparisons
    // -----------------------------------------------------------------------

    function test_invariant5_zeroAmount_reverts() public {
        vm.prank(payer);
        vm.expectRevert(ServiceEscrow.ZeroAmount.selector);
        escrow.lockFunds(SID, provider, 0, reviewWindow, expiry);
    }

    function test_invariant5_pastExpiry_reverts() public {
        vm.prank(payer);
        vm.expectRevert(ServiceEscrow.ExpiryMustBeFuture.selector);
        escrow.lockFunds(SID, provider, amount, reviewWindow, uint64(block.timestamp));
    }

    function test_invariant5_inclusiveTimestamp_windowBoundaryOptimistic() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));
        uint256 attestationTime = block.timestamp;

        // At exactly attestationTime + reviewWindow, claimOptimistic must still revert
        // (we use strict > in the contract for the post-window check).
        vm.warp(attestationTime + reviewWindow);
        vm.expectRevert(ServiceEscrow.WindowNotElapsed.selector);
        escrow.claimOptimistic(SID);

        // One second later: succeeds.
        vm.warp(attestationTime + reviewWindow + 1);
        escrow.claimOptimistic(SID);
        assertEq(uint256(escrow.getService(SID).state), uint256(ServiceEscrow.State.Released));
    }

    function test_invariant5_inclusiveTimestamp_windowBoundaryDispute() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));
        uint256 attestationTime = block.timestamp;

        // At exactly the boundary, dispute is still allowed (inclusive).
        vm.warp(attestationTime + reviewWindow);
        vm.prank(payer);
        escrow.dispute(SID);
        assertEq(uint256(escrow.getService(SID).state), uint256(ServiceEscrow.State.Held));

        // Different service to confirm one second past boundary reverts.
        bytes32 sid2 = keccak256("telehealth-consult-002");
        vm.prank(payer);
        escrow.lockFunds(sid2, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(sid2, keccak256("record2"));
        vm.warp(block.timestamp + reviewWindow + 1);
        vm.prank(payer);
        vm.expectRevert(ServiceEscrow.DisputeWindowClosed.selector);
        escrow.dispute(sid2);
    }

    // -----------------------------------------------------------------------
    // Authorization edge cases
    // -----------------------------------------------------------------------

    function test_onlyProviderCanAttest() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(attacker);
        vm.expectRevert(ServiceEscrow.NotProvider.selector);
        escrow.submitAttestation(SID, keccak256("record"));
    }

    function test_onlyPayerCanAckOrDispute() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));

        vm.prank(attacker);
        vm.expectRevert(ServiceEscrow.NotPayer.selector);
        escrow.ack(SID);

        vm.prank(attacker);
        vm.expectRevert(ServiceEscrow.NotPayer.selector);
        escrow.dispute(SID);
    }

    function test_doubleLockSameServiceId_reverts() public {
        _lock(payer, provider, amount, reviewWindow, expiry);
        vm.prank(payer);
        vm.expectRevert(ServiceEscrow.WrongState.selector);
        escrow.lockFunds(SID, provider, amount, reviewWindow, expiry);
    }

    // -----------------------------------------------------------------------
    // Conservation fuzz: every lock ends in exactly one terminal state, funds
    // never stranded. We model a random walk of (attest?, ack/dispute/optimistic
    // or refundExpired) and assert escrow.balance == 0 after resolution and
    // the service is in a terminal state.
    // -----------------------------------------------------------------------

    function testFuzz_conservation_randomWalk(
        bool _attest,
        bool _disputeAfterAttest,
        bool _optimisticClaim,
        bool _refundExpiredPath,
        uint64 _warpDelta
    ) public {
        _warpDelta = uint64(bound(_warpDelta, 0, 60 days));
        uint256 payerStart    = usdc.balanceOf(payer);
        uint256 providerStart = usdc.balanceOf(provider);

        _lock(payer, provider, amount, reviewWindow, expiry);

        if (_attest) {
            // Make sure the attestation is in-time.
            uint64 delta = _warpDelta > expiry - uint64(block.timestamp)
                ? (expiry - uint64(block.timestamp))
                : _warpDelta;
            if (delta > 0) vm.warp(block.timestamp + delta);

            vm.prank(provider);
            try escrow.submitAttestation(SID, keccak256("record")) {
                // success
            } catch {
                // attestation failed (e.g., past expiry) — fall through to refundExpiredPath
                if (_refundExpiredPath) {
                    vm.warp(expiry + 1);
                    escrow.refundExpired(SID);
                }
                _assertConservation(payerStart, providerStart);
                return;
            }

            if (_disputeAfterAttest) {
                // Dispute at exactly attestation time is allowed.
                vm.prank(payer);
                try escrow.dispute(SID) {
                    // resolved by arbitrator: randomly pick release or refund.
                    vm.prank(arbitrator);
                    bool releaseToProvider = (uint256(keccak256(abi.encode(_warpDelta))) & 1) == 1;
                    escrow.resolveDispute(SID, releaseToProvider);
                } catch {
                    // dispute window already closed; try optimistic
                    vm.warp(block.timestamp + reviewWindow + 1);
                    try escrow.claimOptimistic(SID) {} catch {}
                }
            } else if (_optimisticClaim) {
                vm.warp(block.timestamp + reviewWindow + 1);
                try escrow.claimOptimistic(SID) {} catch {}
            } else if (_refundExpiredPath) {
                vm.warp(expiry + 1);
                try escrow.refundExpired(SID) {} catch {}
            } else {
                // ack
                vm.prank(payer);
                try escrow.ack(SID) {} catch {}
            }
        } else {
            if (_refundExpiredPath) {
                vm.warp(expiry + 1);
                escrow.refundExpired(SID);
            } else {
                // No resolution attempted; assert still Locked and funds in escrow.
                ServiceEscrow.Service memory s = escrow.getService(SID);
                assertEq(uint256(s.state), uint256(ServiceEscrow.State.Locked));
                assertEq(usdc.balanceOf(address(escrow)), amount, "escrow should still hold funds");
                return;
            }
        }

        _assertConservation(payerStart, providerStart);
    }

    function _assertConservation(uint256 payerStart, uint256 providerStart) internal view {
        ServiceEscrow.Service memory s = escrow.getService(SID);
        // Must be in a terminal state.
        assertTrue(
            s.state == ServiceEscrow.State.Released || s.state == ServiceEscrow.State.Refunded,
            "service not in a terminal state"
        );
        // Escrow must hold zero funds for this service.
        assertEq(usdc.balanceOf(address(escrow)), 0, "escrow still holds funds");

        if (s.state == ServiceEscrow.State.Released) {
            // Payer was debited `amount` at lock; provider should now have +amount net of start.
            assertEq(
                usdc.balanceOf(provider),
                providerStart + amount,
                "provider did not receive amount"
            );
            assertEq(
                usdc.balanceOf(payer),
                payerStart - amount,
                "payer balance changed incorrectly after release"
            );
        } else {
            // Refunded: payer should be back to start, provider untouched.
            assertEq(usdc.balanceOf(payer), payerStart, "payer not fully refunded");
            assertEq(usdc.balanceOf(provider), providerStart, "provider should not have been paid");
        }
    }

    // -----------------------------------------------------------------------
    // ackThreshold — optimistic release gating (the release-model fix)
    // -----------------------------------------------------------------------

    /// @dev The exact case that had NO coverage before the fix: an above-threshold
    ///      service where the provider attests and the payer is silent. The provider
    ///      must NOT be able to release funds by waiting out the window.
    function test_aboveThreshold_optimisticRelease_reverts() public {
        uint96 big = 100_000_000; // 100.00 USDC > ackThreshold (50.00)
        _lock(payer, provider, big, reviewWindow, expiry);

        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));

        // Window elapses; payer never acks and never disputes.
        vm.warp(block.timestamp + reviewWindow + 1);

        // Anyone — including the provider — attempts optimistic release.
        vm.expectRevert(ServiceEscrow.OptimisticReleaseBlocked.selector);
        escrow.claimOptimistic(SID);

        // Funds stayed in escrow; provider was not paid; state unchanged.
        assertEq(usdc.balanceOf(provider), 0, "provider was paid without ack");
        assertEq(usdc.balanceOf(address(escrow)), big, "escrow lost funds");
        assertEq(
            uint256(escrow.getService(SID).state),
            uint256(ServiceEscrow.State.Attested),
            "state advanced without ack"
        );
    }

    function test_aboveThreshold_payerAck_releases() public {
        uint96 big = 100_000_000;
        _lock(payer, provider, big, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));

        vm.prank(payer);
        escrow.ack(SID);

        assertEq(usdc.balanceOf(provider), big, "provider not paid on ack");
        assertEq(uint256(escrow.getService(SID).state), uint256(ServiceEscrow.State.Released));
    }

    function test_aboveThreshold_disputeThenArbitration_releases() public {
        uint96 big = 100_000_000;
        _lock(payer, provider, big, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));
        vm.prank(payer);
        escrow.dispute(SID);

        vm.prank(arbitrator);
        escrow.resolveDispute(SID, true);

        assertEq(usdc.balanceOf(provider), big, "provider not paid by arbitrator");
        assertEq(uint256(escrow.getService(SID).state), uint256(ServiceEscrow.State.Released));
    }

    /// @dev Above-threshold + payer silence past expiry: funds must be recoverable
    ///      by the payer. Silence must not pay the provider.
    function test_aboveThreshold_silencePastExpiry_refundsPayer() public {
        uint96 big = 100_000_000;
        uint256 payerStart = usdc.balanceOf(payer);
        _lock(payer, provider, big, reviewWindow, expiry);

        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));

        // Payer neither acks nor disputes; window elapses.
        vm.warp(block.timestamp + reviewWindow + 1);
        vm.expectRevert(ServiceEscrow.OptimisticReleaseBlocked.selector);
        escrow.claimOptimistic(SID);

        // Past expiry, anyone may sweep the funds back to the payer.
        vm.warp(expiry + 1);
        escrow.refundExpired(SID);

        assertEq(usdc.balanceOf(payer), payerStart, "payer not refunded");
        assertEq(usdc.balanceOf(provider), 0, "provider paid despite silence");
        assertEq(uint256(escrow.getService(SID).state), uint256(ServiceEscrow.State.Refunded));
        assertEq(usdc.balanceOf(address(escrow)), 0, "funds stranded");
    }

    /// @dev Boundary: amount == ackThreshold keeps the optimistic flow (<= is allowed).
    function test_atThreshold_optimisticReleaseAllowed() public {
        uint96 at = ackThreshold; // 50.00 USDC, exactly the threshold
        _lock(payer, provider, at, reviewWindow, expiry);
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));

        vm.warp(block.timestamp + reviewWindow + 1);
        escrow.claimOptimistic(SID);

        assertEq(usdc.balanceOf(provider), at, "boundary not released");
        assertEq(uint256(escrow.getService(SID).state), uint256(ServiceEscrow.State.Released));
    }

    /// @dev Sanity: below-threshold behaviour is unchanged (existing tests cover this
    ///      too, but keep it explicit next to the gating tests).
    function test_belowThreshold_optimisticReleaseAllowed() public {
        _lock(payer, provider, amount, reviewWindow, expiry); // 40.00 < 50.00
        vm.prank(provider);
        escrow.submitAttestation(SID, keccak256("record"));

        vm.warp(block.timestamp + reviewWindow + 1);
        escrow.claimOptimistic(SID);

        assertEq(usdc.balanceOf(provider), amount, "below-threshold not released");
        assertEq(uint256(escrow.getService(SID).state), uint256(ServiceEscrow.State.Released));
    }

    /// @dev Strict mode (ackThreshold == 0): no service can be optimistically released,
    ///      because amount must be > 0 to lock, so amount > 0 == amount > threshold.
    function test_strictMode_blocksAllOptimisticRelease() public {
        ServiceEscrow strict = new ServiceEscrow(usdc, arbitrator, 0);
        vm.prank(payer);
        usdc.approve(address(strict), type(uint256).max);
        vm.prank(payer);
        strict.lockFunds(SID, provider, amount, reviewWindow, expiry);
        vm.prank(provider);
        strict.submitAttestation(SID, keccak256("record"));
        vm.warp(block.timestamp + reviewWindow + 1);
        vm.expectRevert(ServiceEscrow.OptimisticReleaseBlocked.selector);
        strict.claimOptimistic(SID);
    }

    // -----------------------------------------------------------------------
    // MIN_REVIEW_WINDOW floor
    // -----------------------------------------------------------------------

    function test_reviewWindowBelowMin_reverts() public {
        // Read the constant BEFORE prank/expectRevert so those cheatcodes are
        // consumed by lockFunds, not by the view getter.
        uint64 minWin = uint64(escrow.MIN_REVIEW_WINDOW());
        vm.prank(payer);
        vm.expectRevert(ServiceEscrow.ReviewWindowTooShort.selector);
        escrow.lockFunds(SID, provider, amount, minWin - 1, expiry);
    }

    function test_reviewWindowAtMin_succeeds() public {
        bytes32 sid = keccak256("min-window-svc");
        uint64 minWin = uint64(escrow.MIN_REVIEW_WINDOW());
        vm.prank(payer);
        escrow.lockFunds(sid, provider, amount, minWin, expiry);
        assertEq(
            uint256(escrow.getService(sid).state),
            uint256(ServiceEscrow.State.Locked)
        );
    }

    // -----------------------------------------------------------------------
    // serviceId helper
    // -----------------------------------------------------------------------

    function test_serviceIdHelper() public view {
        assertEq(escrow.makeServiceId("telehealth-consult-001"), SID);
    }
}
