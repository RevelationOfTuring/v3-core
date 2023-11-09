// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;

import '../NoDelegateCall.sol';

contract NoDelegateCallTest is NoDelegateCall {
    function canBeDelegateCalled() public view returns (uint256) {
        return block.timestamp / 5;
    }

    // 无法被delegatecall
    function cannotBeDelegateCalled() public view noDelegateCall returns (uint256) {
        return block.timestamp / 5;
    }

    // 计算canBeDelegateCalled的gas消耗
    function getGasCostOfCanBeDelegateCalled() external view returns (uint256) {
        uint256 gasBefore = gasleft();
        canBeDelegateCalled();
        return gasBefore - gasleft();
    }

    // 计算cannotBeDelegateCalled的gas消耗
    function getGasCostOfCannotBeDelegateCalled() external view returns (uint256) {
        uint256 gasBefore = gasleft();
        cannotBeDelegateCalled();
        return gasBefore - gasleft();
    }

    function callsIntoNoDelegateCallFunction() external view {
        noDelegateCallPrivate();
    }

    // 被noDelegateCall修饰的私有方法
    function noDelegateCallPrivate() private view noDelegateCall {}
}
