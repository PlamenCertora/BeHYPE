// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IRoleRegistry} from "./IRoleRegistry.sol";
import {IBeHYPEToken} from "./IBeHype.sol";

/**
 * @title IStakingCore
 * @notice Interface for the StakingCore contract that manages staking operations and exchange ratios
 * @dev Provides functionality for staking deposits, withdrawals, token delegation, and exchange ratio management
 * @author EtherFi
 */
interface IStakingCore {

    /* ========== ERRORS ========== */

    error NotAuthorized();
    error ExchangeRatioChangeExceedsThreshold(uint16 yearlyRateInBps);
    error FailedToFetchDelegatorSummary();
    error AmountExceedsUint64Max();
    error FailedToDepositToHyperCore();
    error StakingPaused();
    error ElapsedTimeCannotBeZero();
    error FailedToSendFromWithdrawManager();

    /* ========== EVENTS ========== */

    /**
     * @notice Emitted when the exchange ratio is updated
     * @param oldRatio The previous exchange ratio
     * @param newRatio The new exchange ratio
     * @param yearlyRateInBps The absolute yearly rate in bps
     */
    event ExchangeRatioUpdated(uint256 oldRatio, uint256 newRatio, uint16 yearlyRateInBps);

    /**
     * @notice Emitted when HYPE is deposited to HyperCore staking module from HyperCore spot account
     * @param amount The amount of HYPE deposited
     */
    event HyperCoreDeposit(uint256 amount);

    /**
     * @notice Emitted when HYPE is withdrawn from HyperCore staking module to HyperCore spot account
     * @param amount The amount of HYPE withdrawn
     */
    event HyperCoreWithdraw(uint256 amount);

    /**
     * @notice Emitted when HYPE is deposited to HyperCore staking module from HyperCore spot account
     * @param amount The amount of HYPE deposited
     */
    event HyperCoreStakingDeposit(uint256 amount);

    /**
     * @notice Emitted when HYPE is withdrawn from HyperCore staking module
     * @param amount The amount of HYPE withdrawn
     */
    event HyperCoreStakingWithdraw(uint256 amount);

    /**
     * @notice Emitted when HYPE is staked
     * @param user Who minted the tokens
     * @param amount The amount of HYPE staked
     * @param communityCode The community code of the staked tokens
     */
    event Deposit(address user, uint256 amount, string communityCode);

    /**
     * @notice Emitted when HYPE is delegated or undelegated
     * @param validator The validator address
     * @param amount The amount of HYPE delegated/undelegated
     * @param isUndelegate True if undelegating, false if delegating 22
     */
    event TokenDelegated(address validator, uint256 amount, bool isUndelegate);

    /**
     * @notice Emitted when the withdraw manager is updated
     * @param withdrawManager The new withdraw manager
     */
    event WithdrawManagerUpdated(address withdrawManager);

    /* ========== MAIN FUNCTIONS ========== */

    /**
     * @notice Stakes HYPE
     * @param communityCode The community code of the staked tokens
     */
    function stake(string memory communityCode) external payable;

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Updates the exchange ratio based on L1 delegator summary
     * @dev Only callable by accounts with PROTOCOL_GOVERNOR role
     * @dev Prevents negative rebases and enforces maximum APR change threshold
     * @dev Emits ExchangeRatioUpdated event on successful update
     */
    function updateExchangeRatio() external;

    /**
     * @notice Allows the withdraw manager to send HYPE to the user
     * @param amount The amount of HYPE to send
     * @param to The address to send the HYPE to
     * @dev Only callable by the withdraw manager
     */
    function sendFromWithdrawManager(uint256 amount, address to) external;

    /**
     * @notice Sets the withdraw manager
     * @param _withdrawManager The new withdraw manager
     * @dev Only callable by the protocol upgrader
     */
    function setWithdrawManager(address _withdrawManager) external;

    /**
     * @notice Updates the acceptable APR
     * @param _acceptablAprInBps The new acceptable APR
     * @dev Only callable by the protocol guardian
     */
    function updateAcceptableApr(uint16 _acceptablAprInBps) external;

    /**
     * @notice Updates the exchange rate guard
     * @param _exchangeRateGuard The new exchange rate guard
     * @dev Only callable by the protocol guardian
     */
    function updateExchangeRateGuard(bool _exchangeRateGuard) external;

    /**
     * @notice Deposits HYPE to HyperCore staking module from HyperCore spot account
     * @param amount The amount of HYPE to deposit in wei
     * @dev Only callable by the protocol admin
     */
    function depositToHyperCore(uint256 amount) external;

    /**
     * @notice Withdraws HYPE from HyperCore
     * @param amount The amount of HYPE to withdraw in wei
     * @dev Only callable by accounts with PROTOCOL_GOVERNOR role
     * @dev Sends Action 5 to CoreWriter for HyperCore processing
     * @dev Emits StakingWithdraw event
     * @dev Reverts if the amount is greater than the pending hype withdrawal amount
     */
    function withdrawFromHyperCore(uint256 amount) external;

    /**
     * @notice Deposits HYPE to staking via CoreWriter Action 4
     * @param amount The amount of HYPE to deposit in wei
     * @dev Only callable by accounts with PROTOCOL_ADMIN role
     * @dev Sends Action 4 to CoreWriter for HyperCore processing
     * @dev Emits StakingDeposit event
     */
    function depositToStaking(uint256 amount) external;

    /**
     * @notice Withdraws HYPE from staking via CoreWriter Action 5
     * @param amount The amount of HYPE to withdraw in wei
     * @dev Only callable by accounts with PROTOCOL_ADMIN role
     * @dev Sends Action 5 to CoreWriter for HyperCore processing
     * @dev Emits StakingWithdraw event
     * @dev Reverts if the amount is greater than the pending hype withdrawal amount
     */
    function withdrawFromStaking(uint256 amount) external;

    /**
     * @notice Delegates or undelegates tokens via CoreWriter Action 3
     * @param validator The validator address to delegate/undelegate from
     * @param amount The amount of tokens to delegate/undelegate in wei
     * @param isUndelegate True if undelegating, false if delegating
     * @dev Only callable by accounts with PROTOCOL_ADMIN role
     * @dev Sends Action 3 to CoreWriter for HyperCore processing
     * @dev Emits TokenDelegated event
     */
    function delegateTokens(address validator, uint256 amount, bool isUndelegate) external;

    /**
     * @notice Pauses staking
     * @dev Only callable by the role registry
     */
    function pauseStaking() external;
    
    /**
     * @notice Unpauses staking
     * @dev Only callable by the role registry
     */
    function unpauseStaking() external;

    /* ========== VIEW FUNCTIONS ========== */

    /**
     * @notice Converts kHYPE amount to HYPE using current exchange ratio
     * @param kHYPEAmount The amount of kHYPE tokens to convert
     * @return The equivalent amount of HYPE tokens
     * @dev Uses current exchange ratio for conversion
     */
    function BeHYPEToHYPE(uint256 kHYPEAmount) external view returns (uint256);

    /**
     * @notice Converts HYPE amount to kHYPE using current exchange ratio
     * @param HYPEAmount The amount of HYPE tokens to convert
     * @return The equivalent amount of kHYPE tokens
     * @dev Uses current exchange ratio for conversion
     */
    function HYPEToBeHYPE(uint256 HYPEAmount) external view returns (uint256);

    /**
     * @notice Returns the total amount of HYPE in the protocol
     * @return The total amount of HYPE in the protocol
     */
    function getTotalProtocolHype() external view returns (uint256);
}
