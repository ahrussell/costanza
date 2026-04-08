#!/usr/bin/env python3
"""ntfy.sh notification integration.

Sends push notifications for auction events. Silent when no channel is configured.
"""

import json
import logging
import re
from urllib.request import urlopen, Request

logger = logging.getLogger(__name__)


def _sanitize(text: str) -> str:
    """Redact potential secrets from error messages before external transmission."""
    s = str(text)
    # Redact private keys (0x + 64 hex chars)
    s = re.sub(r'0x[0-9a-fA-F]{64}', '0x[REDACTED]', s)
    # Redact API keys in URLs (common patterns)
    s = re.sub(r'(https?://[^/]*?)[?&](?:key|apikey|api_key|token)=[^&\s]+', r'\1?key=[REDACTED]', s)
    # Redact Bearer tokens
    s = re.sub(r'Bearer\s+[A-Za-z0-9._-]+', 'Bearer [REDACTED]', s)
    return s


def notify(channel, title, message, priority="default", tags=None):
    """Send a notification via ntfy.sh.

    Args:
        channel: ntfy.sh channel name. If None, notification is silently skipped.
        title: Notification title.
        message: Notification body.
        priority: One of: min, low, default, high, urgent.
        tags: List of emoji tags (e.g., ["money_mouth_face", "tada"]).
    """
    if not channel:
        return

    try:
        headers = {
            "Title": title,
            "Priority": priority,
        }
        if tags:
            headers["Tags"] = ",".join(tags)

        req = Request(
            f"https://ntfy.sh/{channel}",
            data=message.encode("utf-8"),
            headers=headers,
            method="POST",
        )
        urlopen(req, timeout=10)
    except Exception as e:
        logger.warning("Failed to send notification: %s", e)


def notify_epoch_started(channel, epoch):
    notify(channel, f"Epoch {epoch} started", f"Auction opened for epoch {epoch}.", tags=["hourglass"])

def notify_bid_committed(channel, epoch, amount_eth):
    notify(channel, f"Bid committed (epoch {epoch})", f"Committed bid of {amount_eth:.6f} ETH.", tags=["lock"])

def notify_bid_revealed(channel, epoch, amount_eth):
    notify(channel, f"Bid revealed (epoch {epoch})", f"Revealed bid of {amount_eth:.6f} ETH.", tags=["key"])

def notify_auction_won(channel, epoch, amount_eth):
    notify(channel, f"Won auction! (epoch {epoch})", f"Winning bid: {amount_eth:.6f} ETH. Starting TEE inference...", priority="high", tags=["trophy"])

def notify_auction_lost(channel, epoch, winner):
    notify(channel, f"Lost auction (epoch {epoch})", f"Winner: {winner[:10]}...", tags=["person_shrugging"])

def notify_result_submitted(channel, epoch, action, bounty_eth=None, cost=None):
    """Notify that a result was submitted, with optional profit/loss breakdown in USD."""
    lines = [f"Action: {action}"]
    if bounty_eth is not None and cost is not None:
        eth_usd = cost["eth_usd_price"]
        bounty_usd = bounty_eth * eth_usd
        profit_usd = bounty_usd - cost["total_cost_usd"]
        sign = "+" if profit_usd >= 0 else ""
        lines.append(f"Bounty: {bounty_eth:.6f} ETH (${bounty_usd:.2f})")
        lines.append(f"Gas: ${cost['gas_cost_usd']:.2f} ({cost['gas_cost_eth']:.6f} ETH)")
        lines.append(f"Compute: ${cost['compute_cost_usd']:.2f} ({cost['vm_minutes']:.1f} min)")
        lines.append(f"Profit: {sign}${profit_usd:.2f}")
        tags = ["money_mouth_face"] if profit_usd >= 0 else ["chart_with_downwards_trend"]
    else:
        tags = ["white_check_mark"]
    notify(channel, f"Result submitted (epoch {epoch})", "\n".join(lines), priority="high", tags=tags)

def notify_epoch_settled(channel, epoch):
    notify(channel, f"Epoch {epoch} settled", f"State cleared, ready for next epoch.", tags=["checkered_flag"])

def notify_execution_expired(channel, epoch):
    notify(channel, f"Execution expired (epoch {epoch})",
           f"Execution window passed. Attempting to advance to next epoch.",
           priority="high", tags=["hourglass_flowing_sand"])

def notify_cached_submission(channel, epoch, attempt, max_retries):
    notify(channel, f"Retrying submission (epoch {epoch})",
           f"Using cached TEE result (attempt {attempt}/{max_retries}).",
           tags=["recycle"])

def notify_commit_closed(channel, epoch):
    notify(channel, f"Commit closed (epoch {epoch})", f"Commit phase closed.", tags=["fast_forward"])

def notify_reveal_closed(channel, epoch):
    notify(channel, f"Reveal closed (epoch {epoch})", f"Reveal phase closed.", tags=["fast_forward"])

def notify_error(channel, epoch, error):
    notify(channel, f"ERROR (epoch {epoch})", _sanitize(str(error)[:500]), priority="urgent", tags=["rotating_light"])

def notify_submission_failed(channel, epoch, error, attempt, max_retries):
    notify(channel, f"Submit failed (epoch {epoch})",
           f"Attempt {attempt}/{max_retries}: {_sanitize(str(error)[:300])}",
           priority="high", tags=["warning"])

def notify_epoch_abandoned(channel, epoch, reason):
    notify(channel, f"Epoch {epoch} abandoned",
           f"Giving up: {_sanitize(str(reason)[:300])}",
           priority="urgent", tags=["rotating_light"])

def notify_bond_forfeited(channel, epoch, bond_eth):
    notify(channel, f"Bond forfeited! (epoch {epoch})",
           f"Missed reveal window — {bond_eth:.6f} ETH bond lost.",
           priority="urgent", tags=["money_with_wings"])

def notify_bond_claimed(channel, epoch, amount_eth):
    notify(channel, f"Bond claimed (epoch {epoch})",
           f"Recovered {amount_eth:.6f} ETH from epoch {epoch}.",
           tags=["moneybag"])
