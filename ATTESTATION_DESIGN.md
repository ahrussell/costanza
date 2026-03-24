# Attestation Design

How The Human Fund verifies that AI inference ran on trusted hardware with approved code.

## Overview

Each epoch, a runner wins an auction to execute AI inference. The contract needs to verify that the runner actually ran the approved code, with the approved model, on real Intel TDX hardware — not a modified version that produces self-serving outputs.

The verification chain:

```
Intel TDX CPU (unforgeable hardware)
  └─ generates TD Report with RTMR measurements + custom REPORTDATA
      └─ Quoting Enclave (Intel SGX) signs it into a DCAP quote
          └─ Automata DCAP contract verifies the signature on-chain
              └─ TdxVerifier checks RTMR[1..3] match + REPORTDATA binds input↔output
```

## How TDX Attestation Works

Intel TDX (Trust Domain Extensions) runs the VM in a hardware-isolated "trust domain." The CPU measures the VM's boot chain into a set of registers (MRTD + RTMR[0..3]) that software cannot forge. When we request an attestation quote, the CPU signs these measurements along with 64 bytes of custom data (REPORTDATA) that we choose.

### The configfs-tsm Interface

On Linux (kernel >= 6.7), attestation is accessed through a virtual filesystem at `/sys/kernel/config/tsm/report/`. This is NOT a regular filesystem — there are no files on disk. Every read/write is a kernel API call that talks to the TDX hardware.

The flow:

```
1. mkdir /sys/kernel/config/tsm/report/my-request
   → Kernel creates a virtual directory with pseudo-files: inblob, outblob, etc.

2. Write 64 bytes to inblob
   → Tells the kernel: "bind this custom data into the attestation quote"

3. Read from outblob
   → Kernel issues TDCALL to the CPU
   → CPU generates a TD Report (measurements + REPORTDATA + hardware MAC)
   → Kernel contacts the Quoting Enclave (QE) on the host
   → QE wraps the TD Report in a DCAP quote with Intel's certificate chain
   → Returns ~8KB signed DCAP quote

4. rmdir /sys/kernel/config/tsm/report/my-request
   → Cleans up the request
```

### What's in the DCAP Quote

The quote contains (among other fields):

| Field | Size | What it measures |
|-------|------|-----------------|
| MRTD | 48 bytes | VM firmware (Google-controlled, varies by cloud provider) |
| RTMR[0] | 48 bytes | TDVF config (ACPI, secure boot settings) |
| RTMR[1] | 48 bytes | Boot loader (GRUB/shim) |
| RTMR[2] | 48 bytes | Kernel + kernel command line |
| RTMR[3] | 48 bytes | Application code (user-defined, extended at boot) |
| REPORTDATA | 64 bytes | Custom data we provide (our input/output binding) |

Plus Intel's signature chain proving this came from real TDX hardware.

### Key Properties

**Another program reading the same outblob** gets the same quote (same REPORTDATA, same RTMRs). But this doesn't help an attacker — the REPORTDATA inside the quote is bound to what we wrote to inblob, and the contract verifies it matches.

**Another program creating its own entry** gets a different quote with different REPORTDATA (whatever they wrote to their inblob), but the same RTMR values (because RTMRs are properties of the VM, not the requesting process).

**Reading outblob at different times** may return different RTMR values if something extended an RTMR between reads. This is why boot-time measurement ordering matters (see below).

**No software can forge RTMR values.** They are maintained by the CPU hardware. The worst a malicious process can do is choose what REPORTDATA to include — but since we define REPORTDATA as a hash of the input and output, and both are verified by the contract, there's nothing useful to forge.

## What We Verify On-Chain

The `TdxVerifier` contract checks three things:

### 1. Genuine TDX Hardware (Automata DCAP)

The raw quote is passed to the [Automata DCAP verifier](https://docs.ata.network/), which validates Intel's certificate chain and confirms the quote came from real TDX hardware. This is a ~10-12M gas operation.

### 2. Approved Image (RTMR[1] + RTMR[2] + RTMR[3])

The contract maintains a registry of approved "image keys":

```
imageKey = keccak256(RTMR[1] || RTMR[2] || RTMR[3])
```

- **RTMR[1]** = boot loader. Determined by the GCP base image version. Same across all VMs using the same image.
- **RTMR[2]** = kernel + command line. Also determined by the GCP base image version.
- **RTMR[3]** = application code + model weights. Extended by our `boot.sh` at startup (see below).

We skip MRTD and RTMR[0] because they vary by cloud provider firmware — this makes the system portable across GCP projects and zones.

If the image key from the quote doesn't match any approved key, the contract rejects the result.

### 3. Input/Output Binding (REPORTDATA)

The contract computes:

```
outputHash  = keccak256(sha256(action) || sha256(reasoning) || approvedPromptHash)
expectedRD  = sha256(inputHash || outputHash)
```

And checks that `expectedRD` matches the REPORTDATA in the quote. This proves:
- The TEE used the correct input (epoch state committed on-chain at `startEpoch()`)
- The TEE produced the exact action + reasoning that were submitted
- The TEE used the approved system prompt (hash stored on-chain)

## When and Where RTMR Values Are Measured

### Boot-Time Measurements (RTMR[1] + RTMR[2])

These are measured automatically by the VM's boot chain — we don't control them:

```
Power on
  → Google's firmware measures itself into MRTD
  → TDVF (firmware) measures boot config into RTMR[0]
  → GRUB/shim measured into RTMR[1]        ← we verify this
  → Kernel + cmdline measured into RTMR[2]  ← we verify this
  → Kernel boots, systemd starts
```

These values are determined entirely by the GCP disk image. Two VMs booted from the same image produce identical RTMR[1] and RTMR[2].

### Application Measurement (RTMR[3])

RTMR[3] starts at all zeros on every boot. Our `tee/boot.sh` extends it with hashes of the enclave code and model weights:

```bash
# Step 1: Hash all enclave Python files in deterministic order
CODE_HASH=$(find /opt/humanfund/enclave -type f -name '*.py' | sort | xargs cat | sha384sum)

# Step 2: Extend RTMR[3] with the code hash via configfs-tsm
echo 3 > /sys/kernel/config/tsm/rtmrs/humanfund-code/index
echo "$CODE_HASH" > /sys/kernel/config/tsm/rtmrs/humanfund-code/digest

# Step 3: Hash the model file
MODEL_HASH=$(sha384sum /opt/humanfund/model/*.gguf)

# Step 4: Extend RTMR[3] again with the model hash
echo 3 > /sys/kernel/config/tsm/rtmrs/humanfund-model/index
echo "$MODEL_HASH" > /sys/kernel/config/tsm/rtmrs/humanfund-model/digest

# Step 5: Start the enclave runner (AFTER measurements are complete)
python3 -m enclave.enclave_runner
```

RTMR extension is an accumulation: `RTMR[3] = SHA384(RTMR[3] || new_data)`. After both extensions:

```
RTMR[3] = SHA384(SHA384(zeros || code_hash) || model_hash)
```

This is deterministic — any VM running the same code files and model produces the same RTMR[3].

**Ordering matters.** The enclave runner starts AFTER the measurements. If a quote is requested before `boot.sh` runs, RTMR[3] would be all zeros, producing a different image key that the contract would reject.

### Why boot.sh is Trustworthy

`boot.sh` is part of the disk image measured by RTMR[2] (kernel + rootfs). If an attacker modified `boot.sh` to skip the code measurement or lie about the hash, RTMR[2] would change, producing a different image key. The trust chain is:

```
RTMR[2] attests the kernel + boot.sh
  └─ boot.sh measures enclave code + model into RTMR[3]
      └─ RTMR[3] attests the application code + model
          └─ The contract verifies keccak256(RTMR[1] || RTMR[2] || RTMR[3])
```

## Registration Flow

### One-Time Setup (Contract Owner)

1. **Create a GCP TDX VM** from the pinned base image with enclave code + model installed
2. **Boot the VM** — `boot.sh` measures code + model into RTMR[3]
3. **Extract measurements** — request a TDX quote, parse out RTMR[1..3]:
   ```bash
   python scripts/extract_measurements.py
   # Output: RTMR1:<hex> RTMR2:<hex> RTMR3:<hex>
   ```
4. **Register on-chain** — compute the image key and call `TdxVerifier.approveImage()`:
   ```bash
   python scripts/register_image.py --vm-name my-vm --verifier 0x...
   # Computes: imageKey = keccak256(RTMR[1] || RTMR[2] || RTMR[3])
   # Calls:    verifier.approveImage(imageKey)
   ```

### Third-Party Runner Verification

A third-party runner creating their own VM can verify their measurements match:

```bash
python scripts/verify_measurements.py --vm-name my-vm --verifier 0x...
# Extracts RTMR[1..3], computes image key, checks if approved on-chain
```

If the measurements match (same GCP base image + same enclave code + same model), the image key will be the same, and their attestation quotes will pass verification.

### When Re-Registration Is Needed

The image key changes when any of these change:

| What changed | Which RTMR changes | Re-register needed? |
|---|---|---|
| GCP updates the base image (kernel patch) | RTMR[1] and/or RTMR[2] | Yes |
| Enclave Python code is modified | RTMR[3] | Yes |
| Model weights are swapped | RTMR[3] | Yes |
| Different GCP project or zone | None | No |
| Different VM instance | None | No |
| System prompt updated | None (prompt hash is separate) | No, just update `approvedPromptHash` |

The contract owner can register multiple image keys simultaneously (e.g., during a migration to a new kernel version), and revoke old ones once all runners have migrated.

## Verified On-Chain Per Epoch

When a runner calls `submitAuctionResult(action, reasoning, proof, ...)`:

```
1. DCAP Verification (Automata, ~10-12M gas)
   └─ Is this quote from genuine Intel TDX hardware?

2. Image Registry Check
   └─ imageKey = keccak256(RTMR[1] || RTMR[2] || RTMR[3]) from the quote
   └─ Is this imageKey in the approvedImages mapping?

3. REPORTDATA Binding
   └─ Compute: outputHash = keccak256(sha256(action) || sha256(reasoning) || approvedPromptHash)
   └─ Compute: expected = sha256(inputHash || outputHash)
   └─ Does expected == REPORTDATA from the quote?

4. If all pass → execute the action, pay the bounty
   If any fail → revert
```

## What Attestation Does NOT Prove

- **That the inference is "correct"** — a different random seed would produce different reasoning. Attestation proves the approved code ran, not that the output is optimal.
- **That the runner is honest about timing** — a runner could delay submission (within the execution window). The contract enforces timing via the auction mechanism.
- **That the model is "good"** — the model hash is pinned, but whether DeepSeek R1 70B makes good decisions is a separate question. Model selection was done via a 75-epoch gauntlet before deployment.
