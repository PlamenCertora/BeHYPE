// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base.t.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract StakingCoreTest is BaseTest {

    function setUp() public override {
        super.setUp();
    }

    function test_stake() public {
        vm.prank(user);
        stakingCore.stake{value: 1 ether}("test");

        assertEq(beHYPE.balanceOf(user), 1 ether);

        vm.prank(admin);
        vm.warp(block.timestamp + 1 days);
        stakingCore.updateExchangeRatio();

        assertEq(stakingCore.exchangeRatio(), 1 ether);
    }

    function test_ExchangeRatio() public {
        test_stake();

        // 1% APR
        DelegatorSummaryMock(DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS).setDelegatorSummary(address(stakingCore), 0.01 ether, 0, 0);
        vm.warp(block.timestamp + 365 days);

        vm.prank(admin);
        stakingCore.updateExchangeRatio();

        assertEq(stakingCore.exchangeRatio(), 1.01 ether);
        assertEq(stakingCore.BeHYPEToHYPE(1 ether), 1.01 ether);
        assertEq(stakingCore.HYPEToBeHYPE(1 ether), 990099009900990099);

    }

    function test_ExchangeRatio_should_revert_if_apr_exceeds_threshold() public {
        test_stake();

        // 5% APR
        DelegatorSummaryMock(DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS).setDelegatorSummary(address(stakingCore), 0.05 ether, 0, 0);
        vm.warp(block.timestamp + 365 days);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IStakingCore.ExchangeRatioChangeExceedsThreshold.selector, 500));
        stakingCore.updateExchangeRatio();
    }

    function test_ExchangeRatio_negative() public {
        test_ExchangeRatio();

        // -1% APR
        DelegatorSummaryMock(DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS).setDelegatorSummary(address(stakingCore), 0, 0, 0);
        vm.warp(block.timestamp + 365 days);

        vm.prank(admin);
        stakingCore.updateExchangeRatio();
        assertEq(stakingCore.exchangeRatio(), 1 ether);
        assertEq(stakingCore.BeHYPEToHYPE(1 ether), 1 ether);
        assertEq(stakingCore.HYPEToBeHYPE(1 ether), 1 ether);
    }

    function test_ExchangeRatio_should_revert_if_apr_exceeds_threshold_negative() public {
        test_ExchangeRatio();

        // -10% APR (-0.01 in 1/10 year ~ -10% in apr)
        DelegatorSummaryMock(DELEGATOR_SUMMARY_PRECOMPILE_ADDRESS).setDelegatorSummary(address(stakingCore), 0, 0, 0);
        vm.warp(block.timestamp + 36.5 days);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IStakingCore.ExchangeRatioChangeExceedsThreshold.selector, 990));
        stakingCore.updateExchangeRatio();
    }

    function test_MockDepositToHyperCore() public {
        test_stake();

        uint256 balanceBefore = address(stakingCore).balance;
        uint256 totalPooledEtherBefore = stakingCore.getTotalProtocolHype();

        mockDepositToHyperCore(1 ether);

        assertEq(address(stakingCore).balance, balanceBefore - 1 ether);
        assertEq(stakingCore.getTotalProtocolHype(), totalPooledEtherBefore);
    }

    function test_RevertUpgradeUnauthorized() public {
        StakingCore newStakingCoreImpl = new StakingCore();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRoleRegistry.OnlyProtocolUpgrader.selector));
        stakingCore.upgradeToAndCall(address(newStakingCoreImpl), "");
    }

    function test_UpgradeSuccess() public {
        StakingCore newStakingCoreImpl = new StakingCore();

        vm.prank(admin);
        stakingCore.upgradeToAndCall(address(newStakingCoreImpl), "");

        assertEq(stakingCore.exchangeRatio(), 1 ether);
    }

    function test_RevertReinitialization() public {
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        stakingCore.initialize(
            address(roleRegistry),
            address(beHYPE),
            address(withdrawManager),
            400,
            true
        );
    }

}
