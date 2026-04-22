#!/usr/bin/env python3
"""Output coverage tests — static guarantees that every enclave-produced
field the client treats as trusted is bound into the TDX REPORTDATA.

Symmetric to `test_hash_coverage.py`. That test asserts every prompt field
shown to the model is included in the input hash; this one asserts every
field of the enclave's output that the client submits to the contract as
a trusted value is included in the output hash bound by REPORTDATA.

The single most important invariant on the OUTPUT side:

    For every field of the enclave's `result` dict that the client reads
    in `_submit_result` and forwards (directly or via simple transforms)
    into a contract-call argument, that field's value MUST be bound into
    REPORTDATA via `compute_report_data`. Otherwise a malicious prover
    client could substitute its own value between enclave output and
    submission, and the DCAP verification would still pass — bypassing
    the entire TEE attestation guarantee for that field.

The walker compares two sets:

  - SUBMITTED: top-level keys of `tee_result` consumed by
    `prover/client/client.py::_submit_result`. Extracted via the same AST
    walker that backs `test_hash_coverage.py` (handles `.get()`, aliasing,
    `or` chains, and the `tee_result["action"]["worldview"]` nested path
    that the worldview sidecar currently flows through).

  - ATTESTED: top-level keys of `result = {...}` in
    `prover/enclave/enclave_runner.py::main` whose value expressions
    reference any local variable that's also passed as an argument to
    `compute_report_data(...)`. This identifies which fields of the
    serial-console output are bound into REPORTDATA.

  - EXEMPT_FROM_ATTESTATION: keys the client reads but explicitly does
    NOT submit as trusted on-chain values. Currently:
       * "attestation_quote" — the DCAP quote IS the attestation (signing,
         not signed).
       * "vm_minutes" — client-side telemetry injected after the enclave
         finishes, used only for local cost accounting; never an enclave
         output and never sent to the contract.

  Assertion: SUBMITTED − EXEMPT_FROM_ATTESTATION ⊆ ATTESTED.

If this fails, the failure message names the leaking field and the
remediation steps (extend `compute_report_data`, update the contract's
`outputHash`, add to the cross-stack test).

Run: `python -m pytest prover/enclave/test_output_coverage.py -v`
"""

import ast
from pathlib import Path
from typing import Dict, Set

from .test_hash_coverage import extract_state_reads


_HERE = Path(__file__).resolve().parent
_REPO = _HERE.parent.parent  # .../<worktree>
_CLIENT = _REPO / "prover" / "client" / "client.py"
_ENCLAVE_RUNNER = _HERE / "enclave_runner.py"
_ATTESTATION = _HERE / "attestation.py"


# Top-level `tee_result` keys the client reads but that don't need to be
# bound into REPORTDATA. Each entry MUST come with a comment justifying
# why it's safe — adding to this set is a deliberate act.
EXEMPT_FROM_ATTESTATION: Set[str] = {
    # The DCAP attestation quote itself — the signing, not a signed
    # value. Submitted as the `proof` argument; the contract verifies
    # the quote against REPORTDATA, which is what binds the rest.
    "attestation_quote",
    # Wall-clock VM lifetime injected by the GCP TEE client AFTER the
    # enclave's serial output is parsed. Never an enclave output, never
    # sent to the contract — used only for local cost accounting via
    # `record_epoch_cost`.
    "vm_minutes",
}


# ─── SUBMITTED set: tee_result fields the client treats as trusted ─────

def _submitted_top_level_keys() -> Set[str]:
    """Top-level keys of `tee_result` that `_submit_result` reads.

    Reuses the AST walker from test_hash_coverage.py with `tee_result` as
    the tainted root. The walker emits dotted paths like `action.worldview`
    when the client extracts a nested field via `.get()` or subscript;
    we collapse to top-level keys because that's the granularity at which
    `result = {...}` is constructed in the enclave.
    """
    paths = extract_state_reads(
        _CLIENT, "_submit_result", state_param="tee_result"
    )
    keys: Set[str] = set()
    for p in paths:
        # Strip element brackets and take the first dotted segment.
        head = p.split(".", 1)[0].split("[", 1)[0]
        if head:
            keys.add(head)
    return keys


# ─── ATTESTED set: result keys whose values are bound into REPORTDATA ──

def _attested_result_keys() -> Set[str]:
    """Top-level keys of the `result = {...}` literal in
    enclave_runner.main whose value expressions reference at least one
    variable that's also passed as an argument to `compute_report_data(...)`.

    Conservative: any reference counts (even inside a transform like
    `.hex()` or string concat). A pure transform of an attested value is
    still attested for our purposes — the value the client receives is
    deterministically derived from the attested bytes.
    """
    tree = ast.parse(_ENCLAVE_RUNNER.read_text())

    main_func = None
    for node in ast.walk(tree):
        if isinstance(node, ast.FunctionDef) and node.name == "main":
            main_func = node
            break
    if main_func is None:
        raise LookupError("enclave_runner.py: function `main` not found")

    # Step 1: collect simple-name args to compute_report_data(...).
    attested_vars: Set[str] = set()
    for node in ast.walk(main_func):
        if not isinstance(node, ast.Call):
            continue
        f = node.func
        is_target = (
            (isinstance(f, ast.Name) and f.id == "compute_report_data")
            or (isinstance(f, ast.Attribute) and f.attr == "compute_report_data")
        )
        if not is_target:
            continue
        for arg in node.args:
            if isinstance(arg, ast.Name):
                attested_vars.add(arg.id)
        for kw in node.keywords:
            if isinstance(kw.value, ast.Name):
                attested_vars.add(kw.value.id)

    if not attested_vars:
        raise AssertionError(
            "compute_report_data(...) call not found in enclave_runner.main "
            "or invoked with non-name arguments — extend the walker"
        )

    # Step 2: find `result = { ... }` dict literal assignments and check
    # which keys reference any attested var in their value expression.
    attested_keys: Set[str] = set()
    for node in ast.walk(main_func):
        if not isinstance(node, ast.Assign):
            continue
        if not (len(node.targets) == 1
                and isinstance(node.targets[0], ast.Name)
                and node.targets[0].id == "result"
                and isinstance(node.value, ast.Dict)):
            continue
        for k_node, v_node in zip(node.value.keys, node.value.values):
            if not (isinstance(k_node, ast.Constant)
                    and isinstance(k_node.value, str)):
                # Non-literal key — skip (would need extension).
                continue
            for sub in ast.walk(v_node):
                if isinstance(sub, ast.Name) and sub.id in attested_vars:
                    attested_keys.add(k_node.value)
                    break

    if not attested_keys:
        raise AssertionError(
            "No `result = {...}` dict literal found in enclave_runner.main, "
            "or none of its values reference attested vars — extend the walker"
        )

    return attested_keys


# ─── Backward contribution trace through compute_report_data ──────────

def _find_function(source: Path, name: str) -> ast.FunctionDef:
    """Return the top-level function definition with the given name."""
    tree = ast.parse(source.read_text())
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return node
    raise LookupError(f"{source}: function `{name}` not found")


def _params_contributing_to_return(func: ast.FunctionDef) -> Set[str]:
    """Subset of `func`'s parameters whose values transitively reach a return.

    Backward trace:
      1. Walk all `name = expr` assignments in the body, recording the set
         of names referenced in each RHS.
      2. Seed a contributor set from every name appearing in any `return expr`.
      3. Fixed-point: anything an existing contributor depends on (per the
         assignment map) is also a contributor.
      4. Intersect with the function's declared parameters.

    Conservative (over-approximates contribution) and linear-only — doesn't
    track scope-shadowing inside loops/conditionals as separate flows. That
    means a param referenced only inside a dead branch would still be
    classified as a contributor, which is the safe direction (false
    positives are stricter, not laxer).
    """
    # 1. Collect linear assignments
    assignments: Dict[str, Set[str]] = {}
    for node in ast.walk(func):
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            tgt = node.targets[0]
            if isinstance(tgt, ast.Name):
                deps = {n.id for n in ast.walk(node.value) if isinstance(n, ast.Name)}
                # Combine with any prior assignment to the same name (over-
                # approximate: a name re-bound across branches contributes
                # the union of its possible RHS deps).
                assignments.setdefault(tgt.id, set()).update(deps)
        elif isinstance(node, ast.AugAssign) and isinstance(node.target, ast.Name):
            # `name += expr` — both `name` (prior value) and `expr` deps contribute.
            deps = {n.id for n in ast.walk(node.value) if isinstance(n, ast.Name)}
            deps.add(node.target.id)
            assignments.setdefault(node.target.id, set()).update(deps)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.value is not None:
            deps = {n.id for n in ast.walk(node.value) if isinstance(n, ast.Name)}
            assignments.setdefault(node.target.id, set()).update(deps)

    # 2. Seed contributors from return expressions
    contributors: Set[str] = set()
    for node in ast.walk(func):
        if isinstance(node, ast.Return) and node.value is not None:
            contributors.update(
                n.id for n in ast.walk(node.value) if isinstance(n, ast.Name)
            )

    # 3. Fixed-point expansion via assignment dependencies
    changed = True
    while changed:
        changed = False
        for name in list(contributors):
            for dep in assignments.get(name, ()):
                if dep not in contributors:
                    contributors.add(dep)
                    changed = True

    # 4. Intersect with declared parameters
    params = {a.arg for a in func.args.args}
    return params & contributors


# ─── The invariant ────────────────────────────────────────────────────

def test_submitted_fields_are_all_attested():
    """Every tee_result field the client submits as trusted MUST be bound
    into REPORTDATA via compute_report_data.

    If a field slips into the submission path without being attested, a
    malicious prover client can substitute its own value between enclave
    output and contract submission. The DCAP verification still passes
    (because it's against the unmodified attested bytes), and the contract
    accepts the substituted value as if it came from the TEE. This
    completely undermines the integrity of the affected field.

    Concrete example caught by this test today: the worldview sidecar
    (`tee_result["action"]["worldview"]`) is consumed as
    `worldview_updates` in the submission call, but `compute_report_data`
    only takes `(input_hash, action_bytes, reasoning)`. A compromised
    prover can therefore strip the model's worldview updates or inject
    arbitrary policy text — persistent prompt injection that survives
    across epochs because worldview is the agent's only cross-epoch memory.
    """
    submitted = _submitted_top_level_keys()
    attested = _attested_result_keys()
    leaked = submitted - attested - EXEMPT_FROM_ATTESTATION

    assert not leaked, (
        "client._submit_result reads tee_result fields that are NOT bound "
        "into REPORTDATA via compute_report_data:\n\n  "
        + "\n  ".join(sorted(leaked))
        + "\n\nA prover client could substitute its own value for these "
        "fields between enclave output and contract submission, and the "
        "DCAP attestation would still verify. Either:\n"
        "  (a) bind the field into REPORTDATA — extend "
        "compute_report_data() to take it as an argument, update "
        "TheHumanFund.submitAuctionResult's outputHash computation "
        "symmetrically, and add a CrossStackHash test; OR\n"
        "  (b) stop reading the field in _submit_result; OR\n"
        "  (c) add it to EXEMPT_FROM_ATTESTATION with a comment "
        "explaining why on-chain trust isn't required (e.g. it IS the "
        "attestation quote itself, or it's client-side telemetry).\n\n"
        f"Attested keys ({len(attested)}): {sorted(attested)}\n"
        f"Submitted keys ({len(submitted)}): {sorted(submitted)}\n"
        f"Exempt: {sorted(EXEMPT_FROM_ATTESTATION)}"
    )


def test_compute_report_data_uses_all_params():
    """Every parameter of `compute_report_data` MUST contribute to its
    returned REPORTDATA value.

    Without this check, `test_submitted_fields_are_all_attested` could pass
    while a parameter's value is silently dropped before hashing — the
    parameter is in ATTESTED_VARS at the call site, but the function body
    doesn't actually fold it into the returned bytes. A malicious prover
    client could then substitute the corresponding `tee_result` field and
    on-chain DCAP verification would still pass, because REPORTDATA was
    computed without that field.

    Pathological example caught here:

        def compute_report_data(input_hash, action_bytes, reasoning,
                                submitted_worldview):
            output_hash = sha256(action_bytes + reasoning)  # forgot worldview
            return sha256(input_hash + output_hash).ljust(64, b'\\x00')

    `submitted_worldview` is declared but never referenced — backward
    trace from `return` doesn't reach it, so it's flagged.
    """
    func = _find_function(_ATTESTATION, "compute_report_data")
    declared = {a.arg for a in func.args.args}
    contributing = _params_contributing_to_return(func)
    orphaned = declared - contributing
    assert not orphaned, (
        f"compute_report_data declares parameters that don't reach the "
        f"returned REPORTDATA value:\n\n  "
        + "\n  ".join(sorted(orphaned))
        + "\n\nThese parameters appear in the function signature (and are "
        "therefore picked up by `_attested_result_keys` as 'attested'), but "
        "the backward trace from `return` doesn't include them. The value "
        "is silently dropped before hashing — substitutable by a malicious "
        "prover client.\n\nFix: include the parameter in the bytes that "
        "flow into the returned hash, e.g.:\n"
        "    output_hash = keccak256(sha256(action) || sha256(reasoning) "
        "|| keccak256(<param>))\n"
        "and update TheHumanFund.submitAuctionResult's outputHash "
        "computation symmetrically. Add a CrossStackHash test that exercises "
        "the new field on both sides.\n\n"
        f"Declared params: {sorted(declared)}\n"
        f"Contributing params: {sorted(contributing)}"
    )
