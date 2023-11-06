// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title Math library for liquidity
// 用于流动性计算的库
// 即uint128 + int128 (带溢出检查)
library LiquidityMath {
    /// @notice Add a signed liquidity delta to liquidity and revert if it overflows or underflows
    /// @param x The liquidity before change
    /// @param y The delta by which liquidity should be changed
    /// @return z The liquidity delta
    // 计算x+y，y为int128，正表示增加，负表示减少
    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        if (y < 0) {
            // 如果y为负数，计算z=x-|y|
            require((z = x - uint128(-y)) < x, 'LS');
        } else {
            // 如果y为非负数，计算z=x + y
            require((z = x + uint128(y)) >= x, 'LA');
        }
    }
}
