// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseTest} from "./Base.t.sol";
import {RoleRegistry} from "../src/RoleRegistry.sol";
import {IStakingCore} from "../src/interfaces/IStakingCore.sol";
import {IWithdrawManager} from "../src/interfaces/IWithdrawManager.sol";
import {IRoleRegistry} from "../src/interfaces/IRoleRegistry.sol";
import {OwnableUpgradeable} from "@openzeppelin-upgradeable/access/OwnableUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin-upgradeable/access/Ownable2StepUpgradeable.sol";
import {EnumerableRoles} from "solady/auth/EnumerableRoles.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract RoleRegistryTest is BaseTest {
    address public guardian = makeAddr("guardian");
    address public pauser = makeAddr("pauser");
    address public unauthorized = makeAddr("unauthorized");

    function setUp() public override {
        super.setUp();
        
        vm.startPrank(admin);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_GUARDIAN(), guardian);
        roleRegistry.grantRole(roleRegistry.PROTOCOL_PAUSER(), pauser);
        vm.stopPrank();
    }

    function test_setProtocolTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        
        vm.prank(guardian);
        roleRegistry.setProtocolTreasury(newTreasury);
        
        assertEq(roleRegistry.protocolTreasury(), newTreasury);
    }

    function test_setProtocolTreasury_revertIfNotGuardian() public {
        address newTreasury = makeAddr("newTreasury");
        
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IRoleRegistry.NotAuthorized.selector));
        roleRegistry.setProtocolTreasury(newTreasury);
    }

    function test_pauseProtocol() public {
        vm.prank(pauser);
        roleRegistry.pauseProtocol();
        
        assertTrue(stakingCore.paused());
        assertTrue(withdrawManager.paused());
        
        vm.expectRevert(IStakingCore.StakingPaused.selector);
        stakingCore.stake("test");
        
        vm.expectRevert(IWithdrawManager.WithdrawalsPaused.selector);
        withdrawManager.withdraw(1 ether, false);
    }

    function test_pauseProtocol_revertIfNotPauser() public {
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IRoleRegistry.NotAuthorized.selector));
        roleRegistry.pauseProtocol();
    }

    function test_unpauseProtocol() public {
        vm.prank(pauser);
        roleRegistry.pauseProtocol();
        
        assertTrue(stakingCore.paused());
        assertTrue(withdrawManager.paused());
        
        vm.prank(guardian);
        roleRegistry.unpauseProtocol();
        
        assertFalse(stakingCore.paused());
        assertFalse(withdrawManager.paused());
        
        vm.deal(user, 1 ether);
        vm.startPrank(user);
        stakingCore.stake{value: 1 ether}("test");
        beHYPE.approve(address(withdrawManager), 1 ether);
        withdrawManager.withdraw(1 ether, false);
    }

    function test_unpauseProtocol_revertIfNotUnpauser() public {
        vm.prank(pauser);
        roleRegistry.pauseProtocol();
        
        vm.prank(unauthorized);
        vm.expectRevert(abi.encodeWithSelector(IRoleRegistry.NotAuthorized.selector));
        roleRegistry.unpauseProtocol();
    }

    function test_pauseAndUnpauseProtocol_cycle() public {
        vm.deal(user, 2 ether);
        
        vm.prank(user);
        stakingCore.stake{value: 1 ether}("test");
        
        vm.prank(pauser);
        roleRegistry.pauseProtocol();
        
        assertTrue(stakingCore.paused());
        assertTrue(withdrawManager.paused());
        
        vm.expectRevert(IStakingCore.StakingPaused.selector);
        vm.prank(user);
        stakingCore.stake{value: 1 ether}("test");
        
        vm.prank(user);
        beHYPE.approve(address(withdrawManager), 1 ether);
        vm.expectRevert(IWithdrawManager.WithdrawalsPaused.selector);
        vm.prank(user);
        withdrawManager.withdraw(1 ether, false);
        
        vm.prank(guardian);
        roleRegistry.unpauseProtocol();
        
        assertFalse(stakingCore.paused());
        assertFalse(withdrawManager.paused());
        
        vm.startPrank(user);
        stakingCore.stake{value: 1 ether}("test");
        beHYPE.approve(address(withdrawManager), 1 ether);
        withdrawManager.withdraw(1 ether, false);
    }

    function test_RevertUpgradeUnauthorized() public {
        RoleRegistry newRoleRegistryImpl = new RoleRegistry();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, user));
        roleRegistry.upgradeToAndCall(address(newRoleRegistryImpl), "");
    }

    function test_UpgradeSuccess() public {
        RoleRegistry newRoleRegistryImpl = new RoleRegistry();

        vm.prank(admin);
        roleRegistry.upgradeToAndCall(address(newRoleRegistryImpl), "");

        assertEq(roleRegistry.protocolTreasury(), protocolTreasury);
    }

    function test_RevertReinitialization() public {
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        roleRegistry.initialize(
            admin,
            address(withdrawManager),
            address(stakingCore),
            protocolTreasury
        );
    }

    function test_TwoStepOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");
        
        vm.prank(admin);
        roleRegistry.transferOwnership(newOwner);
        
        assertEq(roleRegistry.pendingOwner(), newOwner);
        assertEq(roleRegistry.owner(), admin);
        
        vm.prank(newOwner);
        roleRegistry.acceptOwnership();
        
        assertEq(roleRegistry.owner(), newOwner);
        assertEq(roleRegistry.pendingOwner(), address(0));
        
        bytes32 guardianRole = roleRegistry.PROTOCOL_GUARDIAN();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(EnumerableRoles.EnumerableRolesUnauthorized.selector));
        roleRegistry.grantRole(guardianRole, makeAddr("newGuardian"));
        
        address newGuardian = makeAddr("newGuardian");
        vm.prank(newOwner);
        roleRegistry.grantRole(guardianRole, newGuardian);
        assertTrue(roleRegistry.hasRole(guardianRole, newGuardian));
    }

}
