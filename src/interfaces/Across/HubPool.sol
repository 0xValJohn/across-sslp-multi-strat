// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.15;
interface HubPool {  
    struct PooledToken {
        address lpToken;
        bool isEnabled;
        uint32 lastLpFeeUpdate;
        uint256 utilizedReserves;
        uint256 liquidReserves;
        uint256 undistributedLpFees;
    }

    function addLiquidity(address l1Token, uint256 l1TokenAmount) external;
    function removeLiquidity(address l1Token, uint256 lpTokenAmount, bool sendEth) external;
    function pooledTokens(address l1Token) external view returns (PooledToken memory);
}