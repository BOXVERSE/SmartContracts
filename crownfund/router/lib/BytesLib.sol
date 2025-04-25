// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

library BytesLib {

    /**
    * 提取 bytes 變數中的 bytes 值
    * 如果根據 index 偏移後指向的值，並非 offset value + len value + content 的格式，則會得到異常的結果
    */
    function getSubBytes(bytes calldata _bytes, uint256 index) internal pure returns (bytes calldata result) {
        assembly {
            let lengthOffset := add(_bytes.offset, calldataload(add(_bytes.offset, mul(0x20, index))))
            result.offset := add(lengthOffset, 0x20)
            result.length := calldataload(lengthOffset)
        }
    }
}