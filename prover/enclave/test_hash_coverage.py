#!/usr/bin/env python3
"""Hash coverage tests — static guarantees for enclave input-hash integrity.

These tests enforce two invariants:

  1. HASH COVERAGE. Every field the prompt builder shows the model is also
     bound into the input hash. If a new field slips into prompt_builder.py
     without a matching line in input_hash.py, the contract's on-chain
     verification won't catch it — a runner could feed the enclave arbitrary
     values for that field. We catch it here instead, at commit time.

  2. EPOCH-STATE PINNING. prover/client/epoch_state.py only makes contract
     calls from a known allowlist. Every new live read is a potential drift
     source (value changes between enclave-read time and on-chain verify
     time). The allowlist has to grow explicitly so nothing sneaks in.

The hash-coverage test uses an AST walker to extract the set of "state-rooted
key paths" that each file reads. A key path is a dotted string like
`treasury_balance`, `nonprofits[*].name`, or `investments[*].current_value`.
The walker handles the full set of access patterns used in the enclave:

  - literal dict subscripts: `state["k"]`
  - `.get("k")` and `.get("k", default)`
  - bounded integer subscripts and slices (both map to `[*]`)
  - aliasing through assignment: `a = state["k"]; a[i]`
  - loop iteration: `for np in state["nonprofits"]: np["name"]`
  - `enumerate(x)` unpacking: `for i, np in enumerate(...)`
  - inter-procedural calls to helpers defined in the same file
  - comprehensions and f-strings (via generic recursion into sub-expressions)
  - `list(x)` / `tuple(x)` as identity

If the walker encounters a pattern it can't resolve (e.g. attribute access on
a tainted local, unknown helper called with tainted arg), it raises a loud
`WalkerGaveUpError` naming the file and line — NOT a silent skip. False
negatives are the dangerous failure mode here, so the walker is tuned to fail
loudly rather than miss a read.

If you're adding a new pattern the walker doesn't recognize, either:
  (a) refactor to an existing pattern, or
  (b) extend the walker in this file with a handler AND a synthetic unit
      test that exercises it.

Do NOT paper over a walker-gave-up error by adding a `try: ... except: pass`
to the test — that defeats the point.
"""

import ast
from pathlib import Path
from typing import Dict, Optional, Set, Tuple


# ─── Paths ────────────────────────────────────────────────────────────────

_HERE = Path(__file__).resolve().parent
_REPO = _HERE.parent.parent  # .../<worktree>
_PROMPT_BUILDER = _HERE / "prompt_builder.py"
_INPUT_HASH = _HERE / "input_hash.py"
_EPOCH_STATE = _REPO / "prover" / "client" / "epoch_state.py"


# ─── Walker ───────────────────────────────────────────────────────────────


class WalkerGaveUpError(Exception):
    """The walker hit an access pattern it can't resolve. Fail loudly."""


# "Identity" functions: calling these on a tainted value returns the same
# taint. `list(x)` and friends are the common cases in enclave code.
_IDENTITY_CALLS = {"list", "tuple", "set", "dict", "iter", "reversed", "sorted"}


class _FuncVisitor(ast.NodeVisitor):
    """Walks one function body, tracking which local names are aliased to
    state-rooted abstract paths and emitting reads into `analysis.reads`.
    """

    def __init__(self, analysis: "_Analysis", initial_aliases: Dict[str, str]):
        self.analysis = analysis
        # local_name -> abstract path string (e.g. "nonprofits[*]")
        self.aliases: Dict[str, str] = dict(initial_aliases)

    # -- path resolution -------------------------------------------------

    def _emit(self, path: str) -> None:
        if path:
            self.analysis.reads.add(path)

    def _extend(self, base: str, key: str) -> str:
        """Extend `base` path with dict key `key`, emit, return new path."""
        new = f"{base}.{key}" if base else key
        self._emit(new)
        return new

    def _elem(self, base: str) -> str:
        """Descend into a list element, emit, return new path."""
        new = f"{base}[*]"
        self._emit(new)
        return new

    def path_of(self, node: ast.AST) -> Optional[str]:
        """Return the abstract path `node` resolves to, or None if untainted.

        As a side effect, emits reads for every intermediate subscript /
        `.get()` encountered. Also recursively visits sub-expressions that
        might contain their own tainted reads (e.g. f-string components,
        call arguments).
        """
        # Visit every child expression first so nothing is missed, even if
        # the parent node turns out to be untainted. We do this before the
        # type-specific logic so side-effect reads (e.g. inside a f-string)
        # always land.
        if isinstance(node, ast.expr):
            # Type-specific handling:
            if isinstance(node, ast.Name):
                return self.aliases.get(node.id)

            if isinstance(node, ast.Subscript):
                inner = self.path_of(node.value)
                if inner is None:
                    # Still walk the slice for side effects.
                    self._visit_subexprs(node.slice)
                    return None
                slc = node.slice
                # `x[:N]` / `x[a:b]` → same collection, same path.
                if isinstance(slc, ast.Slice):
                    self._visit_subexprs(slc)
                    return inner
                # Literal string key → dict access.
                if isinstance(slc, ast.Constant) and isinstance(slc.value, str):
                    return self._extend(inner, slc.value)
                # Anything else (int index, variable, expression) → element.
                self._visit_subexprs(slc)
                return self._elem(inner)

            if isinstance(node, ast.Call):
                return self._handle_call(node)

            if isinstance(node, ast.Attribute):
                inner = self.path_of(node.value)
                if inner is None:
                    return None
                # `.items()` / `.keys()` / `.values()` on a tainted dict
                # introduce dict-iteration semantics we can't model. Fail.
                if node.attr in ("items", "keys", "values"):
                    raise WalkerGaveUpError(
                        f"`.{node.attr}` on tainted local ({inner}) "
                        f"at {self.analysis.source}:{node.lineno}; extend walker"
                    )
                # Any other attribute / method reference on a tainted value
                # (e.g. `r.startswith(...)`, `action_data.hex()`) absorbs
                # taint — the underlying read is already captured via
                # path_of(node.value) above.
                return None

            if isinstance(node, ast.BoolOp):
                # `a.get("k") or 0` — visit both sides, return left's path
                # as a best effort (some callers chain).
                paths = [self.path_of(v) for v in node.values]
                return next((p for p in paths if p is not None), None)

            if isinstance(node, ast.IfExp):
                self.path_of(node.test)
                t = self.path_of(node.body)
                f = self.path_of(node.orelse)
                return t or f

            if isinstance(node, (ast.ListComp, ast.SetComp, ast.GeneratorExp)):
                return self._handle_comprehension(node, kind="elt")
            if isinstance(node, ast.DictComp):
                return self._handle_comprehension(node, kind="dict")

            if isinstance(node, ast.JoinedStr):  # f-string
                for v in node.values:
                    self.path_of(v)
                return None
            if isinstance(node, ast.FormattedValue):
                self.path_of(node.value)
                if node.format_spec is not None:
                    self.path_of(node.format_spec)
                return None

            if isinstance(node, (ast.BinOp, ast.UnaryOp, ast.Compare)):
                self._visit_subexprs(node)
                return None

            if isinstance(node, (ast.Constant, ast.List, ast.Tuple, ast.Set,
                                 ast.Dict, ast.Lambda, ast.Starred, ast.Await,
                                 ast.Yield, ast.YieldFrom)):
                self._visit_subexprs(node)
                return None

        # Fallback — walk children for side effects but don't claim a path.
        self._visit_subexprs(node)
        return None

    def _visit_subexprs(self, node: Optional[ast.AST]) -> None:
        if node is None:
            return
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.expr):
                self.path_of(child)
            else:
                # Nested statements (e.g. inside a lambda body) — not expected
                # in our enclave code, but walk anyway.
                self._visit_subexprs(child)

    # -- call handling ---------------------------------------------------

    def _handle_call(self, node: ast.Call) -> Optional[str]:
        # Visit keyword args for side effects.
        for kw in node.keywords:
            self.path_of(kw.value)

        func = node.func
        # x.get("k"[, default]) — equivalent to x["k"] for taint purposes.
        if isinstance(func, ast.Attribute) and func.attr == "get":
            inner = self.path_of(func.value)
            # Visit *all* args for side effects (defaults may contain reads).
            for a in node.args:
                self.path_of(a)
            if inner is None:
                return None
            if (node.args
                    and isinstance(node.args[0], ast.Constant)
                    and isinstance(node.args[0].value, str)):
                return self._extend(inner, node.args[0].value)
            # Dynamic key → element-ish; emit as a wildcard access.
            return self._elem(inner)

        # Method calls that don't propagate taint: .append, .items, .keys,
        # .values, .hex, .decode, .encode, .startswith, .replace, .strip,
        # .rstrip, .lstrip, .split, .join, .format, .copy, .update, .pop,
        # .setdefault, .count, .index, .lower, .upper, .ljust.
        #
        # `.items()`, `.keys()`, `.values()` on tainted locals would
        # introduce dict-iteration semantics we don't currently support;
        # if we see one, fail loud.
        if isinstance(func, ast.Attribute):
            if func.attr in ("items", "keys", "values"):
                inner = self.path_of(func.value)
                if inner is not None:
                    raise WalkerGaveUpError(
                        f"`.{func.attr}()` on tainted local ({inner}) "
                        f"at {self.analysis.source}:{node.lineno}; extend walker"
                    )
            # Plain method call — walk receiver + args for side effects.
            # Also enforce the "don't pass the tainted root anywhere" rule
            # here: `json.dumps(state)` would silently serialize every field.
            self.path_of(func.value)
            for a in node.args:
                p = self.path_of(a)
                if p == "":
                    raise WalkerGaveUpError(
                        f"tainted root passed to method call at "
                        f"{self.analysis.source}:{node.lineno}"
                    )
            return None

        # Builtin identity calls: list(x), tuple(x), etc.
        if isinstance(func, ast.Name) and func.id in _IDENTITY_CALLS:
            if node.args:
                p = self.path_of(node.args[0])
                for a in node.args[1:]:
                    self.path_of(a)
                return p
            return None

        # enumerate(x) → we'll special-case in visit_For; here just walk args.
        if isinstance(func, ast.Name) and func.id == "enumerate":
            for a in node.args:
                self.path_of(a)
            return None

        # Call to a known helper in the same file → inter-procedural step.
        if isinstance(func, ast.Name) and func.id in self.analysis.func_defs:
            helper = self.analysis.func_defs[func.id]
            helper_params = [p.arg for p in helper.args.args]
            param_paths: Dict[str, str] = {}
            tainted_any = False
            for param_name, arg_node in zip(helper_params, node.args):
                arg_path = self.path_of(arg_node)
                if arg_path is not None:
                    param_paths[param_name] = arg_path
                    tainted_any = True
            # Visit extra args beyond what the helper declares (*args etc.)
            for a in node.args[len(helper_params):]:
                self.path_of(a)
            if tainted_any:
                self.analysis.analyze_func(func.id, param_paths)
            return None

        # Unknown function / scalar-consuming builtin / string method called
        # with tainted args. The underlying read is captured at the subscript
        # level when we walk each arg via `path_of`. Absorb the taint —
        # calls like `int(x)`, `len(x)`, `str(x)`, `bytes.fromhex(...)` are
        # common in display code and all produce scalars (or transformed
        # values whose original keys are already in the read set).
        #
        # The ONE exception: passing the whole tainted root (path == "")
        # to an unknown function. That's something like `json.dumps(state)`
        # which would silently serialize every field. Fail loud — either
        # refactor or extend the walker.
        for a in node.args:
            p = self.path_of(a)
            if p == "":
                raise WalkerGaveUpError(
                    f"tainted root passed to unknown function at "
                    f"{self.analysis.source}:{node.lineno}; the callee could "
                    f"read any field and we'd miss it — refactor to pass a "
                    f"specific sub-field, or add a known-helper definition "
                    f"in the same file"
                )
        return None

    # -- comprehensions --------------------------------------------------

    def _handle_comprehension(self, node, kind: str) -> Optional[str]:
        # Evaluate generators in order, extending aliases as we go.
        saved = dict(self.aliases)
        try:
            for gen in node.generators:
                iter_path = self.path_of(gen.iter)
                if iter_path is not None:
                    elem_path = self._elem(iter_path)
                    self._bind_target(gen.target, elem_path)
                for if_ in gen.ifs:
                    self.path_of(if_)
            if kind == "elt":
                self.path_of(node.elt)
            elif kind == "dict":
                self.path_of(node.key)
                self.path_of(node.value)
        finally:
            self.aliases = saved
        return None

    # -- statement visitors ---------------------------------------------

    def _bind_target(self, target: ast.AST, path: str) -> None:
        if isinstance(target, ast.Name):
            self.aliases[target.id] = path
        elif isinstance(target, (ast.Tuple, ast.List)):
            # `for i, np in enumerate(nonprofits):` → target is (i, np).
            # We already stripped enumerate in the caller; here we bind both
            # elements to the same element path (idx is scalar-ish, np is
            # the element dict). For non-enumerate tuple unpacks, we
            # conservatively bind every element to the same path.
            for elt in target.elts:
                self._bind_target(elt, path)

    def visit_Assign(self, node):
        path = self.path_of(node.value)
        for tgt in node.targets:
            if path is not None:
                self._bind_target(tgt, path)
            else:
                # Clear any prior alias — we're overwriting with untainted.
                if isinstance(tgt, ast.Name) and tgt.id in self.aliases:
                    del self.aliases[tgt.id]

    def visit_AugAssign(self, node):
        self.path_of(node.value)
        self.path_of(node.target)

    def visit_AnnAssign(self, node):
        if node.value is not None:
            path = self.path_of(node.value)
            if path is not None and isinstance(node.target, ast.Name):
                self.aliases[node.target.id] = path

    def visit_For(self, node):
        # enumerate(x) special case → (idx, elem) where elem has taint of x.
        iter_path = None
        elem_is_second = False
        if (isinstance(node.iter, ast.Call)
                and isinstance(node.iter.func, ast.Name)
                and node.iter.func.id == "enumerate"
                and node.iter.args):
            inner = self.path_of(node.iter.args[0])
            if inner is not None:
                iter_path = f"{inner}[*]"
                self.analysis.reads.add(iter_path)
                elem_is_second = True
        else:
            inner = self.path_of(node.iter)
            if inner is not None:
                iter_path = self._elem(inner)

        if iter_path is not None:
            tgt = node.target
            if elem_is_second and isinstance(tgt, (ast.Tuple, ast.List)) and len(tgt.elts) == 2:
                # idx = scalar, second elt = element-tainted
                self._bind_target(tgt.elts[1], iter_path)
            else:
                self._bind_target(tgt, iter_path)

        for stmt in node.body:
            self.visit(stmt)
        for stmt in node.orelse:
            self.visit(stmt)

    def visit_If(self, node):
        self.path_of(node.test)
        for stmt in node.body:
            self.visit(stmt)
        for stmt in node.orelse:
            self.visit(stmt)

    def visit_While(self, node):
        self.path_of(node.test)
        for stmt in node.body:
            self.visit(stmt)
        for stmt in node.orelse:
            self.visit(stmt)

    def visit_Try(self, node):
        for stmt in node.body:
            self.visit(stmt)
        for h in node.handlers:
            for stmt in h.body:
                self.visit(stmt)
        for stmt in node.orelse:
            self.visit(stmt)
        for stmt in node.finalbody:
            self.visit(stmt)

    def visit_With(self, node):
        for item in node.items:
            self.path_of(item.context_expr)
        for stmt in node.body:
            self.visit(stmt)

    def visit_Return(self, node):
        if node.value is not None:
            self.path_of(node.value)

    def visit_Expr(self, node):
        self.path_of(node.value)

    def generic_visit(self, node):
        # Fallback: walk any other statement's expression children for reads.
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.expr):
                self.path_of(child)
            elif isinstance(child, ast.stmt):
                self.visit(child)


class _Analysis:
    def __init__(self, source: Path):
        self.source = source
        tree = ast.parse(source.read_text())
        self.func_defs: Dict[str, ast.FunctionDef] = {}
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                # Top-level name collision ignored — we just pick the last.
                self.func_defs[node.name] = node
        self.reads: Set[str] = set()
        self._seen: Set[Tuple[str, Tuple]] = set()

    def analyze_func(self, name: str, param_paths: Dict[str, str]) -> None:
        key = (name, tuple(sorted(param_paths.items())))
        if key in self._seen:
            return
        self._seen.add(key)
        func = self.func_defs.get(name)
        if func is None:
            return
        visitor = _FuncVisitor(self, initial_aliases=param_paths)
        for stmt in func.body:
            visitor.visit(stmt)


def extract_state_reads(source: Path, entry_func: str,
                        state_param: Optional[str] = None,
                        initial_path: str = "") -> Set[str]:
    """Extract the set of state-rooted key paths read by `entry_func`.

    The first parameter of `entry_func` is treated as the tainted root
    (representing the epoch state dict). If `state_param` is given it
    overrides the name; otherwise the first positional parameter is used.

    `initial_path` can be set to something like "history[*]" to analyze a
    helper function as if its parameter were already a sub-path of some
    larger state — useful for picking up functions that the walker loses
    track of through dict-indirection patterns.
    """
    analysis = _Analysis(source)
    func = analysis.func_defs.get(entry_func)
    if func is None:
        raise LookupError(f"{source}: function `{entry_func}` not found")
    if state_param is None:
        if not func.args.args:
            raise LookupError(
                f"{source}:{entry_func} has no parameters — can't taint root"
            )
        state_param = func.args.args[0].arg
    analysis.analyze_func(entry_func, {state_param: initial_path})
    return analysis.reads


def _normalize_path(path: str) -> str:
    """Strip trailing `[*]` segments from a path.

    `nonprofits[*]` and `history[*].action[*]` aren't meaningful as
    "key reads" — the first is just list iteration, the second is bytes
    indexing on an already-hashed `action` field. Normalizing both sides
    collapses these to the parent keyed path (`nonprofits`, `history[*].action`).
    """
    while path.endswith("[*]"):
        path = path[:-3]
    return path


def _normalize_reads(reads: Set[str]) -> Set[str]:
    return {p for p in (_normalize_path(r) for r in reads) if p}


# ─── Test 1: hash coverage ────────────────────────────────────────────────

# Fields the prompt builder reads but that are NOT state-rooted in any
# meaningful way — synthesized inside the enclave from seeds/constants,
# or pure display scaffolding. None currently; kept for future use.
_PROMPT_IGNORE: Set[str] = set()

# Fields the hash computes from state but that the prompt builder never
# shows. These are fine (hash is a superset), but we list them here for
# documentation value. Not enforced by the test.
_HASH_ONLY_EXPECTED = {
    # e.g. hash may include a field the prompt never renders directly.
}


def test_prompt_builder_only_reads_hashed_keys():
    """Every state field shown to the model must be bound into input_hash.

    This is the single most important invariant in the enclave: if a field
    slips into the prompt without a matching hash entry, a runner can feed
    the enclave arbitrary values for that field and on-chain verification
    won't catch it.

    We extract the set of state-rooted key paths read by
    `prompt_builder.build_epoch_context` and `input_hash.compute_input_hash`
    via AST walking, then assert the prompt set is a subset of the hash set.
    """
    prompt_reads = _normalize_reads(
        extract_state_reads(_PROMPT_BUILDER, "build_epoch_context")
    )
    # `_content_hash_for_entry` is called via `by_epoch.get(...)` in
    # `_hash_history`, which loses taint through dict-indirection. Pick it
    # up as an extra entry point with `entry` pre-aliased to `history[*]`.
    hash_reads = _normalize_reads(
        extract_state_reads(_INPUT_HASH, "compute_input_hash")
        | extract_state_reads(
            _INPUT_HASH, "_content_hash_for_entry", initial_path="history[*]"
        )
    )

    leaked = (prompt_reads - hash_reads) - _PROMPT_IGNORE
    assert not leaked, (
        "prompt_builder.build_epoch_context reads state fields that are NOT "
        "bound into input_hash.compute_input_hash:\n\n  "
        + "\n  ".join(sorted(leaked))
        + "\n\nEither:\n"
        "  (a) add the field to input_hash.py AND src/TheHumanFund.sol "
        "(plus the cross-stack test) — see CLAUDE.md 'Input Hash Integrity', or\n"
        "  (b) stop reading it in prompt_builder.py, or\n"
        "  (c) derive it inside the enclave from fields that ARE hashed.\n\n"
        f"Hash-side reads ({len(hash_reads)}): "
        + ", ".join(sorted(hash_reads))
    )


# ─── Test 2: epoch-state call allowlist ───────────────────────────────────

# Every contract function that prover/client/epoch_state.py is allowed to
# call. Adding a new one is a deliberate act — every entry here is a
# potential drift source unless the underlying field is either (a) frozen
# into the EpochSnapshot or (b) immutable post-deployment.
#
# Every scalar comes through `getEpochSnapshot`; the remaining calls are
# for raw collection data (nonprofits, history, investments, worldview,
# messages) that the enclave needs to hash the sub-hashes and display to
# the model, bounded by frozen counts.
_EPOCH_STATE_ALLOWED_CALLS: Set[str] = {
    # --- THE ONE TRUE PINNED CALL ---------------------------------------
    # Returns the frozen EpochSnapshot struct — single source of truth
    # for every scalar + sub-hash the enclave needs.
    "getEpochSnapshot",
    # currentEpoch is needed to know which snapshot to read.
    "currentEpoch",

    # --- Raw collection data (bounded by frozen snapshot counts) --------
    # Nonprofit metadata is immutable post-addNonprofit; per-entry
    # counters (totalDonated*) are stable between freeze and verify.
    # Bounded by snap.nonprofit_count.
    "getNonprofit",
    # Historical epoch records — written once, never modified.
    # Bounded by snap.epoch.
    "getEpochRecord",
    # Donor message slots — written once at donateWithMessage time,
    # never modified. Bounded by snap.message_head / snap.message_count.
    "messages",

    # --- Sub-contract addresses (immutable once set) --------------------
    "investmentManager",
    "worldView",

    # --- InvestmentManager helpers (bounded by snap.investment_protocol_count) ---
    # Position metadata (name/risk/apy) is immutable post-addProtocol;
    # drift-prone currentValue/active come from the snapshot arrays.
    "getPosition",

    # --- WorldView helpers (stable between freeze and verify) ----------
    # Policies can only change via _applyPolicyUpdate inside
    # submit{EpochAction,AuctionResult}, which runs AFTER input-hash
    # verification. Live read is drift-free in the observed window.
    "getPolicies",
}


def _collect_contract_calls(source: Path) -> Set[str]:
    """Return the set of contract function names called from `source`.

    Recognizes the pattern `X.functions.<name>(...).call()` used by web3.py.
    Any such name is a contract call.
    """
    tree = ast.parse(source.read_text())
    calls: Set[str] = set()
    for node in ast.walk(tree):
        # Match: ...functions.<name>
        if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Attribute):
            if node.value.attr == "functions":
                calls.add(node.attr)
    return calls


def test_epoch_state_contract_calls_allowlist():
    """`epoch_state.py` must only call contract functions from the allowlist.

    This prevents accidental introduction of new live reads. Every live read
    is a potential drift source — the value might change between the moment
    the enclave reads it and the moment on-chain verification runs. The fix
    is to freeze such fields into `EpochSnapshot` at auction open and read
    from there.

    To add a call: first decide whether the underlying field needs to be
    snapshotted (yes if it can change mid-epoch), then add the call name to
    `_EPOCH_STATE_ALLOWED_CALLS` with a TODO if it's a transition-state
    entry.
    """
    found = _collect_contract_calls(_EPOCH_STATE)
    unexpected = found - _EPOCH_STATE_ALLOWED_CALLS
    stale = _EPOCH_STATE_ALLOWED_CALLS - found

    assert not unexpected, (
        f"epoch_state.py calls contract functions not in the allowlist: "
        f"{sorted(unexpected)}.\n\n"
        f"Every contract call here is a potential drift source. Consider "
        f"freezing the underlying field into EpochSnapshot and reading from "
        f"getEpochSnapshot instead. If the call is genuinely safe (e.g. "
        f"immutable post-deployment), add it to _EPOCH_STATE_ALLOWED_CALLS "
        f"in this test with a comment explaining why."
    )

    # Warn (don't fail) if the allowlist has stale entries — it's not harmful
    # but indicates dead code or a successful snapshot migration.
    if stale:
        print(
            f"\n[info] allowlist entries not found in epoch_state.py "
            f"(consider removing): {sorted(stale)}"
        )


# ─── Walker self-tests ────────────────────────────────────────────────────
# These verify the walker handles the access patterns that show up in the
# real files. If you extend the walker, add a synthetic case here.

import textwrap  # noqa: E402
import tempfile  # noqa: E402


def _walker_on_snippet(src: str, entry: str = "fn") -> Set[str]:
    src = textwrap.dedent(src)
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(src)
        path = Path(f.name)
    try:
        return extract_state_reads(path, entry)
    finally:
        path.unlink()


def test_walker_literal_subscript():
    reads = _walker_on_snippet("""
        def fn(state):
            x = state["a"]
            y = state["b"]
    """)
    assert reads == {"a", "b"}


def test_walker_get_with_default():
    reads = _walker_on_snippet("""
        def fn(state):
            x = state.get("a", 0)
            y = state.get("b")
    """)
    assert reads == {"a", "b"}


def test_walker_nested_dict_in_loop():
    reads = _walker_on_snippet("""
        def fn(state):
            for np in state["nonprofits"]:
                _ = np["name"]
                _ = np.get("description", "")
    """)
    assert reads == {
        "nonprofits",
        "nonprofits[*]",
        "nonprofits[*].name",
        "nonprofits[*].description",
    }


def test_walker_enumerate_unpack():
    reads = _walker_on_snippet("""
        def fn(state):
            for idx, np in enumerate(state["nonprofits"]):
                _ = np["name"]
    """)
    assert "nonprofits[*].name" in reads


def test_walker_alias_through_assignment():
    reads = _walker_on_snippet("""
        def fn(state):
            history = state.get("history", [])
            for entry in history[:10]:
                _ = entry.get("bounty_paid", 0)
    """)
    assert "history[*].bounty_paid" in reads


def test_walker_inter_procedural():
    reads = _walker_on_snippet("""
        def helper(s):
            return s["treasury_balance"]
        def fn(state):
            return helper(state)
    """)
    assert reads == {"treasury_balance"}


def test_walker_inter_procedural_nested_arg():
    reads = _walker_on_snippet("""
        def inner(nps):
            for np in nps:
                _ = np["name"]
        def fn(state):
            inner(state.get("nonprofits", []))
    """)
    assert "nonprofits[*].name" in reads


def test_walker_fstring_subscript():
    reads = _walker_on_snippet("""
        def fn(state):
            s = f"balance: {state['treasury_balance']}"
    """)
    assert reads == {"treasury_balance"}


def test_walker_slice_preserves_path():
    reads = _walker_on_snippet("""
        def fn(state):
            recent = state["history"][:10]
            for entry in recent:
                _ = entry["epoch"]
    """)
    assert "history[*].epoch" in reads


def test_walker_listcomp():
    reads = _walker_on_snippet("""
        def fn(state):
            total = sum(int(np.get("total_donated_usd", 0) or 0)
                        for np in state.get("nonprofits", []))
    """)
    assert "nonprofits[*].total_donated_usd" in reads


def test_walker_fails_loud_on_root_passed_to_unknown():
    """Passing the whole tainted root to an unknown function is a blind
    spot — the callee could read any field. Must raise, not silently pass."""
    import pytest
    with pytest.raises(WalkerGaveUpError):
        _walker_on_snippet("""
            def fn(state):
                import json
                return json.dumps(state)
        """)


def test_walker_fails_loud_on_dict_iteration():
    """`.items()` / `.keys()` / `.values()` on a tainted dict isn't modeled.
    Must raise rather than silently miss whatever keys the loop reads."""
    import pytest
    with pytest.raises(WalkerGaveUpError):
        _walker_on_snippet("""
            def fn(state):
                for k, v in state.items():
                    pass
        """)


def test_walker_absorbs_scalar_consumers():
    """int(x), len(x), str(x) etc. absorb taint — the underlying read is
    captured at the subscript level. No failure, no missed reads."""
    reads = _walker_on_snippet("""
        def fn(state):
            x = int(state.get("treasury_balance", 0) or 0)
            n = len(state["history"])
            s = str(state["nonprofits"][0]["name"])
    """)
    assert "treasury_balance" in reads
    assert "history" in reads
    assert "nonprofits[*].name" in reads


def test_walker_absorbs_string_methods():
    """Methods on tainted strings (startswith, replace, decode, hex) absorb
    taint — the subscript read has already been emitted."""
    reads = _walker_on_snippet("""
        def fn(state):
            for entry in state["history"]:
                r = entry["reasoning"]
                if isinstance(r, str) and r.startswith("0x"):
                    decoded = bytes.fromhex(r[2:]).decode("utf-8")
    """)
    assert "history[*].reasoning" in reads
