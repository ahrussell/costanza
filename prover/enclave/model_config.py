#!/usr/bin/env python3
"""Model configuration — known model identities.

Model integrity is enforced at the block level by dm-verity on the /models
partition. The kernel verifies every block read against a Merkle tree whose
root hash is in the kernel command line (measured into RTMR[2]).

This file exists for reference and logging — it identifies which model is
being used. No application-level hash verification is needed.
"""

# DeepSeek R1 Distill Llama 70B Q4_K_M (42.5 GB) — production model
MODEL_SHA256_70B = "181a82a1d6d2fa24fe4db83a68eee030384986bdbdd4773ba76424e3a6eb9fd8"

# DeepSeek R1 Distill Qwen 14B Q4_K_M (8.99 GB) — development model
MODEL_SHA256_14B = "0b319bd0572f2730bfe11cc751defe82045fad5085b4e60591ac2cd2d9633181"

KNOWN_MODELS = {
    MODEL_SHA256_70B: "DeepSeek-R1-Distill-Llama-70B-Q4_K_M",
    MODEL_SHA256_14B: "DeepSeek-R1-Distill-Qwen-14B-Q4_K_M",
}
