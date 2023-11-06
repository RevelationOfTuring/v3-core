// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.4.0;

/// @title FixedPoint96
/// @notice A library for handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
/// @dev Used in SqrtPriceMath.sol
// 注：该库用于SqrtPriceMath.sol
// 该库的本质是用二进制来表示浮点数
library FixedPoint96 {
    uint8 internal constant RESOLUTION = 96;
    // 2**96
    uint256 internal constant Q96 = 0x1000000000000000000000000;
}
