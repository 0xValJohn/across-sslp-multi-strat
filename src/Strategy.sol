// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import {BaseStrategy, StrategyParams} from "@yearnvaults/contracts/BaseStrategy.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IERC20Metadata.sol";
import "./interfaces/ITradeFactory.sol";
import "./interfaces/Across/HubPool.sol";
import "./interfaces/Across/AcceleratingDistributor.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    event Cloned(address indexed clone);

    // ---------------------- STATE VARIABLES ----------------------

    bool internal isOriginal = true;
    uint256 private constant max = type(uint256).max;
    address public tradeFactory;
    HubPool public constant hubPool = HubPool(0xc186fA914353c44b2E33eBE05f21846F1048bEda);
    AcceleratingDistributor public constant lpStaker = AcceleratingDistributor(0x9040e41eF5E8b281535a96D9a48aCb8cfaBD9a48);
    IERC20 public lpToken;
    IERC20 public emissionToken;
    uint256 internal wantDecimals;

    // ------------------------ CONSTRUCTOR ------------------------

    constructor(address _vault) BaseStrategy(_vault) {
        _initializeStrategy();
    }

    function _initializeStrategy() internal {
        lpToken = IERC20(hubPool.pooledTokens(address(want)).lpToken);
        emissionToken = IERC20(lpStaker.rewardToken());
        wantDecimals = IERC20Metadata(address(want)).decimals();
        IERC20(want).safeApprove(address(hubPool), max);
        IERC20(lpToken).safeApprove(address(lpStaker), max);
    }

    // ---------------------- CLONING ----------------------
        function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrategy();
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper
    ) external returns (address newStrategy) {
        require(isOriginal, "!clone");
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newStrategy := create(0, clone_code, 0x37)
        }
        Strategy(newStrategy).initialize(_vault, _strategist, _rewards, _keeper);
        emit Cloned(newStrategy);
    }

    // ---------------------- MAIN ----------------------

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("StrategyAcross", IERC20Metadata(address(want)).symbol()));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return want.balanceOf(address(this)) + balanceOfAllLPToken() * valueLpToWant() / 1e18;
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        _claimRewards();

        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;

        // @note calculate intial profits
        unchecked {
            _profit = _totalAssets > _totalDebt ? _totalAssets - _totalDebt : 0;
        } // @note no underflow risk

        // @note free up _debtOutstanding + our profit
        uint256 _toLiquidate = _debtOutstanding + _profit;
        uint256 _wantBalance = balanceOfWant();

        if (_toLiquidate > _wantBalance) {
            uint256 _liquidatedAmount;
            (_liquidatedAmount, _loss) = _removeLiquidity(_toLiquidate - _wantBalance);
            _totalAssets = estimatedTotalAssets();
        }

        uint256 _liquidWant = balanceOfWant();

        // @note calculate _debtPayment
        // @note enough to pay for all profit and _debtOutstanding (partial or full)
        if (_liquidWant > _profit) {
            _debtPayment = Math.min(_liquidWant - _profit, _debtOutstanding);
            // @note enough to pay profit (partial or full) only
        } else {
            _profit = _liquidWant;
            _debtPayment = 0;
        }

        // @note calculate final p&L
        unchecked {
            (_loss = _loss + (_totalDebt > _totalAssets ? _totalDebt - _totalAssets : 0));
        } // @note no underflow risk

        if (_loss > _profit) {
            unchecked {
                _loss = _loss - _profit;
            }
            _profit = 0;
        } else {
            unchecked {
                _profit = _profit - _loss;
            }
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _liquidWant = balanceOfWant();
        if (_liquidWant > _debtOutstanding) {
            uint256 _amountToInvest = _liquidWant - _debtOutstanding;
            _addLiquidity(_amountToInvest);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _liquidAssets = balanceOfWant();
        if (_liquidAssets < _amountNeeded) {
            (_liquidatedAmount, _loss) = _removeLiquidity(_amountNeeded - _liquidAssets);
            _liquidAssets = balanceOfWant();
        }

        _liquidatedAmount = Math.min(_amountNeeded, _liquidAssets);
        require(_amountNeeded >= _liquidatedAmount + _loss, "!check");
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _balanceOfAllLPToken = balanceOfAllLPToken();
        if (_balanceOfAllLPToken > 0) {
            _removeLiquidity(_balanceOfAllLPToken);
        }
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        lpStaker.exit(address(lpToken)); // @note exits staking position and get rewards
        lpToken.safeTransfer(_newStrategy, balanceOfUnstakedLPToken());
        emissionToken.safeTransfer(_newStrategy, balanceOfEmissionToken());
    }

    // ---------------------- KEEP3RS ----------------------

    function harvestTrigger(uint256 callCostInWei) public view virtual override returns (bool) {
        StrategyParams memory params = vault.strategies(address(this));
        return super.harvestTrigger(callCostInWei) || block.timestamp - params.lastReport > minReportDelay;
    }

    function protectedTokens() internal view override returns (address[] memory) {}

    function ethToWant(uint256 _ethAmount) public view override returns (uint256) {}

    // ----------------- YSWAPS FUNCTIONS ---------------------

    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        emissionToken.safeApprove(_tradeFactory, max);
        ITradeFactory tf = ITradeFactory(_tradeFactory);
        tf.enable(address(emissionToken), address(want));
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        emissionToken.safeApprove(tradeFactory, 0);
        tradeFactory = address(0);
    }

    // ---------------------- MANAGEMENT FUNCTIONS ----------------------

    function claimRewards() external onlyVaultManagers {
        _claimRewards();
    }

    // ---------------------- HELPER AND UTILITY FUNCTIONS ----------------------

    function _addLiquidity(uint256 _wantAmount) internal {
        hubPool.addLiquidity(address(want), _wantAmount);
        _stake(balanceOfUnstakedLPToken());
    }

    function _removeLiquidity(uint256 _wantNeeded) internal returns (uint256 _liquidatedAmount, uint256 _loss) {
        uint256 _wantAvailable = Math.min(availableLiquidity(), Math.min(_wantNeeded, balanceOfAllLPToken())); // @note check available liquidity in native assets
        uint256 _lpAmount = (_wantAvailable * 1e18) / valueLpToWant();
        uint256 _wantBefore = balanceOfWant();
        _unstake(_lpAmount); // @note will reset the reward multiplier
        hubPool.removeLiquidity(address(want), _lpAmount, false);
        _liquidatedAmount = balanceOfWant() - _wantBefore;
        _loss = _wantAvailable - _liquidatedAmount;
    }

    function _stake(uint256 _amountToStake) internal {
        lpStaker.stake(address(lpToken), _amountToStake);
    }

    function _unstake(uint256 _amountToUnstake) internal {
        lpStaker.unstake(address(lpToken), _amountToUnstake);
    }

    function _claimRewards() internal {
        lpStaker.withdrawReward(address(lpToken));
    }

    function balanceOfEmissionToken() public view returns (uint256) {
        return emissionToken.balanceOf(address(this));
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfUnstakedLPToken() public view returns (uint256) {
        return lpToken.balanceOf(address(this)); // @note returns in native decimals (6 or 18)
    }

    function balanceOfStakedLPToken() public view returns (uint256) {
        return lpStaker.getUserStake(address(lpToken), address(this)); // @note returns in native decimals (6 or 18)
    }

    function balanceOfAllLPToken() public view returns (uint256) {
        return balanceOfUnstakedLPToken() + balanceOfStakedLPToken(); // @note returns in native decimals (6 or 18)
    }

    // @dev _exchangeRateCurrent (HubPool.sol#L928) logic replicated, as there are no view function for the rate
    // https://github.com/across-protocol/contracts-v2/blob/e911cf59ad3469e19f04f5de1c92d6406c336042/contracts/
    function valueLpToWant() public view returns (uint256) {
        address _wantAddress = address(want);
        HubPool _hubPool = hubPool;
        HubPool.PooledToken memory _struct = hubPool.pooledTokens(_wantAddress);
        address bondToken = _hubPool.bondToken();
        uint256 getCurrentTime = _hubPool.getCurrentTime();
        uint256 lpFeeRatePerSecond = _hubPool.lpFeeRatePerSecond();
        uint256 lpTokenTotalSupply = IERC20(_struct.lpToken).totalSupply();
        uint256 bondAmount = _hubPool.bondAmount();
        bool _activeRequest = _hubPool.rootBundleProposal().unclaimedPoolRebalanceLeafCount != 0;
        
        if (lpTokenTotalSupply == 0) return wantDecimals;

        // @note _updateAccumulatedLpFees logic
        uint256 timeFromLastInteraction = getCurrentTime - _struct.lastLpFeeUpdate;
        uint256 maxUndistributedLpFees = (_struct.undistributedLpFees * lpFeeRatePerSecond * timeFromLastInteraction) / (1e18);
        uint256 accumulatedFees = maxUndistributedLpFees < _struct.undistributedLpFees ? maxUndistributedLpFees : _struct.undistributedLpFees;
        _struct.undistributedLpFees -= accumulatedFees;
        _struct.lastLpFeeUpdate = uint32(getCurrentTime);
        
        // @note _sync logic
        uint256 balance = IERC20(_wantAddress).balanceOf(address(_hubPool));
        uint256 balanceSansBond = _wantAddress == address(bondToken) && _activeRequest ? balance - bondAmount : balance;
        if (balanceSansBond > _struct.liquidReserves) {
            _struct.utilizedReserves -= uint256(balanceSansBond - _struct.liquidReserves);
            _struct.liquidReserves = balanceSansBond;
        }
        uint256 numerator = uint256(_struct.liquidReserves) + _struct.utilizedReserves - uint256(_struct.undistributedLpFees);
        return (uint256(numerator) * 1e18) / lpTokenTotalSupply;
    }

    function availableLiquidity() public view returns (uint256) {
        return hubPool.pooledTokens(address(want)).liquidReserves; // @note returns native asset avail.
    }

    function pendingRewards() public view returns (uint256) {
        return lpStaker.getOutstandingRewards(address(lpToken), address(this));
    }
}
