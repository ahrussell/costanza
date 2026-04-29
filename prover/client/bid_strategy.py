#!/usr/bin/env python3
"""Bid strategy — calculate auction bid based on gas and compute costs.

The bid must cover:
1. Gas cost for submitAuctionResult (~12.5M gas for DCAP verification)
2. GCP VM compute cost (boot time + inference time)
3. A profit margin (configurable multiplier)

The bid is clamped to the contract's effectiveMaxBid.
"""


# Gas cost estimate for submitAuctionResult (DCAP verification).
# This is a COST ESTIMATE for bid calculation, not the gas limit ceiling.
# The gas limit (GAS_SUBMIT_RESULT = 15M) is set in auction.py.
# Re-calibrate by checking actual gasUsed from recent submission receipts.
SUBMIT_GAS = 12_500_000

# GCP VM hourly rates (USD, SPOT pricing).
# We use --provisioning-model=SPOT for all TEE VMs.
# Re-calibrate by checking current GCP spot pricing for us-central1.
GCP_HOURLY_RATES = {
    "a3-highgpu-1g": 11.74,    # 1x H100 80GB (spot, us-central1)
    "c3-standard-4": 0.08,     # 4 vCPU, 16GB (spot)
}

# Estimated times (minutes).
# GPU timing for v19 (Hermes 4 70B Q6_K, 2-pass): ~6 min boot + model load
# (58 GB split GGUF takes longer to load than DeepSeek's 42.5 GB), ~3 min
# for two passes + encoding + attestation overhead. Total VM lifetime
# consistently around 9 minutes in v17-v19 experiment runs.
# Re-calibrate by checking vm_minutes from recent TEE results in state dir.
GPU_BOOT_MINUTES = 6       # VM create + model load (Q6_K is 15 GB larger than Q4_K_M)
GPU_INFERENCE_MINUTES = 3  # 2-pass diary + action JSON + attestation
CPU_BOOT_MINUTES = 5
CPU_INFERENCE_MINUTES = 25  # ~22 min inference + overhead (not used in prod)


def estimate_bid(gas_price_wei, machine_type="a3-highgpu-1g", eth_usd_price=2000.0,
                 margin=1.5, observed_costs=None):
    """Estimate the minimum profitable bid.

    If observed_costs is provided (from cost_tracker.get_average_costs()),
    uses real averages for gas and VM time instead of hardcoded estimates.

    Args:
        gas_price_wei: Current gas price in wei.
        machine_type: GCP machine type (determines hourly rate and timing).
        eth_usd_price: Current ETH/USD price for converting compute costs.
        margin: Multiplier over estimated cost (default 1.5x).
        observed_costs: Optional dict with avg_gas_used, avg_vm_minutes from
            the rolling cost tracker. If provided and sufficient, overrides
            hardcoded estimates.

    Returns:
        Bid amount in wei.
    """
    # Use observed data if available, otherwise fall back to hardcoded estimates
    if observed_costs:
        gas_estimate = int(observed_costs["avg_gas_used"])
        total_minutes = observed_costs["avg_vm_minutes"]
    else:
        gas_estimate = SUBMIT_GAS
        if "highgpu" in machine_type or "h100" in machine_type.lower():
            total_minutes = GPU_BOOT_MINUTES + GPU_INFERENCE_MINUTES
        else:
            total_minutes = CPU_BOOT_MINUTES + CPU_INFERENCE_MINUTES

    # Gas cost
    gas_cost_wei = gas_estimate * gas_price_wei

    # Compute cost
    hourly_rate = GCP_HOURLY_RATES.get(machine_type, 11.74)
    compute_cost_usd = hourly_rate * (total_minutes / 60)
    compute_cost_eth = compute_cost_usd / eth_usd_price
    compute_cost_wei = int(compute_cost_eth * 1e18)

    # Total with margin
    total = int((gas_cost_wei + compute_cost_wei) * margin)

    return total


def estimate_cost(gas_used, gas_price_wei, vm_minutes, machine_type="a3-highgpu-1g",
                   eth_usd_price=2000.0):
    """Compute the actual cost of running an epoch (for profit/loss calculation).

    Uses actual gas_used from the tx receipt and actual vm_minutes from the
    TEE client, so the profit/loss figure is as accurate as possible.

    Args:
        gas_used: Actual gas consumed by submitAuctionResult (from receipt).
        gas_price_wei: Effective gas price at time of submission.
        vm_minutes: Actual VM uptime in minutes (from TEE client timer).
        machine_type: GCP machine type used.
        eth_usd_price: ETH/USD price for converting between ETH and USD.

    Returns:
        Dict with cost breakdown in both ETH and USD.
    """
    gas_cost_wei = gas_used * gas_price_wei
    gas_cost_eth = gas_cost_wei / 1e18
    gas_cost_usd = gas_cost_eth * eth_usd_price

    hourly_rate = GCP_HOURLY_RATES.get(machine_type, 35.0)
    compute_cost_usd = hourly_rate * (vm_minutes / 60)
    compute_cost_eth = compute_cost_usd / eth_usd_price

    total_cost_eth = gas_cost_eth + compute_cost_eth
    total_cost_usd = gas_cost_usd + compute_cost_usd

    return {
        "gas_cost_eth": gas_cost_eth,
        "gas_cost_usd": gas_cost_usd,
        "compute_cost_eth": compute_cost_eth,
        "compute_cost_usd": compute_cost_usd,
        "total_cost_eth": total_cost_eth,
        "total_cost_usd": total_cost_usd,
        "vm_minutes": vm_minutes,
        "eth_usd_price": eth_usd_price,
    }


def clamp_bid(bid_wei, max_bid_wei, min_bid_wei=100_000_000_000_000):
    """Clamp bid to valid range.

    Args:
        bid_wei: Proposed bid in wei.
        max_bid_wei: Contract's effectiveMaxBid in wei.
        min_bid_wei: Minimum viable bid (default 0.0001 ETH).

    Returns:
        Clamped bid in wei.
    """
    return max(min_bid_wei, min(bid_wei, max_bid_wei))
