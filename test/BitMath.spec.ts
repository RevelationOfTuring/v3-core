import { expect } from './shared/expect'
import { BitMathTest } from '../typechain/BitMathTest'
import { ethers, waffle } from 'hardhat'
import snapshotGasCost from './shared/snapshotGasCost'

const { BigNumber } = ethers

describe('BitMath', () => {
  let bitMath: BitMathTest
  const fixture = async () => {
    const factory = await ethers.getContractFactory('BitMathTest')
    return (await factory.deploy()) as BitMathTest
  }
  beforeEach('deploy BitMathTest', async () => {
    bitMath = await waffle.loadFixture(fixture)
  })

  describe('#mostSignificantBit', () => {
    it('0', async () => {
      // 计算0的msb，revert
      await expect(bitMath.mostSignificantBit(0)).to.be.reverted
    })
    it('1', async () => {
      // 计算1的msb -> 0
      expect(await bitMath.mostSignificantBit(1)).to.eq(0)
    })
    it('2', async () => {
      // 计算2的msb -> 1
      expect(await bitMath.mostSignificantBit(2)).to.eq(1)
    })
    it('all powers of 2', async () => {
      // 计算2**n的msb，n为[0,255]
      const results = await Promise.all(
        [...Array(255)].map((_, i) => bitMath.mostSignificantBit(BigNumber.from(2).pow(i)))
      )
      // 要求 2**n的msb为n
      expect(results).to.deep.eq([...Array(255)].map((_, i) => i))
    })
    it('uint256(-1)', async () => {
      // type(uint256).max的msb为255
      expect(await bitMath.mostSignificantBit(BigNumber.from(2).pow(256).sub(1))).to.eq(255)
    })

    it('gas cost of smaller number', async () => {
      // 计算3568的msb的gas消耗（与snapshot比较:uniswap-v3/v3-core/test/__snapshots__/BitMath.spec.ts.snap）
      await snapshotGasCost(bitMath.getGasCostOfMostSignificantBit(BigNumber.from(3568)))
    })
    it('gas cost of max uint128', async () => {
      // 计算type(uint128).max的msb的gas消耗（与snapshot比较:uniswap-v3/v3-core/test/__snapshots__/BitMath.spec.ts.snap）
      await snapshotGasCost(bitMath.getGasCostOfMostSignificantBit(BigNumber.from(2).pow(128).sub(1)))
    })
    it('gas cost of max uint256', async () => {
      // 计算type(uint256).max的msb的gas消耗（与snapshot比较:uniswap-v3/v3-core/test/__snapshots__/BitMath.spec.ts.snap）
      await snapshotGasCost(bitMath.getGasCostOfMostSignificantBit(BigNumber.from(2).pow(256).sub(1)))
    })
  })

  describe('#leastSignificantBit', () => {
    it('0', async () => {
      // 计算0的lsb，revert
      await expect(bitMath.leastSignificantBit(0)).to.be.reverted
    })
    it('1', async () => {
      // 计算1的lsb -> 0
      expect(await bitMath.leastSignificantBit(1)).to.eq(0)
    })
    it('2', async () => {
      // 计算1的lsb -> 1
      expect(await bitMath.leastSignificantBit(2)).to.eq(1)
    })
    it('all powers of 2', async () => {
      // 计算2**n的lsb，n为[0,255]
      const results = await Promise.all(
        [...Array(255)].map((_, i) => bitMath.leastSignificantBit(BigNumber.from(2).pow(i)))
      )
      // 要求2**n的lsb为n
      expect(results).to.deep.eq([...Array(255)].map((_, i) => i))
    })
    it('uint256(-1)', async () => {
      // type(uint256).max的lsb为0
      expect(await bitMath.leastSignificantBit(BigNumber.from(2).pow(256).sub(1))).to.eq(0)
    })

    it('gas cost of smaller number', async () => {
      // 计算3568的lsb的gas消耗（与snapshot比较:uniswap-v3/v3-core/test/__snapshots__/BitMath.spec.ts.snap）
      await snapshotGasCost(bitMath.getGasCostOfLeastSignificantBit(BigNumber.from(3568)))
    })
    it('gas cost of max uint128', async () => {
      // 计算type(uint128).max的lsb的gas消耗（与snapshot比较:uniswap-v3/v3-core/test/__snapshots__/BitMath.spec.ts.snap）
      await snapshotGasCost(bitMath.getGasCostOfLeastSignificantBit(BigNumber.from(2).pow(128).sub(1)))
    })
    it('gas cost of max uint256', async () => {
      // 计算type(uint256).max的lsb的gas消耗（与snapshot比较:uniswap-v3/v3-core/test/__snapshots__/BitMath.spec.ts.snap）
      await snapshotGasCost(bitMath.getGasCostOfLeastSignificantBit(BigNumber.from(2).pow(256).sub(1)))
    })
  })
})
