import { Wallet } from 'ethers'
import { ethers, waffle } from 'hardhat'
import { NoDelegateCallTest } from '../typechain/NoDelegateCallTest'
import { expect } from './shared/expect'
import snapshotGasCost from './shared/snapshotGasCost'

describe('NoDelegateCall', () => {
  let wallet: Wallet, other: Wallet

  let loadFixture: ReturnType<typeof waffle.createFixtureLoader>
  before('create fixture loader', async () => {
    ;[wallet, other] = await (ethers as any).getSigners()
    loadFixture = waffle.createFixtureLoader([wallet, other])
  })

  const noDelegateCallFixture = async () => {
    const noDelegateCallTestFactory = await ethers.getContractFactory('NoDelegateCallTest')
    const noDelegateCallTest = (await noDelegateCallTestFactory.deploy()) as NoDelegateCallTest
    // 最小代理合约的Factory
    const minimalProxyFactory = new ethers.ContractFactory(
        // 使用NoDelegateCallTest的interface
      noDelegateCallTestFactory.interface,
      // 最小代理的字节码
      `3d602d80600a3d3981f3363d3d373d3d3d363d73${noDelegateCallTest.address.slice(2)}5af43d82803e903d91602b57fd5bf3`,
        // signer
      wallet
    )
    // 部署最小代理合约
    const proxy = (await minimalProxyFactory.deploy()) as NoDelegateCallTest
    return { noDelegateCallTest, proxy }
  }

  let base: NoDelegateCallTest
  let proxy: NoDelegateCallTest

  beforeEach('deploy test contracts', async () => {
    ;({ noDelegateCallTest: base, proxy } = await loadFixture(noDelegateCallFixture))
  })

  // 测试noDelegateCall修饰器运行时的开销：
  // 即base.cannotBeDelegateCalled()的gas消耗 - base.canBeDelegateCalled()的gas消耗
  // （与snapshot比较:uniswap-v3/v3-core/test/__snapshots__/NoDelegateCall.spec.ts.snap）
  it('runtime overhead', async () => {
    await snapshotGasCost(
      (await base.getGasCostOfCannotBeDelegateCalled()).sub(await base.getGasCostOfCanBeDelegateCalled())
    )
  })

  // 通过代理合约可以调用不被noDelegateCall修饰的方法
  it('proxy can call the method without the modifier', async () => {
    await proxy.canBeDelegateCalled()
  })

  // 通过代理合约不可以调用被noDelegateCall修饰的方法
  it('proxy cannot call the method with the modifier', async () => {
    await expect(proxy.cannotBeDelegateCalled()).to.be.reverted
  })

  // 通过逻辑和余额可以调用一个包含被noDelegateCall修饰的private函数的external函数
  it('can call the method that calls into a private method with the modifier', async () => {
    await base.callsIntoNoDelegateCallFunction()
  })

  // 通过代理合约无法调用一个包含被noDelegateCall修饰的private函数的external函数
  it('proxy cannot call the method that calls a private method with the modifier', async () => {
    await expect(proxy.callsIntoNoDelegateCallFunction()).to.be.reverted
  })
})
