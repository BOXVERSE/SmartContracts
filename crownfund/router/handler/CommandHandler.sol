// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {RoutingTable} from '../routing/RoutingTable.sol';
import {CodeMask} from '../lib/CodeMask.sol';
import {BytesLib} from '../lib/BytesLib.sol';

abstract contract CommandHandler is RoutingTable {
    using BytesLib for bytes;

    constructor(address[] memory addresses) RoutingTable(addresses) {}

    function handle(bytes1 code, bytes calldata input) internal returns (bool isSuccess, bytes memory output) {
        uint8 commandCode = uint8(code & CodeMask.COMMAND_CODE_MASK);

        isSuccess = true;

        if(commandCode == 0x0) {
            address payable to;
            if(uint8(code & CodeMask.FLAG_VALUE_MASK) != 0) {
                uint256 value;
                assembly {
                    to := calldataload(input.offset)
                    value := calldataload(add(input.offset, 0x20))
                }
                bytes calldata data = input.getSubBytes(2);
                (isSuccess, output) = to.call{value: value}(data);
            } else {
                assembly {
                    to := calldataload(input.offset)
                }
                bytes calldata data = input.getSubBytes(1);
                (isSuccess, output) = to.call(data);
            }
        } else if(RoutingTable.addressByCode[commandCode] != address(0x0)) {
            if(uint8(code & CodeMask.FLAG_VALUE_MASK) != 0) {
                uint256 value;
                assembly {
                    value := calldataload(input.offset)
                }
                bytes calldata data = input.getSubBytes(1);
                (isSuccess, output) = RoutingTable.addressByCode[commandCode].call{value: value}(data);
            } else {
                (isSuccess, output) = RoutingTable.addressByCode[commandCode].call(input);
            }
        }
    }
}