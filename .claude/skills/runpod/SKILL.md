---
name: runpod
description: >
  How to run commands, deploy code, and manage inference on the project's RunPod GPU pod.
  Use this skill whenever the task involves: running commands on RunPod, executing inference
  with DeepSeek/llama.cpp, uploading files to the pod, checking GPU status, managing model
  weights, or anything that needs to happen on the remote GPU server. Also trigger when the
  user mentions "the pod", "RunPod", "remote", "GPU", "inference", or "llama.cpp" in the
  context of running something.
---

# RunPod Remote Execution

This project uses a RunPod GPU pod for model inference (DeepSeek R1 70B via llama.cpp).
RunPod's SSH gateway requires a real PTY, which Claude Code's terminal doesn't provide.
We solve this with an `expect`-based wrapper script.

## Quick Reference

```bash
# Set the host (required before using rpod)
export RUNPOD_HOST="xabf55irwjp075-644112cf@ssh.runpod.io"

# Run a command
./scripts/rpod "nvidia-smi"

# Run inference
./scripts/rpod "cat /workspace/test_output.txt"
```

## How to Run Commands

Always use the `rpod` wrapper at `./scripts/rpod`. Never use `ssh` directly — it will
fail with "Your SSH client doesn't support PTY".

```bash
export RUNPOD_HOST="xabf55irwjp075-644112cf@ssh.runpod.io"
./scripts/rpod "your command here"
```

The wrapper uses `expect` to allocate a real PTY, send the command, capture output
between markers, strip ANSI codes, and return clean text. It has a 600-second timeout.

### Important Gotchas

1. **Quoting**: Complex commands with quotes, heredocs, or special characters can break
   the expect script's marker detection. For complex commands, use the base64 upload
   pattern (see below) to write a script file, then execute it.

2. **Long-running commands**: If a command takes more than ~5 minutes (model loading +
   inference, large downloads), the expect timeout will kill the connection — but the
   process may keep running on the pod. Use the background execution pattern instead.

3. **Spinner output**: llama.cpp's model loading spinner (`|-\|/-\|/...`) floods the
   expect buffer. Always redirect stderr when running llama.cpp, or run in background.

## Patterns

### Simple Command
```bash
export RUNPOD_HOST="xabf55irwjp075-644112cf@ssh.runpod.io"
./scripts/rpod "ls -la /workspace/models/"
```

### Upload a Script (base64 pattern)
SCP doesn't work with RunPod's SSH proxy. Instead, base64-encode the content:

```bash
SCRIPT_CONTENT=$(cat path/to/local/script.sh | base64)
export RUNPOD_HOST="xabf55irwjp075-644112cf@ssh.runpod.io"
./scripts/rpod "echo '$SCRIPT_CONTENT' | base64 -d > /workspace/script.sh && chmod +x /workspace/script.sh && echo 'uploaded'"
```

For inline script content:
```bash
B64=$(echo '#!/bin/bash
echo "hello from the pod"
nvidia-smi' | base64)
./scripts/rpod "echo '$B64' | base64 -d > /workspace/myscript.sh && chmod +x /workspace/myscript.sh"
```

### Background Execution (for long-running tasks)
For anything that might exceed the 600s expect timeout (model loading, downloads,
inference), launch in background on the pod and poll for completion:

```bash
# Step 1: Launch in background, write a sentinel file when done
./scripts/rpod "nohup bash -c '/workspace/run_something.sh; echo done > /workspace/task_done.txt' > /dev/null 2>&1 & echo LAUNCHED"

# Step 2: Poll for completion (wait, then check)
sleep 60
./scripts/rpod "if [ -f /workspace/task_done.txt ]; then echo DONE; cat /workspace/output.txt; else echo RUNNING; fi"
```

### Running Inference (Server Mode — Preferred)

The preferred workflow is to run `llama-server` on the pod and call it via HTTP from
the laptop. This avoids all the quoting/timeout issues with SSH-based inference.

```bash
# 1. Start server (once per session — model stays loaded in VRAM)
./scripts/rpod "nohup /workspace/llama.cpp/build/bin/llama-server \
  -m /workspace/models/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf \
  -ngl 99 -ts 1,1 -c 4096 \
  --host 0.0.0.0 --port 8080 \
  > /workspace/server.log 2>&1 & echo STARTED"

# 2. Wait ~90s for model to load, then test health:
curl -s https://xabf55irwjp075-8080.proxy.runpod.net/health
# {"status":"ok"}

# 3. Call the OpenAI-compatible completion API from your laptop:
curl -s https://xabf55irwjp075-8080.proxy.runpod.net/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"prompt": "Your prompt here", "max_tokens": 2048, "temperature": 0.6}'
```

The server exposes an OpenAI-compatible API. Performance: ~14.9 tok/s generation.
The base URL is: `https://xabf55irwjp075-8080.proxy.runpod.net`

### Running Inference (CLI — Fallback)
For one-off runs without the server, use `llama-completion` (not `llama-cli`).
Always use `-ts 1,1` to split across both GPUs. Run in background to avoid timeouts:

```bash
./scripts/rpod "echo 'Your prompt text here' > /workspace/prompt.txt"

./scripts/rpod "nohup bash -c '/workspace/llama.cpp/build/bin/llama-completion \
  -m /workspace/models/DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf \
  -ngl 99 -ts 1,1 -c 4096 -n 2048 \
  -f /workspace/prompt.txt \
  --no-display-prompt \
  > /workspace/output.txt 2>/workspace/stderr.txt; \
  echo done > /workspace/inference_done.txt' > /dev/null 2>&1 & echo LAUNCHED"

sleep 120
./scripts/rpod "if [ -f /workspace/inference_done.txt ]; then echo DONE; cat /workspace/output.txt; else echo RUNNING; fi"
```

### Checking GPU Status
```bash
./scripts/rpod "nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader"
```

### Killing Zombie Processes
Previous inference runs can leave zombie llama processes holding VRAM. Always check
and clean up before running new inference:

```bash
./scripts/rpod "nvidia-smi"  # Check if VRAM is in use
./scripts/rpod "killall llama-completion llama-cli 2>/dev/null; sleep 2; nvidia-smi --query-gpu=memory.free --format=csv,noheader"
```

## Pod Filesystem Layout

```
/workspace/                     # Persistent network volume (survives pod restarts)
├── llama.cpp/                  # Built with CUDA support
│   └── build/bin/
│       ├── llama-completion    # Text completion (use this one)
│       ├── llama-cli           # Chat mode only
│       └── llama-server        # HTTP API server
├── models/
│   └── DeepSeek-R1-Distill-Llama-70B-Q4_K_M.gguf  # 42.5GB
└── *.txt                       # Scratch files for prompts/outputs
```

## Pod Specs
- **GPU**: 2x NVIDIA RTX A6000 (49GB VRAM each, 98GB total)
- **Model split**: ~21GB per GPU with `-ts 1,1`
- **SSH auth**: 1Password SSH agent (key: "RunPods ED25519")
- **Network volume**: mounted at `/workspace`, persists between pod sessions

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| "PTY not supported" | Used `ssh` directly | Use `./scripts/rpod` instead |
| "spawn id not open" | Previous SSH connection was killed | Wait 2-3 seconds, retry |
| "Failed to load model" | VRAM occupied by zombie processes | Kill old llama processes first |
| Command output is empty/garbled | Complex quoting broke expect markers | Use base64 upload pattern |
| Timeout before inference finishes | Expect's 600s limit hit | Use background execution pattern |
| "allocating ... cudaMalloc failed" | Not splitting across GPUs | Add `-ts 1,1` to split across both A6000s |
