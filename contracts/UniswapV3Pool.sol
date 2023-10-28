// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;

import './interfaces/IUniswapV3Pool.sol';

import './NoDelegateCall.sol';

import './libraries/LowGasSafeMath.sol';
import './libraries/SafeCast.sol';
import './libraries/Tick.sol';
import './libraries/TickBitmap.sol';
import './libraries/Position.sol';
import './libraries/Oracle.sol';

import './libraries/FullMath.sol';
import './libraries/FixedPoint128.sol';
import './libraries/TransferHelper.sol';
import './libraries/TickMath.sol';
import './libraries/LiquidityMath.sol';
import './libraries/SqrtPriceMath.sol';
import './libraries/SwapMath.sol';

import './interfaces/IUniswapV3PoolDeployer.sol';
import './interfaces/IUniswapV3Factory.sol';
import './interfaces/IERC20Minimal.sol';
import './interfaces/callback/IUniswapV3MintCallback.sol';
import './interfaces/callback/IUniswapV3SwapCallback.sol';
import './interfaces/callback/IUniswapV3FlashCallback.sol';

contract UniswapV3Pool is IUniswapV3Pool, NoDelegateCall {
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];

    /// @inheritdoc IUniswapV3PoolImmutables
    // uniswap V3的factory合约地址
    address public immutable override factory;
    /// @inheritdoc IUniswapV3PoolImmutables
    // 交易对中地址较小的token的地址
    address public immutable override token0;
    /// @inheritdoc IUniswapV3PoolImmutables
    // 交易对中地址较大的token的地址
    address public immutable override token1;
    /// @inheritdoc IUniswapV3PoolImmutables
    // 该pool的手续费等级
    uint24 public immutable override fee;

    /// @inheritdoc IUniswapV3PoolImmutables
    // 该pool的tick spacing
    int24 public immutable override tickSpacing;

    /// @inheritdoc IUniswapV3PoolImmutables
    uint128 public immutable override maxLiquidityPerTick;

    struct Slot0 {
        // the current price
        // 该池子当前价格平方根，即sqrt(token1/token0)的Q64.96值
        uint160 sqrtPriceX96;
        // the current tick
        // 该池子当前价格平方根对应的tick index
        int24 tick;
        // the most-recently updated index of the observations array
        // 最近一次写入oracle observation的index
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        // 用于防重入的重入锁
        bool unlocked;
    }
    /// @inheritdoc IUniswapV3PoolState
    // 本pool的一些状态变量
    Slot0 public override slot0;

    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal0X128;
    /// @inheritdoc IUniswapV3PoolState
    uint256 public override feeGrowthGlobal1X128;

    // accumulated protocol fees in token0/token1 units
    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }
    /// @inheritdoc IUniswapV3PoolState
    ProtocolFees public override protocolFees;

    /// @inheritdoc IUniswapV3PoolState
    // 处于当前价格区间的流动性
    // 注：非该pool的总流动性！
    uint128 public override liquidity;


    /// @inheritdoc IUniswapV3PoolState
    // 所有ticks的元数据，
    mapping(int24 => Tick.Info) public override ticks;
    /// @inheritdoc IUniswapV3PoolState
    mapping(int16 => uint256) public override tickBitmap;


    /// @inheritdoc IUniswapV3PoolState
    mapping(bytes32 => Position.Info) public override positions;
    /// @inheritdoc IUniswapV3PoolState
    Oracle.Observation[65535] public override observations;

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock() {
        require(slot0.unlocked, 'LOK');
        slot0.unlocked = false;
        _;
        slot0.unlocked = true;
    }

    /// @dev Prevents calling a function from anyone except the address returned by IUniswapV3Factory#owner()
    // 修饰器——只有factory的owner才可以调用
    modifier onlyFactoryOwner() {
        require(msg.sender == IUniswapV3Factory(factory).owner());
        _;
    }

    constructor() {
        int24 _tickSpacing;
        // 从factory中反查对应constructor参数，并存入本合约的storage变量中
        (factory, token0, token1, fee, _tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();
        // 将tick spacing 存入tickSpacing变量
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    /// @dev Common checks for valid tick inputs.
    // 检查输入的tick的有效性
    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        // 要求：
        // 1. tickLower < tickUpper
        // 2. tickLower >= TickMath.MIN_TICK (-887272)
        // 3. tickUpper <= TickMath.MAX_TICK (887272)
        require(tickLower < tickUpper, 'TLU');
        require(tickLower >= TickMath.MIN_TICK, 'TLM');
        require(tickUpper <= TickMath.MAX_TICK, 'TUM');
    }

    /// @dev Returns the block timestamp truncated to 32 bits, i.e. mod 2**32. This method is overridden in tests.
    // 返回当前时间戳（uint32）
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp); // truncation is desired
    }

    /// @dev Get the pool's balance of token0
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    // 返回pool名下的token0的余额
    // 注：该方法是经过gas优化的，避免在returndatasize检查之外进行多余的extcodesize检查
    function balance0() private view returns (uint256) {
        // 使用staticcall调用token0.balanceOf(address(this))
        (bool success, bytes memory data) =
            token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        // 检查：staticcall success为true，且返回值>=32字节
        require(success && data.length >= 32);
        // 将返回值从bytes变成uint256
        return abi.decode(data, (uint256));
    }

    /// @dev Get the pool's balance of token1
    /// @dev This function is gas optimized to avoid a redundant extcodesize check in addition to the returndatasize
    /// check
    // 返回pool名下的token1的余额
    // 注：该方法是经过gas优化的，避免在returndatasize检查之外进行多余的extcodesize检查
    function balance1() private view returns (uint256) {
        // 使用staticcall调用token0.balanceOf(address(this))
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        // 检查：staticcall success为true，且返回值>=32字节
        require(success && data.length >= 32);
        // 将返回值从bytes变成uint256
        return abi.decode(data, (uint256));
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        override
        noDelegateCall
        returns (
            int56 tickCumulativeInside,
            uint160 secondsPerLiquidityInsideX128,
            uint32 secondsInside
        )
    {
        checkTicks(tickLower, tickUpper);

        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            Tick.Info storage lower = ticks[tickLower];
            Tick.Info storage upper = ticks[tickUpper];
            bool initializedLower;
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            require(initializedLower);

            bool initializedUpper;
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            require(initializedUpper);
        }

        Slot0 memory _slot0 = slot0;

        if (_slot0.tick < tickLower) {
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    _slot0.tick,
                    _slot0.observationIndex,
                    liquidity,
                    _slot0.observationCardinality
                );
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 -
                    secondsPerLiquidityOutsideLowerX128 -
                    secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } else {
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    /// @inheritdoc IUniswapV3PoolDerivedState
    function observe(uint32[] calldata secondsAgos)
        external
        view
        override
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return
            observations.observe(
                _blockTimestamp(),
                secondsAgos,
                slot0.tick,
                slot0.observationIndex,
                liquidity,
                slot0.observationCardinality
            );
    }

    /// @inheritdoc IUniswapV3PoolActions
    function increaseObservationCardinalityNext(uint16 observationCardinalityNext)
        external
        override
        lock
        noDelegateCall
    {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext; // for the event
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext);
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        if (observationCardinalityNextOld != observationCardinalityNextNew)
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev not locked because it initializes unlocked
    // 传入pool的初始价格的平方根来初始化pool
    function initialize(uint160 sqrtPriceX96) external override {
        // 初始价格
        require(slot0.sqrtPriceX96 == 0, 'AI');

        // sqrtPriceX96对应的tick index
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        // 初始化本pool的slot0
        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext,
            feeProtocol: 0,
            unlocked: true
        });

        emit Initialize(sqrtPriceX96, tick);
    }

    struct ModifyPositionParams {
        // the address that owns the position
        // 拥有该position的owner地址
        address owner;
        // the lower and upper tick of the position
        // 该position的价格下限tick index
        int24 tickLower;
        // 该position的价格上限tick index
        int24 tickUpper;
        // any change in liquidity
        // 流动性变化量（有符号整数，正负代表增添或移除流动性）
        int128 liquidityDelta;
    }

    /// @dev Effect some changes to a position
    /// @param params the position details and the change to the position's liquidity to effect
    /// @return position a storage pointer referencing the position with the given owner and tick range
    /// @return amount0 the amount of token0 owed to the pool, negative if the pool should pay the recipient
    /// @return amount1 the amount of token1 owed to the pool, negative if the pool should pay the recipient
    // 修改position
    // 参数为：ModifyPositionParams结构体
    function _modifyPosition(ModifyPositionParams memory params)
        private
        noDelegateCall
        returns (
            // 一个a storage pointer，指向
            Position.Info storage position,
            // 需要转移到pool的token0数量，如果是从pool中转出，那么该值为负
            int256 amount0,
            // 需要转移到pool的token1数量，如果是从pool中转出，那么该值为负
            int256 amount1
        )
    {
        // 检查提供流动性上下价格tick index的有效性
        checkTicks(params.tickLower, params.tickUpper);
        // 缓存该pool的slot到内存（一些pool的状态信息），这么操作是为了节约gas
        Slot0 memory _slot0 = slot0; // SLOAD for gas optimization

        // 更新position
        position = _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            _slot0.tick
        );

        if (params.liquidityDelta != 0) {
            // 如果本次流动性该变量不为0，即增添或移除流动性
            // 然后根据当前价格和价格区间的关系分三种情况
            if (_slot0.tick < params.tickLower) {
                // case 1: 价格区间在当前价格的右侧，只需要单边添加token0（贯穿整个区间）
                // 注：下面都是pure级别的数学计算
                // current tick is below the passed range; liquidity can only become in range by crossing from left to
                // right, when we'll need _more_ token0 (it's becoming more valuable) so user must provide it
                amount0 = SqrtPriceMath.getAmount0Delta(
                    // 将区间下限tick index换算成价格的平方根
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    // 将区间上限tick index换算成价格的平方根
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    // 流动性该变量
                    params.liquidityDelta
                );
            } else if (_slot0.tick < params.tickUpper) {
                // case 2: 价格区间包含了当前价格
                // current tick is inside the passed range
                // 缓存当前区间有效流动性（uint128）（节省gas）
                uint128 liquidityBefore = liquidity; // SLOAD for gas optimization

                // write an oracle entry
                // 写入oracle entry
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    _slot0.observationIndex,
                    _blockTimestamp(),
                    _slot0.tick,
                    liquidityBefore,
                    _slot0.observationCardinality,
                    _slot0.observationCardinalityNext
                );

                // 计算出当前价格到价格区间上限的range中，改变流动性params.liquidityDelta
                // 需要的token0数量（pure级别的计算）
                amount0 = SqrtPriceMath.getAmount0Delta(
                    _slot0.sqrtPriceX96,
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
                // 计算出当前价格到价格区间下限的range中，改变流动性params.liquidityDelta
                // 需要的token1数量（pure级别的计算）
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    _slot0.sqrtPriceX96,
                    params.liquidityDelta
                );

                // 更新当前区间的有效流动性（uint128+int128，有溢出检查）
                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                // case 3: 价格区间在当前价格的左侧，只需要单边添加token1（贯穿整个区间）
                // 注：下面都是pure级别的数学计算 (同case 1)
                // current tick is above the passed range; liquidity can only become in range by crossing from right to
                // left, when we'll need _more_ token1 (it's becoming more valuable) so user must provide it
                amount1 = SqrtPriceMath.getAmount1Delta(
                    // 将区间下限tick index换算成价格的平方根
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    // 将区间上限tick index换算成价格的平方根
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    // 流动性该变量
                    params.liquidityDelta
                );
            }
        }
    }

    /// @dev Gets and updates a position with the given liquidity delta
    /// @param owner the owner of the position
    /// @param tickLower the lower tick of the position's tick range
    /// @param tickUpper the upper tick of the position's tick range
    /// @param tick the current tick, passed to avoid sloads
    // 根据流动性该变量来更新position
    function _updatePosition(
        // position的owner地址
        address owner,
        // position的价格下限tick index
        int24 tickLower,
        // position的价格上限tick index
        int24 tickUpper,
        // 流动性该变量
        int128 liquidityDelta,
        // 当前价格对应的tick index
        int24 tick
    ) private returns (Position.Info storage position) {
        // 获取owner的position，返回一个Position.Info storage（引用）。
        // 如果之前没有position，此处相当于返回了一个指向零值的Position.Info storage引用
        // container: mapping(bytes32 => Position.Info)
        // key: keccak256(abi.encodePacked(owner, tickLower, tickUpper))
        position = positions.get(owner, tickLower, tickUpper);

        // 手续费计算相关的cache，为了节约gas（忽略）
        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128; // SLOAD for gas optimization
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128; // SLOAD for gas optimization

        // if we need to update the ticks, do it
        // 根据传入的参数修改原position对应的lower/upper tick中的数据
        // 增加流动性和移出流动性均可
        bool flippedLower;  // 表示lower tick的引用状态是否发生改变
        bool flippedUpper;  // 表示upper tick的引用状态是否发生改变
        // 注：引用状态的改变具体变现为：
        // 被引用 -> 未被引用 或 未被引用 -> 被引用，
        // 后续需要根据这个变量的值来更新 tick 位图
        if (liquidityDelta != 0) {
            // 如果流动性该变量不为0
            // 获取当前时间戳
            uint32 time = _blockTimestamp();
            // oracle observations相关操作（忽略）
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) =
                observations.observeSingle(
                    time,
                    0,
                    slot0.tick,
                    slot0.observationIndex,
                    liquidity,
                    slot0.observationCardinality
                );

            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,
                maxLiquidityPerTick
            );
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,
                maxLiquidityPerTick
            );

            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        // 更新position
        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // clear any tick data that is no longer needed
        if (liquidityDelta < 0) {
            if (flippedLower) {
                ticks.clear(tickLower);
            }
            if (flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    function mint(
        // 流动性所有者地址
        address recipient,
        // 添加流动性的价格区间的下限的tick index（以token0计价）。前端需要通过用户输入的价格下限算出
        int24 tickLower,
        // 添加流动性的价格区间的上限的tick index（以token0计价）。前端需要通过用户输入的价格上限算出
        int24 tickUpper,
        // 注入的流动性数量
        uint128 amount,
        // pool回调NonfungiblePositionManager.uniswapV3MintCallback()的参数
        bytes calldata data
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        // 要求注入流动性>0
        require(amount > 0);
        // v3 pool中添加流动性的核心函数
        (, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                // 构建参数ModifyPositionParams结构体，并传入_modifyPosition()
                ModifyPositionParams({
                    owner: recipient,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    // 注：流动性变化量由uint128转int128，如果发生溢出会revert
                    liquidityDelta: int256(amount).toInt128()
                })
            );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        // 转移token0之前pool的token0余额
        uint256 balance0Before;
        // 转移token1之前pool的token0余额
        uint256 balance1Before;
        // 获取回调前pool名下的token0余额
        if (amount0 > 0) balance0Before = balance0();
        // 获取回调前pool名下的token1余额
        if (amount1 > 0) balance1Before = balance1();
        // 执行回调——即NonfungiblePositionManager.uniswapV3MintCallback()
        // 注：回调中会进行token0或token1的转移
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        // 如果需要注入的token0数量amount0>0，则检验回调后pool的token0增量需要 >= amount0。否则revert
        if (amount0 > 0) require(balance0Before.add(amount0) <= balance0(), 'M0');
        // 如果需要注入的token1数量amount1>0，则检验回调后pool的token1增量需要 >= amount1。否则revert
        if (amount1 > 0) require(balance1Before.add(amount1) <= balance1(), 'M1');

        // 抛出event
        emit Mint(msg.sender, recipient, tickLower, tickUpper, amount, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock returns (uint128 amount0, uint128 amount1) {
        // we don't need to checkTicks here, because invalid positions will never have non-zero tokensOwed{0,1}
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        if (amount0 > 0) {
            position.tokensOwed0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            position.tokensOwed1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    /// @inheritdoc IUniswapV3PoolActions
    /// @dev noDelegateCall is applied indirectly via _modifyPosition
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
        // 返回值为移除流动性会返给user的token0或token1的数量
    ) external override lock returns (uint256 amount0, uint256 amount1) {
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) =
            _modifyPosition(
                ModifyPositionParams({
                    owner: msg.sender,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    // 注：流动性变化量由uint128转int128，如果发生溢出会revert。
                    // 最后再取反
                    liquidityDelta: -int256(amount).toInt128()
                })
            );

        // 将负值转为正值
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            // 手续费相关（忽略）
            (position.tokensOwed0, position.tokensOwed1) = (
                position.tokensOwed0 + uint128(amount0),
                position.tokensOwed1 + uint128(amount1)
            );
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    struct SwapCache {
        // the protocol fee for the input token
        // 对于tokenIn的额外协议费率
        uint8 feeProtocol;
        // liquidity at the beginning of the swap
        // swap开始时候的流动性L
        uint128 liquidityStart;
        // the timestamp of the current block
        // 当前区块的时间戳
        uint32 blockTimestamp;
        // the current value of the tick accumulator, computed only if we cross an initialized tick
        // tick累加器，只有当价格穿越了initialized tick时才进行累加
        int56 tickCumulative;
        // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
        // 每个流动性累加器的当前秒值，只有当价格穿越了initialized tick时才进行计算
        uint160 secondsPerLiquidityCumulativeX128;
        // whether we've computed and cached the above two accumulators
        // 是否计算并缓存上述两个累加器
        bool computedLatestObservation;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        // 指定数量的tokenIn或tokenOut仍剩余未swap的数量
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        // 指定数量的tokenIn或tokenOut已swap掉的数量
        int256 amountCalculated;
        // current sqrt(price)
        // 当前价格的平方根
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        // 当前价格对应的tick index
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // the current liquidity in range
        // 当前流动性区间的流动性
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    /// @inheritdoc IUniswapV3PoolActions
    function swap(
        // 收到amountOut的地址
        address recipient,
        // true为用token0换token1，false为token1换token0
        bool zeroForOne,
        // 用于swap的token数量
        // 注：这里是int256，如果固定input数量就是正数，如果固定out数量就是负数
        int256 amountSpecified,
        // 价格变化的边界值
        // 如果用token0 -> token1，swap后的价格的平方根不能小于该值；
        // 如果用token1 -> token0, swap后的价格的平方根不能大于该值
        uint160 sqrtPriceLimitX96,
        // 传入回调函数的参数
        bytes calldata data
    ) external override noDelegateCall returns (int256 amount0, int256 amount1) {
        // swap token数量不能为0
        require(amountSpecified != 0, 'AS');

        // cache slot来节约gas
        Slot0 memory slot0Start = slot0;

        // 要求当前重入锁还没有上锁
        require(slot0Start.unlocked, 'LOK');
        // 如果是token0 -> token1:
        //      tick能表示的最小价格 < sqrtPriceLimitX96 < pool的当前价格
        // 如果是token1 -> token0:
        //      pool的当前价格 < sqrtPriceLimitX96 < tick能表示的最大价格
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO,
            'SPL'
        );

        // 当前重入锁上锁
        slot0.unlocked = false;

        // 缓存swap前的数据，目的是节省gas
        SwapCache memory cache =
            SwapCache({
                // swap开始时候的流动性L
                liquidityStart: liquidity,
                // 当前时间戳
                blockTimestamp: _blockTimestamp(),
                // 对于tokenIn的额外协议费率
                feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
                // 每个流动性累加器的当前秒值，只有当价格穿越了initialized tick时才进行计算
                secondsPerLiquidityCumulativeX128: 0,
                // tick累加器，只有当价格穿越了initialized tick时才进行累加
                tickCumulative: 0,
                // 是否计算并缓存上述两个累加器
                computedLatestObservation: false
            });

        // exactInput为本次swap是否为确定数量的tokenIn
        bool exactInput = amountSpecified > 0;

        // 用于存储swap过程中计算所需的中间变量。该结构体力的值在swap的步骤中可能会发生变化
        SwapState memory state =
            SwapState({
                // 指定数量的tokenIn或tokenOut仍剩余未swap的数量
                amountSpecifiedRemaining: amountSpecified,
                // 指定数量的tokenIn或tokenOut已swap掉的数量
                amountCalculated: 0,
                // 当前价格的平方根
                sqrtPriceX96: slot0Start.sqrtPriceX96,
                // 当前价格对应的tick index
                tick: slot0Start.tick,
                // 以下两个是手续费率相关（忽略）
                feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
                protocolFee: 0,
                // 当前流动性区间的流动性
                liquidity: cache.liquidityStart
            });

        // continue swapping as long as we haven't used the entire input/output and haven't reached the price limit
        // 只要仍存在未被swap掉的amountSpecifiedRemaining且当前价格没有到达sqrtPriceLimitX96，就会一直循环
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            // 每次进行while循环中使用到的临时变量
            StepComputations memory step;
            // 本次swap的起始价格
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            // 通过tick位图找到下一个可以选的swap价格
            // 这里可能是下一个流动性的边界，也可能还是在本流动性中
            // step.tickNext为：在目前的swap方向上，从当前tick开始出发，下一个可以进行swap的tick index
            // step.initialized：step.tickNext是否是initialized
            (step.tickNext, step.initialized) = tickBitmap.nextInitializedTickWithinOneWord(
                state.tick,
                tickSpacing,
                zeroForOne
            );

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            // 确保step.tickNext在有效的tick index区间内，即 TickMath.MIN_TICK <= step.tickNext <= TickMath.MAX_TICK
            // 这是因为tick位图并不知道这两个边界的存在
            if (step.tickNext < TickMath.MIN_TICK) {
                // 如果step.tickNext<tick最小值，那么step.tickNext为tick最小值
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                // 如果step.tickNext>tick最大值，那么step.tickNext为tick最大值
                step.tickNext = TickMath.MAX_TICK;
            }

            // get the price for the next tick
            // 计算step.tickNext对应的价格(平方根)
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            // 计算当价格(平方根)到达下一个可swap的价格(平方根)时，tokenIn是否全部swap掉了
            // 如果全swap掉了，则结束循环。但是，还需要重新计算出tokenIn全部swap时的价格(平方根)
            // 如果没有全swap掉，那么将继续进入下一次循环
            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            if (exactInput) {
                // 如果是指定tokenIn的数量：
                // 更新tokenIn的剩余数量，以及swap到的tokenOut数量
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                // 注意当指定tokenIn的数量进行swap时，这里的amountCalculated是负数
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                // 如果是指定tokenOut的数量：
                // 更新tokenOut的剩余数量，以及swap到的tokenIn数量
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            // if the protocol fee is on, calculate how much is owed, decrement feeAmount, and increment protocolFee
            // 手续费相关（忽略）
            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            // update global fee tracker
            if (state.liquidity > 0)
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);

            // shift tick if we reached the next price
            // 如果本次结束swap的价格与在目前的swap方向上下一个可以进行swap的tick index相等
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                // 如果step.initialized是initialized，那么就需要进行tick转换
                if (step.initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick
                    // oracle相关（忽略）
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    // liquidityNet为当tick移动到step.tickNext时，liquidity的增加(或减少)的量
                    // 注：如果是从左向右移动，liquidityNet为正值；如果是从右向左移动，liquidityNet为负值
                    int128 liquidityNet =
                        ticks.cross(
                            step.tickNext,
                            (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                            (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                            cache.secondsPerLiquidityCumulativeX128,
                            cache.tickCumulative,
                            cache.blockTimestamp
                        );
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    // 如果swap方向是用token0换token1，那么token0的价格是应该逐渐变小的，即价格从右向左移动
                    // 那此时的liquidityNet应该取反（因为上面得到的liquidityNet为负值）
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    // 更新流动性
                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // 如果本次结束swap的价格与在目前的swap方向上下一个可以进行swap的tick index不相等，表示tokenIn被全部swap掉
                // 计算当前价格（state.sqrtPriceX96）对应的 tick index
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // update tick and write an oracle entry if the tick change
        // 如果swap后的tick index不等于swap开始时的tick index，表示swap的过程中发生了tick index的变化
        if (state.tick != slot0Start.tick) {
            // 写oracle操作（忽略）
            (uint16 observationIndex, uint16 observationCardinality) =
                observations.write(
                    slot0Start.observationIndex,
                    cache.blockTimestamp,
                    slot0Start.tick,
                    cache.liquidityStart,
                    slot0Start.observationCardinality,
                    slot0Start.observationCardinalityNext
                );
            // 更新pool的slot0中的各状态变量
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) = (
                state.sqrtPriceX96,
                state.tick,
                observationIndex,
                observationCardinality
            );
        } else {
            // otherwise just update the price
            // 如果swap后的tick index等于swap开始时的tick index，表示没有发生pool没有发生tick index的变化
            // 只需要更新当前pool的价格即可
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        // 如果流动性发生变化，更新当前区间内的流动性
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        // update fee growth global and, if necessary, protocol fees
        // overflow is acceptable, protocol has to withdraw before it hits type(uint128).max fees
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        (amount0, amount1) = zeroForOne == exactInput
            ? (amountSpecified - state.amountSpecifiedRemaining, state.amountCalculated)
            : (state.amountCalculated, amountSpecified - state.amountSpecifiedRemaining);

        // do the transfers and collect payment
        // swap后的token的转移，从pool中将tokenOut转到recipient名下，并
        // 执行SwapRouter的回调函数将tokenIn转到pool中
        if (zeroForOne) {
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance0Before.add(uint256(amount0)) <= balance0(), 'IIA');
        } else {
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), 'IIA');
        }

        // 抛出事件
        emit Swap(msg.sender, recipient, amount0, amount1, state.sqrtPriceX96, state.liquidity, state.tick);
        // 防重入锁解锁
        slot0.unlocked = true;
    }

    /// @inheritdoc IUniswapV3PoolActions
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override lock noDelegateCall {
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, 'L');

        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        require(balance0Before.add(fee0) <= balance0After, 'F0');
        require(balance1Before.add(fee1) <= balance1After, 'F1');

        // sub is safe because we know balanceAfter is gt balanceBefore by at least fee
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;

        if (paid0 > 0) {
            uint8 feeProtocol0 = slot0.feeProtocol % 16;
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);
            feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity);
        }
        if (paid1 > 0) {
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);
            feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
        }

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    // factory的owner来修改protocol fee
    // 输入参数分别为新的protocol fee：分别针对token0和token1
    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external override lock onlyFactoryOwner {
        // 要求feeProtocol0和feeProtocol1要么为0（即不收protocolFee），要么必须介于[4,10]
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol0 <= 10)) &&
                (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );
        // 之前的feeProtocol
        uint8 feeProtocolOld = slot0.feeProtocol;
        // 拼接两种token的fee到uint8中——即slot0.feeProtocol中，高4位为feeProtocol1，低4位为feeProtocol0
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);
        // 抛出event，里面包含原来的两种protocolFee和新修改的protocolFee
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    /// @inheritdoc IUniswapV3PoolOwnerActions
    function collectProtocol(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override lock onlyFactoryOwner returns (uint128 amount0, uint128 amount1) {
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        if (amount0 > 0) {
            if (amount0 == protocolFees.token0) amount0--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            if (amount1 == protocolFees.token1) amount1--; // ensure that the slot is not cleared, for gas savings
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit CollectProtocol(msg.sender, recipient, amount0, amount1);
    }
}
