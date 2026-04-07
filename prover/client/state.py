#!/usr/bin/env python3
"""Persistent state management for the runner client.

Stores commit/reveal state between cron runs in a JSON file.
Uses atomic writes (write to temp, rename) to prevent corruption.

State fields:
  Bid tracking:
    epoch, commit_salt, bid_amount, committed, revealed
  TEE execution tracking:
    tee_completed, tee_result_path, submission_attempts, submission_failed
  Epoch pacing:
    next_eligible_time
"""

import json
import logging
import os
import tempfile
from pathlib import Path

logger = logging.getLogger(__name__)

DEFAULT_STATE_DIR = Path(os.path.expanduser("~/.humanfund"))


def load(state_dir=DEFAULT_STATE_DIR, current_epoch=None):
    """Load runner state from disk.

    Args:
        state_dir: Directory containing state.json.
        current_epoch: If provided, return empty state if stored epoch doesn't match.

    Returns:
        State dict with keys: epoch, commit_salt, bid_amount, committed, revealed.
        Returns empty dict if no state file or stale epoch.
    """
    state_file = Path(state_dir) / "state.json"
    if not state_file.exists():
        return {}

    try:
        with open(state_file) as f:
            state = json.load(f)
    except (json.JSONDecodeError, IOError):
        return {}

    # Stale epoch — start fresh
    if current_epoch is not None and state.get("epoch") != current_epoch:
        return {}

    return state


def save(state, state_dir=DEFAULT_STATE_DIR):
    """Atomically save runner state to disk.

    Args:
        state: Dict to save. Should include: epoch, commit_salt, bid_amount, committed, revealed.
        state_dir: Directory to write state.json in.
    """
    state_dir = Path(state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    state_file = state_dir / "state.json"

    # Atomic write: write to temp file, then rename
    fd, tmp_path = tempfile.mkstemp(dir=state_dir, suffix=".tmp")
    try:
        os.fchmod(fd, 0o600)  # Set permissions before writing any data
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, indent=2)
        os.rename(tmp_path, state_file)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def clear(state_dir=DEFAULT_STATE_DIR):
    """Delete the state file and any cached TEE results."""
    state_dir = Path(state_dir)
    state_file = state_dir / "state.json"
    try:
        state_file.unlink()
    except FileNotFoundError:
        pass
    # Clean up cached TEE results from previous epochs
    for f in state_dir.glob("tee_result_*.json"):
        try:
            f.unlink()
        except OSError:
            pass


def save_tee_result(result_dict, epoch, state_dir=DEFAULT_STATE_DIR):
    """Atomically save TEE inference result to disk for reuse on retry.

    Returns the path to the saved file.
    """
    state_dir = Path(state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    result_file = state_dir / f"tee_result_{epoch}.json"

    fd, tmp_path = tempfile.mkstemp(dir=state_dir, suffix=".tmp")
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(result_dict, f, indent=2)
        os.rename(tmp_path, result_file)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise

    return str(result_file)


def load_tee_result(path):
    """Load a cached TEE result from disk.

    Returns the result dict, or None if missing/corrupt.
    """
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, IOError) as e:
        logger.warning("Failed to load cached TEE result from %s: %s", path, e)
        return None
