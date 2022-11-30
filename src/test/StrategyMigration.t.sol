// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import {StrategyFixture} from "./utils/StrategyFixture.sol";

import {Strategy} from "../Strategy.sol";
import {IVault} from "../interfaces/Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract StrategyMigrationTest is StrategyFixture {
    function setUp() public override {
        super.setUp();
    }

    // TODO: Add tests that show proper migration of the strategy to a newer one
    // Use another copy of the strategy to simmulate the migration
    // Show that nothing is lost.
    function testMigration(uint256 _amount) public {
        vm.assume(_amount > minFuzzAmt && _amount < maxFuzzAmt);

        // Logic for multi-want testing
        for (uint8 i = 0; i < assetFixtures.length; ++i) {
            AssetFixture memory _assetFixture = assetFixtures[i];
            IVault vault = _assetFixture.vault;
            Strategy strategy = _assetFixture.strategy;
            IERC20 want = _assetFixture.want;
            uint8 _wantDecimals = ERC20(address(want)).decimals();
            string memory _wantSymbol = ERC20(address(want)).symbol();
            if (_wantDecimals != 18) {
                uint256 _decimalDifference = 18 - _wantDecimals;
                _amount = _amount / (10 ** _decimalDifference);
            }
            if (keccak256(abi.encodePacked(_wantSymbol)) == keccak256(abi.encodePacked("WETH"))) {
                _amount = _amount / 1_000; // fuzz amount modifier for WETH e.g. 100 WETH --> 0.1 ETH
            }
        //

            deal(address(want), user, _amount);

            // Deposit to the vault and harvest
            vm.prank(user);
            want.approve(address(vault), _amount);
            vm.prank(user);
            vault.deposit(_amount);
            skip(1);
            vm.prank(strategist);
            strategy.harvest();
            assertRelApproxEq(strategy.estimatedTotalAssets(), _amount, DELTA);

            // Migrate to a new strategy
            vm.prank(strategist);
            Strategy newStrategy = Strategy(deployStrategy(address(vault), ERC20(address(want)).symbol()));
            vm.prank(gov);
            vault.migrateStrategy(address(strategy), address(newStrategy));
            assertRelApproxEq(newStrategy.estimatedTotalAssets(), _amount, DELTA);
        }
    }
}
