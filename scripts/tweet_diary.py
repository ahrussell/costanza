#!/usr/bin/env python3
"""Tweet new diary entries.

Polls TheHumanFund for executed epochs since the last tweet and posts one
tweet per new diary entry. Designed to run via cron every ~5 min on the
Hetzner runner. Independent of the prover — tweets fire regardless of who
won the auction.

State: $STATE_DIR/tweet_state.json (default ~/.humanfund/tweet_state.json).
On first run, initializes to the latest executed epoch (no historical
backfill). To backfill, edit the state file before the next cron run.

Required env (loaded from <repo>/.env if present, else process env):
    RPC_URL                       Base mainnet RPC
    CONTRACT_ADDRESS              TheHumanFund address
    TWITTER_API_KEY               X v2 OAuth1.0a consumer key
    TWITTER_API_SECRET
    TWITTER_ACCESS_TOKEN          User access token (write-permitted)
    TWITTER_ACCESS_TOKEN_SECRET

Optional:
    STATE_DIR                     Override state dir (default ~/.humanfund)
    SITE_URL                      Override link base (default https://thehumanfund.ai/)

Usage:
    python scripts/tweet_diary.py                # tweet new epochs
    python scripts/tweet_diary.py --dry-run      # preview, don't post or save
"""

import argparse
import json
import logging
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ABI_DIR = REPO_ROOT / "out"
DEFAULT_SITE = "https://thehumanfund.ai/"
TWEET_LIMIT = 280
URL_WEIGHT = 23  # twitter-text: every URL counts as 23 chars after t.co
MAX_MESSAGES_PER_EPOCH = 3

logger = logging.getLogger("tweet-diary")


def load_dotenv(path: Path) -> None:
    """Minimal .env loader. Doesn't override values already in os.environ."""
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip()
        v = v.strip().strip("'\"")
        os.environ.setdefault(k, v)


def load_abi(name: str) -> list:
    p = ABI_DIR / f"{name}.sol" / f"{name}.json"
    return json.loads(p.read_text())["abi"]


def state_path() -> Path:
    state_dir = Path(os.environ.get("STATE_DIR") or str(Path.home() / ".humanfund"))
    state_dir.mkdir(parents=True, exist_ok=True)
    return state_dir / "tweet_state.json"


def load_state() -> dict:
    p = state_path()
    return json.loads(p.read_text()) if p.exists() else {}


def save_state(state: dict) -> None:
    state_path().write_text(json.dumps(state, indent=2))


def fmt_eth(wei: int) -> str:
    return f"{wei / 1e18:.3f} ETH"


def truncate(text: str, max_len: int) -> str:
    text = text.strip()
    if len(text) <= max_len:
        return text
    cut = text[: max_len - 1].rsplit(" ", 1)[0]
    return cut.rstrip(".,;:") + "…"


def build_tweet(epoch: int, diary: str, treasury_wei: int, msg_count: int, site_url: str) -> str:
    parts = [f"Epoch {epoch}", f"Treasury {fmt_eth(treasury_wei)}"]
    if msg_count > 0:
        parts.append(f"{msg_count} message{'s' if msg_count != 1 else ''}")
    header = " · ".join(parts)
    url = f"{site_url.rstrip('/')}/#epoch={epoch}"
    # Two blank lines worth of separators = 4 chars (\n\n × 2)
    available = TWEET_LIMIT - len(header) - 4 - URL_WEIGHT
    body = truncate(diary, max(40, available))
    return f"{header}\n\n{body}\n\n{url}"


def latest_executed_epoch(fund, current_epoch: int) -> int:
    for e in range(current_epoch, 0, -1):
        try:
            rec = fund.functions.getEpochRecord(e).call()
            if rec[6]:  # executed
                return e
        except Exception:
            continue
    return 0


def epoch_message_count(fund, epoch: int) -> int:
    """How many messages the agent read this epoch (0..3)."""
    try:
        snap = fund.functions.getEpochSnapshot(epoch).call()
        # Tuple positions per the EpochSnapshot ABI: 16=messageHead, 17=messageCount
        head = int(snap[16])
        count = int(snap[17])
        return max(0, min(count - head, MAX_MESSAGES_PER_EPOCH))
    except Exception as ex:
        logger.warning("getEpochSnapshot(%d) failed: %s", epoch, ex)
        return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="Print tweets, don't post or save state")
    args = ap.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    load_dotenv(REPO_ROOT / ".env")

    from web3 import Web3

    rpc = os.environ["RPC_URL"]
    addr = os.environ["CONTRACT_ADDRESS"]
    site = os.environ.get("SITE_URL", DEFAULT_SITE)

    w3 = Web3(Web3.HTTPProvider(rpc))
    fund = w3.eth.contract(
        address=Web3.to_checksum_address(addr),
        abi=load_abi("TheHumanFund"),
    )

    state = load_state()
    last = int(state.get("last_tweeted_epoch", 0))
    current = int(fund.functions.currentEpoch().call())

    if last == 0:
        latest = latest_executed_epoch(fund, current)
        logger.info("First run: initializing state at epoch %d (no backfill)", latest)
        if not args.dry_run:
            save_state({"last_tweeted_epoch": latest})
        return

    if current <= last:
        logger.info("No new epochs (last=%d, current=%d)", last, current)
        return

    client = None
    if not args.dry_run:
        import tweepy
        client = tweepy.Client(
            consumer_key=os.environ["TWITTER_API_KEY"],
            consumer_secret=os.environ["TWITTER_API_SECRET"],
            access_token=os.environ["TWITTER_ACCESS_TOKEN"],
            access_token_secret=os.environ["TWITTER_ACCESS_TOKEN_SECRET"],
            wait_on_rate_limit=True,
        )

    for e in range(last + 1, current + 1):
        try:
            rec = fund.functions.getEpochRecord(e).call()
        except Exception as ex:
            logger.error("getEpochRecord(%d) failed: %s — bailing", e, ex)
            return

        executed = rec[6]
        if not executed:
            logger.info("Epoch %d not executed (forfeited), skipping", e)
            state["last_tweeted_epoch"] = e
            if not args.dry_run:
                save_state(state)
            continue

        reasoning_bytes = rec[2]
        treasury_after = int(rec[4])
        try:
            diary = bytes(reasoning_bytes).decode("utf-8")
        except UnicodeDecodeError:
            diary = "(binary data)"

        msg_count = epoch_message_count(fund, e)

        text = build_tweet(e, diary, treasury_after, msg_count, site)
        logger.info("Tweet for epoch %d (%d chars):\n%s\n", e, len(text), text)

        if args.dry_run:
            continue

        try:
            client.create_tweet(text=text)
        except Exception as ex:
            logger.error("create_tweet(epoch=%d) failed: %s — bailing, will retry next run", e, ex)
            return

        state["last_tweeted_epoch"] = e
        save_state(state)
        logger.info("Tweeted epoch %d", e)


if __name__ == "__main__":
    main()
