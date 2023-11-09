import { ethers } from 'hardhat'
import { FullMathTest } from '../typechain/FullMathTest'
import { expect } from './shared/expect'
import { Decimal } from 'decimal.js'

const {
  BigNumber,
  constants: { MaxUint256 },
} = ethers

// 2**128
const Q128 = BigNumber.from(2).pow(128)

Decimal.config({ toExpNeg: -500, toExpPos: 500 })

describe('FullMath', () => {
  let fullMath: FullMathTest
  before('deploy FullMathTest', async () => {
    const factory = await ethers.getContractFactory('FullMathTest')
    fullMath = (await factory.deploy()) as FullMathTest
  })

  describe('#mulDiv', () => {
    it('reverts if denominator is 0', async () => {
      // 分母为0，revert
      await expect(fullMath.mulDiv(Q128, 5, 0)).to.be.reverted
    })
    it('reverts if denominator is 0 and numerator overflows', async () => {
      // x*y/z：x*y发生溢出且z==0，revert
      await expect(fullMath.mulDiv(Q128, Q128, 0)).to.be.reverted
    })
    it('reverts if output overflows uint256', async () => {
      // x*y/z的结果溢出，revert
      await expect(fullMath.mulDiv(Q128, Q128, 1)).to.be.reverted
    })
    it('reverts if output overflows uint256', async () => {
      await expect(fullMath.mulDiv(Q128, Q128, 1)).to.be.reverted
    })
    it('reverts on overflow with all max inputs', async () => {
      // x*y/z的结果溢出，revert
      await expect(fullMath.mulDiv(MaxUint256, MaxUint256, MaxUint256.sub(1))).to.be.reverted
    })

    it('all max inputs', async () => {
      // MaxUint256*MaxUint256/MaxUint256=MaxUint256
      expect(await fullMath.mulDiv(MaxUint256, MaxUint256, MaxUint256)).to.eq(MaxUint256)
    })

    it('accurate without phantom overflow', async () => {
      // x*y/z在x*y不溢出的情况下的计算
      const result = Q128.div(3)
      // Q128* (Q128*0.5) / (Q128*1.5) = Q128/3
      expect(
        await fullMath.mulDiv(
          Q128,
          /*0.5=*/ BigNumber.from(50).mul(Q128).div(100),
          /*1.5=*/ BigNumber.from(150).mul(Q128).div(100)
        )
      ).to.eq(result)
    })

    it('accurate with phantom overflow', async () => {
      // x*y/z在x*y溢出的情况下的计算
      const result = BigNumber.from(4375).mul(Q128).div(1000)
      // Q128 * (35*Q128) / (8*Q128) = 4.375*Q128
      expect(await fullMath.mulDiv(Q128, BigNumber.from(35).mul(Q128), BigNumber.from(8).mul(Q128))).to.eq(result)
    })

    it('accurate with phantom overflow and repeating decimal', async () => {
      // x*y/z在x*y溢出的情况下的计算，且结果为无理数
      const result = BigNumber.from(1).mul(Q128).div(3)
      // Q128 * (1000*Q128) / (3000*Q128) = Q128 / 3
      expect(await fullMath.mulDiv(Q128, BigNumber.from(1000).mul(Q128), BigNumber.from(3000).mul(Q128))).to.eq(result)
    })
  })

  describe('#mulDivRoundingUp', () => {
    it('reverts if denominator is 0', async () => {
      // 分母为0，revert
      await expect(fullMath.mulDivRoundingUp(Q128, 5, 0)).to.be.reverted
    })
    it('reverts if denominator is 0 and numerator overflows', async () => {
      // x*y/z：x*y发生溢出且z==0，revert
      await expect(fullMath.mulDivRoundingUp(Q128, Q128, 0)).to.be.reverted
    })
    it('reverts if output overflows uint256', async () => {
      // 计算结果溢出，revert
      await expect(fullMath.mulDivRoundingUp(Q128, Q128, 1)).to.be.reverted
    })
    it('reverts on overflow with all max inputs', async () => {
      // 计算结果溢出，revert
      await expect(fullMath.mulDivRoundingUp(MaxUint256, MaxUint256, MaxUint256.sub(1))).to.be.reverted
    })

    it('reverts if mulDiv overflows 256 bits after rounding up', async () => {
      // 如果rounding up后，计算结果溢出，revert
      await expect(
        fullMath.mulDivRoundingUp(
          '535006138814359',
          '432862656469423142931042426214547535783388063929571229938474969',
          '2'
        )
      ).to.be.reverted
    })

    it('reverts if mulDiv overflows 256 bits after rounding up case 2', async () => {
      // 如果rounding up后，计算结果溢出，revert
      await expect(
        fullMath.mulDivRoundingUp(
          '115792089237316195423570985008687907853269984659341747863450311749907997002549',
          '115792089237316195423570985008687907853269984659341747863450311749907997002550',
          '115792089237316195423570985008687907853269984653042931687443039491902864365164'
        )
      ).to.be.reverted
    })

    it('all max inputs', async () => {
      // MaxUint256*MaxUint256/MaxUint256=MaxUint256
      expect(await fullMath.mulDivRoundingUp(MaxUint256, MaxUint256, MaxUint256)).to.eq(MaxUint256)
    })

    it('accurate without phantom overflow', async () => {
      const result = Q128.div(3).add(1)
        // Q128 * (0.5*Q128) / (1.5*Q128) = Q128 / 3 = Q128.div(3) + 1
        expect(
        await fullMath.mulDivRoundingUp(
          Q128,
          /*0.5=*/ BigNumber.from(50).mul(Q128).div(100),
          /*1.5=*/ BigNumber.from(150).mul(Q128).div(100)
        )
      ).to.eq(result)
    })

      // mulDivRoundingUp中：x*y/z中，x*y出现溢出
    it('accurate with phantom overflow', async () => {
      const result = BigNumber.from(4375).mul(Q128).div(1000)
      // Q128 * (35*Q128) / (8*Q128) == Q128 * 4.375
      expect(await fullMath.mulDivRoundingUp(Q128, BigNumber.from(35).mul(Q128), BigNumber.from(8).mul(Q128))).to.eq(
        result
      )
    })

      // mulDivRoundingUp中：x*y/z中，x*y出现溢出并且结果为无理数
    it('accurate with phantom overflow and repeating decimal', async () => {
        const result = BigNumber.from(1).mul(Q128).div(3).add(1)
      expect(
          // Q128 *(1000*Q128) / 3000*Q128 = Q128/3 + 1
        await fullMath.mulDivRoundingUp(Q128, BigNumber.from(1000).mul(Q128), BigNumber.from(3000).mul(Q128))
      ).to.eq(result)
    })
  })

    // 生成一个小于MaxUint256的随机整数
  function pseudoRandomBigNumber() {
    return BigNumber.from(new Decimal(MaxUint256.toString()).mul(Math.random().toString()).round().toString())
  }

  // tiny fuzzer. unskip to run
  // it('check a bunch of random inputs against JS implementation', async () => {
  it.skip('check a bunch of random inputs against JS implementation', async () => {
    // generates random inputs
    // 创建一个1000个元素的数组，每个元素为
    // {
    //   input: {
    //         x, // 随机整数
    //         y, // 随机整数
    //         d, // 随机整数
    //   },
    //   floored: fullMath.mulDiv(x, y, d),
    //   ceiled: fullMath.mulDivRoundingUp(x, y, d),
    // }
    const tests = Array(1_000)
      .fill(null)
      .map(() => {
        return {
          x: pseudoRandomBigNumber(),
          y: pseudoRandomBigNumber(),
          d: pseudoRandomBigNumber(),
        }
      })
      .map(({ x, y, d }) => {
        return {
          input: {
            x,
            y,
            d,
          },
          floored: fullMath.mulDiv(x, y, d),
          ceiled: fullMath.mulDivRoundingUp(x, y, d),
        }
      })

    // 对上述tests数组做测试
    await Promise.all(
      tests.map(async ({ input: { x, y, d }, floored, ceiled }) => {
        // 如果d为0，那么执行fullMath.mulDiv(x, y, d)和fullMath.mulDivRoundingUp(x, y, d)都要revert
        if (d.eq(0)) {
          await expect(floored).to.be.reverted
          await expect(ceiled).to.be.reverted
          return
        }

        if (x.eq(0) || y.eq(0)) {
          // 如果x或y==0，fullMath.mulDiv(x, y, d)和fullMath.mulDivRoundingUp(x, y, d)结果都是0
          await expect(floored).to.eq(0)
          await expect(ceiled).to.eq(0)
        } else if (x.mul(y).div(d).gt(MaxUint256)) {
          // 当x和y都不为0，且x*y/d结果产生溢出时，fullMath.mulDiv(x, y, d)和fullMath.mulDivRoundingUp(x, y, d)都要revert
          await expect(floored).to.be.reverted
          await expect(ceiled).to.be.reverted
        } else {
          // 当x和y都不为0，且x*y/d结果不产生溢出时，
          // fullMath.mulDiv(x, y, d) == (x.mul(y).div(d)
          // 和fullMath.mulDivRoundingUp(x, y, d) == x.mul(y).div(d).add(x.mul(y).mod(d).gt(0) ? 1 : 0
          expect(await floored).to.eq(x.mul(y).div(d))
          expect(await ceiled).to.eq(
            x
              .mul(y)
              .div(d)
              .add(x.mul(y).mod(d).gt(0) ? 1 : 0)
          )
        }
      })
    )
  })
})
