// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title BitMath
/// @dev This library provides functionality for computing bit properties of an unsigned integer
// 该库专门用于寻找一个uint256的最高和最低有效位（most/least significant bit）
library BitMath {
    /// @notice Returns the index of the most significant bit of the number,
    ///     where the least significant bit is at index 0 and the most significant bit is at index 255
    /// @dev The function satisfies the property:
    ///     x >= 2**mostSignificantBit(x) and x < 2**(mostSignificantBit(x)+1)
    /// @param x the value for which to compute the most significant bit, must be greater than 0
    /// @return r the index of the most significant bit

    // 计算一个uint256的最高有效位，返回值r表示x的最高有效位的index（0~255）
    //     2**r <= x < 2**(r+1)
    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        // (2分法)
        // x不为0
        require(x > 0);

        // 如果x >= 2**128
        if (x >= 0x100000000000000000000000000000000) {
            // x右移128位
            x >>= 128;
            // r自增128
            r += 128;
        }
        // 如果x >= 2**64
        if (x >= 0x10000000000000000) {
            // x右移64位
            x >>= 64;
            // r自增64
            r += 64;
        }
        // 如果x >= 2**32
        if (x >= 0x100000000) {
            // x右移32位
            x >>= 32;
            // r自增32
            r += 32;
        }
        // 如果x >= 2**16
        if (x >= 0x10000) {
            // x右移16位
            x >>= 16;
            // r自增16
            r += 16;
        }
        // 如果x >= 2**8
        if (x >= 0x100) {
            // x右移8位
            x >>= 8;
            // r自增8
            r += 8;
        }
        // 如果x >= 2**4
        if (x >= 0x10) {
            // x右移4位
            x >>= 4;
            // r自增4
            r += 4;
        }
        // 如果x >= 2**2
        if (x >= 0x4) {
            // x右移2位
            x >>= 2;
            // r自增2
            r += 2;
        }
        // 如果x >= 2**1, r就自增1，否则r不自增，直接返回
        if (x >= 0x2) r += 1;
    }

    /// @notice Returns the index of the least significant bit of the number,
    ///     where the least significant bit is at index 0 and the most significant bit is at index 255
    /// @dev The function satisfies the property:
    ///     (x & 2**leastSignificantBit(x)) != 0 and (x & (2**(leastSignificantBit(x)) - 1)) == 0)
    /// @param x the value for which to compute the least significant bit, must be greater than 0
    /// @return r the index of the least significant bit
    // 计算一个uint256的最低有效位，返回值r表示x的最低有效位的index（0~255）
    //     x & (2**r) !=0 且  x & ((2**r)-1) ==0
    function leastSignificantBit(uint256 x) internal pure returns (uint8 r) {
        // (2分法)
        // 要求x不为0
        require(x > 0);
        // 令r为255
        r = 255;
        // 如果x的低128位存在非0位
        if (x & type(uint128).max > 0) {
            // r自减128
            r -= 128;
        } else {
            // 如果x的低128位不存在非0位
            // x右移128位
            x >>= 128;
        }
        // 如果x的低64位存在非0位
        if (x & type(uint64).max > 0) {
            // r自减64
            r -= 64;
        } else {
            // 如果x的低64位不存在非0位
            // x右移64位
            x >>= 64;
        }
        // 如果x的低32位存在非0位
        if (x & type(uint32).max > 0) {
            // r自减32
            r -= 32;
        } else {
            // 如果x的低32位不存在非0位
            // x右移32位
            x >>= 32;
        }
        // 如果x的低16位存在非0位
        if (x & type(uint16).max > 0) {
            // r自减16
            r -= 16;
        } else {
            // 如果x的低16位不存在非0位
            // x右移16位
            x >>= 16;
        }
        // 如果x的低8位存在非0位
        if (x & type(uint8).max > 0) {
            // r自减8
            r -= 8;
        } else {
            // 如果x的低8位不存在非0位
            // x右移8位
            x >>= 8;
        }
        // 如果x的低4位存在非0位
        if (x & 0xf > 0) {
            // r自减4
            r -= 4;
        } else {
            // 如果x的低4位不存在非0位
            // x右移4位
            x >>= 4;
        }
        // 如果x的低2位存在非0位
        if (x & 0x3 > 0) {
            // r自减2
            r -= 2;
        } else {
            // 如果x的低2位不存在非0位
            // x右移2位
            x >>= 2;
        }
        // 如果x的低1位存在非0位，r自减1。否则r不自减，直接返回
        if (x & 0x1 > 0) r -= 1;
    }
}
