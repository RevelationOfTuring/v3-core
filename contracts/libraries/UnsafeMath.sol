// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title Math functions that do not check inputs or outputs
/// @notice Contains methods that perform common math functions but do not do any overflow or underflow checks
// 没有任何数学检查的数学库
library UnsafeMath {
    /// @notice Returns ceil(x / y)
    /// @dev division by 0 has unspecified behavior, and must be checked externally
    /// @param x The dividend
    /// @param y The divisor
    /// @return z The quotient, ceil(x / y)
    // 计算x/y(向上取整)
    // 注：即使除数y=0，也不会报错
    function divRoundingUp(uint256 x, uint256 y) internal pure returns (uint256 z) {
        // 注：
        //    - 如果y==0，那么div(x, y)和mod(x, y)的结果都为0
        //    - gt(x,y)，如果x>y返回1，否则返回0
        assembly {
            z := add(div(x, y), gt(mod(x, y), 0))
        }
    }
}
