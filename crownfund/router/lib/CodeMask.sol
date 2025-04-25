// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

library CodeMask {
    // 該交易失敗是否需復原整批交易的狀態
    bytes1 internal constant FLAG_REVERT_MASK = 0x80;
    // 該交易內容是否需要傳遞 value
    bytes1 internal constant FLAG_VALUE_MASK = 0x40;
    // 該交易的調用指令
    bytes1 internal constant COMMAND_CODE_MASK = 0x3F;
}