// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.7.6;

import '../libraries/BitMath.sol';

contract BitMathTest {
    function mostSignificantBit(uint256 x) external pure returns (uint8 r) {
        return BitMath.mostSignificantBit(x);
    }

    // 计算BitMath.mostSignificantBit()的gas消耗
    function getGasCostOfMostSignificantBit(uint256 x) external view returns (uint256) {
        uint256 gasBefore = gasleft();
        BitMath.mostSignificantBit(x);
        return gasBefore - gasleft();
    }

    function leastSignificantBit(uint256 x) external pure returns (uint8 r) {
        return BitMath.leastSignificantBit(x);
    }

    // 计算BitMath.leastSignificantBit()的gas消耗
    function getGasCostOfLeastSignificantBit(uint256 x) external view returns (uint256) {
        uint256 gasBefore = gasleft();
        BitMath.leastSignificantBit(x);
        return gasBefore - gasleft();
    }
}
