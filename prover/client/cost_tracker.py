#!/usr/bin/env python3
"""Rolling cost tracker — records actual gas and compute costs per epoch.

Maintains a 10-epoch rolling window of real costs in a separate file
(cost_history.json) that survives epoch state clears. Used by bid_strategy
to self-calibrate bids based on observed data.
"""

import json
import logging
import os
import tempfile
from pathlib import Path

logger = logging.getLogger(__name__)

MAX_HISTORY = 10
HISTORY_FILENAME = "cost_history.json"


def _load_history(state_dir):
    """Load cost history from disk. Returns list of dicts."""
    path = Path(state_dir) / HISTORY_FILENAME
    try:
        with open(path) as f:
            data = json.load(f)
            if isinstance(data, list):
                return data
    except (FileNotFoundError, json.JSONDecodeError):
        pass
    return []


def _save_history(history, state_dir):
    """Atomically save cost history to disk."""
    path = Path(state_dir) / HISTORY_FILENAME
    fd, tmp = tempfile.mkstemp(dir=str(state_dir), suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(history, f)
        os.rename(tmp, str(path))
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def record_epoch_cost(state_dir, epoch, gas_used, gas_price_wei, vm_minutes):
    """Record the actual cost of an epoch execution.

    Args:
        state_dir: Path to persistent state directory.
        epoch: Epoch number.
        gas_used: Actual gas consumed by submitAuctionResult.
        gas_price_wei: Gas price at time of submission.
        vm_minutes: Total VM uptime in minutes (boot + inference + cleanup).
    """
    try:
        history = _load_history(state_dir)

        # Don't record duplicate epochs
        if any(h.get("epoch") == epoch for h in history):
            return

        history.append({
            "epoch": epoch,
            "gas_used": gas_used,
            "gas_price_wei": gas_price_wei,
            "vm_minutes": vm_minutes,
        })

        # Keep only the last MAX_HISTORY entries
        history = history[-MAX_HISTORY:]

        _save_history(history, state_dir)
        logger.debug("Recorded epoch %d cost: gas=%d, vm=%.1f min", epoch, gas_used, vm_minutes)
    except Exception:
        logger.debug("Failed to record epoch cost (non-critical)", exc_info=True)


def get_average_costs(state_dir, min_epochs=3):
    """Get average gas and VM time from recent history.

    Args:
        state_dir: Path to persistent state directory.
        min_epochs: Minimum number of data points required.

    Returns:
        Dict with avg_gas_used, avg_vm_minutes, num_epochs.
        Returns None if insufficient data.
    """
    try:
        history = _load_history(state_dir)
        if len(history) < min_epochs:
            return None

        total_gas = sum(h["gas_used"] for h in history)
        total_vm = sum(h["vm_minutes"] for h in history)
        n = len(history)

        return {
            "avg_gas_used": total_gas / n,
            "avg_vm_minutes": total_vm / n,
            "num_epochs": n,
        }
    except Exception:
        logger.debug("Failed to read cost history (non-critical)", exc_info=True)
        return None
