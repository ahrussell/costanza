#!/usr/bin/env python3
"""The Human Fund — Auction Runner Client.

Designed to run as a cron job (e.g., every 2 minutes). Uses chain state as
the source of truth and local state as advisory only.

Every run:
1. Read chain state (epoch, timing, phase, winner, seed)
2. Query chain for our participation (committed? revealed? won?)
3. Load local state (may be empty — that's OK)
4. Detect irrecoverable situations (lost commit salt → accept forfeit)
5. Dispatch based on wall-clock phase + what we CAN do
6. If we can't participate, advance the contract proactively

The ONLY unrecoverable local state is commit_salt. Everything else is
chain-queryable.

Usage:
    */2 * * * * cd /path/to/thehumanfund && python -m prover.client
    python -m prover.client --ntfy-channel my-channel
"""

import fcntl
import json
import logging
import os
import sys
import tempfile
import time
from pathlib import Path

from .config import load_config
from .chain import ChainClient
from .auction import (
    sync_phase, commit_bid, reveal_bid, submit_result, poke_costanza_fees,
    SubmissionError, MAX_SUBMIT_RETRIES, _match_error, ERROR_SELECTORS,
    PHASE_NAMES,
)
from .bid_strategy import estimate_bid, clamp_bid
from .cost_tracker import record_epoch_cost, get_average_costs
from .state import (
    load as load_state, save as save_state, clear as clear_state,
    save_tee_result, load_tee_result,
)
from .notifier import (
    notify_epoch_started, notify_bid_committed, notify_bid_revealed,
    notify_auction_won, notify_auction_lost, notify_result_submitted,
    notify_error, notify_submission_failed, notify_epoch_abandoned,
    notify_epoch_settled, notify_bond_forfeited, notify_bond_claimed,
    notify_cached_submission, notify_low_balance,
    notify_epoch_skipped, notify_reveal_will_fail,
)

logger = logging.getLogger(__name__)

ZERO_ADDR = "0x" + "0" * 40

# Map from action_bytes[0] to a human-readable name. Mirrors the contract's
# action-type byte encoding. Used for notifications — derived from the
# attested `action_bytes` rather than the unattested `tee_result["action"]`
# JSON, so a compromised client can't substitute a misleading label.
_ACTION_NAMES = {
    0: "do_nothing",
    1: "donate",
    2: "set_commission_rate",
    3: "invest",
    4: "withdraw",
}

# Retry schedule: (strategy, min_seconds_remaining) per attempt index.
# "use_cached" resubmits the same TEE result (different tx, same quote).
# "rerun_tee" discards the cached result and boots a fresh TDX VM for a
#   new attestation quote (same deterministic output, different DCAP nonce).
USE_CACHED = "use_cached"
RERUN_TEE = "rerun_tee"

RETRY_SCHEDULE = [
    (RERUN_TEE,  600),   # Attempt 0: initial TEE run (10 min)
    (USE_CACHED,  60),   # Attempt 1: quick resubmit — DCAP might be transient
    (RERUN_TEE,  600),   # Attempt 2: fresh quote — in case the quote itself is bad
]


# ─── Wall-Clock Phase Resolution ────────────────────────────────────────

def _resolve_phase(auction):
    """Resolve the effective phase from wall-clock timing.

    An auction is always open for the current epoch (eager-opened at
    deploy, kept open at every epoch rollover). The "no_auction" branch
    below is a sunset-state artifact: after migrate() runs, the AM is
    SETTLED and `currentAuctionStartTime` is 0. In normal operation we
    always land in commit/reveal/execution/epoch_over.
    """
    start = auction["start_time"]
    now = auction["now"]

    if start == 0:
        return "no_auction"  # sunset edge case
    if now < auction["commit_end"]:
        return "commit"
    elif now < auction["reveal_end"]:
        return "reveal"
    elif now < auction["exec_end"]:
        return "execution"
    else:
        return "epoch_over"


# ─── Helpers ────────────────────────────────────────────────────────────

def _parse_eth_usd(raw_price):
    """Parse ETH/USD price from Chainlink's 8-decimal format."""
    if raw_price > 1e6:
        return raw_price / 1e8
    return 2000.0


def get_tee_client(config):
    """Create the appropriate TEE client based on config."""
    if config["tee_client"] == "gcp-gpu":
        from .tee_clients.gcp import GCPTEEClient
        return GCPTEEClient(
            project=config["gcp_project"],
            zone=config["gcp_zone"],
            image=config["gcp_image"],
            machine_type="a3-highgpu-1g",
            inference_timeout=config.get("enclave_timeout", 900),
        )
    elif config["tee_client"] == "gcp-cpu":
        from .tee_clients.gcp import GCPTEEClient
        return GCPTEEClient(
            project=config["gcp_project"],
            zone=config["gcp_zone"],
            image=config.get("gcp_image"),
            machine_type="c3-standard-4",
            inference_timeout=config.get("enclave_timeout", 1800),
        )
    elif config["tee_client"] == "gcp-persistent":
        # Testnet-only client. Lives in deploy/testnet/ since it's not part
        # of the production cron path.
        from deploy.testnet.gcp_persistent import GCPPersistentTEEClient
        return GCPPersistentTEEClient(
            project=config["gcp_project"],
            zone=config["gcp_zone"],
            image=config.get("gcp_image", "humanfund-base-gpu-llama-b5270-hermes"),
            machine_type=config.get("gcp_machine_type", "a3-highgpu-1g"),
            inference_timeout=config.get("enclave_timeout", 600),
            source_dir=config.get("source_dir", "."),
        )
    else:
        raise ValueError(f"Unknown TEE client: {config['tee_client']}")


def _try_advance(chain, ntfy):
    """Try to advance the contract past the current epoch via syncPhase.

    If a new auction opens, sends a notification. Returns True on success.
    """
    if sync_phase(chain):
        new_epoch = chain.contract.functions.currentEpoch().call()
        new_phase = chain.am.functions.phase().call()
        # AM phases: 0=COMMIT, 1=REVEAL, 2=EXECUTION, 3=SETTLED.
        # A fresh auction after rollover lands in COMMIT.
        if new_phase == 0:  # COMMIT — auction opened
            logger.info("Auction opened for epoch %d", new_epoch)
            notify_epoch_started(ntfy, new_epoch)
        else:
            logger.info("Advanced to epoch %d (phase %d)", new_epoch, new_phase)
        return True
    return False


def _try_claim_bonds(chain, ntfy, state_dir):
    """Try to claim any owed bonds from recent epochs. Best-effort.

    Uses a separate claim_tracker.json that survives epoch state clears.
    """
    try:
        # Load claim tracking state (separate from epoch state)
        claim_file = Path(state_dir) / "claim_tracker.json"
        try:
            with open(claim_file) as f:
                claim_state = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            claim_state = {}

        last_epoch = claim_state.get("last_claimed_epoch", 0)
        current = chain.contract.functions.currentEpoch().call()

        for ep in range(max(1, last_epoch + 1), current):
            receipt = chain.claim_bond(ep)
            if receipt:
                # Historical bond amount from AM's auctionHistory
                bond = chain.am.functions.getBond(ep).call()
                notify_bond_claimed(ntfy, ep, bond / 1e18)
                logger.info("Claimed bond for epoch %d", ep)

        # Persist claim progress (atomic write)
        if current > last_epoch + 1:
            claim_state["last_claimed_epoch"] = current - 1
            fd, tmp = tempfile.mkstemp(dir=str(state_dir), suffix=".tmp")
            try:
                with os.fdopen(fd, "w") as f:
                    json.dump(claim_state, f)
                os.rename(tmp, str(claim_file))
            except Exception:
                try:
                    os.unlink(tmp)
                except OSError:
                    pass
                raise
    except Exception:
        logger.debug("Bond claim check failed (non-critical)", exc_info=True)


# ─── Phase Handlers ─────────────────────────────────────────────────────

def _handle_no_auction(chain, auction, ntfy):
    """No live auction for currentEpoch. Under the 3-phase cyclic model
    this should only happen after FREEZE_SUNSET was set and the fund is
    waiting for migrate() to drain it. Log and return — opening a new
    auction would be a no-op (blocked by sunset) or inappropriate."""
    epoch = auction["epoch"]
    logger.info("Epoch %d has no live auction (sunset state?) — nothing to do", epoch)


def _handle_commit(chain, config, auction, saved, participation, state_dir, ntfy):
    """Commit window is open. Submit a bid if we haven't already."""
    epoch = auction["epoch"]

    # Chain truth: already committed?
    if participation["committed"]:
        logger.info("Already committed for epoch %d (chain-confirmed), waiting for reveal", epoch)
        return

    gas_price = chain.get_gas_price()

    # Balance pre-check: bond + commit gas with 20% headroom. If we can't
    # afford the commit, fail loud BEFORE generating a salt. Otherwise the
    # tx fails with a cryptic web3 stack trace and we still write a half-
    # baked state record on disk. (See incident on 2026-04-14 11:15 UTC.)
    from .auction import GAS_COMMIT  # local import to avoid circular
    bond = chain.get_current_bond()
    required = bond + GAS_COMMIT * gas_price * 12 // 10
    balance = chain.w3.eth.get_balance(chain.account.address)
    if balance < required:
        logger.error("Insufficient funds to commit for epoch %d: have %d wei, "
                     "need ~%d wei (bond=%d, gas headroom=%d)",
                     epoch, balance, required, bond, required - bond)
        if not saved.get("low_balance_notified"):
            notify_low_balance(ntfy, epoch, balance / 1e18, required / 1e18)
            saved["low_balance_notified"] = True
            save_state(saved, state_dir)
        return

    # The AM enforces the snapshotted maxBid (frozen at openAuction), NOT the
    # live fund.effectiveMaxBid. Donations after openAuction don't lift this
    # value for the in-flight auction.
    max_bid = chain.get_auction_max_bid()
    eth_usd = _parse_eth_usd(chain.get_eth_usd_price())

    # Use observed costs if we have enough history
    observed = get_average_costs(state_dir)
    if observed:
        logger.info("Using observed costs: gas=%d, vm=%.1f min (%d epochs)",
                    observed["avg_gas_used"], observed["avg_vm_minutes"], observed["num_epochs"])

    machine_type = config.get("gcp_machine_type", "a3-highgpu-1g")

    # Breakeven check: if even a margin=1.0 bid (zero profit) would exceed the
    # snapshotted cap, no profitable bid exists for this epoch — skip the
    # commit so we don't pay a bond we'll forfeit. Notify once per epoch.
    breakeven = estimate_bid(
        gas_price, machine_type=machine_type,
        eth_usd_price=eth_usd, margin=1.0,
        observed_costs=observed,
    )
    if breakeven > max_bid:
        logger.warning(
            "Skipping commit for epoch %d: breakeven cost %.6f ETH > snapshot cap %.6f ETH",
            epoch, breakeven / 1e18, max_bid / 1e18,
        )
        if not saved.get("uneconomical_notified"):
            notify_epoch_skipped(
                ntfy, epoch,
                f"breakeven {breakeven / 1e18:.6f} ETH > cap {max_bid / 1e18:.6f} ETH "
                f"(treasury too small for profitable bid)",
            )
            saved["uneconomical_notified"] = True
            save_state(saved, state_dir)
        return

    target_bid = estimate_bid(
        gas_price, machine_type=machine_type,
        eth_usd_price=eth_usd, margin=config["bid_margin"],
        observed_costs=observed,
    )
    bid = clamp_bid(target_bid, max_bid)
    logger.info("Bid estimate: %.6f ETH (target=%.6f, cap=%.6f ETH)",
                bid / 1e18, target_bid / 1e18, max_bid / 1e18)

    saved = commit_bid(chain, bid, state_dir=state_dir)
    notify_bid_committed(ntfy, epoch, bid / 1e18)

    # Opportunistic harvest of $COSTANZA fees. Runs on every commit
    # (so multiple competing provers naturally share keeper duty) and
    # routes 98% to the fund. Best-effort — failure here is a benign
    # no-op (see poke_costanza_fees docstring).
    poke_costanza_fees(chain, config.get("costanza_adapter"))


def _handle_reveal(chain, auction, saved, participation, state_dir, ntfy):
    """Reveal window is open. Reveal our bid if possible."""
    epoch = auction["epoch"]

    # Chain truth: did we commit?
    if not participation["committed"]:
        logger.info("Didn't commit for epoch %d, nothing to reveal", epoch)
        return

    # Chain truth: already revealed?
    if participation["revealed"]:
        logger.info("Already revealed for epoch %d (chain-confirmed), waiting for execution", epoch)
        return

    # We committed but haven't revealed. Do we have the salt?
    commit_salt = saved.get("commit_salt")
    bid_amount = saved.get("bid_amount")

    if not commit_salt or bid_amount is None:
        # Salt lost — cannot reveal. Bond will be forfeited.
        logger.warning("Cannot reveal for epoch %d: commit_salt or bid_amount missing "
                       "from local state. Bond will be forfeited.", epoch)
        return

    # Pre-flight: bid must be ≤ AM's snapshotted maxBid. If the cap was
    # smaller than our committed bid (e.g., we read live effectiveMaxBid at
    # commit time but a donation hadn't yet lifted the live value vs. the
    # snapshot), reveal will revert with InvalidParams every cron tick until
    # the window closes and bond forfeits. Notify once and stop trying.
    snapshot_cap = chain.get_auction_max_bid()
    if bid_amount > snapshot_cap:
        if not saved.get("reveal_doomed_notified"):
            logger.error(
                "Reveal will fail for epoch %d: committed bid %.6f ETH > snapshot cap "
                "%.6f ETH. Bond will be forfeited at end of reveal window.",
                epoch, bid_amount / 1e18, snapshot_cap / 1e18,
            )
            notify_reveal_will_fail(ntfy, epoch, bid_amount / 1e18, snapshot_cap / 1e18)
            saved["reveal_doomed_notified"] = True
            save_state(saved, state_dir)
        return

    if reveal_bid(chain, saved):
        saved["revealed"] = True
        save_state(saved, state_dir)
        notify_bid_revealed(ntfy, epoch, bid_amount / 1e18)
    else:
        logger.warning("Reveal failed for epoch %d", epoch)


def _handle_execution(chain, config, auction, saved, participation, state_dir, ntfy):
    """Execution window is open."""
    epoch = auction["epoch"]

    # If the epoch was already executed successfully (we or someone else
    # submitted), there's nothing to do — the next syncPhase will cross
    # the EXECUTION→COMMIT boundary when wall-clock permits.
    if auction["executed"]:
        logger.info("Epoch %d already executed, waiting for next epoch", epoch)
        return

    # Case 1: No winner at all (nobody committed/revealed)
    if participation["winner"] == ZERO_ADDR:
        logger.info("No winner for epoch %d, advancing past stale epoch", epoch)
        _try_advance(chain, ntfy)
        return

    # Case 2: We didn't win
    if not participation["won"]:
        logger.info("Lost auction for epoch %d to %s...", epoch, participation["winner"][:10])
        if not saved.get("loss_notified"):
            notify_auction_lost(ntfy, epoch, participation["winner"])
            saved["loss_notified"] = True
            save_state(saved, state_dir)
        return

    # Case 3: We won!

    # Recovery path: if local state is empty (e.g. operator wiped state mid-
    # execution to apply a hot fix, or we're restarting from a crash), we
    # need to populate `saved` with at least `epoch` so subsequent saves
    # don't write a stub `{won_notified: true}` record that load_state
    # would discard on the next tick. Re-derive bid_amount from the on-
    # chain bid record where possible (purely advisory — submission only
    # needs the TEE result).
    if not saved.get("epoch"):
        logger.info("Local state empty for epoch %d but chain says we won — "
                    "recovering from on-chain record", epoch)
        saved["epoch"] = epoch
        saved["committed"] = True
        saved["revealed"] = True
        bid_record = chain.get_my_bid_record(epoch)
        if bid_record and bid_record["bid_amount"] > 0:
            saved["bid_amount"] = bid_record["bid_amount"]
            logger.info("Recovered bid_amount from chain: %.6f ETH", bid_record["bid_amount"] / 1e18)
        save_state(saved, state_dir)

    # Check if we already failed permanently
    if saved.get("submission_failed"):
        logger.info("Submission previously failed for epoch %d, waiting for epoch to expire", epoch)
        return

    # Check retry limit
    attempts = saved.get("submission_attempts", 0)
    if attempts >= MAX_SUBMIT_RETRIES:
        logger.warning("Max submission retries (%d) exhausted", MAX_SUBMIT_RETRIES)
        saved["submission_failed"] = True
        save_state(saved, state_dir)
        notify_epoch_abandoned(ntfy, epoch, f"Max retries ({MAX_SUBMIT_RETRIES}) exhausted")
        return

    # Notify win (once)
    if not saved.get("won_notified"):
        bounty_wei = auction["winning_bid"]
        logger.info("WE WON the auction! (bounty: %.6f ETH)", bounty_wei / 1e18)
        notify_auction_won(ntfy, epoch, bounty_wei / 1e18)
        saved["won_notified"] = True
        save_state(saved, state_dir)

    # Determine retry strategy for this attempt
    strategy, min_time = RETRY_SCHEDULE[min(attempts, len(RETRY_SCHEDULE) - 1)]
    time_remaining = auction["exec_end"] - auction["now"]

    if time_remaining < min_time:
        logger.warning("Only %ds left in execution window (need %ds for %s), skipping",
                       time_remaining, min_time, strategy)
        return

    # If strategy says rerun TEE, discard cached result so we get a fresh
    # attestation quote (same deterministic output, different DCAP nonce).
    if strategy == RERUN_TEE and attempts > 0:
        if saved.get("tee_completed"):
            logger.info("Discarding cached TEE result for fresh attestation quote (attempt %d)", attempts)
            saved.pop("tee_completed", None)
            saved.pop("tee_result_path", None)
            save_state(saved, state_dir)

    # Sync phase to capture seed (REVEAL → EXECUTION transition)
    sync_phase(chain)

    # Re-read auction state after sync — seed is now captured.
    # IMPORTANT: after a reveal-close tx mines, the state RPC may still return
    # the pre-tx view for a short window (Alchemy node-to-RPC consistency lag).
    # Polling until seed != 0 defends against passing seed=0 to the enclave,
    # which would produce a REPORTDATA that doesn't match the contract's
    # computed input_hash and fails on-chain verification.
    auction = chain.get_auction_state()
    max_wait = 30  # seconds
    poll_start = time.time()
    while auction["randomness_seed"] == 0 and time.time() - poll_start < max_wait:
        logger.info("Post-sync seed still 0 (stale read), retrying in 2s...")
        time.sleep(2)
        auction = chain.get_auction_state()

    if auction["randomness_seed"] == 0:
        # Seed is genuinely 0 on chain — this means sync_phase didn't close
        # reveal (e.g. we're still in the reveal window per wall-clock). Bail;
        # we'll retry on the next cron tick.
        logger.warning("Post-sync seed is 0 after %ds poll — reveal window hasn't "
                       "closed yet. Bailing until next tick.", max_wait)
        return

    logger.info("Post-sync: epoch=%d, phase=%d, seed=%d",
                auction["epoch"], auction["contract_phase"], auction["randomness_seed"])

    # Run TEE inference (loads cached result if available, runs fresh otherwise)
    tee_result = _run_tee_inference(chain, config, auction, saved, state_dir)

    # Submit on-chain
    _submit_result(chain, config, tee_result, auction, saved, state_dir, ntfy)


def _handle_epoch_over(chain, auction, saved, participation, state_dir, ntfy):
    """All windows have passed. Detect bond forfeiture and advance epoch."""
    epoch = auction["epoch"]

    # Chain truth: detect bond forfeiture
    if participation["committed"] and not participation["revealed"]:
        bond = auction["bond_amount"]
        if bond > 0 and not saved.get("forfeit_notified"):
            logger.warning("BOND FORFEITED for epoch %d (committed but missed reveal)", epoch)
            notify_bond_forfeited(ntfy, epoch, bond / 1e18)
            saved["forfeit_notified"] = True
            save_state(saved, state_dir)

    # Advance past the expired epoch
    if _try_advance(chain, ntfy):
        clear_state(state_dir)
        logger.info("Epoch %d expired, advanced past it", epoch)
        notify_epoch_settled(ntfy, epoch)
    else:
        logger.info("Cannot advance epoch yet")


# ─── TEE Inference & Submission ─────────────────────────────────────────

def _run_tee_inference(chain, config, auction, saved, state_dir):
    """Load cached TEE result or run fresh inference."""
    epoch = auction["epoch"]

    # Try cached result first
    if saved.get("tee_completed") and saved.get("tee_result_path"):
        tee_result = load_tee_result(saved["tee_result_path"])
        if tee_result:
            logger.info("Loaded cached TEE result from %s", saved["tee_result_path"])
            return tee_result
        logger.warning("Cached TEE result missing/corrupt, re-running inference")
        saved.pop("tee_completed", None)
        saved.pop("tee_result_path", None)

    logger.info("Starting TEE inference for epoch %d...", auction["epoch"])
    # Pin to the auction's epoch — don't let a syncPhase advance cause us
    # to read the wrong epoch's snapshot (especially with MockVerifier
    # which won't catch hash mismatches).
    epoch_state = chain.read_contract_state(epoch=auction["epoch"])

    prompt_path = Path(config["system_prompt_path"])
    system_prompt = prompt_path.read_text().strip()

    seed = auction["randomness_seed"]
    logger.info("Seed: %d", seed)

    tee_client = get_tee_client(config)
    tee_result = tee_client.run_epoch(
        epoch_state=epoch_state,
        system_prompt=system_prompt,
        seed=seed,
    )
    logger.info("TEE inference complete (%.1f min)", tee_result.get("vm_minutes", 0))
    logger.info("Action: %s", tee_result.get("action", {}).get("action", "unknown"))

    # Cache for retry
    result_path = save_tee_result(tee_result, epoch, state_dir)
    saved["tee_completed"] = True
    saved["tee_result_path"] = result_path
    save_state(saved, state_dir)

    return tee_result


def _submit_result(chain, config, tee_result, auction, saved, state_dir, ntfy):
    """Submit TEE result on-chain."""
    epoch = auction["epoch"]
    attempts = saved.get("submission_attempts", 0)

    action_bytes = bytes.fromhex(tee_result["action_bytes"].replace("0x", ""))
    reasoning_bytes = tee_result["reasoning"].encode("utf-8")
    attestation_bytes = bytes.fromhex(tee_result["attestation_quote"].replace("0x", ""))

    # Memory updates come from the enclave's canonical, pre-validated
    # `submitted_memory` field — the SAME bytes the enclave hashed into
    # REPORTDATA. Reading any other source (e.g. tee_result["action"]
    # ["memory"]) would let a compromised client substitute updates the
    # enclave never produced; the static analyzer in
    # prover/enclave/test_output_coverage.py enforces this invariant.
    raw_mem = tee_result.get("submitted_memory", [])
    memory_updates = []
    if isinstance(raw_mem, list):
        for entry in raw_mem:
            if not isinstance(entry, dict):
                continue
            try:
                slot = int(entry.get("slot"))
            except (TypeError, ValueError):
                continue
            if slot < 0 or slot > 9:
                continue
            title = str(entry.get("title", ""))[:64]
            body = str(entry.get("body", ""))[:280]
            memory_updates.append((slot, title, body))
        # Belt-and-suspenders: contract caps at 3. Enclave already clamped.
        memory_updates = memory_updates[:3]

    # Action name for notification — derive from the FIRST byte of action_bytes
    # rather than tee_result["action"], so notifications can't be swayed by a
    # compromised client substituting the action JSON. action_bytes IS attested.
    action_name = _ACTION_NAMES.get(action_bytes[0], "?") if action_bytes else "?"

    verifier_id = config["verifier_id"]
    logger.info("Submitting result (verifier=%d, memory_updates=%d, attempt=%d/%d)...",
               verifier_id, len(memory_updates), attempts + 1, MAX_SUBMIT_RETRIES)

    try:
        receipt = submit_result(
            chain,
            action_bytes=action_bytes,
            reasoning=reasoning_bytes,
            proof=attestation_bytes,
            verifier_id=verifier_id,
            memory_updates=memory_updates,
        )
        logger.info("Result submitted! tx=%s", receipt['transactionHash'].hex())

        # Record actual costs — success=True means bounty was paid
        gas_used = receipt.get("gasUsed", 0)
        gas_price = receipt.get("effectiveGasPrice", chain.get_gas_price())
        vm_minutes = tee_result.get("vm_minutes", 0)
        record_epoch_cost(state_dir, epoch, gas_used, gas_price, vm_minutes, success=True)
        logger.info("Recorded cost (success): gas=%d, vm=%.1f min", gas_used, vm_minutes)

        clear_state(state_dir)
        notify_result_submitted(ntfy, epoch, action_name)

        # Opportunistic harvest of $COSTANZA fees right after a
        # successful submit. Once-per-epoch cadence, runner gets a 2%
        # tip as gas subsidy. Best-effort; revert here doesn't undo
        # the successful submit.
        poke_costanza_fees(chain, config.get("costanza_adapter"))
    except SubmissionError as e:
        saved["submission_attempts"] = attempts + 1
        if not e.should_retry or saved["submission_attempts"] >= MAX_SUBMIT_RETRIES:
            saved["submission_failed"] = True
            save_state(saved, state_dir)
            logger.error("Submission permanently failed [%s]: %s", e.category, e)
            notify_epoch_abandoned(ntfy, epoch, f"{e.category}: {e}")
            # Record failed run cost (VM was booted, compute was spent)
            vm_minutes = tee_result.get("vm_minutes", 0)
            record_epoch_cost(state_dir, epoch, 0, 0, vm_minutes, success=False)
        else:
            save_state(saved, state_dir)
            logger.warning("Submission failed [%s], will retry (%d/%d): %s",
                          e.category, saved["submission_attempts"], MAX_SUBMIT_RETRIES, e)
            notify_submission_failed(ntfy, epoch, e, saved["submission_attempts"], MAX_SUBMIT_RETRIES)


# ─── Main Entry Point ───────────────────────────────────────────────────

def run(config):
    """Main runner logic — chain truth + wall-clock dispatch."""
    chain = ChainClient(config["rpc_url"], config["private_key"], config["contract_address"])
    ntfy = config["ntfy_channel"]
    state_dir = config["state_dir"]

    # 1. Read chain state (source of truth)
    auction = chain.get_auction_state()
    epoch = auction["epoch"]
    contract_phase = auction["contract_phase"]
    clock_phase = _resolve_phase(auction)

    # When the owner calls nextPhase() to advance manually, the contract
    # can be ahead of the wall-clock. Trust whichever is further along.
    # The AM phase is one of COMMIT(0) / REVEAL(1) / EXECUTION(2);
    # "epoch_over" is a wall-clock state meaning "past the execution
    # deadline" — the AM will still be at EXECUTION until someone drives
    # _closeExecution.
    CONTRACT_TO_EFFECTIVE = {0: "commit", 1: "reveal", 2: "execution"}
    PHASE_ORDER = {"commit": 0, "reveal": 1, "execution": 2, "epoch_over": 3}
    contract_effective = CONTRACT_TO_EFFECTIVE.get(contract_phase, "commit")

    if PHASE_ORDER.get(contract_effective, 0) > PHASE_ORDER.get(clock_phase, 0):
        effective_phase = contract_effective
        logger.info("Epoch %d | Contract: %s | Clock: %s - using contract (ahead)",
                    epoch, PHASE_NAMES.get(contract_phase, str(contract_phase)), clock_phase)
    else:
        effective_phase = clock_phase
        logger.info("Epoch %d | Contract: %s | Clock: %s",
                    epoch, PHASE_NAMES.get(contract_phase, str(contract_phase)), clock_phase)

    # 2. Load local state (advisory only — may be empty)
    saved = load_state(state_dir, current_epoch=epoch)

    # 3. Query chain for our participation (source of truth)
    participation = chain.check_participation(epoch)
    logger.info("Participation: committed=%s revealed=%s won=%s",
                participation["committed"], participation["revealed"], participation["won"])

    # 4. Detect irrecoverable salt loss early
    if participation["committed"] and not saved.get("commit_salt"):
        if not participation["revealed"]:
            bond = auction["bond_amount"]
            logger.warning("SALT LOST: committed on-chain but no local salt. "
                          "Bond of %.6f ETH will be forfeited.", bond / 1e18)
            if not saved.get("salt_loss_notified"):
                notify_bond_forfeited(ntfy, epoch, bond / 1e18)
                saved["salt_loss_notified"] = True
                save_state(saved, state_dir)

    # 5. Claim any owed bonds (cheap, best-effort)
    _try_claim_bonds(chain, ntfy, state_dir)

    # 6. Dispatch based on wall-clock phase
    if effective_phase == "no_auction":
        _handle_no_auction(chain, auction, ntfy)
    elif effective_phase == "commit":
        _handle_commit(chain, config, auction, saved, participation, state_dir, ntfy)
    elif effective_phase == "reveal":
        _handle_reveal(chain, auction, saved, participation, state_dir, ntfy)
    elif effective_phase == "execution":
        _handle_execution(chain, config, auction, saved, participation, state_dir, ntfy)
    elif effective_phase == "epoch_over":
        _handle_epoch_over(chain, auction, saved, participation, state_dir, ntfy)


def main():
    logging.basicConfig(
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        level=logging.INFO,
    )

    config = load_config()

    # Acquire exclusive lock (skip with --no-lock for Docker on macOS)
    lock_fd = None
    if not config.get("no_lock"):
        lock_path = Path(config["state_dir"]) / ".runner.lock"
        lock_path.parent.mkdir(parents=True, exist_ok=True)
        lock_fd = open(lock_path, "w")
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            logger.info("Another runner instance is active, exiting")
            sys.exit(0)

    try:
        run(config)
    except Exception as e:
        logger.error("Runner failed: %s", e, exc_info=True)
        error_name = _match_error(str(e))
        if error_name:
            msg = f"Contract error: {error_name} — {str(e)[:200]}"
        else:
            msg = str(e)
        notify_error(config.get("ntfy_channel"), "?", msg)
        sys.exit(1)
    finally:
        if lock_fd:
            lock_fd.close()


if __name__ == "__main__":
    main()
