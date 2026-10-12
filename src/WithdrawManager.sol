// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRoleRegistry} from "./interfaces/IRoleRegistry.sol";
import {IBeHYPEToken} from "./interfaces/IBeHype.sol";
import {IStakingCore} from "./interfaces/IStakingCore.sol";
import {IWithdrawManager} from "./interfaces/IWithdrawManager.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BucketLimiter} from "./lib/BucketLimiter.sol";

contract WithdrawManager is
    Initializable,
    UUPSUpgradeable,
    IWithdrawManager,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using Math for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */
    
    IBeHYPEToken public beHypeToken;
    IStakingCore public stakingCore;
    IRoleRegistry public roleRegistry;
    
    uint256 public hypeRequestedForWithdraw;
    uint256 public lastFinalizedIndex;

    WithdrawalEntry[] public withdrawalQueue;
    mapping(address => uint256[]) public userWithdrawals;

    uint256 public minWithdrawalAmount;
    uint256 public maxWithdrawalAmount;

    uint16 public instantWithdrawalFeeInBps;
    uint16 public lowWatermarkInBpsOfTvl;

    BucketLimiter.Limit public instantWithdrawalLimit;

    /* ========== CONSTANTS ========== */

    uint256 public constant BUCKET_UNIT_SCALE = 1e12;
    uint256 public constant BASIS_POINT_SCALE = 1e4;
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }
    
    function initialize(
        uint256 _minStakeAmount,
        uint256 _maxStakeAmount,
        uint16 _lowWatermarkInBpsOfTvl,
        uint16 _instantWithdrawalFeeInBps,
        address _roleRegistry,
        address _beHypeToken,
        address _stakingCore,
        uint256 _bucketCapacity,
        uint64 _bucketRefillRate
    ) public initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        minWithdrawalAmount = _minStakeAmount;
        maxWithdrawalAmount = _maxStakeAmount;
        lowWatermarkInBpsOfTvl = _lowWatermarkInBpsOfTvl;
        instantWithdrawalFeeInBps = _instantWithdrawalFeeInBps;
        
        roleRegistry = IRoleRegistry(_roleRegistry);
        beHypeToken = IBeHYPEToken(_beHypeToken);
        stakingCore = IStakingCore(_stakingCore);

        instantWithdrawalLimit = BucketLimiter.create(
            _convertToBucketUnit(_bucketCapacity, Math.Rounding.Floor), 
            _bucketRefillRate
        );

        withdrawalQueue.push(WithdrawalEntry({
            user: address(0),
            beHypeAmount: 0,
            hypeAmount: 0,
            finalized: true
        }));
    }
    
    /* ========== MAIN FUNCTIONS ========== */
    
    function withdraw(
        uint256 beHypeAmount, bool instant
    ) external nonReentrant returns (uint256 withdrawalId) {
        if (paused()) revert WithdrawalsPaused();
        if (beHypeAmount < minWithdrawalAmount) revert InvalidAmount();
        if (beHypeAmount > maxWithdrawalAmount) revert InvalidAmount();
        if (beHypeToken.balanceOf(msg.sender) < beHypeAmount) revert InsufficientBeHYPEBalance();
        uint256 hypeAmount = stakingCore.BeHYPEToHYPE(beHypeAmount);

        if (instant) {
            if (!_canRateLimiterConsume(hypeAmount)) revert InstantWithdrawalRateLimitExceeded();
            if (!canInstantWithdraw(beHypeAmount)) revert InsufficientHYPELiquidity();

            _updateRateLimit(hypeAmount);

            beHypeToken.transferFrom(msg.sender, address(this), beHypeAmount);

            uint256 instantWithdrawalFee = beHypeAmount.mulDiv(instantWithdrawalFeeInBps, BASIS_POINT_SCALE);
            beHypeToken.transfer(roleRegistry.protocolTreasury(), instantWithdrawalFee);
            uint256 beHypeWithdrawalAfterFee = beHypeAmount - instantWithdrawalFee;
            uint256 hypeWithdrawalAfterFee = stakingCore.BeHYPEToHYPE(beHypeWithdrawalAfterFee);

            beHypeToken.burn(address(this), beHypeWithdrawalAfterFee);

            stakingCore.sendFromWithdrawManager(hypeWithdrawalAfterFee, msg.sender);

            emit InstantWithdrawal(msg.sender, beHypeAmount, hypeWithdrawalAfterFee, instantWithdrawalFee);
        } else {
            withdrawalId = withdrawalQueue.length;
            hypeRequestedForWithdraw += hypeAmount;
        
            beHypeToken.transferFrom(msg.sender, address(this), beHypeAmount);
        
            withdrawalQueue.push(WithdrawalEntry({
                user: msg.sender,
                beHypeAmount: beHypeAmount,
                hypeAmount: hypeAmount,
                finalized: false
            }));
        
            userWithdrawals[msg.sender].push(withdrawalId);
                
            emit WithdrawalQueued(msg.sender, withdrawalId, beHypeAmount, hypeAmount, withdrawalId);
        }
        
    }

    /* ========== ADMIN FUNCTIONS ========== */

    function finalizeWithdrawals(uint256 index) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();
        if (index >= withdrawalQueue.length) revert IndexOutOfBounds();
        if (index <= lastFinalizedIndex) revert CanOnlyFinalizeForward();


        uint256 hypeAmountToFinalize = 0;
        uint256 beHypeAmountToFinalize = 0;
        for (uint256 i = lastFinalizedIndex + 1; i <= index;) {
            stakingCore.sendFromWithdrawManager(withdrawalQueue[i].hypeAmount, withdrawalQueue[i].user);
            beHypeAmountToFinalize += withdrawalQueue[i].beHypeAmount;
            hypeAmountToFinalize += withdrawalQueue[i].hypeAmount;
            withdrawalQueue[i].finalized = true;

            unchecked { ++i; }
        }

        lastFinalizedIndex = index;
        beHypeToken.burn(address(this), beHypeAmountToFinalize);
        hypeRequestedForWithdraw -= hypeAmountToFinalize;

        emit WithdrawalsBatchFinalized(index);
    }

    function setInstantWithdrawalFeeInBps(uint16 _instantWithdrawalFeeInBps) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_GUARDIAN(), msg.sender)) revert NotAuthorized();
        if (_instantWithdrawalFeeInBps > BASIS_POINT_SCALE) revert InvalidInstantWithdrawalFee();

        instantWithdrawalFeeInBps = _instantWithdrawalFeeInBps;

        emit InstantWithdrawalFeeInBpsUpdated(_instantWithdrawalFeeInBps);
    }

    function setInstantWithdrawalCapacity(uint256 capacity) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();
        // max capacity = max(uint64) * 1e12 ~= 16 * 1e18 * 1e12 = 16 * 1e12 HYPE, which is practically enough
        uint64 bucketUnit = _convertToBucketUnit(capacity, Math.Rounding.Floor);
        BucketLimiter.setCapacity(instantWithdrawalLimit, bucketUnit);
    }

    function setInstantWithdrawalRefillRatePerSecond(uint64 refillRate) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();
        BucketLimiter.setRefillRate(instantWithdrawalLimit, refillRate);
    }

    function pauseWithdrawals() external {
        if (msg.sender != address(roleRegistry)) revert NotAuthorized();
        _pause();
    }
    
    function unpauseWithdrawals() external {
        if (msg.sender != address(roleRegistry)) revert NotAuthorized();
        _unpause();
    }
    
    /* ========== VIEW FUNCTIONS ========== */

    function getWithdrawalQueue(uint256 index) external view returns (WithdrawalEntry memory) {
        return withdrawalQueue[index];
    }
    
    function getUserUnFinalizedWithdrawals(address user) external view returns (uint256[] memory) {
        uint256[] memory unFinalizedWithdrawals = new uint256[](userWithdrawals[user].length);
        uint256 count = 0;
        for (uint256 i = 0; i < userWithdrawals[user].length;) {
            WithdrawalEntry storage entry = withdrawalQueue[userWithdrawals[user][i]];
            if (!entry.finalized) {
                unFinalizedWithdrawals[count] = userWithdrawals[user][i];
                unchecked { ++count; }
            }
            unchecked { ++i; }
        }

        assembly {
            mstore(unFinalizedWithdrawals, count)
        }

        return unFinalizedWithdrawals;
    }

    /**
     * @dev The total amount of beHYPE that can be instant withdrawn.
     * Contract balance must maintain a minimum of lowWatermarkInHYPE() HYPE.
     */
    function getTotalInstantWithdrawableBeHYPE() public view returns (uint256) {
        if (getLiquidHypeAmount() < lowWatermarkInHYPE()) return 0;

        uint256 withdrawableAmount = getLiquidHypeAmount() - lowWatermarkInHYPE();
        uint256 rateLimitAllowedAmount = _convertFromBucketUnit(BucketLimiter.consumable(instantWithdrawalLimit));

        return stakingCore.HYPEToBeHYPE(Math.min(withdrawableAmount, rateLimitAllowedAmount));
    }

    function canInstantWithdraw(uint256 beHypeAmount) public view returns (bool) {
        return beHypeAmount <= getTotalInstantWithdrawableBeHYPE();
    }

    /**
     * @dev The staking core's balance is our liquid hype amount.
     */
    function getLiquidHypeAmount() public view returns (uint256) {
        return address(stakingCore).balance;
    }
    
    function getPendingWithdrawalsCount() external view returns (uint256) {
        // -1 because the first withdrawal entry is a placeholder
        return withdrawalQueue.length - lastFinalizedIndex - 1;
    }

    function lowWatermarkInHYPE() public view returns (uint256) {
        return stakingCore.getTotalProtocolHype().mulDiv(lowWatermarkInBpsOfTvl, BASIS_POINT_SCALE);
    }
    
    /* ========== INTERNAL FUNCTIONS ========== */

    function _updateRateLimit(uint256 amount) internal {
        uint64 bucketUnit = _convertToBucketUnit(amount, Math.Rounding.Ceil);
        if (!BucketLimiter.consume(instantWithdrawalLimit, bucketUnit)) revert InstantWithdrawalRateLimitExceeded();
    }

    function _canRateLimiterConsume(uint256 amount) internal view returns (bool) {
        return BucketLimiter.canConsume(instantWithdrawalLimit, _convertToBucketUnit(amount, Math.Rounding.Ceil));
    }

    function _convertToBucketUnit(uint256 amount, Math.Rounding rounding) internal pure returns (uint64) {
        require(amount < type(uint64).max * BUCKET_UNIT_SCALE, "WithdrawManager: Amount too large");
        return (rounding == Math.Rounding.Ceil) ? SafeCast.toUint64((amount + BUCKET_UNIT_SCALE - 1) / BUCKET_UNIT_SCALE) : SafeCast.toUint64(amount / BUCKET_UNIT_SCALE);
    }

    function _convertFromBucketUnit(uint64 bucketUnit) internal pure returns (uint256) {
        return bucketUnit * BUCKET_UNIT_SCALE;
    }

    function _authorizeUpgrade(
        address /* newImplementation */
    ) internal view override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }
    
    receive() external payable {}
}
