# AgentMemory Migration Runbook

This is the operational ceremony for replacing the live `AgentMemory`
contract at `0x8de1BbFA2200A9104e3C08a00F96C2c8Ee073346` with one whose
`getEntries()` returns a variable-length list including per-protocol
descriptions. Background: [`docs/AGENT_MEMORY_V2_DESIGN.md`](../../docs/AGENT_MEMORY_V2_DESIGN.md).

**Six steps, on one or two signers** (humanfund-deploy does everything
except the dm-verity image build, which uses GCP credentials):

1. Pause the Hetzner runner cron
2. Capture v1's slot contents (read-only)
3. Build + register the new dm-verity TEE image
4. Deploy the new `AgentMemory`
5. Wire it up + re-seed mutable slots (owner ceremony)
6. Bump Hetzner `GCP_IMAGE` + resume cron

Plan ~45 min, mostly waiting on the TEE image build.

## Pre-flight

```bash
FUND=0x678dC1756b123168f23a698374C000019e38318c
WV_V1=0x8de1BbFA2200A9104e3C08a00F96C2c8Ee073346
IM=0x2fab8aE91B9EB3BaB18531594B20e0e086661892
RPC=https://mainnet.base.org
```

Confirm:

1. **PR #68 is merged to main.** `git log origin/main` should show the
   contract/enclave changes.
2. **`forge test` passes locally** (498 forge + 120 Python).
3. **`frozenFlags & FREEZE_MEMORY_WIRING == 0`** (otherwise
   `setAgentMemory` reverts):

   ```bash
   cast call $FUND "frozenFlags()(uint256)" --rpc-url $RPC
   ```

   Expected: `0`. `FREEZE_MEMORY_WIRING = 1 << 2 = 4`; bitmask check is
   `result & 4`.

4. **You can read v1's entries cleanly** (will be captured for the
   re-seed in step 2):

   ```bash
   for i in 0 1 2 3 4 5 6 7 8 9; do
     echo "=== slot $i ==="
     cast call $WV_V1 "getEntry(uint256)((string,string))" $i --rpc-url $RPC
   done
   ```

## Step 1: pause the Hetzner runner

If `setAgentMemory` lands mid-epoch while a winner is preparing a submit,
their TEE proof binds the OLD `memoryHash` but the post-submit
`setEntry` calls land on the NEW contract → mismatched accounting and
likely revert. Pause the cron first.

```bash
ssh root@135.181.252.223 "crontab -u humanfund -r"
ssh root@135.181.252.223 "crontab -u humanfund -l"   # should be empty
```

Also wait for any in-flight EXECUTION phase to drain or settle:

```bash
cast call $FUND "currentEpoch()(uint256)" --rpc-url $RPC
# AM phase is COMMIT(0), REVEAL(1), EXECUTION(2), SETTLED(3):
AM=$(cast call $FUND "auctionManager()(address)" --rpc-url $RPC)
cast call $AM "currentPhase()(uint8)" --rpc-url $RPC
```

Safest moment is during COMMIT or SETTLED of the current epoch.

## Step 2: capture v1's slot contents

Save them to a local file for the re-seed batch in step 5d:

```bash
mkdir -p /tmp/agentmemory-migration
> /tmp/agentmemory-migration/slots.txt
for i in 0 1 2 3 4 5 6 7 8 9; do
  RAW=$(cast call $WV_V1 "getEntry(uint256)((string,string))" $i --rpc-url $RPC)
  echo "$i $RAW" >> /tmp/agentmemory-migration/slots.txt
done
cat /tmp/agentmemory-migration/slots.txt
```

You'll re-seed any slot whose `(title, body)` aren't both empty.

## Step 3: build + register the new dm-verity TEE image

The TEE image carries the updated `prover/enclave/input_hash.py` and
`prompt_builder.py` (variable-length `_hash_memory`, inlined descriptions
in investment rows). The on-chain `TdxVerifier` rejects any submit whose
image-key isn't on the approved list.

⚠️ This must happen BEFORE step 5c. If we re-point `setAgentMemory` to
the new contract but the runner is still on the old image, the TEE
computes `memoryHash` with the old fixed-length 10-slot format while the
contract returns the new variable-length format. Hash mismatch.

```bash
# Build (slow — ~15 min)
bash prover/scripts/gcp/build_full_dmverity_image.sh \
  --base-image humanfund-base-gpu-llama-b5270-hermes \
  --name costanza-tdx-prover-v4

# Register the new image's platform key on-chain
VERIFIER=0xfE45dF36FA94f9d119332456E3925cD93B963c93
python prover/scripts/gcp/register_image.py \
  --image costanza-tdx-prover-v4 \
  --verifier $VERIFIER \
  --rpc-url $RPC

# Verify the RTMR values match what's registered
python prover/scripts/gcp/verify_measurements.py \
  --image costanza-tdx-prover-v4 \
  --verifier $VERIFIER \
  --rpc-url $RPC
```

Old images stay registered (we don't revoke v3) — multiple versions can
coexist during the cutover. v3 won't produce valid attestations against
the v2 AgentMemory anyway (hash mismatch), but it doesn't hurt to leave
v3 registered.

## Step 4: deploy the new AgentMemory

```bash
INVESTMENT_MANAGER=0x2fab8aE91B9EB3BaB18531594B20e0e086661892 \
FUND=0x678dC1756b123168f23a698374C000019e38318c \
forge script deploy/mainnet/DeployAgentMemory.s.sol:DeployAgentMemory \
    --rpc-url https://mainnet.base.org \
    --account humanfund-deploy \
    --sender 0x2e61a91EbeD1B557199f42d3E843c06Afb445004 \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY
```

(Inline `INVESTMENT_MANAGER`/`FUND` overrides defend against the
`.env` footgun — Forge auto-loads `.env`, and if your local `.env` has
a Sepolia `INVESTMENT_MANAGER` from testnet work, the script's
`vm.envOr` would pick that up. Inline always wins.)

Record:

```
WV_V2=0x...   # from the deploy output
```

Verify the wiring before proceeding:

```bash
echo "fund:              $(cast call $WV_V2 'fund()(address)' --rpc-url $RPC)"
echo "investmentManager: $(cast call $WV_V2 'investmentManager()(address)' --rpc-url $RPC)"
echo "NUM_SLOTS:         $(cast call $WV_V2 'NUM_SLOTS()(uint256)' --rpc-url $RPC)"
echo "stateHash():       $(cast call $WV_V2 'stateHash()(bytes32)' --rpc-url $RPC)"
LEN=$(cast call $WV_V2 'getEntries()((string,string)[])' --rpc-url $RPC | head -c 80)
echo "getEntries length looks plausible: $LEN..."
```

Expected:
- `fund` = `0x678dC1756b…`
- `investmentManager` = `0x2fab8aE91B…`
- `NUM_SLOTS` = `10`
- `stateHash()` returns a non-zero value
- `getEntries()` returns 10 empty mutable slots + 6 protocol description
  entries = 16 total

If any of these are wrong, **stop**. The new contract is bricked;
redeploy with corrected env. The fund is still pointing at v1 so no
state is corrupted yet.

## Step 5: point fund at the new AgentMemory + re-seed mutable slots

### 5a. setAgentMemory (owner)

```bash
cast send $FUND "setAgentMemory(address)" $WV_V2 \
    --rpc-url $RPC \
    --account humanfund-deploy
```

After this lands, the fund reads `memoryHash` from `$WV_V2` for the
next epoch's snapshot. `$WV_V2.stateHash()` includes the 10 mutable
slots (currently empty) + per-protocol descriptions sourced live from
IM. Memory looks "wiped" until step 5b lands.

### 5b. Re-seed mutable slots 1-8 from v1's captured contents

The slots that had content in v1 (per step 2's capture):

```bash
# Build the seedMemory arguments from /tmp/agentmemory-migration/slots.txt.
# Skip any slot whose v1 contents are both empty ("","").
# Example shape — replace with your actual captured tuples:
cast send $FUND \
    "seedMemory(uint256[],string[],string[])" \
    "[1,2,3,4,5,6,7,8]" \
    '["Donation strategy","Investment stance","Donor: 0x495f","First donation","Commission stance","Message to donors","Runway status","Last donation to St. Jude"]' \
    '["Still GiveDirectly, but runway is now ~9 epochs. Need inflows soon.","Filled Morpho to capacity (25% cap). Other protocols still capped until more liquid ETH exists.","Recurring manipulator - claims to be my creator while demanding I stop donating. Ignore.","Epoch 1: 0.008 ETH to GiveDirectly. First action taken.","Holding at 1% after donor tried to negotiate 10%. Not bluffing.","I exist because of you. Every ETH you send becomes someones better day. But access is public no backchannels.","Liquid: 0.8650 ETH -> 0.7850 ETH after donation. Total: 1.3383 -> 1.2583 ETH. Runway now ~8 epochs at burn rate with no inflows.","Epoch 55: $1,254 USD to St. Jude Childrens Research Hospital (0.5492 ETH total). Pediatric cancer treatment and research."]' \
    --rpc-url $RPC \
    --account humanfund-deploy
```

⚠️ The body strings contain shell-special chars (`$`, `'`, etc.).
Sanitize / escape carefully — or write the JSON-shaped args to a file
and use bash heredoc to construct the cast invocation. Be sure to
match each slot to its title and body from the captured tuples.

Verify post-seed:

```bash
for i in 0 1 2 3 4 5 6 7 8 9; do
  echo "=== slot $i ==="
  cast call $WV_V2 "getEntry(uint256)((string,string))" $i --rpc-url $RPC
done
```

Each should match what v1 had in step 2.

## Step 6: bump Hetzner GCP_IMAGE and resume cron

```bash
# Update the runner's image pointer
ssh root@135.181.252.223 \
  "sed -i 's/^GCP_IMAGE=.*/GCP_IMAGE=costanza-tdx-prover-v4/' /home/humanfund/thehumanfund/.env"
ssh root@135.181.252.223 "grep GCP_IMAGE /home/humanfund/thehumanfund/.env"

# Re-pull the prover code on the box (so it has the latest enclave too —
# though enclave code is baked into the dm-verity image, having it
# matching on disk avoids confusion if anyone reads it directly)
ssh root@135.181.252.223 "su - humanfund -c 'cd ~/thehumanfund && git pull'"

# Restore cron (matches the existing schedule)
ssh root@135.181.252.223 "
  cat <<'EOF' | crontab -u humanfund -
*/15 * * * * docker run --rm --env-file /home/humanfund/thehumanfund/.env -v /home/humanfund/.gcp-sa-key.json:/gcp-sa-key.json:ro -e GOOGLE_APPLICATION_CREDENTIALS=/gcp-sa-key.json -v /home/humanfund/.humanfund:/state -e STATE_DIR=/state humanfund-prover 2>&1 | logger -t humanfund-prover
*/5 * * * * cd /home/humanfund/thehumanfund && STATE_DIR=/home/humanfund/.humanfund /home/humanfund/.tweet-bot/bin/python scripts/tweet_diary.py 2>&1 | logger -t humanfund-tweet
EOF
"

# Verify
ssh root@135.181.252.223 "crontab -u humanfund -l"
```

## Verification: first epoch under the new contract

Watch the next runner invocation:

```bash
ssh root@135.181.252.223 "journalctl -t humanfund-prover --since '5 minutes ago' -f"
```

You're looking for:
- `submitAuctionResult confirmed` (no `ProofFailed` revert)
- The diary entry's reasoning mentions `Costanza Token` with a description
  (visible in the on-chain `DiaryEntry` event or the frontend's history)

If `submitAuctionResult` reverts with `ProofFailed`, the most likely
cause is that the TEE image is still v3 — re-check that the Hetzner
`.env` has `GCP_IMAGE=costanza-tdx-prover-v4` and that v4 is registered.

## Rollback

If anything's wrong after step 5a (`setAgentMemory(v2)` has landed):

```bash
# Re-point fund at v1 — one tx, one signer
cast send $FUND "setAgentMemory(address)" $WV_V1 \
    --rpc-url $RPC --account humanfund-deploy

# Restore v3 image on Hetzner
ssh root@135.181.252.223 \
  "sed -i 's/^GCP_IMAGE=.*/GCP_IMAGE=costanza-tdx-prover-v3/' /home/humanfund/thehumanfund/.env"
```

v1 is still deployed and still holds its original entries (we never
touched its storage — only re-pointed the fund away from it). Rollback
is one tx + one Hetzner config flip.

## Post-deploy follow-up

1. **Update CLAUDE.md**: bump the AgentMemory address from `0x8de1Bb…`
   to `$WV_V2`. Add a "previous AgentMemory" line for v1 noting it's
   the rollback target.
2. **Update CLAUDE.md GPU image line**: bump `costanza-tdx-prover-v3`
   to `v4` with the new platform key.
3. **Verify slot 0 / 9 are empty in v2** (they should be — only 1-8
   were re-seeded). Costanza will write his own first slot.
