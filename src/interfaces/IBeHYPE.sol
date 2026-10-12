// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IBeHYPEToken
 * @notice Interface for the BeHYPE token contract
 */
interface IBeHYPEToken is IERC20 {

    error Unauthorized();

    event StakingCoreUpdated(address stakingCore);
    event WithdrawManagerUpdated(address withdrawManager);
    
    /**
     * @notice Mints new tokens to the specified address
     * @param to Address to receive the minted tokens
     * @param amount Amount of tokens to mint
     */
    function mint(address to, uint256 amount) external;

    /**
     * @notice Burns tokens from the specified address
     * @param from Address to burn tokens fro
     * @param amount Amount of tokens to burn
     */
    function burn(address from, uint256 amount) external;
}
