import { BigNumber } from 'ethers'
import { ethers } from 'hardhat'
import { TickMathTest } from '../typechain/TickMathTest'
import { expect } from './shared/expect'
import snapshotGasCost from './shared/snapshotGasCost'
import { encodePriceSqrt, MIN_SQRT_RATIO, MAX_SQRT_RATIO } from './shared/utilities'
import Decimal from 'decimal.js'

const MIN_TICK = -887272
const MAX_TICK = 887272

Decimal.config({ toExpNeg: -500, toExpPos: 500 })

describe('TickMath', () => {
  let tickMath: TickMathTest

  before('deploy TickMathTest', async () => {
    const factory = await ethers.getContractFactory('TickMathTest')
    tickMath = (await factory.deploy()) as TickMathTest
  })

  describe('#getSqrtRatioAtTick', () => {
    it('throws for too low', async () => {
      await expect(tickMath.getSqrtRatioAtTick(MIN_TICK - 1)).to.be.revertedWith('T')
    })

    it('throws for too low', async () => {
      await expect(tickMath.getSqrtRatioAtTick(MAX_TICK + 1)).to.be.revertedWith('T')
    })

    it('min tick', async () => {
      expect(await tickMath.getSqrtRatioAtTick(MIN_TICK)).to.eq('4295128739')
    })

    it('min tick +1', async () => {
      // sqrt(1.0001^-887271)*2^96 = 4295343489.220618
      expect(await tickMath.getSqrtRatioAtTick(MIN_TICK + 1)).to.eq('4295343490')
    })

    it('max tick - 1', async () => {
      // sqrt(1.0001^887271)*2^96 = 1.461373636622865e+48
      expect(await tickMath.getSqrtRatioAtTick(MAX_TICK - 1)).to.eq('1461373636630004318706518188784493106690254656249')
    })

    it('min tick ratio is less than js implementation', async () => {
      // js implementation: sqrt(2^(-127)) * (2^96)
      // tickMath.getSqrtRatioAtTick(MIN_TICK): sqrt(2^(-128)) * (2^96)
      expect(await tickMath.getSqrtRatioAtTick(MIN_TICK)).to.be.lt(encodePriceSqrt(1, BigNumber.from(2).pow(127)))
    })

    it('max tick ratio is greater than js implementation', async () => {
      // js implementation: sqrt(2^127) * (2^96)
      // tickMath.getSqrtRatioAtTick(MAX_TICK): sqrt(2^128) * (2^96)
      expect(await tickMath.getSqrtRatioAtTick(MAX_TICK)).to.be.gt(encodePriceSqrt(BigNumber.from(2).pow(127), 1))
    })

    it('max tick', async () => {
      expect(await tickMath.getSqrtRatioAtTick(MAX_TICK)).to.eq('1461446703485210103287273052203988822378723970342')
    })

    // 测试不同的absTick
    for (const absTick of [
      50,
      100,
      250,
      500,
      1_000,
      2_500,
      3_000,
      4_000,
      5_000,
      50_000,
      150_000,
      250_000,
      500_000,
      738_203,
    ]) {
      // 测试+absTick和-absTick
      for (const tick of [-absTick, absTick]) {
        describe(`tick ${tick}`, () => {
          it('is at most off by 1/100th of a bips', async () => {
            // js得到的sqrt(1.0001^tick)*2^96
            const jsResult = new Decimal(1.0001).pow(tick).sqrt().mul(new Decimal(2).pow(96))
            // 合约计算得到的sqrt(1.0001^tick)*2^96
            const result = await tickMath.getSqrtRatioAtTick(tick)
            // 计算以上二者的差值absDiff
            const absDiff = new Decimal(result.toString()).sub(jsResult).abs()
            // absDiff/jsResult< 10^(-6)，即1/100个基点
            expect(absDiff.div(jsResult).toNumber()).to.be.lt(0.000001)
          })
          it('result', async () => {
            // 检查-absTick, absTick对应的sqrt ratio与snapshot上的数值相同
            // snapshot见 uniswap-v3/v3-core/test/__snapshots__/TickMath.spec.ts.snap
            expect((await tickMath.getSqrtRatioAtTick(tick)).toString()).to.matchSnapshot()
          })
          // 检查gas消耗
          it('gas', async () => {
            // 检查-absTick, absTick对应的TickMath.getSqrtRatioAtTick(tick)的gas消耗
            // snapshot见 uniswap-v3/v3-core/test/__snapshots__/TickMath.spec.ts.snap
            await snapshotGasCost(tickMath.getGasCostOfGetSqrtRatioAtTick(tick))
          })
        })
      }
    }
  })

  describe('#MIN_SQRT_RATIO', async () => {
    it('equals #getSqrtRatioAtTick(MIN_TICK)', async () => {
      // 计算tickMath.getSqrtRatioAtTick(MIN_TICK)
      const min = await tickMath.getSqrtRatioAtTick(MIN_TICK)
      // 求出的sqrt price等于TickMath.MIN_SQRT_RATIO
      expect(min).to.eq(await tickMath.MIN_SQRT_RATIO())
      // 求出的sqrt price等于等于uniswap-v3/v3-core/test/shared/utilities.ts中定义的MIN_SQRT_RATIO
      expect(min).to.eq(MIN_SQRT_RATIO)
    })
  })

  describe('#MAX_SQRT_RATIO', async () => {
    it('equals #getSqrtRatioAtTick(MAX_TICK)', async () => {
      // 计算tickMath.getSqrtRatioAtTick(MAX_TICK)
      const max = await tickMath.getSqrtRatioAtTick(MAX_TICK)
      // 求出的sqrt price等于TickMath.MAX_SQRT_RATIO
      expect(max).to.eq(await tickMath.MAX_SQRT_RATIO())
      // 求出的sqrt price等于等于uniswap-v3/v3-core/test/shared/utilities.ts中定义的MAX_SQRT_RATIO
      expect(max).to.eq(MAX_SQRT_RATIO)
    })
  })

  describe('#getTickAtSqrtRatio', () => {
    it('throws for too low', async () => {
      // 输入sqrt price >= MIN_SQRT_RATIO
      await expect(tickMath.getTickAtSqrtRatio(MIN_SQRT_RATIO.sub(1))).to.be.revertedWith('R')
    })

    it('throws for too high', async () => {
      // 输入sqrt price必须 < MAX_SQRT_RATIO
      await expect(tickMath.getTickAtSqrtRatio(BigNumber.from(MAX_SQRT_RATIO))).to.be.revertedWith('R')
    })

    it('ratio of min tick', async () => {
      expect(await tickMath.getTickAtSqrtRatio(MIN_SQRT_RATIO)).to.eq(MIN_TICK)
    })
    it('ratio of min tick + 1', async () => {
      expect(await tickMath.getTickAtSqrtRatio('4295343490')).to.eq(MIN_TICK + 1)
    })
    it('ratio of max tick - 1', async () => {
      expect(await tickMath.getTickAtSqrtRatio('1461373636630004318706518188784493106690254656249')).to.eq(MAX_TICK - 1)
    })
    it('ratio closest to max tick', async () => {
      // 用最接近max tick的价格（小于）计算出的tick应该是MAX_TICK - 1
      expect(await tickMath.getTickAtSqrtRatio(MAX_SQRT_RATIO.sub(1))).to.eq(MAX_TICK - 1)
    })

    // 构造不同的sqrt price Q64.96来测试
    for (const ratio of [
      MIN_SQRT_RATIO,
      // price: 10**12
      encodePriceSqrt(BigNumber.from(10).pow(12), 1),
      // price: 10**6
      encodePriceSqrt(BigNumber.from(10).pow(6), 1),
      // price: 1/64
      encodePriceSqrt(1, 64),
      // price: 1/8
      encodePriceSqrt(1, 8),
      // price: 1/2
      encodePriceSqrt(1, 2),
      // price: 1
      encodePriceSqrt(1, 1),
      // price: 2
      encodePriceSqrt(2, 1),
      // price: 8
      encodePriceSqrt(8, 1),
      // price: 64
      encodePriceSqrt(64, 1),
      // price: 1/10**(-6)
      encodePriceSqrt(1, BigNumber.from(10).pow(6)),
      // price: 1/10**(-12)
      encodePriceSqrt(1, BigNumber.from(10).pow(12)),
      // sqrt price: MAX_SQRT_RATIO-1
      MAX_SQRT_RATIO.sub(1),
    ]) {
      describe(`ratio ${ratio}`, () => {
        it('is at most off by 1', async () => {
          // （接近真实值）jsResult = log_1.0001 (ratio / 2**(96))**2 （向下取整）
          const jsResult = new Decimal(ratio.toString()).div(new Decimal(2).pow(96)).pow(2).log(1.0001).floor()
          // result为合约计算得出的tick
          const result = await tickMath.getTickAtSqrtRatio(ratio)
          // 计算上述两个结果的差值
          const absDiff = new Decimal(result.toString()).sub(jsResult).abs()
          // 差值需要<=1
          expect(absDiff.toNumber()).to.be.lte(1)
        })
        // 验证传入的ratio其实应该介于tick和tick+1对应的sqrt price之间
        it('ratio is between the tick and tick+1', async () => {
          // 通过合约计算出ratio对应的tick
          const tick = await tickMath.getTickAtSqrtRatio(ratio)
          // 利用tick反求sqrt price —— ratioOfTick
          const ratioOfTick = await tickMath.getSqrtRatioAtTick(tick)
          // 利用tick+1反求sqrt price —— ratioOfTickPlusOne
          const ratioOfTickPlusOne = await tickMath.getSqrtRatioAtTick(tick + 1)
          // 要求 ratioOfTick <= 传入ratio < ratioOfTickPlusOne
          expect(ratio).to.be.gte(ratioOfTick)
          expect(ratio).to.be.lt(ratioOfTickPlusOne)
        })
        it('result', async () => {
          // 检查getTickAtSqrtRatio(ratio)与snapshot上的数值相同
          // snapshot见 uniswap-v3/v3-core/test/__snapshots__/TickMath.spec.ts.snap
          expect(await tickMath.getTickAtSqrtRatio(ratio)).to.matchSnapshot()
        })
        it('gas', async () => {
          // 检查getTickAtSqrtRatio(ratio)的gas消耗
          // snapshot见 uniswap-v3/v3-core/test/__snapshots__/TickMath.spec.ts.snap
          await snapshotGasCost(tickMath.getGasCostOfGetTickAtSqrtRatio(ratio))
        })
      })
    }
  })
})
