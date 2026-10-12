// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Base.t.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {IBeHYPEToken} from "../src/interfaces/IBeHype.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract BeHYPETest is BaseTest {
    using ECDSA for bytes32;

    // Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public override {
        super.setUp();
    }

    function test_InitialState() public view {
        assertEq(beHYPE.name(), "BeHYPE Token");
        assertEq(beHYPE.symbol(), "BeHYPE");
        assertEq(beHYPE.decimals(), 18);
        assertEq(beHYPE.totalSupply(), 0);
        assertEq(beHYPE.stakingCore(), address(stakingCore));
        assertEq(address(beHYPE.roleRegistry()), address(roleRegistry));
    }

    function test_Mint() public {
        uint256 amount = 100 ether;

        vm.prank(address(stakingCore));
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), user, amount);
        beHYPE.mint(user, amount);

        assertEq(beHYPE.balanceOf(user), amount);
        assertEq(beHYPE.totalSupply(), amount);
    }

    function test_Permit() public {
        uint256 privateKey = 0xA11CE;
        address owner = vm.addr(privateKey);
        address spender = makeAddr("bob");
        uint256 value = 100 ether;
        uint256 deadline = block.timestamp + 1 days;
        uint256 nonce = beHYPE.nonces(owner);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );

        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", beHYPE.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);

        beHYPE.permit(owner, spender, value, deadline, v, r, s);

        assertEq(beHYPE.allowance(owner, spender), value);
        assertEq(beHYPE.nonces(owner), 1);
    }

    function test_RevertPermitExpired() public {
        uint256 privateKey = 0xA11CE;
        address owner = vm.addr(privateKey);
        address spender = makeAddr("bob");
        uint256 value = 100 ether;
        uint256 deadline = block.timestamp - 1;
        uint256 nonce = beHYPE.nonces(owner);

        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                owner,
                spender,
                value,
                nonce,
                deadline
            )
        );

        bytes32 hash = keccak256(abi.encodePacked("\x19\x01", beHYPE.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, hash);

        vm.expectRevert(abi.encodeWithSelector(ERC20PermitUpgradeable.ERC2612ExpiredSignature.selector, deadline));
        beHYPE.permit(owner, spender, value, deadline, v, r, s);
    }

    function test_RevertUnauthorizedMint() public {
        uint256 amount = 100 ether;

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IBeHYPEToken.Unauthorized.selector));
        beHYPE.mint(user, amount);
    }

    function test_RevertUnauthorizedBurn() public {
        // First mint some tokens
        _mintTokens(user, 100 ether);

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IBeHYPEToken.Unauthorized.selector));
        beHYPE.burn(user, 50 ether);
    }

    function test_Burn() public {
        uint256 mintAmount = 100 ether;
        uint256 burnAmount = 50 ether;

        // First mint tokensEWh
        _mintTokens(user, mintAmount);
        assertEq(beHYPE.balanceOf(user), mintAmount);
        assertEq(beHYPE.totalSupply(), mintAmount);

        // Then burn tokens
        _burnTokens(user, burnAmount);
        assertEq(beHYPE.balanceOf(user), mintAmount - burnAmount);
        assertEq(beHYPE.totalSupply(), mintAmount - burnAmount);
    }

    function test_Transfer() public {
        uint256 amount = 100 ether;
        _mintTokens(user, amount);

        vm.prank(user);
        beHYPE.transfer(user2, 50 ether);

        assertEq(beHYPE.balanceOf(user), 50 ether);
        assertEq(beHYPE.balanceOf(user2), 50 ether);
    }

    function test_Approve() public {
        uint256 amount = 100 ether;
        _mintTokens(user, amount);

        vm.prank(user);
        beHYPE.approve(user2, 50 ether);

        assertEq(beHYPE.allowance(user, user2), 50 ether);
    }

    function test_TransferFrom() public {
        uint256 amount = 100 ether;
        _mintTokens(user, amount);

        vm.prank(user);
        beHYPE.approve(user2, 50 ether);

        vm.prank(user2);
        beHYPE.transferFrom(user, user2, 50 ether);

        assertEq(beHYPE.balanceOf(user), 50 ether);
        assertEq(beHYPE.balanceOf(user2), 50 ether);
        assertEq(beHYPE.allowance(user, user2), 0);
    }

    function test_UpgradeProxy() public {
        uint256 amount = 100 ether;
        _mintTokens(user, amount);
        assertEq(beHYPE.balanceOf(user), amount);
        assertEq(beHYPE.totalSupply(), amount);
        BeHYPE newBeHYPEImpl = new BeHYPE();
        console.log("New BeHYPE implementation deployed at:", address(newBeHYPEImpl));

        address oldImplementation = _getProxyImplementation(address(beHYPE));
        console.log("Old implementation address:", oldImplementation);

        vm.prank(admin);
        beHYPE.upgradeToAndCall(address(newBeHYPEImpl), "");

        address newImplementation = _getProxyImplementation(address(beHYPE));
        console.log("New implementation address:", newImplementation);
        assertEq(newImplementation, address(newBeHYPEImpl));
        assertTrue(newImplementation != oldImplementation);

        _mintTokens(user2, 50 ether);
        assertEq(beHYPE.balanceOf(user2), 50 ether);
        assertEq(beHYPE.totalSupply(), amount + 50 ether);
    }

    function test_RevertUpgradeUnauthorized() public {
        BeHYPE newBeHYPEImpl = new BeHYPE();

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(IRoleRegistry.OnlyProtocolUpgrader.selector));
        beHYPE.upgradeToAndCall(address(newBeHYPEImpl), "");
    }

    function test_RevertReinitialization() public {
        vm.prank(admin);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        beHYPE.initialize(
            "BeHYPE Token",
            "BeHYPE",
            address(roleRegistry),
            address(stakingCore),
            address(withdrawManager)
        );
    }

}
