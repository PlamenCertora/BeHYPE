// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base.t.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract WithdrawManagerTest is BaseTest {

    function setUp() public override {
        super.setUp();

        vm.prank(user);
        stakingCore.stake{value: 1 ether}("");

        vm.prank(user2);
        stakingCore.stake{value: 10 ether}("");
    }

    function test_withdraw() public {
        vm.startPrank(user);
        beHYPE.approve(address(withdrawManager), 1 ether);
        withdrawManager.withdraw(1 ether, false);
        vm.stopPrank();

        assertEq(beHYPE.balanceOf(user), 0 ether);
        assertEq(beHYPE.balanceOf(address(withdrawManager)), 1 ether);

        vm.startPrank(user2);
        beHYPE.approve(address(withdrawManager), 10 ether);
        withdrawManager.withdraw(10 ether, false);
        vm.stopPrank();

        assertEq(withdrawManager.hypeRequestedForWithdraw(), 11 ether);
        assertEq(beHYPE.balanceOf(user2), 0 ether);
        assertEq(beHYPE.balanceOf(address(withdrawManager)), 11 ether);

        uint256[] memory unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user);
        assertEq(unFinalizedWithdrawals.length, 1);
        assertEq(unFinalizedWithdrawals[0], 1);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user2);
        assertEq(unFinalizedWithdrawals.length, 1);
        assertEq(unFinalizedWithdrawals[0], 2);

        uint256 balanceBeforeBeHYPE = beHYPE.balanceOf(address(withdrawManager));
        uint256 balanceBefore = address(user).balance;
        vm.prank(admin);
        withdrawManager.finalizeWithdrawals(1);
        assertEq(beHYPE.balanceOf(address(withdrawManager)), balanceBeforeBeHYPE - 1 ether);
        assertEq(user.balance, balanceBefore + 1 ether);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user);
        assertEq(unFinalizedWithdrawals.length, 0);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user2);
        assertEq(unFinalizedWithdrawals.length, 1);
        assertEq(unFinalizedWithdrawals[0], 2);
    }

    function test_withdraw_with_exchange_rate() public {
        vm.deal(user, 100 ether);
        vm.prank(user);
        stakingCore.stake{value: 89 ether}("");

        assertEq(stakingCore.getTotalProtocolHype(), 100 ether);

        vm.startPrank(user);
        beHYPE.approve(address(withdrawManager), 20 ether);
        withdrawManager.withdraw(5 ether, false);
        withdrawManager.withdraw(5 ether, false);
        withdrawManager.withdraw(5 ether, false);
        withdrawManager.withdraw(5 ether, false);
        vm.stopPrank();

        assertEq(withdrawManager.hypeRequestedForWithdraw(), 20 ether);

        uint256 balanceBefore = address(user).balance;
        vm.prank(admin);
        withdrawManager.finalizeWithdrawals(2);

        assertEq(stakingCore.getTotalProtocolHype(), 90 ether);
        assertEq(withdrawManager.hypeRequestedForWithdraw(), 10 ether);
        assertEq(user.balance, balanceBefore + 10 ether);

        // update exchange rate to 1 BeHYPE = 2 HYPE
        DelegatorSummaryMock(DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS).setDelegatorSummary(address(stakingCore), 90 ether, 0, 0);
        vm.warp(block.timestamp + (365 days * 100));
        vm.prank(admin);
        stakingCore.updateExchangeRatio();
        assertEq(stakingCore.BeHYPEToHYPE(1 ether), 2 ether);
        assertEq(withdrawManager.hypeRequestedForWithdraw(), 10 ether);

        // test core writer withdrawal guard (no effect on state)
        vm.startPrank(admin);
        stakingCore.withdrawFromStaking(5 ether);
        vm.expectRevert(abi.encodeWithSelector(IStakingCore.NotAuthorized.selector));
        stakingCore.withdrawFromStaking(11 ether);

        stakingCore.withdrawFromHyperCore(5 ether);
        vm.expectRevert(abi.encodeWithSelector(IStakingCore.NotAuthorized.selector));
        stakingCore.withdrawFromHyperCore(11 ether);
        vm.stopPrank();

        vm.prank(admin);
        withdrawManager.finalizeWithdrawals(4);

        assertEq(user.balance, balanceBefore + 20 ether);
        assertEq(withdrawManager.hypeRequestedForWithdraw(), 0);
    }

    function test_withdraw_finalization_reverts() public {
        vm.deal(user, 100 ether);
        vm.prank(user);
        stakingCore.stake{value: 89 ether}("");
        assertEq(stakingCore.getTotalProtocolHype(), 100 ether);

        // update exchange rate to 1 BeHYPE = 2 HYPE
        DelegatorSummaryMock(DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS).setDelegatorSummary(address(stakingCore), 100 ether, 0, 0);
        vm.warp(block.timestamp + (365 days * 100));
        vm.prank(admin);
        stakingCore.updateExchangeRatio();
        assertEq(stakingCore.BeHYPEToHYPE(1 ether), 2 ether);

        vm.startPrank(user);
        beHYPE.approve(address(withdrawManager), 100 ether);
        withdrawManager.withdraw(45 ether, false);
        vm.stopPrank();

        vm.prank(admin);
        withdrawManager.finalizeWithdrawals(1);

        assertEq(withdrawManager.hypeRequestedForWithdraw(), 0);
        assertEq(withdrawManager.getLiquidHypeAmount(), 10 ether);

        vm.startPrank(user);
        withdrawManager.withdraw(1 ether, false);
        withdrawManager.withdraw(1 ether, false);
        withdrawManager.withdraw(1 ether, false);
        withdrawManager.withdraw(1 ether, false);
        withdrawManager.withdraw(1 ether, false);
        withdrawManager.withdraw(1 ether, false);
        vm.stopPrank();

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(IStakingCore.FailedToSendFromWithdrawManager.selector));
        withdrawManager.finalizeWithdrawals(7);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawManager.IndexOutOfBounds.selector));
        withdrawManager.finalizeWithdrawals(8);

        vm.expectRevert(abi.encodeWithSelector(IWithdrawManager.CanOnlyFinalizeForward.selector));
        withdrawManager.finalizeWithdrawals(1);
    }

    /* ========== INSTANT WITHDRAWAL TESTS ========== */

    function test_instantWithdrawal() public {
        vm.deal(user, 100 ether);

        vm.prank(user);
        stakingCore.stake{value: 89 ether}("");
        assertEq(stakingCore.getTotalProtocolHype(), 100 ether);

        mockDepositToHyperCore(98 ether);

        assertEq(withdrawManager.getLiquidHypeAmount(), 2 ether);
        assertEq(withdrawManager.getTotalInstantWithdrawableBeHYPE(), 1 ether);
        
        vm.startPrank(user);
        uint256 userBalanceBefore = user.balance;
        beHYPE.approve(address(withdrawManager), 1 ether);
        withdrawManager.withdraw(1 ether, true);
        
        uint256 instantWithdrawalFee = 0.003 ether; // 30 bps fee on 1 ether
        assertEq(beHYPE.balanceOf(roleRegistry.protocolTreasury()), instantWithdrawalFee);
        assertEq(user.balance, userBalanceBefore + 0.997 ether);
        assertEq(beHYPE.balanceOf(address(withdrawManager)), 0 ether);

        beHYPE.approve(address(withdrawManager), 1 ether);
        vm.expectRevert(IWithdrawManager.InsufficientHYPELiquidity.selector);
        withdrawManager.withdraw(0.1 ether, true);
    }

    function test_instantWithdrawal_with_exchange_rate() public {
        vm.deal(user, 100 ether);

        vm.prank(user);
        stakingCore.stake{value: 89 ether}("");
        assertEq(stakingCore.getTotalProtocolHype(), 100 ether);

        mockDepositToHyperCore(96 ether);

        // update exchange rate to 1 BeHYPE = 2 HYPE
        DelegatorSummaryMock(DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS).setDelegatorSummary(address(stakingCore), 100 ether, 0, 0);
        vm.warp(block.timestamp + (365 days * 100));
        vm.prank(admin);
        stakingCore.updateExchangeRatio();
        assertEq(stakingCore.BeHYPEToHYPE(1 ether), 2 ether);

        uint256 userBalanceBefore = user.balance;
        vm.startPrank(user);
        beHYPE.approve(address(withdrawManager), 1 ether);
        withdrawManager.withdraw(1 ether, true);

        assertEq(beHYPE.balanceOf(roleRegistry.protocolTreasury()), 0.003 ether);
        assertEq(user.balance - userBalanceBefore, stakingCore.BeHYPEToHYPE(0.997 ether));

        beHYPE.approve(address(withdrawManager), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IWithdrawManager.InsufficientHYPELiquidity.selector));
        withdrawManager.withdraw(0.1 ether, true);
    }

    function test_instantWithdrawalRateLimit() public {
        vm.deal(user, 5000 ether);

        vm.startPrank(user);
        stakingCore.stake{value: 5000 ether}("");
        
        beHYPE.approve(address(withdrawManager), 15 ether);
        withdrawManager.withdraw(5 ether, true);

        withdrawManager.withdraw(5 ether, true);

        
        vm.expectRevert(abi.encodeWithSelector(IWithdrawManager.InstantWithdrawalRateLimitExceeded.selector));
        withdrawManager.withdraw(5 ether, true);

        vm.warp(block.timestamp + 1 days);
        withdrawManager.withdraw(5 ether, true);
    }

    function test_multipleUsersMultipleWithdrawals() public {
        address user3 = makeAddr("user3");
        address user4 = makeAddr("user4");
        
        vm.deal(user3, 50 ether);
        vm.deal(user4, 75 ether);
        
        vm.prank(user3);
        stakingCore.stake{value: 25 ether}("");
        
        vm.prank(user4);
        stakingCore.stake{value: 40 ether}("");
        
        // User 1: 1 ether stake, 2 withdrawals (0.3 ether, 0.7 ether)
        vm.startPrank(user);
        beHYPE.approve(address(withdrawManager), 1 ether);
        withdrawManager.withdraw(0.3 ether, false);
        withdrawManager.withdraw(0.7 ether, false);
        vm.stopPrank();
        
        // User 2: 10 ether stake, 3 withdrawals (2 ether, 3 ether, 5 ether)
        vm.startPrank(user2);
        beHYPE.approve(address(withdrawManager), 10 ether);
        withdrawManager.withdraw(2 ether, false);
        withdrawManager.withdraw(3 ether, false);
        withdrawManager.withdraw(5 ether, false);
        vm.stopPrank();
        
        // User 3: 25 ether stake, 2 withdrawals (8 ether, 17 ether)
        vm.startPrank(user3);
        beHYPE.approve(address(withdrawManager), 25 ether);
        withdrawManager.withdraw(8 ether, false);
        withdrawManager.withdraw(17 ether, false);
        vm.stopPrank();
        
        // User 4: 40 ether stake, 3 withdrawals (10 ether, 15 ether, 15 ether)
        vm.startPrank(user4);
        beHYPE.approve(address(withdrawManager), 40 ether);
        withdrawManager.withdraw(10 ether, false);
        withdrawManager.withdraw(15 ether, false);
        withdrawManager.withdraw(15 ether, false);
        vm.stopPrank();

        uint256 userBalanceBefore = user.balance;
        uint256 user2BalanceBefore = user2.balance;
        uint256 user3BalanceBefore = user3.balance;
        uint256 user4BalanceBefore = user4.balance;

        uint256[] memory unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user);
        assertEq(unFinalizedWithdrawals.length, 2);
        assertEq(unFinalizedWithdrawals[0], 1);
        assertEq(unFinalizedWithdrawals[1], 2);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user2);
        assertEq(unFinalizedWithdrawals.length, 3);
        assertEq(unFinalizedWithdrawals[0], 3);
        assertEq(unFinalizedWithdrawals[1], 4);
        assertEq(unFinalizedWithdrawals[2], 5);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user3);
        assertEq(unFinalizedWithdrawals.length, 2);
        assertEq(unFinalizedWithdrawals[0], 6);
        assertEq(unFinalizedWithdrawals[1], 7);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user4);
        assertEq(unFinalizedWithdrawals.length, 3);
        assertEq(unFinalizedWithdrawals[0], 8);
        assertEq(unFinalizedWithdrawals[1], 9);
        assertEq(unFinalizedWithdrawals[2], 10);

        // Finalize withdrawals in batches
        vm.prank(admin);
        withdrawManager.finalizeWithdrawals(6); // Finalize first 5 withdrawals (users 1, 2, and user 3 first withdrawal)

        assertEq(user.balance, userBalanceBefore + 1 ether);
        assertEq(user2.balance, user2BalanceBefore + 10 ether);
        assertEq(user3.balance, user3BalanceBefore + 8 ether);
        assertEq(user4.balance, user4BalanceBefore);
        assertEq(withdrawManager.hypeRequestedForWithdraw(), 57 ether);
        assertEq(withdrawManager.getPendingWithdrawalsCount(), 4);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user);
        assertEq(unFinalizedWithdrawals.length, 0);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user2);
        assertEq(unFinalizedWithdrawals.length, 0);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user3);
        assertEq(unFinalizedWithdrawals.length, 1);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user4);
        assertEq(unFinalizedWithdrawals.length, 3);
        
        vm.prank(admin);
        withdrawManager.finalizeWithdrawals(10);

        assertEq(user.balance, userBalanceBefore + 1 ether);
        assertEq(user2.balance, user2BalanceBefore + 10 ether);
        assertEq(user3.balance, user3BalanceBefore + 25 ether);
        assertEq(user4.balance, user4BalanceBefore + 40 ether);
        assertEq(withdrawManager.hypeRequestedForWithdraw(), 0);
        assertEq(withdrawManager.getPendingWithdrawalsCount(), 0);
        assertEq(beHYPE.balanceOf(address(withdrawManager)), 0);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user3);
        assertEq(unFinalizedWithdrawals.length, 0);

        unFinalizedWithdrawals = withdrawManager.getUserUnFinalizedWithdrawals(user4);
        assertEq(unFinalizedWithdrawals.length, 0);
    }
    function test_RevertUpgradeUnauthorized() public {
        WithdrawManager newWithdrawManagerImpl = new WithdrawManager();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRoleRegistry.OnlyProtocolUpgrader.selector));
        withdrawManager.upgradeToAndCall(address(newWithdrawManagerImpl), "");
    }

    function test_UpgradeSuccess() public {
        WithdrawManager newWithdrawManagerImpl = new WithdrawManager();

        vm.prank(admin);
        withdrawManager.upgradeToAndCall(address(newWithdrawManagerImpl), "");

        assertEq(withdrawManager.getPendingWithdrawalsCount(), 0);
    }

    function test_RevertReinitialization() public {
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        withdrawManager.initialize(
            0.1 ether,
            100 ether,
            100,
            30,
            address(roleRegistry), 
            address(beHYPE),
            address(stakingCore),
            10 ether,
            1 days
        );
    }

}
