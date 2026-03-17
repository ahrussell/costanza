# The Human Fund — TEE Inference Image (Phase 1)
#
# This image runs inside a TDX Confidential VM (via Phala Cloud / dstack).
# It contains llama.cpp, the model weights, the system prompt, and the
# enclave runner script that:
#   1. Receives epoch input (contract state) via HTTP
#   2. Constructs the prompt
#   3. Runs inference with llama.cpp
#   4. Returns the action + reasoning + TDX attestation quote
#
# The docker-compose hash is recorded in RTMR[3] by dstack, creating a
# verifiable chain: hardware → firmware → OS → this image → model weights.

FROM ubuntu:22.04 AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Build llama.cpp (CPU only — GPU TEE is a future upgrade)
WORKDIR /build
RUN git clone --depth 1 https://github.com/ggml-org/llama.cpp.git && \
    cd llama.cpp && \
    cmake -B build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build build --config Release -j$(nproc) --target llama-server

# --- Runtime stage ---
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install flask requests

# Copy llama.cpp server binary
COPY --from=builder /build/llama.cpp/build/bin/llama-server /usr/local/bin/llama-server

# Copy agent files
COPY enclave_runner.py /app/enclave_runner.py
COPY system_prompt.txt /app/system_prompt.txt
COPY start.sh /app/start.sh

# Model weights will be downloaded at build time or mounted
# For the 14B Q4_K_M model (~8.7 GB), we download during build
ARG MODEL_URL="https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"
ARG MODEL_FILE="DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"

RUN mkdir -p /models && \
    curl -L -o /models/${MODEL_FILE} ${MODEL_URL}

ENV MODEL_PATH=/models/${MODEL_FILE}
ENV LLAMA_SERVER_PORT=8080
ENV ENCLAVE_PORT=8090

WORKDIR /app

# Start both the llama server and the enclave runner
CMD ["/bin/bash", "/app/start.sh"]

EXPOSE 8090
