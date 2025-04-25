// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IRoutingTable} from '../interfaces/IRoutingTable.sol';
import {Ownable} from '../access/Ownable.sol';

abstract contract RoutingTable is IRoutingTable, Ownable {

    mapping(uint256 => address payable) internal addressByCode;

    event MappingChanged(uint256 indexed index, address newAddress);

    constructor(address[] memory addresses) {
        assembly {
            let len := mload(addresses)            
            
            for
                {let index := 0}
                lt(index, len)
                {}
            {
                index := add(index, 1)

                mstore(0, index)
                mstore(0x20, addressByCode.slot)
                let hash := keccak256(0, 64)
                sstore(hash, mload(add(addresses, mul(index, 0x20))))
            }
        }
    }

    /**
    * 修改 Mapping 指向的地址
    */
    function changeMapping(uint256 index, address newAddress) external onlyOwner {
        require(index != 0x0 && index <= 0x3F, "OUT_OF_INDEX_RANGE");

        emit MappingChanged(index, newAddress);
        assembly {
            mstore(0, index)
            mstore(0x20, addressByCode.slot)
            let hash := keccak256(0, 64)
            sstore(hash, newAddress)
        } 
    }

    /**
    * 根據索引取得對應地址
    */
    function getAddress(uint256 index) external view onlyOwner returns (address result) {
        assembly {
            mstore(0, index)
            mstore(0x20, addressByCode.slot)
            let hash := keccak256(0, 64)
            result := sload(hash)
        } 
    }
}