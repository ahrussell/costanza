#!/usr/bin/env python3
"""Persistent state management for the runner client.

Stores commit/reveal state between cron runs in a JSON file.
Uses atomic writes (write to temp, rename) to prevent corruption.
"""

import json
import os
import tempfile
from pathlib import Path


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
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, indent=2)
        os.rename(tmp_path, state_file)
        os.chmod(state_file, 0o600)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def clear(state_dir=DEFAULT_STATE_DIR):
    """Delete the state file."""
    state_file = Path(state_dir) / "state.json"
    try:
        state_file.unlink()
    except FileNotFoundError:
        pass
