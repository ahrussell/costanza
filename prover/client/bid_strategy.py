#!/usr/bin/env python3
"""Bid strategy — calculate auction bid based on gas and compute costs.

The bid must cover:
1. Gas cost for submitAuctionResult (~12.5M gas for DCAP verification)
2. GCP VM compute cost (boot time + inference time)
3. A profit margin (configurable multiplier)

The bid is clamped to the contract's effectiveMaxBid.
"""


# Gas cost for submitAuctionResult (includes DCAP verification)
SUBMIT_GAS = 12_500_000

# GCP VM hourly rates (USD, on-demand)
GCP_HOURLY_RATES = {
    "a3-highgpu-1g": 35.0,     # 1x H100 80GB
    "c3-standard-4": 0.21,     # 4 vCPU, 16GB (CPU inference)
}

# Estimated times (minutes)
GPU_BOOT_MINUTES = 5     # VM create + model load
GPU_INFERENCE_MINUTES = 1  # ~30s inference + overhead
CPU_BOOT_MINUTES = 5
CPU_INFERENCE_MINUTES = 25  # ~22 min inference + overhead


def estimate_bid(gas_price_wei, machine_type="a3-highgpu-1g", eth_usd_price=2000.0,
                 margin=1.5):
    """Estimate the minimum profitable bid.

    Args:
        gas_price_wei: Current gas price in wei.
        machine_type: GCP machine type (determines hourly rate and timing).
        eth_usd_price: Current ETH/USD price for converting compute costs.
        margin: Multiplier over estimated cost (default 1.5x).

    Returns:
        Bid amount in wei.
    """
    # Gas cost
    gas_cost_wei = SUBMIT_GAS * gas_price_wei

    # Compute cost
    hourly_rate = GCP_HOURLY_RATES.get(machine_type, 35.0)
    if "highgpu" in machine_type or "h100" in machine_type.lower():
        total_minutes = GPU_BOOT_MINUTES + GPU_INFERENCE_MINUTES
    else:
        total_minutes = CPU_BOOT_MINUTES + CPU_INFERENCE_MINUTES

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
