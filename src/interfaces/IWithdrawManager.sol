// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRoleRegistry} from "./IRoleRegistry.sol";
import {IBeHYPEToken} from "./IBeHYPE.sol";
import {IStakingCore} from "./IStakingCore.sol";

/**
 * @title IWithdrawManager
 * @notice Interface for the WithdrawalQueue contract
 * @dev Defines all public and external functions for withdrawal management
 */
interface IWithdrawManager {

    /* ========== STRUCTS ========== */
    
    struct WithdrawalEntry {
        address user;              // Address of the user
        uint256 beHypeAmount;      // Amount of beHYPE tokens locked for withdrawal
        uint256 hypeAmount;        // Amount of HYPE to be withdrawn
        bool finalized;            // Whether the withdrawal has been finalized
    }

    /* ========== ERRORS ========== */

    error WithdrawalsPaused();
    error InvalidAmount();
    error InsufficientBeHYPEBalance();
    error NotAuthorized();
    error IndexOutOfBounds();
    error CanOnlyFinalizeForward();
    error WithdrawalNotFinalized();
    error InvalidWithdrawalID();
    error TransferFailed();
    error WithdrawalsNotPaused();
    error InsufficientHYPELiquidity();
    error InstantWithdrawalRateLimitExceeded();
    error InvalidInstantWithdrawalFee();

    /* ========== EVENTS ========== */
    
    event WithdrawalQueued(
        address indexed user,
        uint256 indexed withdrawalId,
        uint256 beHypeAmount,
        uint256 hypeAmount,
        uint256 queueIndex
    );
    
    event WithdrawalsBatchFinalized(uint256 upToIndex);
    
    event InstantWithdrawal(
        address indexed user,
        uint256 beHypeAmountWithdrawn,
        uint256 hypeAmountReceived,
        uint256 beHypeInstantWithdrawalFee
    );
    
    event InstantWithdrawalFeeInBpsUpdated(uint256 instantWithdrawalFeeInBps);
    
    /* ========== MAIN FUNCTIONS ========== */
    
    /**
     * @notice Queue a withdrawal request
     * @param beHypeAmount Amount of beHYPE tokens to withdraw
     * @param instant Whether to withdraw instantly for a fee or queue
     * @return withdrawalId The ID of the withdrawal request
     */
    function withdraw(uint256 beHypeAmount, bool instant) external returns (uint256 withdrawalId);
    
    /**
     * @notice Finalize withdrawals up to a specific index (protocol governor only)
     * @param index Index up to which withdrawals should be finalized
     */
    function finalizeWithdrawals(uint256 index) external;
    
    /* ========== VIEW FUNCTIONS ========== */
    
    /**
     * @notice Get the count of pending (unfinalized) withdrawals
     * @return uint256 Number of pending withdrawals
     */
    function getPendingWithdrawalsCount() external view returns (uint256);
    
    /**
     * @notice Check if a withdrawal amount can be instant withdrawn
     * @param beHypeAmount Amount of beHYPE tokens to withdraw
     * @return bool True if the withdrawal can be instant withdrawn
     */
    function canInstantWithdraw(uint256 beHypeAmount) external view returns (bool);
    
    /**
     * @notice Get a withdrawal entry from the queue
     * @param index Index of the withdrawal entry
     * @return WithdrawalEntry The withdrawal entry
     */
    function getWithdrawalQueue(uint256 index) external view returns (WithdrawalEntry memory);

    /**
     * @notice Get the amount of hype requested for withdrawal
     * @return uint256 The amount of hype requested for withdrawal
     */
    function hypeRequestedForWithdraw() external view returns (uint256);
    
    /* ========== ADMIN FUNCTIONS ========== */
    
    /**
     * @notice Pause withdrawals
     * @dev Only callable by the role registry
     */
    function pauseWithdrawals() external;
    
    /**
     * @notice Unpause withdrawals
     * @dev Only callable by the role registry
     */
    function unpauseWithdrawals() external;
    
}
