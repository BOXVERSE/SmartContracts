// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {CommandHandler} from './handler/CommandHandler.sol';
import {IRouter} from './interfaces/IRouter.sol';
import {IERC721Receiver} from './interfaces/IERC721Receiver.sol';
import {IERC165} from './interfaces/IERC165.sol';
import {CodeMask} from './lib/CodeMask.sol';

contract Router is IRouter, CommandHandler, IERC721Receiver, IERC165 {

    constructor(address[] memory addresses) CommandHandler(addresses) {}

    /**
    * code => rollback flag(1 bit) + value flag(1 bit) + command code(6 bit)
    */
    function run(bytes calldata codes, bytes[] calldata inputs) external payable {
        bool isSuccess;
        bytes memory output;
        uint256 codesLen = codes.length;

        if (inputs.length != codesLen) revert IllegalInput();

        for(uint256 index = 0; index < codesLen;) {
            bytes1 code = codes[index];
            bytes calldata input = inputs[index];

            (isSuccess, output) = handle(code, input);

            if (!isSuccess && mustSucceed(code)) {
                revert HandleFailed({index: index, message: output});
            }

            assembly {
                index := add(index, 1)
            }
        }
    }

    function mustSucceed(bytes1 code) internal pure returns (bool) {
        return code & CodeMask.FLAG_REVERT_MASK != 0;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC721Receiver).interfaceId
        || interfaceId == type(IERC165).interfaceId;
    }
}