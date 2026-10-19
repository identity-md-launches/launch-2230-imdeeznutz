// Fill these in once the launch has happened: the factory's launch record gives DeezLaunch, DeezToken,
// DeezRewards and DeezLiquidityLock; the requester's `launch` transaction gives the hook and pool id
// (DeezLaunch.hook() / DeezLaunch.poolId(), or the Launched event). Leave a field empty and the site shows
// "announced at launch" in its place. Never invent an address here.
window.DEEZ = {
  chainId: 1,
  token: "",          // DeezToken ($DEEZ) address, from the launch record
  launcher: "",       // DeezLaunch address, from the launch record
  hook: "",           // DeezHook address: DeezLaunch.hook() after the launch transaction
  rewards: "",        // DeezRewards address, from the launch record
  liquidityLock: "",  // DeezLiquidityLock address, from the launch record
  poolId: "",         // Uniswap v4 pool id (bytes32): DeezLaunch.poolId()
  imd: "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7",
  poolManager: "0x000000000004444c5dc75cB358380D2e3dE08A90", // Uniswap v4 PoolManager on Ethereum mainnet
  poolFee: 12500,     // 1.25% LP fee, as DeezLaunch.POOL_FEE
  tickSpacing: 60,    // DeezLaunch.TICK_SPACING
  deployTx: "",       // the factory's deployment transaction hash
  launchTx: "",       // the requester's DeezLaunch.launch transaction hash
  rpc: "https://ethereum-rpc.publicnode.com",
  links: {
    uniswap: "",      // e.g. https://app.uniswap.org/explore/pools/ethereum/<poolId>
    dexscreener: "",  // e.g. https://dexscreener.com/ethereum/<poolId>
    imd: "https://imd.fun",
    docs: "https://imd.fun/docs/",
    telegram: "https://imd.fun/telegram/",
  },
};
