// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DualSystem} from "./DualSystem.sol";
import {BeHYPEProtocol} from "../../certora/BeHYPEProtocol.sol";

/// @notice Receiver that can re-enter `withdraw` from its receive() hook. One instance per system.
contract ReentrantActor {
    address public reenterTarget;
    bool public armed;
    uint256 public reenterAmount;
    bool public reenterInstant;
    bool public lastOk;
    bytes public lastRet;
    bytes public midStateView; // protocol views observed from inside the payout callback

    constructor(address _reenterTarget) {
        reenterTarget = _reenterTarget;
    }

    function arm(uint256 amount, bool instant) external {
        armed = true;
        reenterAmount = amount;
        reenterInstant = instant;
    }

    function exec(address to, bytes calldata data) external payable returns (bytes memory) {
        (bool ok, bytes memory r) = to.call{value: msg.value}(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
        return r;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            (, bytes memory pending) = reenterTarget.staticcall(abi.encodeWithSignature("getPendingWithdrawalsCount()"));
            (, bytes memory requested) = reenterTarget.staticcall(abi.encodeWithSignature("hypeRequestedForWithdraw()"));
            (, bytes memory last) = reenterTarget.staticcall(abi.encodeWithSignature("lastFinalizedIndex()"));
            (, bytes memory instantCap) = reenterTarget.staticcall(abi.encodeWithSignature("getTotalInstantWithdrawableBeHYPE()"));
            midStateView = bytes.concat(pending, requested, last, instantCap);
            (lastOk, lastRet) = reenterTarget.call(abi.encodeWithSignature("withdraw(uint256,bool)", reenterAmount, reenterInstant));
        }
    }
}

contract MergedEquivalenceTest is DualSystem {
    address internal a0;
    address internal a1;
    address internal a2;

    function setUp() public {
        _deployBoth();
        a0 = actors[0];
        a1 = actors[1];
        a2 = actors[2];
    }

    function _diverged(string memory what) internal pure override {
        revert(string.concat("DIVERGENCE: ", what));
    }

    /* ---------------------------- action helpers ---------------------------- */

    function _stake(address who, uint256 amount) internal returns (bool) {
        return _dual(who, amount, address(scO), address(m), abi.encodeWithSignature("stake(string)", "ref"));
    }

    function _approve(address who, uint256 amount) internal returns (bool) {
        return _dual2(who, 0,
            address(tokenO), abi.encodeWithSignature("approve(address,uint256)", address(wmO), amount),
            address(m), abi.encodeWithSignature("approve(address,uint256)", address(m), amount));
    }

    function _withdraw(address who, uint256 amount, bool instant) internal returns (bool) {
        return _dual(who, 0, address(wmO), address(m), abi.encodeWithSignature("withdraw(uint256,bool)", amount, instant));
    }

    function _finalize(address who, uint256 index) internal returns (bool) {
        return _dual(who, 0, address(wmO), address(m), abi.encodeWithSignature("finalizeWithdrawals(uint256)", index));
    }

    function _updateRatio(address who) internal returns (bool) {
        return _dual(who, 0, address(scO), address(m), abi.encodeWithSignature("updateExchangeRatio()"));
    }

    function _sc(address who, bytes memory data) internal returns (bool) {
        return _dual(who, 0, address(scO), address(m), data);
    }

    function _wm(address who, bytes memory data) internal returns (bool) {
        return _dual(who, 0, address(wmO), address(m), data);
    }

    function _tok(address who, bytes memory data) internal returns (bool) {
        return _dual(who, 0, address(tokenO), address(m), data);
    }

    function _reg(address who, bytes memory data) internal returns (bool) {
        return _dual(who, 0, address(regO), address(regM), data);
    }

    /* -------------------------------- tests -------------------------------- */

    function test_initialState() public {
        _compareState("init");
    }

    function test_stakeQueueFinalize() public {
        assertTrue(_stake(a0, 10 ether));
        assertTrue(_stake(a1, 5 ether));
        assertFalse(_withdraw(a0, 1 ether, false)); // no allowance -> ERC20InsufficientAllowance(WM/m, ...)
        assertTrue(_approve(a0, type(uint256).max));
        assertTrue(_approve(a1, 3 ether));
        assertTrue(_withdraw(a0, 2 ether, false));
        assertTrue(_withdraw(a1, 3 ether, false));
        assertTrue(_withdraw(a0, 1 ether, false));
        assertFalse(_withdraw(a0, 0.01 ether, false)); // below min
        assertFalse(_withdraw(a0, 101 ether, false)); // above max
        assertFalse(_withdraw(a2, 1 ether, false)); // no balance

        assertFalse(_finalize(admin, 0)); // CanOnlyFinalizeForward
        assertFalse(_finalize(admin, 4)); // IndexOutOfBounds
        assertFalse(_finalize(outsider, 1)); // NotAuthorized
        assertTrue(_finalize(admin, 2));
        assertTrue(_finalize(admin, 3));
        assertFalse(_finalize(admin, 3));
    }

    function test_finalizeWithoutLiquidity() public {
        assertTrue(_stake(a0, 10 ether));
        assertTrue(_approve(a0, type(uint256).max));
        assertTrue(_withdraw(a0, 5 ether, false));
        assertTrue(_sc(admin, abi.encodeWithSignature("depositToHyperCore(uint256)", 8 ether)));
        assertFalse(_finalize(admin, 1)); // FailedToSendFromWithdrawManager
    }

    function test_instantWithdraw_feeRateLimitWatermark() public {
        assertTrue(_stake(a0, 50 ether));
        assertTrue(_stake(a1, 50 ether));
        assertTrue(_approve(a0, type(uint256).max));
        assertTrue(_approve(a1, type(uint256).max));

        assertTrue(_withdraw(a0, 4 ether, true));
        assertTrue(_withdraw(a1, 5 ether, true));
        assertFalse(_withdraw(a0, 2 ether, true)); // rate limit exhausted
        vm.warp(block.timestamp + 1 hours);
        assertTrue(_withdraw(a0, 2 ether, true));

        // Watermark: move most HYPE to HyperCore so liquidity < low watermark.
        assertTrue(_sc(admin, abi.encodeWithSignature("depositToHyperCore(uint256)", 88.5 ether)));
        _setL1(0, 0, 0, 88.5 ether);
        vm.warp(block.timestamp + 1 days);
        assertFalse(_withdraw(a0, 1 ether, true)); // InsufficientHYPELiquidity

        // Fee changes incl. invalid fee
        assertFalse(_wm(admin, abi.encodeWithSignature("setInstantWithdrawalFeeInBps(uint16)", uint16(10_001))));
        assertTrue(_wm(admin, abi.encodeWithSignature("setInstantWithdrawalFeeInBps(uint16)", uint16(10_000))));
        assertTrue(_wm(admin, abi.encodeWithSignature("setInstantWithdrawalCapacity(uint256)", 1 ether)));
        assertTrue(_wm(admin, abi.encodeWithSignature("setInstantWithdrawalRefillRatePerSecond(uint64)", uint64(0))));
        assertFalse(_wm(admin, abi.encodeWithSignature("setInstantWithdrawalCapacity(uint256)", type(uint256).max))); // too large
        assertTrue(_wm(admin, abi.encodeWithSignature("setInstantWithdrawalCapacity(uint256)", 1 ether + 1e12 - 1))); // floor rounding
        assertTrue(_wm(admin, abi.encodeWithSignature("setInstantWithdrawalCapacity(uint256)", 1 ether)));
        _setL1(0, 0, 0, 0);
        assertTrue(_sc(admin, abi.encodeWithSignature("depositToHyperCore(uint256)", 0)));
        vm.deal(address(scO), 100 ether);
        vm.deal(address(m), 100 ether);
        assertTrue(_withdraw(a1, 0.5 ether, true)); // 100% fee
    }

    function test_exchangeRatio() public {
        assertTrue(_stake(a0, 100 ether));
        assertFalse(_updateRatio(admin)); // elapsed == 0
        vm.warp(block.timestamp + 365 days);
        _setL1(0, 0, 0, 3 ether); // +3% over a year -> 300 bps <= 400
        assertTrue(_updateRatio(admin));
        vm.warp(block.timestamp + 1 days);
        _setL1(10 ether, 0, 0, 3 ether); // big jump -> guard reverts
        assertFalse(_updateRatio(admin));
        assertFalse(_sc(outsider, abi.encodeWithSignature("updateExchangeRateGuard(bool)", false)));
        assertTrue(_sc(admin, abi.encodeWithSignature("updateExchangeRateGuard(bool)", false)));
        assertTrue(_updateRatio(admin));
        assertTrue(_sc(admin, abi.encodeWithSignature("updateAcceptableApr(uint16)", uint16(1))));
        assertTrue(_sc(admin, abi.encodeWithSignature("updateExchangeRateGuard(bool)", true)));
        vm.warp(block.timestamp + 1 days);
        _setL1(0, 0, 0, 0); // ratio drop
        assertFalse(_updateRatio(admin));
        assertFalse(_updateRatio(outsider));

        // stake/withdraw at a non-1 ratio
        assertTrue(_stake(a1, 7.123456789 ether));
        assertTrue(_approve(a1, type(uint256).max));
        assertTrue(_withdraw(a1, 1.5 ether, false));
        assertTrue(_withdraw(a1, 1 ether, true));
    }

    function test_hyperCoreOps() public {
        assertTrue(_stake(a0, 20 ether));
        assertTrue(_approve(a0, type(uint256).max));
        assertTrue(_withdraw(a0, 5 ether, false));

        assertTrue(_sc(admin, abi.encodeWithSignature("depositToHyperCore(uint256)", 10 ether)));
        assertFalse(_sc(admin, abi.encodeWithSignature("depositToHyperCore(uint256)", 1000 ether)));
        assertTrue(_sc(admin, abi.encodeWithSignature("depositToStaking(uint256)", 3 ether)));
        assertFalse(_sc(admin, abi.encodeWithSignature("depositToStaking(uint256)", type(uint256).max))); // > uint64
        assertTrue(_sc(admin, abi.encodeWithSignature("delegateTokens(address,uint256,bool)", address(0xBEEF), 3 ether, false)));
        assertTrue(_sc(admin, abi.encodeWithSignature("withdrawFromStaking(uint256)", 5 ether)));
        assertFalse(_sc(admin, abi.encodeWithSignature("withdrawFromStaking(uint256)", 5 ether + 1))); // > requested
        assertTrue(_sc(admin, abi.encodeWithSignature("withdrawFromHyperCore(uint256)", 5 ether)));
        assertFalse(_sc(admin, abi.encodeWithSignature("withdrawFromHyperCore(uint256)", 6 ether)));
    }

    function test_pause() public {
        assertFalse(_reg(outsider, abi.encodeWithSignature("pauseProtocol()")));
        assertTrue(_reg(admin, abi.encodeWithSignature("pauseProtocol()")));
        assertFalse(_reg(admin, abi.encodeWithSignature("pauseProtocol()"))); // EnforcedPause
        assertFalse(_stake(a0, 1 ether)); // StakingPaused
        assertFalse(_withdraw(a0, 1 ether, false)); // WithdrawalsPaused
        assertTrue(_reg(admin, abi.encodeWithSignature("unpauseProtocol()")));
        assertFalse(_reg(admin, abi.encodeWithSignature("unpauseProtocol()"))); // ExpectedPause
        assertTrue(_stake(a0, 1 ether));

        // Direct calls (only the registry may pause)
        assertFalse(_sc(admin, abi.encodeWithSignature("pauseStaking()")));
        assertFalse(_wm(admin, abi.encodeWithSignature("pauseWithdrawals()")));
        assertFalse(_sc(admin, abi.encodeWithSignature("unpauseStaking()")));
        assertFalse(_wm(admin, abi.encodeWithSignature("unpauseWithdrawals()")));
    }

    /// @dev The two pause flags are independent state (each original contract had its own Pausable).
    /// Through RoleRegistry they always move together, so drive them individually as the registry.
    function test_independentPauseFlags() public {
        assertTrue(_stake(a0, 5 ether));
        assertTrue(_approve(a0, type(uint256).max));

        vm.prank(address(regO));
        scO.pauseStaking();
        vm.prank(address(regM));
        m.pauseStaking();
        _compareState("pauseStaking only");
        assertFalse(_stake(a0, 1 ether));
        assertTrue(_withdraw(a0, 1 ether, false)); // withdrawals still open

        vm.prank(address(regO));
        scO.unpauseStaking();
        vm.prank(address(regM));
        m.unpauseStaking();
        vm.prank(address(regO));
        wmO.pauseWithdrawals();
        vm.prank(address(regM));
        m.pauseWithdrawals();
        _compareState("pauseWithdrawals only");
        assertTrue(_stake(a0, 1 ether)); // staking still open
        assertFalse(_withdraw(a0, 1 ether, false));
        assertFalse(_reg(admin, abi.encodeWithSignature("pauseProtocol()"))); // WM already paused -> EnforcedPause
    }

    function test_permissions() public {
        assertTrue(_stake(a0, 10 ether));
        address[2] memory callers = [outsider, a0];
        for (uint256 i = 0; i < callers.length; i++) {
            address c = callers[i];
            assertFalse(_sc(c, abi.encodeWithSignature("updateExchangeRatio()")));
            assertFalse(_sc(c, abi.encodeWithSignature("sendFromWithdrawManager(uint256,address)", 1 ether, c)));
            assertFalse(_sc(c, abi.encodeWithSignature("setWithdrawManager(address)", c)));
            assertFalse(_sc(c, abi.encodeWithSignature("updateAcceptableApr(uint16)", uint16(1))));
            assertFalse(_sc(c, abi.encodeWithSignature("updateExchangeRateGuard(bool)", false)));
            assertFalse(_sc(c, abi.encodeWithSignature("depositToHyperCore(uint256)", 1 ether)));
            assertFalse(_sc(c, abi.encodeWithSignature("withdrawFromHyperCore(uint256)", 0)));
            assertFalse(_sc(c, abi.encodeWithSignature("depositToStaking(uint256)", 1 ether)));
            assertFalse(_sc(c, abi.encodeWithSignature("withdrawFromStaking(uint256)", 0)));
            assertFalse(_sc(c, abi.encodeWithSignature("delegateTokens(address,uint256,bool)", c, 1, true)));
            assertFalse(_sc(c, abi.encodeWithSignature("pauseStaking()")));
            assertFalse(_sc(c, abi.encodeWithSignature("unpauseStaking()")));
            assertFalse(_wm(c, abi.encodeWithSignature("finalizeWithdrawals(uint256)", 1)));
            assertFalse(_wm(c, abi.encodeWithSignature("setInstantWithdrawalFeeInBps(uint16)", uint16(1))));
            assertFalse(_wm(c, abi.encodeWithSignature("setInstantWithdrawalCapacity(uint256)", 1)));
            assertFalse(_wm(c, abi.encodeWithSignature("setInstantWithdrawalRefillRatePerSecond(uint64)", uint64(1))));
            assertFalse(_wm(c, abi.encodeWithSignature("pauseWithdrawals()")));
            assertFalse(_wm(c, abi.encodeWithSignature("unpauseWithdrawals()")));
            assertFalse(_tok(c, abi.encodeWithSignature("mint(address,uint256)", c, 1 ether)));
            assertFalse(_tok(c, abi.encodeWithSignature("burn(address,uint256)", a0, 1 ether)));
            assertFalse(_dual2(c, 0,
                address(tokenO), abi.encodeWithSignature("setStakingCore(address)", c),
                address(m), abi.encodeWithSignature("setTokenStakingCore(address)", c)));
            assertFalse(_dual2(c, 0,
                address(tokenO), abi.encodeWithSignature("setWithdrawManager(address)", c),
                address(m), abi.encodeWithSignature("setTokenWithdrawManager(address)", c)));
            // UUPS upgrade authorisation on every proxy
            bytes memory up = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(0xdead), "");
            assertFalse(_sc(c, up));
            assertFalse(_wm(c, up));
            assertFalse(_tok(c, up));
            // Re-initialisation
            assertFalse(_dual2(c, 0,
                address(scO), abi.encodeWithSignature("initialize(address,address,address,uint32,bool)", c, c, c, uint32(0), false),
                address(m), abi.encodeWithSignature(
                    "initialize(string,string,address,(uint32,bool,uint256,uint256,uint16,uint16,uint256,uint64))",
                    "", "", c, BeHYPEProtocol.InitConfig(0, false, 0, 0, 0, 0, 0, 0))));
        }
    }

    /// @dev Pointer re-configuration by the protocol upgrader: internal hops must fail/succeed exactly as
    /// the cross-contract calls did, and the newly pointed-to EOA gains exactly the same powers.
    function test_pointerRepointing() public {
        address x = outsider;
        assertTrue(_stake(a0, 20 ether));
        assertTrue(_approve(a0, type(uint256).max));
        assertTrue(_withdraw(a0, 2 ether, false));

        // StakingCore.withdrawManager -> EOA
        assertTrue(_sc(admin, abi.encodeWithSignature("setWithdrawManager(address)", x)));
        assertFalse(_finalize(admin, 1)); // NotAuthorized from sendFromWithdrawManager
        assertFalse(_withdraw(a0, 1 ether, true)); // NotAuthorized on instant payout
        assertTrue(_withdraw(a0, 1 ether, false)); // queueing does not touch StakingCore pointer
        assertFalse(_sc(admin, abi.encodeWithSignature("withdrawFromStaking(uint256)", 0))); // call to EOA reverts
        assertTrue(_sc(x, abi.encodeWithSignature("sendFromWithdrawManager(uint256,address)", 1 ether, x)));
        assertTrue(_dual2(admin, 0,
            address(scO), abi.encodeWithSignature("setWithdrawManager(address)", address(wmO)),
            address(m), abi.encodeWithSignature("setWithdrawManager(address)", address(m))));
        assertTrue(_finalize(admin, 1));

        // BeHYPE.withdrawManager -> EOA
        assertTrue(_dual2(admin, 0,
            address(tokenO), abi.encodeWithSignature("setWithdrawManager(address)", x),
            address(m), abi.encodeWithSignature("setTokenWithdrawManager(address)", x)));
        assertFalse(_finalize(admin, 2)); // burn -> Unauthorized
        assertFalse(_withdraw(a0, 1 ether, true)); // burn -> Unauthorized
        assertTrue(_tok(x, abi.encodeWithSignature("burn(address,uint256)", a0, 1 ether)));
        assertTrue(_dual2(admin, 0,
            address(tokenO), abi.encodeWithSignature("setWithdrawManager(address)", address(wmO)),
            address(m), abi.encodeWithSignature("setTokenWithdrawManager(address)", address(m))));
        assertTrue(_finalize(admin, 2));

        // BeHYPE.stakingCore -> EOA
        assertTrue(_dual2(admin, 0,
            address(tokenO), abi.encodeWithSignature("setStakingCore(address)", x),
            address(m), abi.encodeWithSignature("setTokenStakingCore(address)", x)));
        assertFalse(_stake(a1, 1 ether)); // mint -> Unauthorized
        assertTrue(_tok(x, abi.encodeWithSignature("mint(address,uint256)", a1, 3 ether)));
        assertTrue(_dual2(admin, 0,
            address(tokenO), abi.encodeWithSignature("setStakingCore(address)", address(scO)),
            address(m), abi.encodeWithSignature("setTokenStakingCore(address)", address(m))));
        assertTrue(_stake(a1, 1 ether));
    }

    function test_tokenTransfersAndPermit() public {
        assertTrue(_stake(a0, 10 ether));
        assertTrue(_tok(a0, abi.encodeWithSignature("transfer(address,uint256)", a1, 1 ether)));
        assertFalse(_tok(a0, abi.encodeWithSignature("transfer(address,uint256)", address(0), 1 ether)));
        assertTrue(_tok(a0, abi.encodeWithSignature("approve(address,uint256)", a2, 2 ether)));
        assertTrue(_tok(a2, abi.encodeWithSignature("transferFrom(address,address,uint256)", a0, a2, 2 ether)));
        assertFalse(_tok(a2, abi.encodeWithSignature("transferFrom(address,address,uint256)", a0, a2, 1)));
        // Donation of beHYPE into the withdraw-manager escrow
        assertTrue(_dual2(a1, 0,
            address(tokenO), abi.encodeWithSignature("transfer(address,uint256)", address(wmO), 0.5 ether),
            address(m), abi.encodeWithSignature("transfer(address,uint256)", address(m), 0.5 ether)));

        // permit: signatures differ per domain (verifyingContract), outcomes must match.
        (address owner, uint256 pk) = makeAddrAndKey("permitOwner");
        _track(owner, owner);
        assertTrue(_tok(a0, abi.encodeWithSignature("transfer(address,uint256)", owner, 1 ether)));
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory pO = _permitCall(address(tokenO), owner, pk, address(wmO), 1 ether, deadline);
        bytes memory pM = _permitCall(address(m), owner, pk, address(m), 1 ether, deadline);
        assertTrue(_dual2(a2, 0, address(tokenO), pO, address(m), pM));
        // Expired deadline -> ERC2612ExpiredSignature(deadline). (A replay is not compared: the recovered
        // signer inside ERC2612InvalidSigner is pseudo-random per domain and differs by construction.)
        bytes memory eO = _permitCall(address(tokenO), owner, pk, address(wmO), 1 ether, block.timestamp - 1);
        bytes memory eM = _permitCall(address(m), owner, pk, address(m), 1 ether, block.timestamp - 1);
        assertFalse(_dual2(a2, 0, address(tokenO), eO, address(m), eM));
        assertTrue(_withdraw(owner, 1 ether, false));
    }

    function _permitCall(address token, address owner, uint256 pk, address spender, uint256 value, uint256 deadline)
        internal view returns (bytes memory)
    {
        (, bytes memory sepRet) = token.staticcall(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        (, bytes memory nonceRet) = token.staticcall(abi.encodeWithSignature("nonces(address)", owner));
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            owner, spender, value, abi.decode(nonceRet, (uint256)), deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", abi.decode(sepRet, (bytes32)), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodeWithSignature("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            owner, spender, value, deadline, v, r, s);
    }

    /// @dev A queued user whose receive() re-enters withdraw(instant) mid-finalize must observe the
    /// same (stale) state and produce the same outcome in both systems.
    function test_reentrancyDuringFinalize() public {
        ReentrantActor rO = new ReentrantActor(address(wmO));
        ReentrantActor rM = new ReentrantActor(address(m));
        _addPair(address(rO), address(rM));
        _track(address(rO), address(rM));

        assertTrue(_stake(a0, 60 ether));
        assertTrue(_dual2(address(this), 10 ether,
            address(rO), abi.encodeCall(ReentrantActor.exec, (address(scO), abi.encodeWithSignature("stake(string)", "r"))),
            address(rM), abi.encodeCall(ReentrantActor.exec, (address(m), abi.encodeWithSignature("stake(string)", "r")))));
        assertTrue(_dual2(address(this), 0,
            address(rO), abi.encodeCall(ReentrantActor.exec, (address(tokenO), abi.encodeWithSignature("approve(address,uint256)", address(wmO), type(uint256).max))),
            address(rM), abi.encodeCall(ReentrantActor.exec, (address(m), abi.encodeWithSignature("approve(address,uint256)", address(m), type(uint256).max)))));
        assertTrue(_dual2(address(this), 0,
            address(rO), abi.encodeCall(ReentrantActor.exec, (address(wmO), abi.encodeWithSignature("withdraw(uint256,bool)", 5 ether, false))),
            address(rM), abi.encodeCall(ReentrantActor.exec, (address(m), abi.encodeWithSignature("withdraw(uint256,bool)", 5 ether, false)))));

        assertTrue(_dual2(address(this), 0,
            address(rO), abi.encodeCall(ReentrantActor.arm, (1 ether, true)),
            address(rM), abi.encodeCall(ReentrantActor.arm, (1 ether, true))));
        assertTrue(_finalize(admin, 1));

        assertEq(rO.lastOk(), rM.lastOk(), "reentry success");
        assertEq(rO.midStateView(), rM.midStateView(), "state observed mid-finalize");
        assertEq(keccak256(_norm(rO.lastRet())), keccak256(rM.lastRet()), "reentry ret");
        assertTrue(rO.lastOk(), "reentry should have succeeded in this setup");

        // Reentry during an instant withdrawal hits the shared nonReentrant lock in both.
        assertTrue(_dual2(address(this), 0,
            address(rO), abi.encodeCall(ReentrantActor.arm, (1 ether, false)),
            address(rM), abi.encodeCall(ReentrantActor.arm, (1 ether, false))));
        vm.warp(block.timestamp + 1 days);
        assertTrue(_dual2(address(this), 0,
            address(rO), abi.encodeCall(ReentrantActor.exec, (address(wmO), abi.encodeWithSignature("withdraw(uint256,bool)", 1 ether, true))),
            address(rM), abi.encodeCall(ReentrantActor.exec, (address(m), abi.encodeWithSignature("withdraw(uint256,bool)", 1 ether, true)))));
        assertEq(rO.lastOk(), rM.lastOk(), "nested reentry success");
        assertFalse(rO.lastOk(), "nested withdraw must hit ReentrancyGuard");
        assertEq(keccak256(_norm(rO.lastRet())), keccak256(rM.lastRet()), "nested reentry ret");
    }

    /// @dev Stateless fuzz over a short user flow at a fuzzed exchange rate.
    function testFuzz_flow(uint256 s0, uint256 s1, uint256 w0, uint256 w1, uint256 l1Spot, uint256 dt, bool i0, bool i1) public {
        s0 = bound(s0, 0, 200 ether);
        s1 = bound(s1, 0, 200 ether);
        _stake(a0, s0);
        _stake(a1, s1);
        dt = bound(dt, 1, 400 days);
        vm.warp(block.timestamp + dt);
        _setL1(0, 0, 0, bound(l1Spot, 0, 50 ether) / 1e10 * 1e10);
        _updateRatio(admin);
        _approve(a0, type(uint256).max);
        _approve(a1, type(uint256).max);
        _withdraw(a0, bound(w0, 0, s0 + 1 ether), i0);
        _withdraw(a1, bound(w1, 0, s1 + 1 ether), i1);
        _finalize(admin, 1);
        _finalize(admin, 2);
    }
}
