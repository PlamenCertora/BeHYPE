// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
 * BeHYPEProtocol — single-contract merge of StakingCore + WithdrawManager + BeHYPE
 * for formal verification (Certora Autoprover accepts one contract).
 *
 * Address mapping vs. the unmerged deployment:
 *   StakingCore proxy     -> address(this)
 *   WithdrawManager proxy -> address(this)
 *   BeHYPE token proxy    -> address(this)
 *
 * Every former cross-contract hop is now internal but keeps the exact permission
 * check the callee used to perform, against the same (still settable) pointer:
 *   StakingCore.stake -> BeHYPE.mint                    : tokenStakingCore     == address(this)
 *   WithdrawManager   -> BeHYPE.burn                    : tokenWithdrawManager == address(this)
 *   WithdrawManager   -> StakingCore.sendFromWithdrawManager : withdrawManager == address(this)
 *   StakingCore       -> WithdrawManager.hypeRequestedForWithdraw : read via withdrawManager pointer
 * The external mint/burn/sendFromWithdrawManager entry points keep their msg.sender guards.
 *
 * Kept external (inferred dependencies): RoleRegistry, HyperCore L1Read precompile reader, CoreWriter.
 * See certora/README.md for the full function mapping and the residual (address-collapse) differences.
 */

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/* ========== EXTERNAL DEPENDENCIES (kept out of the merge) ========== */

/// @notice Subset of src/interfaces/IRoleRegistry.sol used by the protocol contracts.
interface IRoleRegistry {
    function PROTOCOL_ADMIN() external view returns (bytes32);
    function PROTOCOL_GUARDIAN() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function onlyProtocolUpgrader(address account) external view;
    function protocolTreasury() external view returns (address);
}

/// @notice ABI-identical subset of src/lib/L1Read.sol (HyperCore precompile reader at 0xb746...).
interface IL1Read {
    struct SpotBalance {
        uint64 total;
        uint64 hold;
        uint64 entryNtl;
    }

    struct DelegatorSummary {
        uint64 delegated;
        uint64 undelegated;
        uint64 totalPendingWithdrawal;
        uint64 nPendingWithdrawals;
    }

    function spotBalance(address user, uint64 token) external view returns (SpotBalance memory);
    function delegatorSummary(address user) external view returns (DelegatorSummary memory);
}

/// @notice HyperCore CoreWriter system contract (0x3333...).
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/// @notice Only used when StakingCore's withdrawManager pointer is re-pointed away from this contract.
interface IExternalWithdrawManager {
    function hypeRequestedForWithdraw() external view returns (uint256);
}

/* ========== INLINED LIBRARY ========== */

/// @notice Formerly src/lib/BucketLimiter.sol, verbatim except canConsume/consumable are `internal`
/// instead of `external` (the original compiles to a separately linked library; both are
/// pure-view on a memory copy, so behaviour is identical).
library BucketLimiter {
    struct Limit {
        uint64 capacity;
        uint64 remaining;
        uint64 lastRefill;
        uint64 refillRate;
    }

    function create(uint64 capacity, uint64 refillRate) internal view returns (Limit memory) {
        return Limit({
            capacity: capacity,
            remaining: capacity,
            lastRefill: uint64(block.timestamp),
            refillRate: refillRate
        });
    }

    function canConsume(Limit memory limit, uint64 amount) internal view returns (bool) {
        _refill(limit);
        return limit.remaining >= amount;
    }

    function consumable(Limit memory limit) internal view returns (uint64) {
        _refill(limit);
        return limit.remaining;
    }

    function consume(Limit storage limit, uint64 amount) internal returns (bool) {
        Limit memory _limit = limit;
        _refill(_limit);
        if (_limit.remaining < amount) {
            return false;
        }
        limit.remaining = _limit.remaining - amount;
        limit.lastRefill = _limit.lastRefill;
        return true;
    }

    function refill(Limit storage limit) internal {
        Limit memory _limit = limit;
        _refill(_limit);
        limit.remaining = _limit.remaining;
        limit.lastRefill = _limit.lastRefill;
    }

    function _refill(Limit memory limit) internal view {
        uint64 now_ = uint64(block.timestamp);

        if (now_ == limit.lastRefill) {
            return;
        }

        uint256 delta;
        unchecked {
            delta = now_ - limit.lastRefill;
        }
        uint256 tokens = delta * uint256(limit.refillRate);
        uint256 newRemaining = uint256(limit.remaining) + tokens;
        if (newRemaining > limit.capacity) {
            limit.remaining = limit.capacity;
        } else {
            limit.remaining = uint64(newRemaining);
        }
        limit.lastRefill = now_;
    }

    function setCapacity(Limit storage limit, uint64 capacity) internal {
        refill(limit);
        limit.capacity = capacity;
        if (limit.remaining > capacity) {
            limit.remaining = capacity;
        }
    }

    function setRefillRate(Limit storage limit, uint64 refillRate) internal {
        refill(limit);
        limit.refillRate = refillRate;
    }

    function setRemaining(Limit storage limit, uint64 remaining) internal {
        refill(limit);
        limit.remaining = remaining;
    }
}

/* ========== MERGED PROTOCOL ========== */

contract BeHYPEProtocol is Initializable, UUPSUpgradeable, ERC20PermitUpgradeable, ReentrancyGuardUpgradeable {
    using Math for uint256;

    /* ========== STRUCTS ========== */

    struct WithdrawalEntry {
        address user;
        uint256 beHypeAmount;
        uint256 hypeAmount;
        bool finalized;
    }

    /* ========== ERRORS ========== */

    // StakingCore (IStakingCore) + WithdrawManager (IWithdrawManager)
    error NotAuthorized();
    // StakingCore
    error ExchangeRatioChangeExceedsThreshold(uint16 yearlyRateInBps);
    error AmountExceedsUint64Max();
    error FailedToDepositToHyperCore();
    error StakingPaused();
    error ElapsedTimeCannotBeZero();
    error FailedToSendFromWithdrawManager();
    // WithdrawManager
    error WithdrawalsPaused();
    error InvalidAmount();
    error InsufficientBeHYPEBalance();
    error IndexOutOfBounds();
    error CanOnlyFinalizeForward();
    error InsufficientHYPELiquidity();
    error InstantWithdrawalRateLimitExceeded();
    error InvalidInstantWithdrawalFee();
    // BeHYPE
    error Unauthorized();
    // PausableUpgradeable (StakingCore and WithdrawManager each had one)
    error EnforcedPause();
    error ExpectedPause();

    /* ========== EVENTS ========== */

    // StakingCore
    event ExchangeRatioUpdated(uint256 oldRatio, uint256 newRatio, uint16 yearlyRateInBps);
    event HyperCoreDeposit(uint256 amount);
    event HyperCoreWithdraw(uint256 amount);
    event HyperCoreStakingDeposit(uint256 amount);
    event HyperCoreStakingWithdraw(uint256 amount);
    event Deposit(address user, uint256 amount, string communityCode);
    event TokenDelegated(address validator, uint256 amount, bool isUndelegate);
    // StakingCore + BeHYPE
    event WithdrawManagerUpdated(address withdrawManager);
    // BeHYPE
    event StakingCoreUpdated(address stakingCore);
    // WithdrawManager
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
    // PausableUpgradeable
    event Paused(address account);
    event Unpaused(address account);

    /* ========== STATE VARIABLES ========== */

    // Shared (StakingCore, WithdrawManager and BeHYPE each stored the same registry)
    IRoleRegistry public roleRegistry;

    // StakingCore
    address public withdrawManager;
    uint256 public exchangeRatio;
    uint32 public acceptablAprInBps;
    bool public exchangeRateGuard;
    uint256 public lastExchangeRatioUpdate;
    bool public stakingPaused;

    // WithdrawManager
    uint256 public hypeRequestedForWithdraw;
    uint256 public lastFinalizedIndex;

    WithdrawalEntry[] public withdrawalQueue;
    mapping(address => uint256[]) public userWithdrawals;

    uint256 public minWithdrawalAmount;
    uint256 public maxWithdrawalAmount;

    uint16 public instantWithdrawalFeeInBps;
    uint16 public lowWatermarkInBpsOfTvl;

    BucketLimiter.Limit public instantWithdrawalLimit;
    bool public withdrawalsPaused;

    // BeHYPE
    address public tokenStakingCore;
    address public tokenWithdrawManager;

    /* ========== CONSTANTS ========== */

    // StakingCore
    uint64 public constant HYPE_TOKEN_ID = 150;
    address public constant L1_HYPE_CONTRACT = 0x2222222222222222222222222222222222222222;
    IL1Read public constant l1Read = IL1Read(0xb7467E0524Afba7006957701d1F06A59000d15A2);
    ICoreWriter public constant coreWriter = ICoreWriter(0x3333333333333333333333333333333333333333);

    // WithdrawManager
    uint256 public constant BUCKET_UNIT_SCALE = 1e12;
    uint256 public constant BASIS_POINT_SCALE = 1e4;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice StakingCore + WithdrawManager initializer parameters (grouped to stay below the
    /// legacy-codegen stack limit, so the contract compiles with and without via-IR).
    struct InitConfig {
        // StakingCore.initialize
        uint32 acceptablAprInBps;
        bool exchangeRateGuard;
        // WithdrawManager.initialize
        uint256 minStakeAmount;
        uint256 maxStakeAmount;
        uint16 lowWatermarkInBpsOfTvl;
        uint16 instantWithdrawalFeeInBps;
        uint256 bucketCapacity;
        uint64 bucketRefillRate;
    }

    /// @notice Union of StakingCore/WithdrawManager/BeHYPE initializers, with all internal
    /// pointers wired to this contract (the post-deployment wiring of the unmerged system).
    function initialize(
        string memory _name,
        string memory _symbol,
        address _roleRegistry,
        InitConfig calldata cfg
    ) public initializer {
        __UUPSUpgradeable_init();
        __ERC20_init(_name, _symbol);
        __ERC20Permit_init(_name);
        __ReentrancyGuard_init();

        roleRegistry = IRoleRegistry(_roleRegistry);

        // BeHYPE.initialize
        tokenStakingCore = address(this);
        tokenWithdrawManager = address(this);

        _initStakingCore(cfg.acceptablAprInBps, cfg.exchangeRateGuard);
        _initWithdrawManager(
            cfg.minStakeAmount, cfg.maxStakeAmount, cfg.lowWatermarkInBpsOfTvl, cfg.instantWithdrawalFeeInBps,
            cfg.bucketCapacity, cfg.bucketRefillRate
        );
    }

    /// @dev StakingCore.initialize
    function _initStakingCore(uint32 _acceptablAprInBps, bool _exchangeRateGuard) private {
        acceptablAprInBps = _acceptablAprInBps;
        exchangeRateGuard = _exchangeRateGuard;
        withdrawManager = address(this);

        exchangeRatio = 1 ether;
        lastExchangeRatioUpdate = block.timestamp;
    }

    /// @dev WithdrawManager.initialize
    function _initWithdrawManager(
        uint256 _minStakeAmount,
        uint256 _maxStakeAmount,
        uint16 _lowWatermarkInBpsOfTvl,
        uint16 _instantWithdrawalFeeInBps,
        uint256 _bucketCapacity,
        uint64 _bucketRefillRate
    ) private {
        minWithdrawalAmount = _minStakeAmount;
        maxWithdrawalAmount = _maxStakeAmount;
        lowWatermarkInBpsOfTvl = _lowWatermarkInBpsOfTvl;
        instantWithdrawalFeeInBps = _instantWithdrawalFeeInBps;

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

    /* =====================================================================
     *                              STAKING CORE
     * ===================================================================== */

    function stake(string memory communityCode) public payable {
        if (stakingPaused) revert StakingPaused();

        _mintFromStakingCore(msg.sender, HYPEToBeHYPE(msg.value));

        emit Deposit(msg.sender, msg.value, communityCode);
    }

    function updateExchangeRatio() external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();

        uint256 totalProtocolHype = getTotalProtocolHype();

        uint256 newRatio = Math.mulDiv(totalProtocolHype, 1e18, totalSupply());

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

    /// @notice External entry point kept for a re-pointed (external) withdraw manager.
    function sendFromWithdrawManager(uint256 amount, address to) external {
        if (msg.sender != withdrawManager) revert NotAuthorized();
        _sendHype(amount, to);
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
        if (amount > _withdrawManagerHypeRequested()) revert NotAuthorized();

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
        if (amount > _withdrawManagerHypeRequested()) revert NotAuthorized();

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
        if (stakingPaused) revert EnforcedPause();
        stakingPaused = true;
        emit Paused(msg.sender);
    }

    function unpauseStaking() external {
        if (msg.sender != address(roleRegistry)) revert NotAuthorized();
        if (!stakingPaused) revert ExpectedPause();
        stakingPaused = false;
        emit Unpaused(msg.sender);
    }

    function BeHYPEToHYPE(uint256 kHYPEAmount) public view returns (uint256) {
        return Math.mulDiv(kHYPEAmount, exchangeRatio, 1e18);
    }

    function HYPEToBeHYPE(uint256 HYPEAmount) public view returns (uint256) {
        return Math.mulDiv(HYPEAmount, 1e18, exchangeRatio);
    }

    function getTotalProtocolHype() public view returns (uint256) {
        IL1Read.DelegatorSummary memory delegatorSummary = l1Read.delegatorSummary(address(this));
        uint256 totalHypeInStakingAccount = _convertTo18Decimals(delegatorSummary.delegated) + _convertTo18Decimals(delegatorSummary.undelegated) + _convertTo18Decimals(delegatorSummary.totalPendingWithdrawal);

        IL1Read.SpotBalance memory spotBalance = l1Read.spotBalance(address(this), HYPE_TOKEN_ID);
        uint256 totalHypeInSpotAccount = _convertTo18Decimals(spotBalance.total);

        uint256 totalHypeInLiquidityPool = address(this).balance;

        uint256 total = totalHypeInStakingAccount + totalHypeInSpotAccount + totalHypeInLiquidityPool;

        return total;
    }

    /// @notice WithdrawManager.stakingCore() — always this contract.
    function stakingCore() external view returns (address) {
        return address(this);
    }

    /// @notice StakingCore.beHypeToken() / WithdrawManager.beHypeToken() — always this contract.
    function beHypeToken() external view returns (address) {
        return address(this);
    }

    /* =====================================================================
     *                            WITHDRAW MANAGER
     * ===================================================================== */

    function withdraw(
        uint256 beHypeAmount, bool instant
    ) external nonReentrant returns (uint256 withdrawalId) {
        if (withdrawalsPaused) revert WithdrawalsPaused();
        if (beHypeAmount < minWithdrawalAmount) revert InvalidAmount();
        if (beHypeAmount > maxWithdrawalAmount) revert InvalidAmount();
        if (balanceOf(msg.sender) < beHypeAmount) revert InsufficientBeHYPEBalance();
        uint256 hypeAmount = BeHYPEToHYPE(beHypeAmount);

        if (instant) {
            if (!_canRateLimiterConsume(hypeAmount)) revert InstantWithdrawalRateLimitExceeded();
            if (!canInstantWithdraw(beHypeAmount)) revert InsufficientHYPELiquidity();

            _updateRateLimit(hypeAmount);

            _transferFromToWithdrawManager(msg.sender, beHypeAmount);

            uint256 instantWithdrawalFee = beHypeAmount.mulDiv(instantWithdrawalFeeInBps, BASIS_POINT_SCALE);
            _transfer(address(this), roleRegistry.protocolTreasury(), instantWithdrawalFee);
            uint256 beHypeWithdrawalAfterFee = beHypeAmount - instantWithdrawalFee;
            uint256 hypeWithdrawalAfterFee = BeHYPEToHYPE(beHypeWithdrawalAfterFee);

            _burnFromWithdrawManager(address(this), beHypeWithdrawalAfterFee);

            _sendFromWithdrawManager(hypeWithdrawalAfterFee, msg.sender);

            emit InstantWithdrawal(msg.sender, beHypeAmount, hypeWithdrawalAfterFee, instantWithdrawalFee);
        } else {
            withdrawalId = withdrawalQueue.length;
            hypeRequestedForWithdraw += hypeAmount;

            _transferFromToWithdrawManager(msg.sender, beHypeAmount);

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

    function finalizeWithdrawals(uint256 index) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();
        if (index >= withdrawalQueue.length) revert IndexOutOfBounds();
        if (index <= lastFinalizedIndex) revert CanOnlyFinalizeForward();

        uint256 hypeAmountToFinalize = 0;
        uint256 beHypeAmountToFinalize = 0;
        for (uint256 i = lastFinalizedIndex + 1; i <= index;) {
            _sendFromWithdrawManager(withdrawalQueue[i].hypeAmount, withdrawalQueue[i].user);
            beHypeAmountToFinalize += withdrawalQueue[i].beHypeAmount;
            hypeAmountToFinalize += withdrawalQueue[i].hypeAmount;
            withdrawalQueue[i].finalized = true;

            unchecked { ++i; }
        }

        lastFinalizedIndex = index;
        _burnFromWithdrawManager(address(this), beHypeAmountToFinalize);
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
        uint64 bucketUnit = _convertToBucketUnit(capacity, Math.Rounding.Floor);
        BucketLimiter.setCapacity(instantWithdrawalLimit, bucketUnit);
    }

    function setInstantWithdrawalRefillRatePerSecond(uint64 refillRate) external {
        if (!roleRegistry.hasRole(roleRegistry.PROTOCOL_ADMIN(), msg.sender)) revert NotAuthorized();
        BucketLimiter.setRefillRate(instantWithdrawalLimit, refillRate);
    }

    function pauseWithdrawals() external {
        if (msg.sender != address(roleRegistry)) revert NotAuthorized();
        if (withdrawalsPaused) revert EnforcedPause();
        withdrawalsPaused = true;
        emit Paused(msg.sender);
    }

    function unpauseWithdrawals() external {
        if (msg.sender != address(roleRegistry)) revert NotAuthorized();
        if (!withdrawalsPaused) revert ExpectedPause();
        withdrawalsPaused = false;
        emit Unpaused(msg.sender);
    }

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

    function getTotalInstantWithdrawableBeHYPE() public view returns (uint256) {
        if (getLiquidHypeAmount() < lowWatermarkInHYPE()) return 0;

        uint256 withdrawableAmount = getLiquidHypeAmount() - lowWatermarkInHYPE();
        uint256 rateLimitAllowedAmount = _convertFromBucketUnit(BucketLimiter.consumable(instantWithdrawalLimit));

        return HYPEToBeHYPE(Math.min(withdrawableAmount, rateLimitAllowedAmount));
    }

    function canInstantWithdraw(uint256 beHypeAmount) public view returns (bool) {
        return beHypeAmount <= getTotalInstantWithdrawableBeHYPE();
    }

    /// @dev The staking core's balance is our liquid hype amount (staking core == this).
    function getLiquidHypeAmount() public view returns (uint256) {
        return address(this).balance;
    }

    function getPendingWithdrawalsCount() external view returns (uint256) {
        return withdrawalQueue.length - lastFinalizedIndex - 1;
    }

    function lowWatermarkInHYPE() public view returns (uint256) {
        return getTotalProtocolHype().mulDiv(lowWatermarkInBpsOfTvl, BASIS_POINT_SCALE);
    }

    /* =====================================================================
     *                                 BeHYPE
     * ===================================================================== */

    function mint(address to, uint256 amount) external {
        if (msg.sender != tokenStakingCore) revert Unauthorized();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        if (msg.sender != tokenWithdrawManager) revert Unauthorized();
        _burn(from, amount);
    }

    /// @notice BeHYPE.setStakingCore
    function setTokenStakingCore(address _stakingCore) external {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
        tokenStakingCore = _stakingCore;

        emit StakingCoreUpdated(tokenStakingCore);
    }

    /// @notice BeHYPE.setWithdrawManager (renamed: selector collides with StakingCore.setWithdrawManager)
    function setTokenWithdrawManager(address _withdrawManager) external {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
        tokenWithdrawManager = _withdrawManager;

        emit WithdrawManagerUpdated(tokenWithdrawManager);
    }

    /* =====================================================================
     *                   FORMER CROSS-CONTRACT HOPS (internal)
     * ===================================================================== */

    /// @dev StakingCore -> BeHYPE.mint : BeHYPE checked msg.sender (StakingCore) == its stakingCore.
    function _mintFromStakingCore(address to, uint256 amount) internal {
        if (tokenStakingCore != address(this)) revert Unauthorized();
        _mint(to, amount);
    }

    /// @dev WithdrawManager -> BeHYPE.burn : BeHYPE checked msg.sender (WithdrawManager) == its withdrawManager.
    function _burnFromWithdrawManager(address from, uint256 amount) internal {
        if (tokenWithdrawManager != address(this)) revert Unauthorized();
        _burn(from, amount);
    }

    /// @dev WithdrawManager -> BeHYPE.transferFrom(from, WithdrawManager, value): spender is WithdrawManager.
    function _transferFromToWithdrawManager(address from, uint256 value) internal {
        _spendAllowance(from, address(this), value);
        _transfer(from, address(this), value);
    }

    /// @dev WithdrawManager -> StakingCore.sendFromWithdrawManager : StakingCore checked
    /// msg.sender (WithdrawManager) == its withdrawManager.
    function _sendFromWithdrawManager(uint256 amount, address to) internal {
        if (withdrawManager != address(this)) revert NotAuthorized();
        _sendHype(amount, to);
    }

    /// @dev StakingCore -> IWithdrawManager(withdrawManager).hypeRequestedForWithdraw()
    function _withdrawManagerHypeRequested() internal view returns (uint256) {
        if (withdrawManager == address(this)) return hypeRequestedForWithdraw;
        return IExternalWithdrawManager(withdrawManager).hypeRequestedForWithdraw();
    }

    function _sendHype(uint256 amount, address to) internal {
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert FailedToSendFromWithdrawManager();
    }

    /* ========== INTERNAL HELPERS ========== */

    // StakingCore
    function _convertTo8Decimals(uint256 amount) internal pure returns (uint64) {
        uint256 truncatedAmount = amount / 1e10;
        if (truncatedAmount > type(uint64).max) revert AmountExceedsUint64Max();
        return uint64(truncatedAmount);
    }

    function _convertTo18Decimals(uint64 amount) internal pure returns (uint256) {
        return uint256(amount) * 1e10;
    }

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

    // WithdrawManager
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

    /* ========== UPGRADE ========== */

    function _authorizeUpgrade(
        address /* newImplementation */
    ) internal view override {
        roleRegistry.onlyProtocolUpgrader(msg.sender);
    }

    receive() external payable {}
}
