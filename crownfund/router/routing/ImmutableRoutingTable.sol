// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IRoutingTable} from '../interfaces/IRoutingTable.sol';
import {Ownable} from '../access/Ownable.sol';

abstract contract ImmutableRoutingTable is IRoutingTable, Ownable {

    mapping(uint256 => address) internal addressByCode;

    address internal immutable SEAPORT = 0x00000000006c3852cbEf3e08E8dF289169EdE581;

    address internal immutable X2Y2 = 0x74312363e45DCaBA76c59ec49a7Aa8A65a67EeD3;

    address internal immutable LOOKS_RARE = 0x59728544B08AB483533076417FbBB2fD0B17CE3a;

    constructor() {
        addressByCode[0x1] = SEAPORT;
        addressByCode[0x2] = X2Y2;
        addressByCode[0x3] = LOOKS_RARE;
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