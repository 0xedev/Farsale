const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Presale Platform", function () {
  let owner, user1, user2, user3;
  let Token,
    WETH,
    USDC,
    MockUniswapV2Router,
    PresaleFactory,
    Presale,
    LiquidityLocker;
  let token, weth, usdc, router, factory, presaleETH, presaleStable;
  let accounts;

  const creationFee = ethers.parseEther("0.1");
  const presaleOptionsETH = {
    tokenDeposit: ethers.parseEther("1000"),
    hardCap: ethers.parseEther("10"),
    softCap: ethers.parseEther("2.5"),
    max: ethers.parseEther("2"),
    min: ethers.parseEther("0.1"),
    start: Math.floor(Date.now() / 1000) + 60, // Starts in 60 seconds
    end: Math.floor(Date.now() / 1000) + 3600, // Ends in 1 hour
    liquidityBps: 5100, // 51%
    slippageBps: 200, // 2%
    presaleRate: ethers.parseUnits("100", 0), // 100 tokens per ETH
    listingRate: ethers.parseUnits("50", 0), // 50 tokens per ETH
    lockupDuration: 30 * 24 * 60 * 60, // 30 days
    currency: ethers.ZeroAddress, // ETH
  };
  const presaleOptionsStable = { ...presaleOptionsETH, currency: null }; // Set later with USDC address

  before(async function () {
    accounts = await ethers.getSigners();
    [owner, user1, user2, user3] = accounts.slice(0, 4);

    // Deploy mock contracts
    Token = await ethers.getContractFactory("Token");
    token = await Token.deploy(ethers.parseEther("10000"), "TestToken", "TTK");
    await token.waitForDeployment();

    WETH = await ethers.getContractFactory("WETH");
    weth = await WETH.deploy();
    await weth.waitForDeployment();

    Token = await ethers.getContractFactory("Token"); // Reuse Token for USDC
    usdc = await Token.deploy(ethers.parseEther("10000"), "USD Coin", "USDC");
    await usdc.waitForDeployment();
    presaleOptionsStable.currency = usdc.target;

    MockUniswapV2Router = await ethers.getContractFactory(
      "MockUniswapV2Router"
    );
    router = await MockUniswapV2Router.deploy();
    await router.waitForDeployment();

    // Deploy PresaleFactory
    PresaleFactory = await ethers.getContractFactory("PresaleFactory");
    factory = await PresaleFactory.deploy(creationFee, ethers.ZeroAddress); // ETH fee
    await factory.waitForDeployment();

    locker = await ethers.getContractAt(
      "LiquidityLocker",
      await factory.liquidityLocker()
    );
  });

  describe("Presale Creation", function () {
    it("should deploy an ETH-based presale", async function () {
      const tx = await factory.createPresale(
        presaleOptionsETH,
        token.target,
        weth.target,
        router.target,
        { value: creationFee }
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log) => log.eventName === "PresaleCreated"
      );
      presaleETH = await ethers.getContractAt("Presale", event.args.presale);
      expect(await factory.getPresaleCount()).to.equal(1);
    });

    it("should deploy a stablecoin-based presale", async function () {
      const tx = await factory.createPresale(
        presaleOptionsStable,
        token.target,
        weth.target,
        router.target,
        { value: creationFee }
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find(
        (log) => log.eventName === "PresaleCreated"
      );
      presaleStable = await ethers.getContractAt("Presale", event.args.presale);
      expect(await factory.getPresaleCount()).to.equal(2);
    });
  });

  describe("ETH Presale Flow", function () {
    beforeEach(async function () {
      const tx = await factory.createPresale(
        presaleOptionsETH,
        token.target,
        weth.target,
        router.target,
        { value: creationFee }
      );
      const receipt = await tx.wait();
      presaleETH = await ethers.getContractAt(
        "Presale",
        receipt.logs.find((log) => log.eventName === "PresaleCreated").args
          .presale
      );
    });

    it("should deposit tokens and activate presale", async function () {
      await token.approve(presaleETH.target, presaleOptionsETH.tokenDeposit);
      await expect(presaleETH.deposit())
        .to.emit(presaleETH, "Deposit")
        .withArgs(owner.address, presaleOptionsETH.tokenDeposit, anyValue);
      expect(await presaleETH.pool().state).to.equal(2);
    });

    it("should accept ETH contributions", async function () {
      await token.approve(presaleETH.target, presaleOptionsETH.tokenDeposit);
      await presaleETH.deposit();
      await ethers.provider.send("evm_increaseTime", [60]);
      await ethers.provider.send("evm_mine");

      const contribution = ethers.parseEther("1");
      await expect(() =>
        presaleETH.connect(user1).contribute({ value: contribution })
      ).to.changeEtherBalances(
        [user1, presaleETH],
        [-contribution, contribution]
      );
      expect(await presaleETH.contributions(user1.address)).to.equal(
        contribution
      );
    });

    it("should enforce whitelist with many users", async function () {
      await token.approve(presaleETH.target, presaleOptionsETH.tokenDeposit);
      await presaleETH.deposit();
      await presaleETH.toggleWhitelist(true);

      const whitelistUsers = accounts.slice(0, 200).map((acc) => acc.address); // Use 200 accounts
      await presaleETH.updateWhitelist(whitelistUsers, true);

      await ethers.provider.send("evm_increaseTime", [60]);
      await ethers.provider.send("evm_mine");

      await expect(
        presaleETH
          .connect(user3)
          .contribute({ value: ethers.parseEther("0.1") })
      ).to.be.revertedWithCustomError(presaleETH, "NotWhitelisted");
      await expect(() =>
        presaleETH
          .connect(user1)
          .contribute({ value: ethers.parseEther("0.1") })
      ).to.changeEtherBalance(presaleETH, ethers.parseEther("0.1"));
    });

    it("should finalize and lock liquidity", async function () {
      await token.approve(presaleETH.target, presaleOptionsETH.tokenDeposit);
      await presaleETH.deposit();
      await ethers.provider.send("evm_increaseTime", [60]);
      await ethers.provider.send("evm_mine");

      await presaleETH
        .connect(user1)
        .contribute({ value: ethers.parseEther("3") });
      await expect(presaleETH.finalize())
        .to.emit(presaleETH, "Finalized")
        .withArgs(owner.address, ethers.parseEther("3"), anyValue);
      expect(await presaleETH.pool().state).to.equal(4);

      const lockCount = await locker.lockCount();
      expect(lockCount).to.be.gt(0);
      const [tokenAddr, amount] = await locker.getLock(lockCount - 1n);
      expect(amount).to.be.gt(0);
    });

    it("should allow claims", async function () {
      await token.approve(presaleETH.target, presaleOptionsETH.tokenDeposit);
      await presaleETH.deposit();
      await ethers.provider.send("evm_increaseTime", [60]);
      await ethers.provider.send("evm_mine");

      const contribution = ethers.parseEther("1");
      await presaleETH.connect(user1).contribute({ value: contribution });
      await presaleETH.finalize();

      const expectedTokens = contribution * presaleOptionsETH.presaleRate;
      await expect(presaleETH.connect(user1).claim())
        .to.emit(presaleETH, "TokenClaim")
        .withArgs(user1.address, expectedTokens, anyValue);
    });

    it("should allow refunds if soft cap not reached", async function () {
      await token.approve(presaleETH.target, presaleOptionsETH.tokenDeposit);
      await presaleETH.deposit();
      await ethers.provider.send("evm_increaseTime", [60]);
      await ethers.provider.send("evm_mine");

      const contribution = ethers.parseEther("1"); // Below soft cap
      await presaleETH.connect(user1).contribute({ value: contribution });
      await ethers.provider.send("evm_increaseTime", [3600]);
      await ethers.provider.send("evm_mine");

      await expect(() =>
        presaleETH.connect(user1).refund()
      ).to.changeEtherBalances(
        [user1, presaleETH],
        [contribution, -contribution]
      );
    });
  });

  describe("Stablecoin Presale Flow", function () {
    beforeEach(async function () {
      const tx = await factory.createPresale(
        presaleOptionsStable,
        token.target,
        weth.target,
        router.target,
        { value: creationFee }
      );
      const receipt = await tx.wait();
      presaleStable = await ethers.getContractAt(
        "Presale",
        receipt.logs.find((log) => log.eventName === "PresaleCreated").args
          .presale
      );
    });

    it("should accept stablecoin contributions", async function () {
      await token.approve(
        presaleStable.target,
        presaleOptionsStable.tokenDeposit
      );
      await presaleStable.deposit();
      await ethers.provider.send("evm_increaseTime", [60]);
      await ethers.provider.send("evm_mine");

      const contribution = ethers.parseEther("1");
      await usdc.transfer(user1.address, contribution);
      await usdc.connect(user1).approve(presaleStable.target, contribution);
      await presaleStable.connect(user1).contributeStablecoin(contribution);
      expect(await presaleStable.contributions(user1.address)).to.equal(
        contribution
      );
    });

    it("should finalize and lock liquidity with stablecoin", async function () {
      await token.approve(
        presaleStable.target,
        presaleOptionsStable.tokenDeposit
      );
      await presaleStable.deposit();
      await ethers.provider.send("evm_increaseTime", [60]);
      await ethers.provider.send("evm_mine");

      const contribution = ethers.parseEther("3");
      await usdc.transfer(user1.address, contribution);
      await usdc.connect(user1).approve(presaleStable.target, contribution);
      await presaleStable.connect(user1).contributeStablecoin(contribution);
      await presaleStable.finalize();

      const lockCount = await locker.lockCount();
      expect(lockCount).to.be.gt(0);
    });
  });

  const anyValue = () =>
    ethers.toBeHex(ethers.toBigInt(Math.floor(Date.now() / 1000)));
});
