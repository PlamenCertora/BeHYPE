// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {DualSystem} from "./DualSystem.sol";

/// @notice Drives random action sequences against both systems; every action is executed on both and
/// compared (success, revert/return data, events, ETH movements, full observable state).
contract EquivalenceHandler is DualSystem {
    uint256 public divergences;
    string public firstDivergence;
    uint256 public calls;

    bool internal scWmRepointed;
    bool internal tokenWmRepointed;
    bool internal tokenScRepointed;

    constructor() {
        _deployBoth();
    }

    function _diverged(string memory what) internal override {
        if (divergences == 0) firstDivergence = what;
        divergences++;
    }

    /* ------------------------------ pickers ------------------------------ */

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev ~50% admin (holds every role + owner), otherwise an outsider or an actor.
    function _caller(uint256 seed) internal view returns (address) {
        if (seed % 2 == 0) return admin;
        if (seed % 6 == 1) return outsider;
        return _actor(seed / 6);
    }

    /// @dev Amounts concentrated around protocol limits, plus bucket-unit and decimal-truncation edges.
    function _amount(uint256 seed) internal pure returns (uint256) {
        uint256 kind = seed % 8;
        uint256 v = seed >> 8;
        if (kind == 0) return 0;
        if (kind == 1) return bound(v, 0.1 ether - 1, 0.1 ether + 1);
        if (kind == 2) return bound(v, 100 ether - 1, 100 ether + 1);
        if (kind == 3) return bound(v, 0, 1e12 * 3); // sub-bucket-unit
        if (kind == 4) return bound(v, 0, 1e10 * 3); // sub-8-decimals
        return bound(v, 0, 150 ether);
    }

    /* ------------------------------- actions ------------------------------ */

    function stake(uint256 actorSeed, uint256 amountSeed) external {
        calls++;
        _dual(_actor(actorSeed), _amount(amountSeed), address(scO), address(m), abi.encodeWithSignature("stake(string)", "c"));
    }

    function approve(uint256 actorSeed, uint256 amountSeed, bool infinite) external {
        calls++;
        uint256 amt = infinite ? type(uint256).max : _amount(amountSeed);
        _dual2(_actor(actorSeed), 0,
            address(tokenO), abi.encodeWithSignature("approve(address,uint256)", address(wmO), amt),
            address(m), abi.encodeWithSignature("approve(address,uint256)", address(m), amt));
    }

    function withdraw(uint256 actorSeed, uint256 amountSeed, bool instant) external {
        calls++;
        _dual(_actor(actorSeed), 0, address(wmO), address(m), abi.encodeWithSignature("withdraw(uint256,bool)", _amount(amountSeed), instant));
    }

    function finalize(uint256 callerSeed, uint256 indexSeed) external {
        calls++;
        uint256 idx = bound(indexSeed, 0, _queueLength());
        _dual(_caller(callerSeed), 0, address(wmO), address(m), abi.encodeWithSignature("finalizeWithdrawals(uint256)", idx));
    }

    function updateRatio(uint256 callerSeed) external {
        calls++;
        _dual(_caller(callerSeed), 0, address(scO), address(m), abi.encodeWithSignature("updateExchangeRatio()"));
    }

    function setL1(uint256 d, uint256 u, uint64 p, uint256 s) external {
        calls++;
        _setL1(bound(d, 0, 200 ether), bound(u, 0, 200 ether), uint64(bound(p, 0, 200e8)), bound(s, 0, 200 ether));
        _compareState("setL1");
    }

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 0, 40 days));
        _compareState("warp");
    }

    function hyperCore(uint8 op, uint256 callerSeed, uint256 amountSeed) external {
        calls++;
        address c = _caller(callerSeed);
        uint256 amt = _amount(amountSeed);
        op = op % 5;
        bytes memory data;
        if (op == 0) data = abi.encodeWithSignature("depositToHyperCore(uint256)", amt);
        else if (op == 1) data = abi.encodeWithSignature("withdrawFromHyperCore(uint256)", amt);
        else if (op == 2) data = abi.encodeWithSignature("depositToStaking(uint256)", amt);
        else if (op == 3) data = abi.encodeWithSignature("withdrawFromStaking(uint256)", amt);
        else data = abi.encodeWithSignature("delegateTokens(address,uint256,bool)", address(0xBEEF), amt, amountSeed % 2 == 0);
        _dual(c, 0, address(scO), address(m), data);
    }

    function guardianSetters(uint8 op, uint256 callerSeed, uint256 value) external {
        calls++;
        address c = _caller(callerSeed);
        op = op % 3;
        if (op == 0) {
            _dual(c, 0, address(wmO), address(m), abi.encodeWithSignature("setInstantWithdrawalFeeInBps(uint16)", uint16(bound(value, 0, 10_100))));
        } else if (op == 1) {
            _dual(c, 0, address(scO), address(m), abi.encodeWithSignature("updateAcceptableApr(uint16)", uint16(bound(value, 0, 2_000))));
        } else {
            _dual(c, 0, address(scO), address(m), abi.encodeWithSignature("updateExchangeRateGuard(bool)", value % 2 == 0));
        }
    }

    function limiterSetters(bool capacity, uint256 callerSeed, uint256 value) external {
        calls++;
        address c = _caller(callerSeed);
        if (capacity) {
            uint256 cap = value % 4 == 0 ? value : bound(value, 0, 50 ether); // occasionally absurdly large
            _dual(c, 0, address(wmO), address(m), abi.encodeWithSignature("setInstantWithdrawalCapacity(uint256)", cap));
        } else {
            _dual(c, 0, address(wmO), address(m), abi.encodeWithSignature("setInstantWithdrawalRefillRatePerSecond(uint64)", uint64(bound(value, 0, 1e9))));
        }
    }

    function pause(bool doPause, uint256 callerSeed, bool direct) external {
        calls++;
        address c = _caller(callerSeed);
        if (direct) {
            string memory sig = doPause ? "pauseStaking()" : "unpauseStaking()";
            _dual(c, 0, address(scO), address(m), abi.encodeWithSignature(sig));
            sig = doPause ? "pauseWithdrawals()" : "unpauseWithdrawals()";
            _dual(c, 0, address(wmO), address(m), abi.encodeWithSignature(sig));
        } else {
            _dual(c, 0, address(regO), address(regM), abi.encodeWithSignature(doPause ? "pauseProtocol()" : "unpauseProtocol()"));
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool toEscrow) external {
        calls++;
        address from = _actor(fromSeed);
        uint256 amt = _amount(amountSeed);
        if (toEscrow) {
            _dual2(from, 0,
                address(tokenO), abi.encodeWithSignature("transfer(address,uint256)", address(wmO), amt),
                address(m), abi.encodeWithSignature("transfer(address,uint256)", address(m), amt));
        } else {
            _dual(from, 0, address(tokenO), address(m), abi.encodeWithSignature("transfer(address,uint256)", _actor(toSeed), amt));
        }
    }

    /// @dev Protocol upgrader re-points one of the three internal pointers to `outsider` or back.
    function repoint(uint8 which, uint256 callerSeed) external {
        calls++;
        address c = callerSeed % 4 == 0 ? outsider : admin;
        which = which % 3;
        if (which == 0) {
            scWmRepointed = !scWmRepointed;
            _dual2(c, 0,
                address(scO), abi.encodeWithSignature("setWithdrawManager(address)", scWmRepointed ? outsider : address(wmO)),
                address(m), abi.encodeWithSignature("setWithdrawManager(address)", scWmRepointed ? outsider : address(m)));
            if (c != admin) scWmRepointed = !scWmRepointed;
        } else if (which == 1) {
            tokenWmRepointed = !tokenWmRepointed;
            _dual2(c, 0,
                address(tokenO), abi.encodeWithSignature("setWithdrawManager(address)", tokenWmRepointed ? outsider : address(wmO)),
                address(m), abi.encodeWithSignature("setTokenWithdrawManager(address)", tokenWmRepointed ? outsider : address(m)));
            if (c != admin) tokenWmRepointed = !tokenWmRepointed;
        } else {
            tokenScRepointed = !tokenScRepointed;
            _dual2(c, 0,
                address(tokenO), abi.encodeWithSignature("setStakingCore(address)", tokenScRepointed ? outsider : address(scO)),
                address(m), abi.encodeWithSignature("setTokenStakingCore(address)", tokenScRepointed ? outsider : address(m)));
            if (c != admin) tokenScRepointed = !tokenScRepointed;
        }
    }

    /// @dev Outsider tries the privileged cross-contract entry points (succeeds only when pointed to).
    function outsiderPowers(uint8 op, uint256 targetSeed, uint256 amountSeed) external {
        calls++;
        uint256 amt = _amount(amountSeed);
        address who = _actor(targetSeed);
        op = op % 3;
        if (op == 0) _dual(outsider, 0, address(scO), address(m), abi.encodeWithSignature("sendFromWithdrawManager(uint256,address)", amt, who));
        else if (op == 1) _dual(outsider, 0, address(tokenO), address(m), abi.encodeWithSignature("mint(address,uint256)", who, amt));
        else _dual(outsider, 0, address(tokenO), address(m), abi.encodeWithSignature("burn(address,uint256)", who, amt));
    }

    /// @dev Plain HYPE donation to the liquidity pool (StakingCore vs merged).
    function donate(uint256 amountSeed) external {
        calls++;
        _dual(outsider, _amount(amountSeed), address(scO), address(m), "");
    }
}

contract MergedEquivalenceInvariantTest is StdInvariant, Test {
    EquivalenceHandler internal h;

    function setUp() public {
        h = new EquivalenceHandler();
        bytes4[] memory sels = new bytes4[](15);
        sels[0] = EquivalenceHandler.stake.selector;
        sels[1] = EquivalenceHandler.approve.selector;
        sels[2] = EquivalenceHandler.withdraw.selector;
        sels[3] = EquivalenceHandler.finalize.selector;
        sels[4] = EquivalenceHandler.updateRatio.selector;
        sels[5] = EquivalenceHandler.setL1.selector;
        sels[6] = EquivalenceHandler.warp.selector;
        sels[7] = EquivalenceHandler.hyperCore.selector;
        sels[8] = EquivalenceHandler.guardianSetters.selector;
        sels[9] = EquivalenceHandler.limiterSetters.selector;
        sels[10] = EquivalenceHandler.pause.selector;
        sels[11] = EquivalenceHandler.transfer.selector;
        sels[12] = EquivalenceHandler.repoint.selector;
        sels[13] = EquivalenceHandler.outsiderPowers.selector;
        sels[14] = EquivalenceHandler.donate.selector;
        // Weight core user flows higher.
        bytes4[] memory weighted = new bytes4[](sels.length + 6);
        for (uint256 i = 0; i < sels.length; i++) weighted[i] = sels[i];
        weighted[15] = EquivalenceHandler.stake.selector;
        weighted[16] = EquivalenceHandler.stake.selector;
        weighted[17] = EquivalenceHandler.withdraw.selector;
        weighted[18] = EquivalenceHandler.withdraw.selector;
        weighted[19] = EquivalenceHandler.approve.selector;
        weighted[20] = EquivalenceHandler.finalize.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: weighted}));
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 50
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_mergedEquivalentToOriginal() public view {
        assertEq(h.divergences(), 0, h.firstDivergence());
    }
}
