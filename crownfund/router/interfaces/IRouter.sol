// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface IRouter {

    error IllegalInput();
    error HandleFailed(uint256 index, bytes message);

    function run(bytes calldata codes, bytes[] calldata inputs) external payable;
}