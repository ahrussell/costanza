#!/usr/bin/env python3
"""ntfy.sh notification integration.

Sends push notifications for auction events. Silent when no channel is configured.
"""

import json
from urllib.request import urlopen, Request


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
        print(f"WARNING: Failed to send notification: {e}")


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

def notify_error(channel, epoch, error):
    notify(channel, f"ERROR (epoch {epoch})", str(error)[:500], priority="urgent", tags=["rotating_light"])

def notify_vm_started(channel, vm_name):
    notify(channel, "TEE VM started", f"VM: {vm_name}", tags=["computer"])

def notify_bond_forfeited(channel, epoch, runner):
    notify(channel, f"Bond forfeited (epoch {epoch})", f"Runner {runner[:10]}... failed to deliver.", tags=["warning"])
