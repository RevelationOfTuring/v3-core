// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3PoolDeployer.sol';

import './UniswapV3Pool.sol';

contract UniswapV3PoolDeployer is IUniswapV3PoolDeployer {
    // 在创建pool时的参数
    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @inheritdoc IUniswapV3PoolDeployer
    // 每次部署pool时候都会将对应constructor参数写入到这部分storage中，部署成功后会将该storage delete掉
    // 这么做的目的是不希望在部署合约的时候携带constructor参数，这样在找token0 vs token1的pool时，就可以更方便地直接通过计算CREATE2
    // 生成地址得到（计算的过程中不再需要考虑constructor参数，更加节省gas）
    // 注：CREATE2 会将合约的initcode和salt一起用来计算创建出的合约地址。而initcode是包含contructor code和其参数的。所以上面是不希望
    // 在部署合约的时候携带constructor参数。
    Parameters public override parameters;

    /// @dev Deploys a pool with the given parameters by transiently setting the parameters storage slot and then
    /// clearing it after deploying the pool.
    /// @param factory The contract address of the Uniswap V3 factory
    /// @param token0 The first token of the pool by address sort order
    /// @param token1 The second token of the pool by address sort order
    /// @param fee The fee collected upon every swap in the pool, denominated in hundredths of a bip
    /// @param tickSpacing The spacing between usable ticks
    function deploy(
        // 即Parameters中存储的参数
        address factory,
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing
    ) internal returns (address pool) {
        // 将部署pool涉及到的参数都写入全局变量parameters中
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing});
        // 使用CREATE2来部署pool合约，使用的salt为hash(token0.token1.fee)
        // 注：在部署的UniswapV3Pool的constructor函数中会反查factory合约的parameters()方法得到上一步存在storage的各个constructor参数
        // ，然后正常进行pool合约的初始化
        // pool为部署后的合约地址
        pool = address(new UniswapV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}());
        // 部署pool后，delete掉存在storage中的参数
        delete parameters;
    }
}
