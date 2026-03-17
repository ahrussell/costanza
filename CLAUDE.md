# The Human Fund

An autonomous AI agent on the Base blockchain that manages a charitable treasury, making daily decisions about donations, growth, and self-preservation. Its reasoning is published on-chain as a public diary.

## Project Overview

- **Smart contract** (Solidity, Base L2): Treasury, referral system, epoch actions, diary events
- **Agent inference**: DeepSeek R1 Distill Llama 70B (Q4_K_M, 42.5GB GGUF) via llama.cpp on RunPod (Phase 0); DeepSeek R1 Distill Qwen 14B in TDX TEE (Phase 1)
- **Runner software**: Python script that reads contract state, runs inference (direct or via TEE), parses output, submits on-chain
- **TEE enclave**: Docker image with llama.cpp + model + Flask API, runs in TDX Confidential VM on Phala Cloud
- **Frontend**: Diary viewer, treasury dashboard, donation/referral interface (Phase 4)

## Current Status

**Phase 0 is complete.** The end-to-end loop works on Base Sepolia testnet:
- Contract deployed at `0x2F213Ea0D3F6D8349e2162b37Cc8cE6605dc9420`
- First on-chain epoch executed successfully (agent chose `noop` — sensible with 0.0001 ETH treasury)
- Current epoch: 2
- Deployer address: `0xffea30B0DbDAd460B9b6293fb51a059129fCCdAf`

**DESIGN.md is a living document** — see it for the full specification and implementation checklist.

## Architecture

Each epoch (24 hours in production, manual in Phase 0):
1. Runner reads contract state (treasury, nonprofits, epoch history)
2. Runner constructs prompt from system prompt + epoch context + decision history
3. Runner calls llama.cpp server for inference (two-pass: reasoning then action)
4. Runner parses output, encodes action, submits to contract
5. Contract validates bounds, executes action, emits DiaryEntry event

## Key Design Decisions

- **Single action per epoch**: donate, set_commission_rate, set_max_bid, or noop
- **Hard bounds enforced by contract**: max 10% treasury donated/epoch, commission 1-90%, max bid 0.0001 ETH to 2% treasury
- **No free-text input fields** — prompt injection mitigated by structured numeric/address data only
- **Two-pass inference**: Pass 1 generates reasoning (stop at `</think>`), Pass 2 generates JSON action (lower temperature) — needed because DeepSeek R1 often hits EOS before producing structured output
- **Auto-escalation**: missed epochs automatically raise bid ceiling by 10% (compounding) until a runner accepts
- **Full design doc**: See DESIGN.md for complete specification

## Implementation Phases

- **Phase 0** (COMPLETE): End-to-end loop on testnet with trusted operator, no TEE
- **Phase 1**: TEE integration (TDX enclave image, on-chain attestation verification)
- **Phase 2**: Reverse auction mechanism, permissionless runners
- **Phase 3**: Oracle integration (Chainlink ETH/USD, gas price), prompt refinement
- **Phase 4**: Frontend (diary viewer, treasury dashboard, donation UI)
- **Phase 5**: Audit and mainnet deployment

## Tech Stack

- **Chain**: Base (Coinbase L2), Solidity ^0.8.20
- **Inference**: llama.cpp + DeepSeek R1 Distill Llama 70B Q4_K_M (RunPod, Phase 0); 14B Q4_K_M (TEE, Phase 1)
- **TEE**: Intel TDX via Phala Cloud / dstack
- **Attestation**: Automata Network DCAP contracts (Phase 1+)
- **Tooling**: Foundry (Solidity), Python 3.9+ with venv (runner + enclave)

## Python Environment

```bash
# Set up venv (first time)
python3 -m venv .venv
source .venv/bin/activate
pip install flask web3 requests

# Activate venv (each session)
source .venv/bin/activate
```

All Python commands (runner, enclave runner, etc.) should be run inside the venv.

## Project Structure

```
thehumanfund/
├── CLAUDE.md                    # This file — project context for Claude
├── DESIGN.md                    # Full design specification (living document)
├── foundry.toml                 # Foundry configuration
├── .venv/                       # Python virtual environment (gitignored)
├── src/
│   └── TheHumanFund.sol         # Main smart contract
├── test/
│   └── TheHumanFund.t.sol       # Contract tests (26 tests)
├── script/
│   └── Deploy.s.sol             # Foundry deployment script
├── agent/
│   ├── runner.py                # Runner: state → prompt → inference → submit (Phase 0 + 1)
│   ├── run_eval.py              # Prompt evaluation framework
│   ├── prompts/
│   │   └── system_v1.txt        # System prompt v1
│   └── scenarios/
│       └── scenarios.json       # 5 synthetic test scenarios
├── tee/                         # Phase 1: TEE enclave image
│   ├── Dockerfile               # Multi-stage: llama.cpp + model + enclave runner
│   ├── docker-compose.yaml      # Phala Cloud / dstack deployment config
│   ├── enclave_runner.py        # Flask API: /health, /run_epoch (inference + attestation)
│   ├── start.sh                 # Container entrypoint
│   └── system_prompt.txt        # Copy of agent/prompts/system_v1.txt
├── frontend/
│   └── index.html               # Internal dashboard (reads contract state)
├── models/                      # Local model files (gitignored)
├── scripts/
│   ├── rpod                     # SSH wrapper for RunPod
│   ├── runpod-setup.sh          # First-time RunPod pod setup
│   └── runpod-ssh.exp           # Low-level expect script for RunPod SSH
└── .env                         # Secrets (gitignored)
```

## Smart Contract

**`src/TheHumanFund.sol`** — Phase 0 contract (single authorized runner, no auction/TEE):
- Treasury management with 3 hardcoded nonprofits
- Referral system with mintable codes and 7-day commission escrow
- 4 agent actions with contract-enforced bounds
- Auto-escalation: `effectiveMaxBid` increases 10% per consecutive missed epoch
- `DiaryEntry` event emits reasoning + action on-chain
- Balance snapshots every 5 epochs

**Action encoding**: `uint8 action_type + ABI-encoded params`
- 0 = noop
- 1 = donate(nonprofit_id, amount)
- 2 = set_commission_rate(rate_bps)
- 3 = set_max_bid(amount)

## Runner Script

**`agent/runner.py`** — Reads contract state, builds prompt, runs inference, submits action.

Supports two modes:
- **Direct mode** (Phase 0): `python agent/runner.py` — calls llama-server directly
- **TEE mode** (Phase 1): `python agent/runner.py --tee-url http://host:8090` — sends epoch context to TEE enclave

Key implementation details:
- **Two-pass inference**: Pass 1 generates reasoning with `stop=["</think>"]`, Pass 2 generates JSON action with `temperature=0.3`
- **JSON parsing**: Custom `_extract_json_object()` with brace depth tracking (regex fails on nested JSON)
- **Gas limit**: 5,000,000 (reasoning calldata can be 3KB+, ~16 gas per non-zero byte)
- **Reasoning cap**: 8KB on-chain to stay within gas budget
- **Pre-submission bounds check**: Clamps donate to 9.9%, commission 100-9000 bps, max_bid to valid range
- **Retry logic**: Up to 3 attempts on parse failure
- **Custom User-Agent**: `TheHumanFund/1.0` to bypass Cloudflare blocking on RunPod proxy

## RunPod Development Environment

Model inference runs on RunPod (2x RTX A6000, 49GB VRAM each). The pod's network volume is mounted at `/workspace` and persists between sessions.

### Connecting to RunPod

SSH requires PTY allocation that RunPod's proxy demands. Use the `rpod` wrapper:

```bash
export RUNPOD_HOST="xabf55irwjp075-644112cf@ssh.runpod.io"
./scripts/rpod "your command here"
```

SSH keys are managed via 1Password SSH agent (configured in ~/.ssh/config).

### RunPod filesystem layout

```
/workspace/                  # Persistent network volume
├── llama.cpp/               # Built with CUDA support
│   └── build/bin/
│       ├── llama-cli        # CLI inference
│       └── llama-server     # HTTP server mode
└── models/
    └── DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf  # 42.5GB
```

### Running inference (server mode — preferred)

Start llama-server on the pod, then call it from your laptop via the RunPod proxy:

```bash
# Start server on pod (run once per session, model stays loaded)
./scripts/rpod "nohup /workspace/llama.cpp/build/bin/llama-server \
  -m /workspace/models/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf \
  -ngl 99 -ts 1,1 -c 4096 \
  --host 0.0.0.0 --port 8080 \
  > /workspace/server.log 2>&1 & echo STARTED"

# Wait ~90s for model to load, then call from laptop:
RUNPOD_BASE_URL=https://xabf55irwjp075-8080.proxy.runpod.net

curl -s $RUNPOD_BASE_URL/health
# {"status":"ok"}

curl -s $RUNPOD_BASE_URL/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Your prompt here", "max_tokens": 2048, "temperature": 0.6}'
```

Performance: ~14.9 tok/s generation, ~27ms/tok prompt processing.

**Important**: Always use `-ts 1,1` to split model across both A6000 GPUs.

## Commands

```bash
# Python environment (always activate first)
source .venv/bin/activate

# Smart contracts
forge build                                    # Compile contracts
forge test                                     # Run all tests (26 tests)
forge test -vvv                                # Verbose test output
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL --broadcast              # Deploy to testnet

# Runner (direct mode — Phase 0)
python agent/runner.py                         # Run one epoch (reads .env)
python agent/runner.py --epochs 5              # Run 5 epochs in sequence
python agent/runner.py --dry-run               # Inference only, no submission

# Runner (TEE mode — Phase 1)
python agent/runner.py --tee-url http://host:8090

# TEE enclave (local testing)
llama-server -m models/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf -c 4096 --port 8080 &
cd tee && python enclave_runner.py             # Starts on :8090

# RunPod
./scripts/rpod "command"                       # Run command on RunPod pod
bash scripts/runpod-setup.sh                   # First-time setup (run ON the pod)
```

## Environment Variables (.env)

```
PRIVATE_KEY=0x...              # Deployer/runner wallet private key
DEPLOYER_ADDRESS=0x...         # Wallet address
RPC_URL=https://sepolia.base.org
CONTRACT_ADDRESS=0x...         # Deployed contract address
LLAMA_SERVER_URL=https://...   # RunPod proxy URL for llama-server
```

## Agent Action Space

The agent outputs exactly one action per epoch as JSON:

| Action | Parameters | Bounds |
|---|---|---|
| `donate` | `nonprofit_id` (1-3), `amount_eth` | amount <= 10% of treasury |
| `set_commission_rate` | `rate_bps` (100-9000) | 1%-90% |
| `set_max_bid` | `amount_eth` | 0.0001 ETH to 2% of treasury |
| `noop` | none | -- |

Output format:
```
<think>
[Chain-of-thought reasoning -- published on-chain as diary entry]
</think>
{"action": "...", "params": {...}}
```
