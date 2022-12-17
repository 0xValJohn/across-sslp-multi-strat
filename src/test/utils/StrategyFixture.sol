// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;
pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ExtendedTest} from "./ExtendedTest.sol";
import {Vm} from "forge-std/Vm.sol";
import {IVault} from "../../interfaces/Vault.sol";
import {Strategy} from "../../Strategy.sol";
string constant vaultArtifact = "artifacts/Vault.json";

contract StrategyFixture is ExtendedTest {
    using SafeERC20 for IERC20;

    struct AssetFixture {
        IVault vault;
        Strategy strategy;
        IERC20 want;
    }

    IERC20 public weth;

    AssetFixture[] public assetFixtures;

    mapping(string => address) public tokenAddrs;
    mapping(string => uint256) public tokenPrices; 

    address public gov = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;
    address public user = address(1);
    address public whale = address(2);
    address public rewards = address(3);
    address public guardian = address(4);
    address public management = address(5);
    address public strategist = address(6);
    address public keeper = address(7);

    uint256 public minFuzzAmt = 1_000 ether;
    uint256 public maxFuzzAmt = 5_000_000 ether;
    uint256 public constant DELTA = 1;

    function setUp() public virtual {
        _setTokenPrices();
        _setTokenAddrs();

        weth = IERC20(tokenAddrs["WETH"]);

        // @note want selector for strategy
        string[3] memory _tokensToTest = ["USDC", "DAI", "WETH"];

        for (uint8 i = 0; i < _tokensToTest.length; ++i) {
            string memory _tokenToTest = _tokensToTest[i];
            IERC20 _want = IERC20(tokenAddrs[_tokenToTest]);

            (address _vault, address _strategy) = deployVaultAndStrategy(
                address(_want), _tokenToTest, gov, rewards, "", "", guardian, management, keeper, strategist
            );

            assetFixtures.push(AssetFixture(IVault(_vault), Strategy(_strategy), _want));

            vm.label(address(_vault), string(abi.encodePacked(_tokenToTest, "Vault")));
            vm.label(address(_strategy), string(abi.encodePacked(_tokenToTest, "Strategy")));
            vm.label(address(_want), _tokenToTest);
        }

        // add more labels to make your traces readable
        vm.label(gov, "Gov");
        vm.label(user, "User");
        vm.label(whale, "Whale");
        vm.label(rewards, "Rewards");
        vm.label(guardian, "Guardian");
        vm.label(management, "Management");
        vm.label(strategist, "Strategist");
        vm.label(keeper, "Keeper");
    }

    // Deploys a vault
    function deployVault(
        address _token,
        address _gov,
        address _rewards,
        string memory _name,
        string memory _symbol,
        address _guardian,
        address _management
    ) public returns (address) {
        vm.prank(_gov);
        address _vaultAddress = deployCode(vaultArtifact);
        IVault _vault = IVault(_vaultAddress);
        vm.prank(_gov);
        _vault.initialize(_token, _gov, _rewards, _name, _symbol, _guardian, _management);

        vm.prank(_gov);
        _vault.setDepositLimit(type(uint256).max);

        return address(_vault);
    }

    // Deploys a strategy
    function deployStrategy(address _vault, string memory _tokenSymbol) public returns (address) {
        Strategy _strategy = new Strategy(
            _vault
            );

        return address(_strategy);
    }

    // Deploys a vault and strategy attached to vault
    function deployVaultAndStrategy(
        address _token,
        string memory _tokenSymbol,
        address _gov,
        address _rewards,
        string memory _name,
        string memory _symbol,
        address _guardian,
        address _management,
        address _keeper,
        address _strategist
    ) public returns (address _vaultAddr, address _strategyAddr) {
        _vaultAddr = deployVault(_token, _gov, _rewards, _name, _symbol, _guardian, _management);
        IVault _vault = IVault(_vaultAddr);

        vm.prank(_strategist);
        _strategyAddr = deployStrategy(_vaultAddr, _tokenSymbol);
        Strategy _strategy = Strategy(_strategyAddr);

        vm.prank(_strategist);
        _strategy.setKeeper(_keeper);

        vm.prank(_gov);
        _vault.addStrategy(_strategyAddr, 10_000, 0, type(uint256).max, 1_000);

        return (address(_vault), address(_strategy));
    }

    function _setTokenAddrs() internal {
        tokenAddrs["WETH"] = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        tokenAddrs["DAI"] = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
        tokenAddrs["USDC"] = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    }

    function _setTokenPrices() internal {
        tokenPrices["WETH"] = 1_000;
        tokenPrices["USDC"] = 1;
        tokenPrices["DAI"] = 1;
    }
}
