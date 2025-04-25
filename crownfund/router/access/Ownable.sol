// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/**
* 訪問權限控制-合約所有者
*/
abstract contract Ownable {

    address private owner;

    event OwnerChanged(address indexed previousOwner, address indexed newOwner);

    constructor() {
        owner = msg.sender;
    }

    /**
    * 轉移合約所有者
    */
    function changeOwner(address _newOwner) external onlyOwner {
        emit OwnerChanged(owner, _newOwner);
        owner = _newOwner;
    }

    /**
    * 取得當前合約所有者
    */
    function getOwner() external view virtual returns (address) {
        return owner;
    }

    /**
    * 只限定合約所有者操作的修飾器
    */
    modifier onlyOwner() {
        require(msg.sender == owner, "NOT_CURRENT_OWNER");
        _;
    }
}