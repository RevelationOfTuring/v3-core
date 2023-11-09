// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

/// @title Prevents delegatecall to a contract
/// @notice Base contract that provides a modifier for preventing delegatecall to methods in a child contract
// NoDelegateCall是为了防止本合约被delegatecall
// 该抽象合约提供可一个modifier —— noDelegateCall。所有被该modifier修饰的方法都无法被delegatecall调用
abstract contract NoDelegateCall {
    /// @dev The original address of this contract
    // immutable变量，用于记录本合约的地址
    address private immutable original;

    constructor() {
        // Immutables are computed in the init code of the contract, and then inlined into the deployed bytecode.
        // In other words, this variable won't change when it's checked at runtime.
        // 将本合约地址写入immutable变量。由于immutable变量会在合约初始化的时候计算并写在deployed bytecode中。换句话说，immutable
        // 变量的值不会在合约部署后的任意操作中改变
        original = address(this);
    }

    /// @dev Private method is used instead of inlining into modifier because modifiers are copied into each method,
    ///     and the use of immutable means the address bytes are copied in every place the modifier is used.
    function checkNotDelegateCall() private view {
        // 要求本合约地址等于immutable变量original。如果是delegatecall调用，那么address(this)势必不为original
        require(address(this) == original);
    }

    /// @notice Prevents delegatecall into the modified method
    // 该modifier是用来防止delegatecall对函数进行调用的
    modifier noDelegateCall() {
        // modifier中的内容会被复制到每个被他修饰的函数中。
        // 为什么要用private函数：checkNotDelegateCall()进行封装？
        // 答：如果修饰器内不使用private函数，而是直接写require(address(this) == original);
        // 那么会增大factory合约bytecode（因为require(address(this) == original)会被复制到各个使用该修饰器的函数中），而private函数的代码
        // 只会存一份在bytecode中，调用的时候进行跳转
        // 而immutable变量original的address bytes会被复制到每个使用modifier的地方
        checkNotDelegateCall();
        _;
    }
}
