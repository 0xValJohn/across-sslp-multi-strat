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
    
    // @note want.balanceOf() and balanceOfAllLPToken() returns naive decimals, _valueLpToWant() returns 18
    function estimatedTotalAssets() public view override returns (uint256) {
        return want.balanceOf(address(this)) + balanceOfAllLPToken() * _valueLpToWant() / 1e18;
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (uint256 _profit, uint256 _loss, uint256 _debtPayment)
    {
        _claimRewards();
         // @note Grab the estimate total debt from the vault
        uint256 _vaultDebt = vault.strategies(address(this)).totalDebt;
        uint256 _totalAssets = estimatedTotalAssets();

        unchecked {
            _profit = _totalAssets > _vaultDebt ? _totalAssets - _vaultDebt : 0;
        }

        // @note Free up _debtOutstanding + our profit, and make any necessary adjustments to the accounting.
        uint256 _amountNeeded = _debtOutstanding + _profit;
        uint256 _wantBalance = balanceOfWant();

        if (_amountNeeded > _wantBalance) {
            withdrawSome(_amountNeeded);
        }

        unchecked {
            _loss = (_vaultDebt > _totalAssets ? _vaultDebt - _totalAssets : 0);
        }

        uint256 _liquidWant = balanceOfWant();

        // @note calculate final p&l and _debtPayment
        // @note enough to pay profit (partial or full) only
        if (_liquidWant <= _profit) {
            _profit = _liquidWant;
            _debtPayment = 0;
            // @note enough to pay for all profit and _debtOutstanding (partial or full)
        } else {
            _debtPayment = Math.min(_liquidWant - _profit, _debtOutstanding);
        }

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

        // @note withdraw the amount needed or the maximum available liquidity! 
        uint256 _wantBalance = balanceOfWant();

        if (_wantBalance < _amountNeeded) {
            (_liquidatedAmount, _loss) = withdrawSome(_amountNeeded - _wantBalance);
            _wantBalance = balanceOfWant();
        }

        _liquidatedAmount = Math.min(_amountNeeded, _wantBalance);
        require(_amountNeeded >= _liquidatedAmount + _loss, "!check");
    }

    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _balanceOfStakedLPToken = balanceOfStakedLPToken();
        if (_balanceOfStakedLPToken > 0) {
            _unstake(_balanceOfStakedLPToken);
        }
        uint256 _balanceOfUnstakedLPToken = balanceOfUnstakedLPToken();
        if (_balanceOfUnstakedLPToken > 0) {
            _removeLiquidity(_balanceOfUnstakedLPToken);
        }
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        if (balanceOfStakedLPToken() > 0) {
            lpStaker.exit(address(lpToken)); // @note exits staking position and get rewards
        }
        uint256 _balanceOfUnstakedLPToken = balanceOfUnstakedLPToken();
        if (_balanceOfUnstakedLPToken > 0) {
            lpToken.safeTransfer(_newStrategy, _balanceOfUnstakedLPToken);
        }
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
    
    // @params _amountNeeded WANT we need to free
    function withdrawSome(uint256 _amountNeeded) internal returns (uint256 _liquidatedAmount, uint256 _loss) {
        _amountNeeded = Math.min(_amountNeeded - balanceOfWant(), availableLiquidity());
        uint256 _preWithdrawWant = balanceOfWant();
        // @note how much LP we need to unstake to match exact want needed
        uint256 _lpAmount = (_amountNeeded * 1e18) / _valueLpToWant();
        uint256 _balanceOfUnstakedLPToken = balanceOfUnstakedLPToken();

        // @note if for some reason we have unstaked LP tokens idle in the strategy, account them
        if (_lpAmount > _balanceOfUnstakedLPToken) {
            _unstake(Math.min((_lpAmount - _balanceOfUnstakedLPToken),balanceOfStakedLPToken())); // @note will reset the reward multiplier
        }

        _removeLiquidity(_lpAmount);

        uint256 _wantFreed = balanceOfWant() - _preWithdrawWant;
        if (_amountNeeded > _wantFreed) {
            _liquidatedAmount = _wantFreed;
            _loss = _amountNeeded - _wantFreed;
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function _removeLiquidity(uint256 _lpAmount) internal {
        hubPool.removeLiquidity(address(want), _lpAmount, false);
    }

    function _stake(uint256 _amountToStake) internal {
        lpStaker.stake(address(lpToken), _amountToStake);
    }
    
    // @note just in case we need to easily stake idle LP tokens
    function stake(uint256 _amountToStake) external onlyVaultManagers {
        _stake(_amountToStake);
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
    // @note Returns 18 decimal
    function _valueLpToWant() internal view returns (uint256) {
        address _wantAddress = address(want);
        HubPool.PooledToken memory _struct = hubPool.pooledTokens(_wantAddress);

        if (IERC20(_struct.lpToken).totalSupply() == 0) return 1e18;

        // @note _updateAccumulatedLpFees logic
        uint256 timeFromLastInteraction = block.timestamp - _struct.lastLpFeeUpdate;
        uint256 maxUndistributedLpFees = (_struct.undistributedLpFees * hubPool.lpFeeRatePerSecond() * timeFromLastInteraction) / (1e18);
        uint256 accumulatedFees = maxUndistributedLpFees < _struct.undistributedLpFees ? maxUndistributedLpFees : _struct.undistributedLpFees;
        _struct.undistributedLpFees -= accumulatedFees;
        _struct.lastLpFeeUpdate = uint32(block.timestamp);
        
        // @note _sync logic
        uint256 balance = IERC20(_wantAddress).balanceOf(address(hubPool));
        uint256 balanceSansBond = _wantAddress == address(hubPool.bondToken()) && hubPool.rootBundleProposal().unclaimedPoolRebalanceLeafCount != 0 ? balance - hubPool.bondAmount() : balance;
        if (balanceSansBond > _struct.liquidReserves) {
            _struct.utilizedReserves -= uint256(balanceSansBond - _struct.liquidReserves);
            _struct.liquidReserves = balanceSansBond;
        }
        uint256 numerator = uint256(_struct.liquidReserves) + _struct.utilizedReserves - uint256(_struct.undistributedLpFees);
        return (uint256(numerator) * 1e18) / IERC20(_struct.lpToken).totalSupply();
    }

    function valueLpToWant() external view returns (uint256) {
        return _valueLpToWant();
    }

    function availableLiquidity() public view returns (uint256) {
        return hubPool.pooledTokens(address(want)).liquidReserves; // @note returns native asset avail.
    }

    function pendingRewards() external view returns (uint256) {
        return lpStaker.getOutstandingRewards(address(lpToken), address(this));
    }
}
