// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Factory.sol';

import './UniswapV3PoolDeployer.sol';
import './NoDelegateCall.sol';

import './UniswapV3Pool.sol';

/// @title Canonical Uniswap V3 factory
/// @notice Deploys Uniswap V3 pools and manages ownership and control over pool protocol fees
contract UniswapV3Factory is IUniswapV3Factory, UniswapV3PoolDeployer, NoDelegateCall {
    /// @inheritdoc IUniswapV3Factory
    // factory的owner
    address public override owner;

    /// @inheritdoc IUniswapV3Factory
    // 定义tick间隔的mapping，不同的fee对应不同的tick间隔
    // key为fee，value为对应手续费的tick spacing
    mapping(uint24 => int24) public override feeAmountTickSpacing;
    /// @inheritdoc IUniswapV3Factory
    // key1: token0 address
    // key2: token1 address
    // key3: fee等级
    // value: 对应pool地址
    mapping(address => mapping(address => mapping(uint24 => address))) public override getPool;

    constructor() {
        // 设定owner
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);

        // 0.05%手续费对应tick spacing为10
        feeAmountTickSpacing[500] = 10;
        emit FeeAmountEnabled(500, 10);
        // 0.3%手续费对应tick spacing为60
        feeAmountTickSpacing[3000] = 60;
        emit FeeAmountEnabled(3000, 60);
        // 1%手续费对应tick spacing为200
        feeAmountTickSpacing[10000] = 200;
        emit FeeAmountEnabled(10000, 200);
    }

    /// @inheritdoc IUniswapV3Factory
    // 创建pool（禁止delegatecall）
    function createPool(
        // 两个token的地址
        address tokenA,
        address tokenB,
        // 该pool的手续费等级
        uint24 fee
    ) external override noDelegateCall returns (address pool) {
        // 两个token地址不能一样
        require(tokenA != tokenB);
        // 按照地址大小排序，最终：token0<token1
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        // token0不能为0地址
        require(token0 != address(0));
        // 通过手续费等级获得对应tick space
        int24 tickSpacing = feeAmountTickSpacing[fee];
        // 要求fee为0.05%/0.3%/1%其中的一种
        require(tickSpacing != 0);
        // 要求token0-token1-fee的pool没有创建
        require(getPool[token0][token1][fee] == address(0));
        // 部署pool
        pool = deploy(address(this), token0, token1, fee, tickSpacing);
        // 记录部署的pool地址到mapping
        getPool[token0][token1][fee] = pool;
        // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses
        // token1-token0-fee反向映射填充mapping（目的是为了在后面已知token{0、1}来寻找对应pool地址时，不进行排序，节省gas）
        getPool[token1][token0][fee] = pool;
        // 抛出事件
        emit PoolCreated(token0, token1, fee, tickSpacing, pool);
    }

    /// @inheritdoc IUniswapV3Factory
    // 当前owner设置新owner
    function setOwner(address _owner) external override {
        require(msg.sender == owner);
        emit OwnerChanged(owner, _owner);
        owner = _owner;
    }

    /// @inheritdoc IUniswapV3Factory
    // 当前owner增添新的fee类别及对应tick space
    // fee为真实fee * 10000*100，比如要设置手续费等级为20%，那么fee = 0.2*10000*100=200000
    function enableFeeAmount(uint24 fee, int24 tickSpacing) public override {
        // 验证管理员身份
        require(msg.sender == owner);
        // 要求手续费最大不能超过100%
        require(fee < 1000000);
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        // 对应的tick space需要介于(0,16384)之间，tick space过大会引起 TickBitmap#nextInitializedTickWithinOneWord 产生int24的溢出
        // tick space ==16384意味着 1个tick间隔会引起5倍的价格变化
        require(tickSpacing > 0 && tickSpacing < 16384);
        // 要求该等级的fee之前没有被设置过tick space
        require(feeAmountTickSpacing[fee] == 0);

        // 设置该等级的fee的tick space为tickSpacing
        feeAmountTickSpacing[fee] = tickSpacing;
        // 抛出事件
        emit FeeAmountEnabled(fee, tickSpacing);
    }
}
