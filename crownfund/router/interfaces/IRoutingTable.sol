// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IRoutingTable {
    function getAddress(uint256 index) external view returns (address result);
}