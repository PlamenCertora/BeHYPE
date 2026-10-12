// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* ========== IMPORTS ========== */

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IRoleRegistry} from "./interfaces/IRoleRegistry.sol";
import {IBeHYPEToken} from "./interfaces/IBeHYPE.sol";
import {IStakingCore} from "./interfaces/IStakingCore.sol";
import {IWithdrawManager} from "./interfaces/IWithdrawManager.sol";
import {L1Read} from "./lib/L1Read.sol";
import {CoreWriter} from "./lib/CoreWriter.sol";

contract StakingCore is IStakingCore, Initializable, UUPSUpgradeable, PausableUpgradeable {

     /* ========== STATE VARIABLES ========== */

    IRoleRegistry public roleRegistry;
    IBeHYPEToken public beHypeToken;
    address public withdrawManager;
    uint256 public exchangeRatio;
    uint32 public acceptablAprInBps;
    bool public exchangeRateGuard;
    uint256 public lastExchangeRatioUpdate;

    /* ========== CONSTANTS ========== */

    uint64 public constant HYPE_TOKEN_ID = 150;
    address public constant L1_HYPE_CONTRACT = 0x2222222222222222222222222222222222222222;
    L1Read public constant l1Read = L1Read(0xb7467E0524Afba7006957701d1F06A59000d15A2);
    CoreWriter public constant coreWriter = CoreWriter(0x3333333333333333333333333333333333333333);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(
        address _roleRegistry,
        address _beHype,
        address _withdrawManager,
        uint32 _acceptablAprInBps,
        bool _exchangeRateGuard
    ) public initializer {
        __UUPSUpgradeable_init();

        roleRegistry = IRoleRegistry(_roleRegistry);
        beHypeToken = IBeHYPEToken(_beHype);
        acceptablAprInBps = _acceptablAprInBps;
        exchangeRateGuard = _exchangeRateGuard;
        withdrawManager = _withdrawManager;

        exchangeRatio = 1 ether;
        lastExchangeRatioUpdate = block.timestamp;
    }

    /* ========== MAIN FUNCTIONS ========== */

    function stake(string memory communityCode) public payable {
       if (paused()) revert StakingPaused();
        
       beHypeToken.mint(msg.sender, HYPEToBeHYPE(msg.value));

       emit Deposit(msg.sender, msg.value, communityCode); 
    }

    /* ========== ADMIN FUNCTIONS ========== */

    function updateExchangeRatio() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();

        uint256 totalProtocolHype = getTotalProtocolHype();
        
        uint256 newRatio = Math.mulDiv(totalProtocolHype, 1e18, beHypeToken.totalSupply());

        uint256 ratioChange;
        if (newRatio > exchangeRatio) {
            ratioChange = newRatio - exchangeRatio;
        } else {
            ratioChange = exchangeRatio - newRatio;
        }
        
        uint256 elapsedTime = block.timestamp - lastExchangeRatioUpdate;

        if (elapsedTime == 0) revert ElapsedTimeCannotBeZero();

        uint256 percentageChange = Math.mulDiv(ratioChange, 1e18, exchangeRatio);
        uint256 yearlyRate = Math.mulDiv(percentageChange, 365 days, elapsedTime);
        uint256 yearlyRateInBps = yearlyRate / 1e14;

        uint16 yearlyRateInBps16 = uint16(Math.min(yearlyRateInBps, type(uint16).max));

        if (exchangeRateGuard) {
            if (yearlyRateInBps16 > acceptablAprInBps) revert ExchangeRatioChangeExceedsThreshold(yearlyRateInBps16);
        }

        uint256 oldRatio = exchangeRatio;
        exchangeRatio = newRatio;
        lastExchangeRatioUpdate = block.timestamp;

        emit ExchangeRatioUpdated(oldRatio, exchangeRatio, yearlyRateInBps16);
    }

    function sendFromWithdrawManager(uint256 amount, address to) external {
        if (msg.sender != withdrawManager) revert NotAuthorized();

        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert FailedToSendFromWithdrawManager();
    }

    function setWithdrawManager(address _withdrawManager) external {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
        withdrawManager = _withdrawManager;

        emit WithdrawManagerUpdated(withdrawManager);
    }

    function updateAcceptableApr(uint16 _acceptablAprInBps) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_GUARDIAN(), msg.sender)) revert NotAuthorized();
        acceptablAprInBps = _acceptablAprInBps;
    }

    function updateExchangeRateGuard(bool _exchangeRateGuard) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_GUARDIAN(), msg.sender)) revert NotAuthorized();
        exchangeRateGuard = _exchangeRateGuard;
    }

    function depositToHyperCore(uint256 amount) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();

        (bool success,) = payable(L1_HYPE_CONTRACT).call{value: amount}("");
        if (!success) revert FailedToDepositToHyperCore();
        emit HyperCoreDeposit(amount);
    }

    function withdrawFromHyperCore(uint256 amount) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();
        if (amount > IWithdrawManager(withdrawManager).hypeRequestedForWithdraw()) revert NotAuthorized();
        
        _encodeAction(6, abi.encode(L1_HYPE_CONTRACT, HYPE_TOKEN_ID, _convertTo8Decimals(amount)));
        emit HyperCoreWithdraw(amount);
    }

    function depositToStaking(uint256 amount) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();
        
        _encodeAction(4, abi.encode(_convertTo8Decimals(amount)));
        emit HyperCoreStakingDeposit(amount);
    }

    function withdrawFromStaking(uint256 amount) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();
        if (amount > IWithdrawManager(withdrawManager).hypeRequestedForWithdraw()) revert NotAuthorized();
        
        _encodeAction(5, abi.encode(_convertTo8Decimals(amount)));
        emit HyperCoreStakingWithdraw(amount);
    }

    function delegateTokens(address validator, uint256 amount, bool isUndelegate) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();
        
        _encodeAction(3, abi.encode(validator, _convertTo8Decimals(amount), isUndelegate));
        emit TokenDelegated(validator, amount, isUndelegate);
    }

    function pauseStaking() external {
        if (msg.sender != address(roleRegistry)) revert NotAuthorized();
        _pause();
    }

    function unpauseStaking() external {
        if (msg.sender != address(roleRegistry)) revert NotAuthorized();
        _unpause();
    }

    /* ========== VIEW FUNCTIONS ========== */

    function BeHYPEToHYPE(uint256 kHYPEAmount) public view returns (uint256) {
        return Math.mulDiv(kHYPEAmount, exchangeRatio, 1e18);
    }

    function HYPEToBeHYPE(uint256 HYPEAmount) public view returns (uint256) {
        return Math.mulDiv(HYPEAmount, 1e18, exchangeRatio);
    }

    function getTotalProtocolHype() public view returns (uint256) {
        L1Read.DelegatorSummary memory delegatorSummary = l1Read.delegatorSummary(address(this));
        uint256 totalHypeInStakingAccount = _convertTo18Decimals(delegatorSummary.delegated) + _convertTo18Decimals(delegatorSummary.undelegated) + _convertTo18Decimals(delegatorSummary.totalPendingWithdrawal);

        L1Read.SpotBalance memory spotBalance = l1Read.spotBalance(address(this), HYPE_TOKEN_ID);
        uint256 totalHypeInSpotAccount = _convertTo18Decimals(spotBalance.total);

        uint256 totalHypeInLiquidityPool = address(this).balance;

        uint256 total = totalHypeInStakingAccount + totalHypeInSpotAccount + totalHypeInLiquidityPool;
        
        return total;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _convertTo8Decimals(uint256 amount) internal pure returns (uint64) {
        uint256 truncatedAmount = amount / 1e10;
        if (truncatedAmount > type(uint64).max) revert AmountExceedsUint64Max();
        return uint64(truncatedAmount);
    }

    function _convertTo18Decimals(uint64 amount) internal pure returns (uint256) {
        return uint256(amount) * 1e10;
    }

    /**
     * @notice Encodes and calls the action on hyperCore
     * @dev https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/hyperevm/interacting-with-hypercore
     * @param actionId The action ID (1-255)
     * @param actionData The encoded action data
     */
    function _encodeAction(uint8 actionId, bytes memory actionData) internal {
        bytes memory data = new bytes(4 + actionData.length);

        data[0] = 0x01;
        data[1] = 0x00;
        data[2] = 0x00;
        data[3] = bytes1(actionId);
        
        for (uint256 i = 0; i < actionData.length; i++) {
            data[4 + i] = actionData[i];
        }
        coreWriter.sendRawAction(data);
    }

    function _authorizeUpgrade(
        address /* newImplementation */
    ) internal view override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    receive() external payable {}
}
