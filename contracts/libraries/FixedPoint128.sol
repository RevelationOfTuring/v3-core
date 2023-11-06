// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.4.0;

/// @title FixedPoint128
/// @notice A library for handling binary fixed point numbers, see https://en.wikipedia.org/wiki/Q_(number_format)
// 该库的本质是用二进制来表示浮点数
library FixedPoint128 {
    // 2**128
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;
}
