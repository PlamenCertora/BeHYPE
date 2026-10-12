// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {UUPSProxy} from "../src/lib/UUPSProxy.sol";
import {BeHYPE} from "../src/BeHYPE.sol";
import {RoleRegistry} from "../src/RoleRegistry.sol";
import {StakingCore} from "../src/StakingCore.sol";
import {CoreWriter} from "../src/lib/CoreWriter.sol";
import {WithdrawManager} from "../src/WithdrawManager.sol";
import {StakingCore} from "../src/StakingCore.sol";
import {IStakingCore} from "../src/interfaces/IStakingCore.sol";
import {IWithdrawManager} from "../src/interfaces/IWithdrawManager.sol";
import {IRoleRegistry} from "../src/interfaces/IRoleRegistry.sol";
import {L1Read} from "../src/lib/L1Read.sol";
import {SpotBalanceMock} from "./mock/SpotBalanceMock.sol";
import {DelegatorSummaryMock} from "./mock/DelegatorSummaryMock.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "forge-std/console.sol";

contract BaseTest is Test {
    using Math for uint256;
    
    BeHYPE public beHYPE;
    RoleRegistry public roleRegistry;
    WithdrawManager public withdrawManager;
    StakingCore public stakingCore;

    address public admin = makeAddr("admin");
    address public user = makeAddr("user");
    address public user2 = makeAddr("user2");
    address public protocolTreasury = makeAddr("protocolTreasury");

    address constant SPOT_BALANCE_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000801;
    address constant DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000805;
    // TODO: add this to an address registry bc its one of our deployed address and not a precompile
    address constant L1_READ_PRECOMPILE_ADDRESS = 0xb7467E0524Afba7006957701d1F06A59000d15A2;
    address constant CORE_WRITER_PRECOMPILE_ADDRESS = 0x3333333333333333333333333333333333333333;

    function _getProxyImplementation(address proxy) internal view returns (address) {
        bytes32 implSlot = vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT);
        return address(uint160(uint256(implSlot)));
    }

    function setUp() public virtual {
        SpotBalanceMock spotBalanceMock = new SpotBalanceMock();
        DelegatorSummaryMock delegatorSummaryMock = new DelegatorSummaryMock();
        L1Read l1Read = new L1Read();
        CoreWriter coreWriter = new CoreWriter();

        vm.etch(SPOT_BALANCE_PRECOMPILE_ADDRESS, address(spotBalanceMock).code);
        vm.etch(DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS, address(delegatorSummaryMock).code);
        vm.etch(L1_READ_PRECOMPILE_ADDRESS, address(l1Read).code);
        vm.etch(CORE_WRITER_PRECOMPILE_ADDRESS, address(coreWriter).code);
        
        RoleRegistry roleRegistryImpl = new RoleRegistry();
        roleRegistry = RoleRegistry(address(new UUPSProxy(
            address(roleRegistryImpl),
            abi.encodeWithSelector(RoleRegistry.initialize.selector, admin, address(0), address(0), protocolTreasury)
        )));

        BeHYPE beHYPEImpl = new BeHYPE();
        beHYPE = BeHYPE(address(new UUPSProxy(
            address(beHYPEImpl),
            abi.encodeWithSelector(
                BeHYPE.initialize.selector,
                "BeHYPE Token",
                "BeHYPE",
                address(roleRegistry),
                address(0)
            )
        )));

        StakingCore stakingCoreImpl = new StakingCore();
        stakingCore = StakingCore(payable(address(new UUPSProxy(
            address(stakingCoreImpl),
            abi.encodeWithSelector(
                StakingCore.initialize.selector,
                address(roleRegistry),
                address(beHYPE),
                address(withdrawManager),
                400,
                true
            )
        ))));

        WithdrawManager withdrawManagerImpl = new WithdrawManager();
        withdrawManager = WithdrawManager(payable(address(new UUPSProxy(
            address(withdrawManagerImpl),
            abi.encodeWithSelector(WithdrawManager.initialize.selector,
                0.1 ether,
                100 ether,
                100,
                30,
                address(roleRegistry), 
                address(beHYPE),
                address(stakingCore),
                10 ether,
                1 days
            )
        ))));

        vm.startPrank(admin);
        beHYPE.setStakingCore(address(stakingCore));
        beHYPE.setWithdrawManager(address(withdrawManager));
        stakingCore.setWithdrawManager(address(withdrawManager));
        roleRegistry.grantRole(roleRegistry.PROTOCOL_ADMIN(), admin);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_GUARDIAN(), admin);
        roleRegistry.setWithdrawManager(address(withdrawManager));
        roleRegistry.setStakingCore(address(stakingCore));
        vm.stopPrank();

        vm.deal(user, 10 ether);
        vm.deal(user2, 10 ether);
    }

    function _mintTokens(address to, uint256 amount) internal {
        vm.prank(address(stakingCore));
        beHYPE.mint(to, amount);
    }

    function _burnTokens(address from, uint256 amount) internal {
        vm.prank(address(withdrawManager));
        beHYPE.burn(from, amount);
    }

    function _convertTo8Decimals(uint256 amount) internal pure returns (uint64) {
        uint256 truncatedAmount = amount / 1e10;
        if (truncatedAmount > type(uint64).max) revert("Amount exceeds uint64 max");
        return uint64(truncatedAmount);
    }

    function _convertTo18Decimals(uint64 amount) internal pure returns (uint256) {
        return uint256(amount) * 1e10;
    }


    function mockDepositToHyperCore(uint256 amount) public {
        L1Read.SpotBalance memory spotBalanceBefore = L1Read(L1_READ_PRECOMPILE_ADDRESS).spotBalance(address(stakingCore), 150);

        vm.prank(admin);
        stakingCore.depositToHyperCore(amount);

        uint256 newTotalInSpotAccount = _convertTo18Decimals(spotBalanceBefore.total) + amount;

        SpotBalanceMock(SPOT_BALANCE_PRECOMPILE_ADDRESS).setSpotHypeBalance(address(stakingCore), newTotalInSpotAccount);
    }
}
