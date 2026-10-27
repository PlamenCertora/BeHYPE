// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {UUPSProxy} from "../../src/lib/UUPSProxy.sol";
import {BeHYPE} from "../../src/BeHYPE.sol";
import {RoleRegistry} from "../../src/RoleRegistry.sol";
import {StakingCore} from "../../src/StakingCore.sol";
import {WithdrawManager} from "../../src/WithdrawManager.sol";
import {CoreWriter} from "../../src/lib/CoreWriter.sol";
import {L1Read} from "../../src/lib/L1Read.sol";
import {SpotBalanceMock} from "../mock/SpotBalanceMock.sol";
import {DelegatorSummaryMock} from "../mock/DelegatorSummaryMock.sol";
import {BeHYPEProtocol} from "../../certora/BeHYPEProtocol.sol";

/// @notice Deploys the original 3-contract system ("O") and the merged single contract ("M")
/// side by side and provides differential execution / comparison helpers.
abstract contract DualSystem is Test {
    // ---- original system ----
    RoleRegistry internal regO;
    BeHYPE internal tokenO;
    StakingCore internal scO;
    WithdrawManager internal wmO;

    // ---- merged system ----
    RoleRegistry internal regM;
    BeHYPEProtocol internal m;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("protocolTreasury");
    address internal outsider = makeAddr("outsider");
    address[] internal actors;

    // Address pairs (original-side, merged-side) used to normalise revert data / logs / views.
    address[] internal pairO;
    address[] internal pairM;
    // Addresses whose ETH and beHYPE balances are compared (original-side, merged-side).
    address[] internal trackedO;
    address[] internal trackedM;

    address constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;
    address constant DELEGATOR_SUMMARY_PRECOMPILE = 0x0000000000000000000000000000000000000805;
    address constant L1_READ = 0xb7467E0524Afba7006957701d1F06A59000d15A2;
    address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address constant L1_HYPE_CONTRACT = 0x2222222222222222222222222222222222222222;

    uint32 constant APR_BPS = 400;
    bool constant GUARD = true;
    uint256 constant MIN_WD = 0.1 ether;
    uint256 constant MAX_WD = 100 ether;
    uint16 constant WATERMARK_BPS = 100;
    uint16 constant FEE_BPS = 30;
    uint256 constant BUCKET_CAPACITY = 10 ether;
    uint64 constant BUCKET_REFILL = 1 days;

    /// @dev Called on any divergence between the two systems.
    function _diverged(string memory what) internal virtual;

    /* ================================================================
     *                            DEPLOYMENT
     * ================================================================ */

    function _deployBoth() internal {
        vm.etch(SPOT_BALANCE_PRECOMPILE, address(new SpotBalanceMock()).code);
        vm.etch(DELEGATOR_SUMMARY_PRECOMPILE, address(new DelegatorSummaryMock()).code);
        vm.etch(L1_READ, address(new L1Read()).code);
        vm.etch(CORE_WRITER, address(new CoreWriter()).code);

        address regImpl = address(new RoleRegistry());

        // ---------- original ----------
        regO = RoleRegistry(address(new UUPSProxy(
            regImpl, abi.encodeCall(RoleRegistry.initialize, (admin, address(0), address(0), treasury))
        )));
        tokenO = BeHYPE(address(new UUPSProxy(
            address(new BeHYPE()),
            abi.encodeCall(BeHYPE.initialize, ("BeHYPE Token", "BeHYPE", address(regO), address(0), address(0)))
        )));
        scO = StakingCore(payable(address(new UUPSProxy(
            address(new StakingCore()),
            abi.encodeCall(StakingCore.initialize, (address(regO), address(tokenO), address(0), APR_BPS, GUARD))
        ))));
        wmO = WithdrawManager(payable(address(new UUPSProxy(
            address(new WithdrawManager()),
            abi.encodeCall(WithdrawManager.initialize, (
                MIN_WD, MAX_WD, WATERMARK_BPS, FEE_BPS, address(regO), address(tokenO), address(scO),
                BUCKET_CAPACITY, BUCKET_REFILL
            ))
        ))));

        // ---------- merged ----------
        regM = RoleRegistry(address(new UUPSProxy(
            regImpl, abi.encodeCall(RoleRegistry.initialize, (admin, address(0), address(0), treasury))
        )));
        m = BeHYPEProtocol(payable(address(new UUPSProxy(
            address(new BeHYPEProtocol()),
            abi.encodeCall(BeHYPEProtocol.initialize, (
                "BeHYPE Token", "BeHYPE", address(regM), BeHYPEProtocol.InitConfig({
                    acceptablAprInBps: APR_BPS,
                    exchangeRateGuard: GUARD,
                    minStakeAmount: MIN_WD,
                    maxStakeAmount: MAX_WD,
                    lowWatermarkInBpsOfTvl: WATERMARK_BPS,
                    instantWithdrawalFeeInBps: FEE_BPS,
                    bucketCapacity: BUCKET_CAPACITY,
                    bucketRefillRate: BUCKET_REFILL
                })
            ))
        ))));

        // ---------- wiring (the merged contract self-wires in initialize) ----------
        vm.startPrank(admin);
        tokenO.setStakingCore(address(scO));
        tokenO.setWithdrawManager(address(wmO));
        scO.setWithdrawManager(address(wmO));
        _grantRoles(regO);
        _grantRoles(regM);
        regO.setWithdrawManager(address(wmO));
        regO.setStakingCore(address(scO));
        regM.setWithdrawManager(address(m));
        regM.setStakingCore(address(m));
        vm.stopPrank();

        // Both systems start at the same timestamp-dependent state (lastExchangeRatioUpdate, bucket lastRefill).
        require(scO.lastExchangeRatioUpdate() == m.lastExchangeRatioUpdate(), "setup ts");

        _addPair(address(scO), address(m));
        _addPair(address(wmO), address(m));
        _addPair(address(tokenO), address(m));
        _addPair(address(regO), address(regM));

        for (uint256 i = 0; i < 4; i++) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            _track(a, a);
        }
        _track(admin, admin);
        _track(treasury, treasury);
        _track(outsider, outsider);
        _track(L1_HYPE_CONTRACT, L1_HYPE_CONTRACT);
        _track(address(this), address(this));
        _track(address(wmO), address(m)); // beHYPE escrow holder

        vm.deal(address(this), 1e30);
    }

    function _grantRoles(RoleRegistry r) private {
        r.grantRole(r.PROTOCOL_ADMIN(), admin);
        r.grantRole(r.PROTOCOL_GUARDIAN(), admin);
        r.grantRole(r.PROTOCOL_PAUSER(), admin);
    }

    function _addPair(address o, address mm) internal {
        pairO.push(o);
        pairM.push(mm);
    }

    function _track(address o, address mm) internal {
        trackedO.push(o);
        trackedM.push(mm);
    }

    /* ================================================================
     *                       HYPERCORE (L1) MOCKS
     * ================================================================ */

    /// @dev Sets identical HyperCore state for both systems' staking-core addresses.
    function _setL1(uint256 delegated, uint256 undelegated, uint64 pending8dec, uint256 spot) internal {
        _setL1For(address(scO), delegated, undelegated, pending8dec, spot);
        _setL1For(address(m), delegated, undelegated, pending8dec, spot);
    }

    function _setL1For(address who, uint256 delegated, uint256 undelegated, uint64 pending8dec, uint256 spot) private {
        // DelegatorSummaryMock scales delegated/undelegated by 1e10 but stores pending as given.
        DelegatorSummaryMock(DELEGATOR_SUMMARY_PRECOMPILE).setDelegatorSummary(who, delegated, undelegated, pending8dec);
        SpotBalanceMock(SPOT_BALANCE_PRECOMPILE).setSpotHypeBalance(who, spot);
    }

    /* ================================================================
     *                     DIFFERENTIAL EXECUTION
     * ================================================================ */

    struct Outcome {
        bool ok;
        bytes ret;
        Vm.Log[] logs;
        int256[] ethDelta;
    }

    /// @dev Same calldata, original target `oT`, merged target `mT`.
    function _dual(address caller, uint256 value, address oT, address mT, bytes memory data)
        internal returns (bool ok)
    {
        return _dual2(caller, value, oT, data, mT, data);
    }

    /// @dev Possibly different calldata (renamed functions).
    function _dual2(address caller, uint256 value, address oT, bytes memory oData, address mT, bytes memory mData)
        internal returns (bool ok)
    {
        Outcome memory o = _exec(caller, value, oT, oData, trackedO, false);
        Outcome memory r = _exec(caller, value, mT, mData, trackedM, true);

        string memory tag = _tag(mData);
        if (o.ok != r.ok) _diverged(string.concat(tag, ": success differs"));
        if (keccak256(_norm(o.ret)) != keccak256(r.ret)) _diverged(string.concat(tag, ": return/revert data differs"));
        _cmpLogs(o.logs, r.logs, tag);
        for (uint256 i = 0; i < o.ethDelta.length; i++) {
            // Protocol-held HYPE is compared as an aggregate in the last slot (SC+WM+token vs merged).
            if (i < trackedM.length && trackedM[i] == address(m)) continue;
            if (o.ethDelta[i] != r.ethDelta[i]) _diverged(string.concat(tag, ": ETH delta differs for tracked #", vm.toString(i)));
        }
        _compareState(tag);
        return o.ok;
    }

    function _exec(address caller, uint256 value, address target, bytes memory data, address[] storage tracked, bool merged)
        private returns (Outcome memory out)
    {
        // Under vm.prank, msg.value is debited from the pranked caller: fund it before snapshotting.
        if (value > 0) vm.deal(caller, caller.balance + value);
        uint256 n = tracked.length;
        uint256[] memory pre = new uint256[](n + 1);
        for (uint256 i = 0; i < n; i++) pre[i] = tracked[i].balance;
        pre[n] = _protocolEth(merged);

        vm.recordLogs();
        vm.prank(caller);
        (out.ok, out.ret) = target.call{value: value}(data);
        out.logs = vm.getRecordedLogs();

        out.ethDelta = new int256[](n + 1);
        for (uint256 i = 0; i < n; i++) out.ethDelta[i] = int256(tracked[i].balance) - int256(pre[i]);
        out.ethDelta[n] = int256(_protocolEth(merged)) - int256(pre[n]);
    }

    /// @dev ETH custodied by the protocol: StakingCore + WithdrawManager + token (original) vs merged.
    function _protocolEth(bool merged) private view returns (uint256) {
        if (merged) return address(m).balance;
        return address(scO).balance + address(wmO).balance + address(tokenO).balance;
    }

    function _cmpLogs(Vm.Log[] memory a, Vm.Log[] memory b, string memory tag) private {
        if (a.length != b.length) {
            _diverged(string.concat(tag, ": log count differs ", vm.toString(a.length), " vs ", vm.toString(b.length)));
            return;
        }
        for (uint256 i = 0; i < a.length; i++) {
            if (_mapAddr(a[i].emitter) != b[i].emitter) _diverged(string.concat(tag, ": log emitter differs #", vm.toString(i)));
            if (a[i].topics.length != b[i].topics.length) {
                _diverged(string.concat(tag, ": topic count differs #", vm.toString(i)));
                continue;
            }
            for (uint256 j = 0; j < a[i].topics.length; j++) {
                if (keccak256(_norm(abi.encode(a[i].topics[j]))) != keccak256(abi.encode(b[i].topics[j]))) {
                    _diverged(string.concat(tag, ": log topic differs #", vm.toString(i)));
                }
            }
            if (keccak256(_norm(a[i].data)) != keccak256(b[i].data)) _diverged(string.concat(tag, ": log data differs #", vm.toString(i)));
        }
    }

    /* ================================================================
     *                         STATE COMPARISON
     * ================================================================ */

    function _cmpView(address oT, bytes memory oData, bytes memory mData, string memory what) internal {
        (bool ok1, bytes memory r1) = oT.staticcall(oData);
        (bool ok2, bytes memory r2) = address(m).staticcall(mData);
        if (ok1 != ok2 || keccak256(_norm(r1)) != keccak256(r2)) _diverged(string.concat("state: ", what));
    }

    function _cmpView(address oT, bytes memory data, string memory what) internal {
        _cmpView(oT, data, data, what);
    }

    function _compareState(string memory ctx) internal {
        // Address-collapse preconditions: anything held at an original address that the merge folds
        // into address(m) must be zero on the non-canonical original contracts.
        if (address(wmO).balance != 0 || address(tokenO).balance != 0) _diverged(string.concat(ctx, ": HYPE stranded on WM/token"));
        if (tokenO.balanceOf(address(scO)) != 0 || tokenO.balanceOf(address(tokenO)) != 0) {
            _diverged(string.concat(ctx, ": beHYPE stranded on SC/token"));
        }

        // StakingCore
        _cmpView(address(scO), abi.encodeWithSignature("exchangeRatio()"), "exchangeRatio");
        _cmpView(address(scO), abi.encodeWithSignature("acceptablAprInBps()"), "acceptablAprInBps");
        _cmpView(address(scO), abi.encodeWithSignature("exchangeRateGuard()"), "exchangeRateGuard");
        _cmpView(address(scO), abi.encodeWithSignature("lastExchangeRatioUpdate()"), "lastExchangeRatioUpdate");
        _cmpView(address(scO), abi.encodeWithSignature("withdrawManager()"), "sc.withdrawManager");
        _cmpView(address(scO), abi.encodeWithSignature("beHypeToken()"), "sc.beHypeToken");
        _cmpView(address(scO), abi.encodeWithSignature("roleRegistry()"), "sc.roleRegistry");
        _cmpView(address(scO), abi.encodeWithSignature("paused()"), abi.encodeWithSignature("stakingPaused()"), "stakingPaused");
        _cmpView(address(scO), abi.encodeWithSignature("getTotalProtocolHype()"), "getTotalProtocolHype");
        _cmpView(address(scO), abi.encodeWithSignature("HYPEToBeHYPE(uint256)", 1 ether), "HYPEToBeHYPE");
        _cmpView(address(scO), abi.encodeWithSignature("BeHYPEToHYPE(uint256)", 1 ether), "BeHYPEToHYPE");

        // WithdrawManager
        _cmpView(address(wmO), abi.encodeWithSignature("hypeRequestedForWithdraw()"), "hypeRequestedForWithdraw");
        _cmpView(address(wmO), abi.encodeWithSignature("lastFinalizedIndex()"), "lastFinalizedIndex");
        _cmpView(address(wmO), abi.encodeWithSignature("minWithdrawalAmount()"), "minWithdrawalAmount");
        _cmpView(address(wmO), abi.encodeWithSignature("maxWithdrawalAmount()"), "maxWithdrawalAmount");
        _cmpView(address(wmO), abi.encodeWithSignature("instantWithdrawalFeeInBps()"), "instantWithdrawalFeeInBps");
        _cmpView(address(wmO), abi.encodeWithSignature("lowWatermarkInBpsOfTvl()"), "lowWatermarkInBpsOfTvl");
        _cmpView(address(wmO), abi.encodeWithSignature("instantWithdrawalLimit()"), "instantWithdrawalLimit");
        _cmpView(address(wmO), abi.encodeWithSignature("paused()"), abi.encodeWithSignature("withdrawalsPaused()"), "withdrawalsPaused");
        _cmpView(address(wmO), abi.encodeWithSignature("getPendingWithdrawalsCount()"), "getPendingWithdrawalsCount");
        _cmpView(address(wmO), abi.encodeWithSignature("getTotalInstantWithdrawableBeHYPE()"), "getTotalInstantWithdrawableBeHYPE");
        _cmpView(address(wmO), abi.encodeWithSignature("lowWatermarkInHYPE()"), "lowWatermarkInHYPE");
        _cmpView(address(wmO), abi.encodeWithSignature("getLiquidHypeAmount()"), "getLiquidHypeAmount");
        _cmpView(address(wmO), abi.encodeWithSignature("stakingCore()"), "wm.stakingCore");
        _cmpView(address(wmO), abi.encodeWithSignature("beHypeToken()"), "wm.beHypeToken");
        _cmpView(address(wmO), abi.encodeWithSignature("canInstantWithdraw(uint256)", 1 ether), "canInstantWithdraw");
        uint256 qLen = _queueLength();
        for (uint256 i = 0; i <= qLen; i++) { // i == qLen checks the out-of-bounds revert too
            _cmpView(address(wmO), abi.encodeWithSignature("getWithdrawalQueue(uint256)", i), "getWithdrawalQueue");
        }

        // BeHYPE
        _cmpView(address(tokenO), abi.encodeWithSignature("totalSupply()"), "totalSupply");
        _cmpView(address(tokenO), abi.encodeWithSignature("name()"), "name");
        _cmpView(address(tokenO), abi.encodeWithSignature("symbol()"), "symbol");
        _cmpView(address(tokenO), abi.encodeWithSignature("decimals()"), "decimals");
        _cmpView(address(tokenO), abi.encodeWithSignature("stakingCore()"), abi.encodeWithSignature("tokenStakingCore()"), "token.stakingCore");
        _cmpView(address(tokenO), abi.encodeWithSignature("withdrawManager()"), abi.encodeWithSignature("tokenWithdrawManager()"), "token.withdrawManager");

        for (uint256 i = 0; i < trackedO.length; i++) {
            _cmpView(address(tokenO), abi.encodeWithSignature("balanceOf(address)", trackedO[i]),
                abi.encodeWithSignature("balanceOf(address)", trackedM[i]), "balanceOf");
            _cmpView(address(tokenO), abi.encodeWithSignature("allowance(address,address)", trackedO[i], address(wmO)),
                abi.encodeWithSignature("allowance(address,address)", trackedM[i], address(m)), "allowance->WM");
            _cmpView(address(tokenO), abi.encodeWithSignature("nonces(address)", trackedO[i]),
                abi.encodeWithSignature("nonces(address)", trackedM[i]), "nonces");
            _cmpView(address(wmO), abi.encodeWithSignature("getUserUnFinalizedWithdrawals(address)", trackedO[i]),
                abi.encodeWithSignature("getUserUnFinalizedWithdrawals(address)", trackedM[i]), "getUserUnFinalizedWithdrawals");
        }

        // Custodied HYPE
        if (address(scO).balance != address(m).balance) _diverged(string.concat(ctx, ": protocol HYPE balance differs"));
    }

    function _queueLength() internal view returns (uint256 n) {
        // No length getter: probe until out of bounds (queue is small in tests).
        while (true) {
            (bool ok,) = address(wmO).staticcall(abi.encodeWithSignature("withdrawalQueue(uint256)", n));
            if (!ok) return n;
            n++;
        }
    }

    /* ================================================================
     *                           NORMALISATION
     * ================================================================ */

    function _mapAddr(address a) internal view returns (address) {
        for (uint256 i = 0; i < pairO.length; i++) {
            if (a == pairO[i]) return pairM[i];
        }
        return a;
    }

    /// @dev Replaces every 20-byte occurrence of an original-side address with its merged-side counterpart.
    function _norm(bytes memory b) internal view returns (bytes memory r) {
        r = bytes.concat(b);
        uint256 n = r.length;
        uint256 i = 0;
        while (i + 20 <= n) {
            address a;
            assembly { a := shr(96, mload(add(add(r, 32), i))) }
            address mapped = _mapAddr(a);
            if (mapped != a) {
                assembly {
                    let p := add(add(r, 32), i)
                    mstore(p, or(and(mload(p), 0xffffffffffffffffffffffff), shl(96, mapped)))
                }
                i += 20;
            } else {
                unchecked { ++i; }
            }
        }
    }

    function _tag(bytes memory data) internal pure returns (string memory) {
        if (data.length < 4) return "call(<empty>)";
        return string.concat("call(", vm.toString(abi.encodePacked(bytes4(data))), ")");
    }
}
