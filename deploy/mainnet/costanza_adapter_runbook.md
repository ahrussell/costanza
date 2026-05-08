# CostanzaTokenAdapter — Mainnet Deployment Runbook

This is the operational ceremony for registering the `CostanzaTokenAdapter`
on top of the live Human Fund system on Base. Three transactions, on
three different signers, in any order. Plan for ~30 minutes start to
finish.

The adapter contract is reviewed in PR #46 and documented in
[`docs/COSTANZA_TOKEN_ADAPTER_DESIGN.md`](../../docs/COSTANZA_TOKEN_ADAPTER_DESIGN.md).
Adversarial-impact analysis is in
[`docs/COSTANZA_TOKEN_ADAPTER_ADVERSARIAL_REPORT.md`](../../docs/COSTANZA_TOKEN_ADAPTER_ADVERSARIAL_REPORT.md).

## Pre-flight

Before starting, confirm:

1. **PR #46 is merged** to `main`, and the local working tree is on the
   merged commit. The deploy script reads constants out of
   `src/adapters/CostanzaTokenAdapter.sol`; there's no fallback if a
   deploy is run on a stale branch.
2. **`forge test`** passes locally. 491 should pass; 28 skipped is the
   expected baseline (10 fork + 6 adversarial sim + 12 pre-existing).
3. **A fork dry-run** of `DeployCostanzaAdapter.s.sol` succeeds — see
   the **Fork rehearsal** section below. Don't go to mainnet without
   this.
4. **The current Doppler beneficiary EOA** is identified and reachable
   for signing. As of writing, this is the deployer wallet that
   originally collected fees from the $COSTANZA launch. The on-chain
   value isn't exposed via a public getter on the Doppler hook — find
   it by reading the most recent `BeneficiaryUpdated` event from
   `0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544`, or by asking the
   project lead.
5. **The IM admin key** (currently EOA `0x2e61a91…`, will eventually be
   Safe `0x6dF6f527…`) is reachable for signing.
6. **Base mainnet ETH for gas** on the deployer wallet. Estimated
   ~0.0001 ETH at typical Base gas prices for the contract deploys;
   the two follow-up calls are cheap.

## Signer matrix

| Step | Action | Signer | Why |
|---|---|---|---|
| 1 | Run `DeployCostanzaAdapter.s.sol` | Deployer EOA (any) | Just deploys three contracts |
| 2 | `im.addProtocol(...)` | IM admin (`0x2e61a91…` or Safe successor) | Only admin can register protocols |
| 3 | `feeDistributor.updateBeneficiary(poolId, adapter)` | Current Doppler beneficiary EOA | Doppler enforces caller-is-current-beneficiary |

Steps 2 and 3 are independent. Run order is flexible:
- (2) before (3): fees stay flowing to the old beneficiary until (3) lands.
- (3) before (2): fees pile up in the adapter contract; the first
  `pokeFees()` post-registration sweeps them.

Either way, no funds get lost.

## Fork rehearsal (do this first)

Run the full ceremony on a Base mainnet fork. This catches real
problems — wrong addresses, IM admin mismatch, pool key fields off,
etc. — at zero cost.

```bash
# Spin up a Base mainnet fork on anvil. Run this in a separate terminal:
anvil --fork-url https://mainnet.base.org --port 8545

# In your working terminal:
export RPC_URL=http://localhost:8545
export PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
# (anvil's well-known account 0; safe — it's a fork)

# Step 1: deploy
forge script deploy/mainnet/DeployCostanzaAdapter.s.sol:DeployCostanzaAdapter \
    --rpc-url $RPC_URL --broadcast

# Capture the deployed adapter address from the output. Then...

# Step 2: register (impersonating the IM admin)
ADAPTER=0x...  # from step 1 output
IM=0x2fab8aE91B9EB3BaB18531594B20e0e086661892
IM_ADMIN=0x2e61a91EbeD1B557199f42d3E843c06Afb445004

cast rpc anvil_impersonateAccount $IM_ADMIN --rpc-url $RPC_URL
cast send --unlocked --from $IM_ADMIN $IM \
    "addProtocol(address,string,string,uint8,uint16)" \
    $ADAPTER \
    "Costanza Token" \
    "Your own memecoin, \$COSTANZA. Speculative — buy/sell via deposit/withdraw; trading fees from other holders accrue to the fund and lower your per-token cost basis. The contract won't sell below cost basis, so a position can be locked during drawdowns. Lifetime cap: 5 ETH." \
    4 0 \
    --rpc-url $RPC_URL

# Step 3: beneficiary handover (impersonating current beneficiary)
DOPPLER=0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544
POOL_ID=0x1d7463c5ce91bdd756546180433b37665c11d33063a55280f8db068f9af2d8cc
BENEFICIARY=0x...  # known current beneficiary EOA — confirm before running

cast rpc anvil_impersonateAccount $BENEFICIARY --rpc-url $RPC_URL
cast send --unlocked --from $BENEFICIARY $DOPPLER \
    "updateBeneficiary(bytes32,address)" \
    $POOL_ID $ADAPTER \
    --rpc-url $RPC_URL

# Verify: a small deposit succeeds end-to-end
FUND=0x678dC1756b123168f23a698374C000019e38318c
cast rpc anvil_impersonateAccount $FUND --rpc-url $RPC_URL
cast send --unlocked --from $FUND --value 0.01ether $IM \
    "deposit(uint256,uint256)" 6 0.01ether \
    --rpc-url $RPC_URL

# And withdraw
cast call $IM "totalInvestedValue()(uint256)" --rpc-url $RPC_URL
# (record the value, confirm it's roughly 0.01 ether or the cost-basis floor)

cast send --unlocked --from $FUND $IM \
    "withdraw(uint256,uint256)" 6 1 \
    --rpc-url $RPC_URL
# (1 wei withdraw — just exercises the path; actual withdraw should be
#  done by the agent through the auction flow once everything's live)
```

If any of these steps revert, **do not proceed to mainnet**. Common failure
modes:
- **Pool not initialized at given PoolKey** → `POOL_FEE` or `POOL_TICK_SPACING`
  is wrong for the live pool. Re-check against the fork tests' constants.
- **`InvalidConfig`** during adapter deploy → `COSTANZA_TOKEN` or `WETH`
  doesn't match the PoolKey's currency0/currency1. Adapter constructor
  validates this; trust the revert.
- **`AdapterAlreadyExists`** during step 2 → IM has already been told
  about this address. Either the adapter was registered earlier, or the
  same deployer ran step 1 twice and is using a stale address.
- **`Unauthorized`** during step 3 → wrong signer for `updateBeneficiary`.
  Double-check the current beneficiary EOA.

## Mainnet ceremony

Once the fork rehearsal passes, the mainnet flow is the same calls
against `https://mainnet.base.org` with real signers.

### Step 1: deploy

```bash
# Use a hardware-wallet-backed keystore for the deployer. The deployer
# can be any EOA — the contracts have no privileged dependency on it
# beyond initial ownership.
forge script deploy/mainnet/DeployCostanzaAdapter.s.sol:DeployCostanzaAdapter \
    --rpc-url https://mainnet.base.org \
    --account <keystore-name> \
    --sender 0x<deployer-address> \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY

# Optionally set ADAPTER_OWNER to transfer ownership to the Safe at
# deploy time. The Safe must call acceptOwnership() afterwards
# (Ownable2Step is two-phase).
#   export ADAPTER_OWNER=0x6dF6f527E193fAf1334c26A6d811fAd62E79E5Db
```

Record the three addresses from the output:
- `V4PoolStateReader: 0x...`
- `V4SwapExecutor: 0x...`
- `CostanzaTokenAdapter: 0x...`

The script prints a `poolId` for the registered pool — confirm it matches
`0x1d7463c5ce91bdd756546180433b37665c11d33063a55280f8db068f9af2d8cc`.
If it doesn't, the PoolKey fields are wrong; halt and investigate.

Verify all three contracts are verified on BaseScan before proceeding.

### Step 2: IM admin registers the protocol

The IM admin (currently EOA `0x2e61a91EbeD1B557199f42d3E843c06Afb445004`,
will eventually be Safe `0x6dF6f527E193fAf1334c26A6d811fAd62E79E5Db`) must
call `addProtocol`. Pseudocode:

```
investmentManager.addProtocol(
    adapter        = 0x<from step 1>,
    name           = "Costanza Token",
    description    = "Your own memecoin, $COSTANZA. Speculative — buy/sell via deposit/withdraw; trading fees from other holders accrue to the fund and lower your per-token cost basis. The contract won't sell below cost basis, so a position can be locked during drawdowns. Lifetime cap: 5 ETH.",
    riskTier       = 4,
    expectedApyBps = 0
)
```

For the EOA-admin path:

```bash
cast send 0x2fab8aE91B9EB3BaB18531594B20e0e086661892 \
    "addProtocol(address,string,string,uint8,uint16)" \
    $ADAPTER \
    "Costanza Token" \
    "Your own memecoin, \$COSTANZA. Speculative — buy/sell via deposit/withdraw; trading fees from other holders accrue to the fund and lower your per-token cost basis. The contract won't sell below cost basis, so a position can be locked during drawdowns. Lifetime cap: 5 ETH." \
    4 0 \
    --rpc-url https://mainnet.base.org \
    --account <admin-keystore> \
    --sender 0x2e61a91EbeD1B557199f42d3E843c06Afb445004
```

For the Safe path: queue the same call as a Safe transaction; signers
approve and execute via the Safe UI.

After the call lands:
- The new protocol ID will be `6` (one past the existing five).
- `im.protocolCount()` reads `6`.
- `im.getProtocol(6)` returns the adapter.
- The agent's next epoch prompt will show "Costanza Token" in its
  investment portfolio listing.

### Step 3: Doppler beneficiary handover

The current Doppler beneficiary (the EOA that owns the post-launch
fee stream) calls:

```bash
cast send 0xBDF938149ac6a781F94FAa0ed45E6A0e984c6544 \
    "updateBeneficiary(bytes32,address)" \
    0x1d7463c5ce91bdd756546180433b37665c11d33063a55280f8db068f9af2d8cc \
    $ADAPTER \
    --rpc-url https://mainnet.base.org \
    --account <beneficiary-keystore> \
    --sender 0x<current-beneficiary-eoa>
```

After this call lands, all subsequent fee accruals release to the
adapter when claimed.

### Step 4: smoke test

A small deposit-and-back exercise to confirm the wiring:

```bash
# Read current state
cast call 0x2fab8aE91B9EB3BaB18531594B20e0e086661892 "totalInvestedValue()(uint256)" --rpc-url https://mainnet.base.org
cast call $ADAPTER "balance()(uint256)" --rpc-url https://mainnet.base.org

# Pre-claim any pending fees (permissionless)
cast send $ADAPTER "pokeFees()" \
    --rpc-url https://mainnet.base.org \
    --account <any-keystore>
# Confirm the FeesClaimed event in the receipt — token amounts >0
# means fees were already accruing, ETH amount is 98% of the total
# (2% goes to the caller's tip).
```

The agent should pick the new protocol up automatically on its next
epoch — no further action needed.

## Rollback considerations

The adapter is an additive deployment. If something is wrong post-deploy,
recovery options are:

| Issue | Recovery |
|---|---|
| Wrong PoolKey but adapter already deployed | Adapter is bricked but harmless. Deploy a fresh one with corrected PoolKey, register it as protocol #7, deactivate #6 via `setProtocolActive(6, false)`. |
| Wrong description / risk tier registered | Cannot fix in place — `name`/`description`/`riskTier` are immutable post-`addProtocol`. Same recovery as above: deploy a fresh adapter, register as #7, deactivate #6. |
| Beneficiary handover went to the wrong address | Whoever is listed as beneficiary calls `updateBeneficiary` again to point at the right adapter. Adapter owner can also call `transferFeeClaim(newAddress)` to drive the same call from this side. |
| Adapter has a bug we want to replace | `migrate(newAdapter)` atomically moves the position + fee stream to a successor adapter, then deactivate the old protocol. See `docs/COSTANZA_TOKEN_ADAPTER_DESIGN.md` §5. |

Note that `setProtocolActive(id, false)` only blocks new deposits — the
agent can still withdraw from a deactivated protocol, so existing
positions are never stranded.

## Post-deploy follow-up

1. **Update `CLAUDE.md`** — bump "5 DeFi adapters registered" to 6, or
   call out Costanza as a separate "speculative position" line so the
   model doesn't lump it with yield.
2. **Watch the first agent epoch** that has visibility into the new
   protocol. The system prompt's `risk_labels` dict maps tier 4 to
   `HIGH`. The agent should see something like:
   ```
   #6 Costanza Token [HIGH, ~0% APY]: 0 deposited -> $0 (~0 ETH)  |  room: ...
   ```
3. **Decide on adapter ownership transfer.** The deployer holds owner
   initially. Move to the Safe via `transferOwnership(safe)` followed
   by `acceptOwnership()` from the Safe. Defer `freeze()` until you've
   exercised `transferFeeClaim` and/or `migrate` enough times to be
   confident no operational lever is needed (per §5 of the design doc,
   freeze is permanent).
