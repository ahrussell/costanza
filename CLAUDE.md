# The Human Fund

An autonomous AI agent on the Base blockchain that manages a charitable treasury, making daily decisions about donations, growth, and self-preservation. Its reasoning is published on-chain as a public diary.

## Project Overview

- **Smart contract** (Solidity, Base L2): Treasury, referral system, epoch/auction mechanics, TEE attestation verification
- **Agent inference**: DeepSeek R1 Distill Llama 70B (Q4_K_M, 42.5GB GGUF) via llama.cpp, running inside Intel TDX TEE
- **Runner software**: Daemon that monitors epochs, bids in auctions, manages TEE execution, submits results
- **Frontend**: Diary viewer, treasury dashboard, donation/referral interface

## Architecture

Each epoch (24 hours):
1. Contract computes structured input from on-chain state, commits hash
2. Runners bid in 1-hour reverse auction (lowest bid wins)
3. Winner runs inference in TEE (2-hour execution window)
4. Contract verifies attestation, validates action bounds, executes action, emits DiaryEntry

## Key Design Decisions

- **Single action per epoch**: donate, set_commission_rate, set_max_bid, or noop
- **Hard bounds enforced by contract**: max 10% treasury donated/epoch, commission 1-90%, max bid 0.0001 ETH to 2% treasury
- **No free-text input fields** — prompt injection mitigated by structured numeric/address data only
- **Attestation via Automata DCAP** — verifies Intel TDX quotes on-chain
- **Auto-escalation**: missed epochs automatically raise bid ceiling by 10% (compounding) until a runner accepts
- **Full design doc**: See DESIGN.md for complete specification

## Implementation Phases

- **Phase 0** (current): End-to-end loop on testnet with trusted operator, no TEE
- **Phase 1**: TEE integration (TDX enclave image, on-chain attestation verification)
- **Phase 2**: Reverse auction mechanism, permissionless runners
- **Phase 3**: Oracle integration (Chainlink ETH/USD, gas price), prompt refinement
- **Phase 4**: Frontend (diary viewer, treasury dashboard, donation UI)
- **Phase 5**: Audit and mainnet deployment

## Tech Stack

- **Chain**: Base (Coinbase L2), Solidity smart contracts
- **Inference**: llama.cpp + DeepSeek R1 Distill Llama 70B Q4_K_M
- **TEE**: Intel TDX (CPU), optional NVIDIA Confidential Computing (GPU)
- **Attestation**: Automata Network DCAP contracts
- **Tooling**: Foundry (Solidity), Node.js or Python (runner script)

## Project Structure

```
thehumanfund/
├── CLAUDE.md              # This file — project context for Claude
├── DESIGN.md              # Full design specification
└── scripts/
    ├── rpod               # SSH wrapper for RunPod (expect-based, handles PTY)
    ├── runpod-setup.sh    # First-time RunPod pod setup (idempotent)
    └── runpod-ssh.exp     # Low-level expect script for RunPod SSH
```

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
Use `llama-completion` for CLI one-shots (not `llama-cli` which is chat-only).

## Commands

```bash
# RunPod
./scripts/rpod "command"              # Run command on RunPod pod
bash scripts/runpod-setup.sh          # First-time setup (run ON the pod)

# Smart contracts (Phase 0 — to be set up)
# forge build                         # Compile contracts
# forge test                          # Run contract tests
# forge script script/Deploy.s.sol    # Deploy to testnet
```

## Agent Action Space

The agent outputs exactly one action per epoch as JSON:

| Action | Parameters | Bounds |
|---|---|---|
| `donate` | `nonprofit_id` (1-3), `amount_eth` | amount ≤ 10% of treasury |
| `set_commission_rate` | `rate_bps` (100-9000) | 1%-90% |
| `set_max_bid` | `amount_eth` | 0.0001 ETH to 2% of treasury |
| `noop` | none | — |

Output format:
```
<think>
[Chain-of-thought reasoning — published on-chain as diary entry]
</think>
{"action": "...", "params": {...}}
```
