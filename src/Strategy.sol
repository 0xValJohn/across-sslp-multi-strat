// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.15;
pragma experimental ABIEncoderV2;

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

// ---------------------- STATE VARIABLES ----------------------

    bool internal isOriginal = true;
    uint256 private constant max = type(uint256).max;
    address public tradeFactory;
    HubPool public hubPool;
    AcceleratingDistributor public lpStaker;
    IERC20 public lpToken;
    IERC20 public emissionToken;
    uint256 internal wantDecimals;
    string internal strategyName;

// ------------------------ CONSTRUCTOR ------------------------

    constructor(address _vault, address _hubPool, address _lpStaker) BaseStrategy(_vault) {
        _initializeStrategy(_hubPool, _lpStaker);
    }

    function _initializeStrategy(
        address _hubPool,
        address _lpStaker
    ) internal {
        hubPool = HubPool(_hubPool);
        lpToken = IERC20(hubPool.pooledTokens(address(want)).lpToken);
        lpStaker = AcceleratingDistributor(_lpStaker);
        emissionToken = IERC20(lpStaker.rewardToken());
        wantDecimals = IERC20Metadata(address(want)).decimals();
    }

// ---------------------- CLONING ----------------------
    event Cloned(address indexed clone);

    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _hubPool,
        address _lpStaker
    ) public {
        require(address(hubPool) == address(0)); // @dev only initialize one time
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrategy(_hubPool, _lpStaker);
    }

    function clone(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _hubPool,
        address _lpStaker
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
        Strategy(newStrategy).initialize(
            _vault, _strategist, _rewards, _keeper, _hubPool, _lpStaker
        );
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
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        _claimRewards();

        uint256 _totalAssets = estimatedTotalAssets();
        uint256 _totalDebt = vault.strategies(address(this)).totalDebt;

        // @dev calculate intial profits
        unchecked { _profit = _totalAssets > _totalDebt ? _totalAssets - _totalDebt : 0; } // @dev no underflow risk

        // @dev free up _debtOutstanding + our profit
        uint256 _toLiquidate = _debtOutstanding + _profit;
        uint256 _wantBalance = balanceOfWant();

        if (_toLiquidate > _wantBalance) {
            uint256 _liquidatedAmount;
            unchecked { (_liquidatedAmount, _loss) = _removeLiquidity(_toLiquidate - _wantBalance); } // @dev no underflow risk
            _totalAssets = estimatedTotalAssets();
        }

        uint256 _liquidWant = balanceOfWant();

        // @dev calculate _debtPayment
        // @dev enough to pay for all profit and _debtOutstanding (partial or full)
        if (_liquidWant > _profit) {
	        _debtPayment = Math.min(_liquidWant - _profit, _debtOutstanding);
        // @dev enough to pay profit (partial or full) only
        } else {
            _profit = _liquidWant;
            _debtPayment = 0;
        }

        // @dev calculate final p&L
        unchecked { (_loss = _loss + (_totalDebt > _totalAssets ? _totalDebt - _totalAssets : 0)); } // @dev no underflow risk
        
        if (_loss > _profit) {
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            _profit = _profit - _loss;
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
        uint256 _balanceOfUnstakedLPToken = balanceOfUnstakedLPToken();
        if (_balanceOfUnstakedLPToken > 0) {
            _removeLiquidity(_balanceOfUnstakedLPToken);
        }
        return balanceOfWant();
    }

    function prepareMigration(address _newStrategy) internal override {
        _unstake(balanceOfStakedLPToken());
        lpToken.safeTransfer(_newStrategy, balanceOfUnstakedLPToken());
    }

// ---------------------- KEEP3RS ----------------------

    function harvestTrigger(uint256 callCostinEth) public view override returns (bool) {
        if (!isActive()) {
            return false;
        }

        StrategyParams memory params = vault.strategies(address(this));
        if (block.timestamp - params.lastReport > maxReportDelay) {
            return true;
        }

        if (!isBaseFeeAcceptable()) {
            return false;
        }

        if (forceHarvestTriggerOnce) {
            return true;
        }

        if (block.timestamp - params.lastReport > minReportDelay) {
            return true;
        }

        if (vault.creditAvailable() > creditThreshold) {
            return true;
        }

        return false;
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
        _checkAllowance(address(hubPool), address(want), _wantAmount);
        hubPool.addLiquidity(address(want), _wantAmount);
        _stake(balanceOfUnstakedLPToken());
    }

    function _removeLiquidity(uint256 _amountNeeded) internal returns (uint256 _liquidatedAmount, uint256 _loss) {
        uint256 _wantAvailable = Math.min(availableLiquidity(), _amountNeeded); // @dev checking the available liquidity to withdraw
        uint256 _lpTokenAmount = _wantAvailable / valueLpToWant() / 1e18;
        _unstake(_lpTokenAmount); // @dev this will reset the reward multiplier
        hubPool.removeLiquidity(address(want), _lpTokenAmount, false); // @dev 3rd arg is optional, to wrap and unwrap ETH (not required)
    }

    function _stake(uint256 _amountToStake) internal {
        _checkAllowance(address(lpStaker), address(lpToken), _amountToStake);
        lpStaker.stake(address(lpToken), _amountToStake);
    }

    function _unstake(uint256 _amountToUnstake) internal {
        lpStaker.unstake(address(lpToken), _amountToUnstake);    
    }

    function _claimRewards() internal {
        if (pendingRewards() > 0) {
        lpStaker.withdrawReward(address(lpToken));
        }
    }

    function _checkAllowance(address _contract, address _token, uint256 _amount) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, _amount);
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfUnstakedLPToken() public view returns (uint256) {
        return lpToken.balanceOf(address(this));
    }

    function balanceOfStakedLPToken() public view returns (uint256) {
        return lpStaker.getUserStake(address(lpToken),address(this));
    }

    function balanceOfAllLPToken() public view returns (uint256) {
        return balanceOfUnstakedLPToken() + balanceOfStakedLPToken();
    }

    // @dev Will slightly underestimate rate when l1Token balance > liquidReserves
    // Hubpool.sync (internal) can't be called to account for recently concluded L2 -> L1 transfer and associated accounting
    function valueLpToWant() public view returns (uint256) { 
        uint256 _utilizedReserves = hubPool.pooledTokens(address(want)).utilizedReserves; // @note gas-opti: could probably make one hubPool.pooledTokens call
        uint256 _liquidReserves = hubPool.pooledTokens(address(want)).liquidReserves;
        uint256 _undistributedLpFees = hubPool.pooledTokens(address(want)).undistributedLpFees;
        uint256 _lpTokenSupply = lpToken.totalSupply();
        return (_liquidReserves + _utilizedReserves -_undistributedLpFees) * 1e18 / _lpTokenSupply ; // @dev returns rate with 18 decimals
    }

    // @dev When trying to withdraw more funds than available (i.e l1TokensToReturn > liquidReserves), lpStaker will underflow
    function availableLiquidity() public view returns (uint256) {
        return hubPool.pooledTokens(address(want)).liquidReserves;
    }

    function pendingRewards() public view returns (uint256) {
        return lpStaker.getOutstandingRewards(address(lpToken), address(this));
    }

}