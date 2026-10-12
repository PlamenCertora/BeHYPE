// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IWithdrawManager} from "./IWithdrawManager.sol";
import {IStakingCore} from "./IStakingCore.sol";

/**
 * @title IRoleRegistry
 * @notice Interface for the RoleRegistry contract
 * @dev Defines the external interface for RoleRegistry with role management functions
 * @author ether.fi
 */
interface IRoleRegistry {
    /**
     * @dev Error thrown when a function is called by an account without the protocol upgrader role
     */
    error OnlyProtocolUpgrader();

    /**
     * @dev Error thrown when a function is called by an unauthorized account
     */
    error NotAuthorized();

    /* ========== EVENTS ========== */

    /**
     * @notice Emitted when the protocol treasury is updated
     * @param _protocolTreasury The new protocol treasury address
     */
    event ProtocolTreasuryUpdated(address _protocolTreasury);

    /**
     * @notice Emitted when the withdraw manager is updated
     * @param _withdrawManager The new withdraw manager address
     */
    event WithdrawManagerUpdated(address _withdrawManager);

    /**
     * @notice Emitted when the staking core is updated
     * @param _stakingCore The new staking core address
     */
    event StakingCoreUpdated(address _stakingCore);

    /**
     * @notice Emitted when the protocol is paused
     */
    event ProtocolPaused();

    /**
     * @notice Emitted when the protocol is unpaused
     */
    event ProtocolUnpaused();

    /**
     * @notice Returns the maximum allowed role value
     * @dev This is used by EnumerableRoles._validateRole to ensure roles are within valid range
     * @return The maximum role value
     */
    function MAX_ROLE() external pure returns (uint256);

    /**
     * @notice Initializes the contract with the specified parameters
     * @param _owner The address that will be set as the initial owner
     * @param _withdrawManager The address of the withdraw manager contract
     * @param _stakingCore The address of the staking core contract
     * @param _protocolTreasury The address of the protocol treasury
     */
    function initialize(address _owner, address _withdrawManager, address _stakingCore, address _protocolTreasury) external;

    /**
     * @notice Checks if an account has any of the specified roles
     * @dev Reverts if the account doesn't have at least one of the roles
     * @param account The address to check roles for
     * @param encodedRoles ABI encoded roles (abi.encode(ROLE_1, ROLE_2, ...))
     */
    function checkRoles(address account, bytes memory encodedRoles) external view;

    /**
     * @notice Checks if an account has a specific role
     * @param role The role to check (as bytes32)
     * @param account The address to check the role for
     * @return bool True if the account has the role, false otherwise
     */
    function hasRole(bytes32 role, address account) external view returns (bool);

    /**
     * @notice Grants a role to an account
     * @dev Only callable by the contract owner
     * @param role The role to grant (as bytes32)
     * @param account The address to grant the role to
     */
    function grantRole(bytes32 role, address account) external;

    /**
     * @notice Revokes a role from an account
     * @dev Only callable by the contract owner
     * @param role The role to revoke (as bytes32)
     * @param account The address to revoke the role from
     */
    function revokeRole(bytes32 role, address account) external;

    /**
     * @notice Gets all addresses that have a specific role
     * @dev Wrapper around EnumerableRoles roleHolders function
     * @param role The role to query (as bytes32)
     * @return Array of addresses that have the specified role
     */
    function roleHolders(bytes32 role) external view returns (address[] memory);

    /**
     * @notice Checks if an account is the protocol upgrader
     * @dev Reverts if the account is not the protocol upgrader
     * @param account The address to check
     */
    function onlyProtocolUpgrader(address account) external view;

    /**
     * @notice Returns the PROTOCOL_PAUSER role identifier
     * @return The bytes32 identifier for the PROTOCOL_PAUSER role
     */
    function PROTOCOL_PAUSER() external view returns (bytes32);

    /**
     * @notice Returns the PROTOCOL_ADMIN role identifier
     * @dev performs protocol admin actions
     * @return The bytes32 identifier for the PROTOCOL_ADMIN role
     */
    function PROTOCOL_ADMIN() external view returns (bytes32);

    /**
     * @notice Returns the PROTOCOL_GUARDIAN role identifier
     * @dev performs protocol guardian actions
     * @return The bytes32 identifier for the PROTOCOL_GUARDIAN role
     */
    function PROTOCOL_GUARDIAN() external view returns (bytes32);

    /**
     * @notice Returns the withdraw manager contract address
     * @return The address of the withdraw manager contract
     */
    function withdrawManager() external view returns (IWithdrawManager);

    /**
     * @notice Returns the staking core contract address
     * @return The address of the staking core contract
     */
    function stakingCore() external view returns (IStakingCore);

    /**
     * @notice Returns the protocol treasury address
     * @return The address of the protocol treasury
     */
    function protocolTreasury() external view returns (address);

    /* ========== ADMIN FUNCTIONS ========== */

    /**
     * @notice Sets the protocol treasury address
     * @dev Only callable by accounts with PROTOCOL_GUARDIAN role
     * @param _protocolTreasury The new protocol treasury address
     */
    function setProtocolTreasury(address _protocolTreasury) external;

    /**
     * @notice Sets the withdraw manager contract address
     * @dev Only callable by accounts with PROTOCOL_GUARDIAN role
     * @param _withdrawManager The new withdraw manager contract address
     */
    function setWithdrawManager(address _withdrawManager) external;

    /**
     * @notice Sets the staking core contract address
     * @dev Only callable by accounts with PROTOCOL_GUARDIAN role
     * @param _stakingCore The new staking core contract address
     */
    function setStakingCore(address _stakingCore) external;

    /**
     * @notice Pauses the protocol by pausing withdrawals and staking
     * @dev Only callable by accounts with PROTOCOL_PAUSER role
     */
    function pauseProtocol() external;

    /**
     * @notice Unpauses the protocol by unpausing withdrawals and staking
     * @dev Only callable by accounts with PROTOCOL_GUARDIAN role
     */
    function unpauseProtocol() external;
}
