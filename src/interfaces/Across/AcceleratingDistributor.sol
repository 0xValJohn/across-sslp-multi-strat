// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.15;

interface AcceleratingDistributor {
    function rewardToken() external view returns (address);
    function stake(address stakedToken, uint256 amount) external;
    function unstake(address stakedToken, uint256 amount) external;
    function withdrawReward(address stakedToken) external;
    function getOutstandingRewards(address stakedToken, address account) external view returns (uint256);
    function getUserStake(address stakedToken, address account) external view returns (uint256);
}