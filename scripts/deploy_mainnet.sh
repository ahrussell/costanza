#!/bin/bash
# ═══ The Human Fund — Mainnet Deployment Guide ═══
#
# This script documents the exact steps for deploying to Base mainnet.
# Run each section manually — DO NOT run this script end-to-end.
#
# Prerequisites:
#   - Owner key on a hardware wallet or secure machine (NOT the runner key)
#   - Foundry installed (forge, cast)
#   - .env with PRIVATE_KEY set to the OWNER key
#   - Base mainnet ETH for gas (~0.01 ETH)

set -euo pipefail

echo "═══ The Human Fund — Mainnet Deployment ═══"
echo ""
echo "This is a GUIDE, not an automated script."
echo "Run each section manually after reviewing."
echo ""

# ─── Step 1: Set environment variables ───────────────────────────────
cat << 'ENVVARS'

# Required for deployment (set these before proceeding):
export PRIVATE_KEY=0x...                    # OWNER key (hardware wallet recommended)
export RPC_URL=https://mainnet.base.org     # Base mainnet RPC
export ETHERSCAN_API_KEY=...                # For contract verification on BaseScan

# DeFi addresses (Base mainnet — from scripts/base_addresses.json):
export ENDAOMENT_FACTORY=0x10fD9348136dCea154F752fe0B6dB45Fc298A589
export WETH=0x4200000000000000000000000000000000000006
export USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export SWAP_ROUTER=0x2626664c2603336E57B271c5C0b26F421741e481
export ETH_USD_FEED=0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70
export SEED_AMOUNT=0.1ether

# DeFi protocol addresses (for adapter deployment):
export AAVE_V3_POOL=0xa238dd80c259a72e81d7e4664a9801593f98d1c5
export AAVE_WETH=0x4200000000000000000000000000000000000006
export AAVE_AWETH=0xd4a0e0b9149bcee3c920d2e00b5de09138fd8bb7
export AAVE_AUSDC=0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB
export WSTETH=0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452
export CBETH=0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22
export COMPOUND_COMET=0xb125E6687d4313864e53df431d5425969c15Eb2F
export MORPHO_GAUNTLET_WETH=0x6b13c060F13Af1fdB319F52315BbbF3fb1D88844

ENVVARS

# ─── Step 2: Deploy contracts ────────────────────────────────────────
cat << 'DEPLOY'

# Deploy all contracts (TheHumanFund + TdxVerifier + AuctionManager + InvestmentManager + WorldView + adapters):
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY

# Record the deployed addresses from the output:
#   TheHumanFund:      0x...
#   AuctionManager:    0x...
#   TdxVerifier:       0x...
#   InvestmentManager: 0x...
#   WorldView:         0x...

DEPLOY

# ─── Step 3: Configure auction timing ────────────────────────────────
cat << 'TIMING'

# Timing is set via setAuctionManager at deploy time (Deploy.s.sol).
# To change timing mid-life, use resetAuction(commitWindow, revealWindow, executionWindow):
# FUND=0x...  # TheHumanFund address from step 2
# cast send $FUND "resetAuction(uint256,uint256,uint256)" \
#   1200 1200 3000 \
#   --rpc-url $RPC_URL \
#   --private-key $PRIVATE_KEY

TIMING

# ─── Step 4: Build and register production image ─────────────────────
cat << 'IMAGE'

# Build the production dm-verity image:
bash scripts/build_full_dmverity_image.sh \
  --base-image humanfund-base-gpu-llama-b5270 \
  --name humanfund-dmverity-gpu-mainnet-v1

# Register image key on-chain:
VERIFIER=0x...  # TdxVerifier address from step 2

python scripts/register_image.py \
  --vm-name humanfund-e2e-measure \
  --verifier $VERIFIER \
  --rpc-url $RPC_URL

# Verify:
python scripts/verify_measurements.py \
  --vm-name humanfund-e2e-measure \
  --verifier $VERIFIER \
  --rpc-url $RPC_URL

IMAGE

# ─── Step 5: Configure runner on Hetzner ─────────────────────────────
cat << 'RUNNER'

# On your Hetzner machine, create /home/humanfund/.env:
PRIVATE_KEY=0x...                                    # RUNNER key (NOT the owner key)
RPC_URL=https://mainnet.base.org
CONTRACT_ADDRESS=0x...                               # TheHumanFund from step 2
GCP_PROJECT=the-human-fund
GCP_ZONE=us-central1-a
GCP_IMAGE=humanfund-dmverity-gpu-mainnet-v1
NTFY_CHANNEL=humanfund-runner

# Fund the runner wallet with ~0.05 ETH on Base for gas + bonds

# Test with dry run:
python -m runner.client --dry-run

# Set up cron:
# */5 * * * * cd /home/humanfund/thehumanfund && source .venv/bin/activate && python -m runner.client 2>&1 >> /home/humanfund/runner.log

RUNNER

# ─── Step 6: Start first auction ─────────────────────────────────────
cat << 'START'

# Auction is always available (no setAuctionEnabled needed).
# Direct submission is frozen at deploy time.
# Monitor first epoch closely!

START

# ─── Step 7: Progressive freeze (after 5+ successful epochs) ─────────
cat << 'FREEZE'

# Each freeze is IRREVERSIBLE. Do them gradually after confirming stability.

# 1. Disable owner direct submission (auctions only):
cast send $FUND "freeze(uint256)" 64 --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# 2. Lock nonprofit list:
cast send $FUND "freeze(uint256)" 1 --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# 3. Lock verifier registry:
cast send $FUND "freeze(uint256)" 16 --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# 4. Lock auction config:
cast send $FUND "freeze(uint256)" 8 --rpc-url $RPC_URL --private-key $PRIVATE_KEY

# DO NOT freeze investment wiring (2) or emergency withdrawal (128) initially.

FREEZE
