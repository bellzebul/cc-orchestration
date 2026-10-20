"""Regression battery for .claude/hooks/bash-guard.sh.

Every line of scripts/guard_battery.jsonl is fed to the hook as the PreToolUse JSON payload
(never executed) and must end with exit 2 (block) or exit 0 (pass). Lines tagged
`"needs": "gh"` get their verdict from a live `gh pr view` lookup and are skipped unless
GUARD_BATTERY_GH=1 (an authenticated gh, on a branch whose open PR targets dev). All other
probes run in a hermetic env (no gh tokens, empty GH_CONFIG_DIR), so they make no network calls.

No verdict depends on the checked-out branch: every probe runs with GUARD_TEST_MODE=1 and
GUARD_CURRENT_BRANCH set to its `"branch"` key (default `feat/battery`), and with GIT_DIR pointed at a
scratch repo whose HEAD is that same branch, so a hook that ignores the injection and asks
`git symbolic-ref` (origin/dev's) sees the same branch.

The differential test runs the offline probes through origin/dev's hook as well — a probe with a
`"branch"` key on that branch only, every other probe on BOTH `dev` and `feat/battery`, so a weakening
of the current-branch check is caught even without a dedicated probe — and fails when the head hook
lets through anything origin/dev blocked, unless scripts/guard_relaxations.jsonl lists the
(cmd, branch) as an intended relaxation (an entry without `"branch"` covers `feat/battery` only; a
relaxation on `dev` needs `"branch": "dev"`). Locally, run `git fetch origin dev` first: a stale
`origin/dev` is a stale baseline. In CI (no origin/dev in the depth-1 checkout) the test fetches it
and fails, never skips, when it cannot.

A row with `"known_gap": "<reason>"` is a hole the hook is known to have: its `expect` is the TRUE
wanted verdict and it runs as a strict xfail; gap rows are left out of the offline pass/block floors
only (they stay in the differential like any other row).
"""

import json
import os
import shutil
import subprocess
from collections import Counter
from collections.abc import Callable, Iterator
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from pydantic_settings import BaseSettings, SettingsConfigDict

pytestmark = pytest.mark.unit

# (probe or relaxation entry, branch the hook should see) -> the hermetic env for that run
ProbeEnvBuilder = Callable[[dict, str], dict[str, str]]
HookResults = dict[int, subprocess.CompletedProcess[str]]

# CI relies on `bash`, `git` and `node` being preinstalled on GitHub's ubuntu-latest runner.
_REPO_ROOT = Path(__file__).resolve().parents[3]
_HOOK_REL_PATH = ".claude/hooks/bash-guard.sh"
_HOOK = _REPO_ROOT / _HOOK_REL_PATH
_BATTERY = _REPO_ROOT / "scripts" / "guard_battery.jsonl"
_RELAXATIONS = _REPO_ROOT / "scripts" / "guard_relaxations.jsonl"
_BASE_REF = "origin/dev"
_BASE_REMOTE, _BASE_BRANCH = "origin", "dev"
_EXIT_CODES = {"block": 2, "pass": 0}
_MIN_PROBES = 80
_MIN_OFFLINE_PASS_PROBES = 20
_REQUIRED_KEYS = {"cmd", "expect", "why"}
# known_gap: "<reason>" — the hook is known to get this row wrong; `expect` is the TRUE wanted
# verdict and the row runs as a strict xfail, so the gap stays visible until the hook is fixed.
_ALLOWED_KEYS = _REQUIRED_KEYS | {"needs", "branch", "known_gap"}
_RELAXATION_REQUIRED_KEYS = {"cmd", "why"}
_RELAXATION_ALLOWED_KEYS = _RELAXATION_REQUIRED_KEYS | {"branch"}
_NEUTRAL_BRANCH = "feat/battery"
# Branches a probe WITHOUT a "branch" key is diffed on: a protected one and the neutral one.
_DIFFERENTIAL_BRANCHES = ("dev", _NEUTRAL_BRANCH)
_PROBE_TIMEOUT_S = 10
_GIT_TIMEOUT_S = 60
_TIMEOUT_RETURNCODE = -1
_POOL_WORKERS = 16
_CI_FALSE_VALUES = ("", "0", "false")
# Dropped from the env of every probe: gh credentials (offline probes only) and bash startup files (always).
_GH_TOKEN_VARS = (
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_ENTERPRISE_TOKEN",
    "GITHUB_ENTERPRISE_TOKEN",
)
_SHELL_STARTUP_VARS = ("BASH_ENV", "ENV")
# Every GIT_* var is dropped from the probe env (GIT_DIR is then set to the probe's scratch repo),
# so a run from inside a git hook (GIT_INDEX_FILE, GIT_WORK_TREE, …) cannot leak into a verdict.
_GIT_ENV_PREFIX = "GIT_"
# git never waits for a credential or ssh prompt: a fetch without credentials fails fast instead.
_GIT_NO_PROMPT_ENV = {
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_SSH_COMMAND": "ssh -o BatchMode=yes",
}
_FETCH_HYGIENE = ["-c", "gc.auto=0", "-c", "maintenance.auto=false"]
# S5: a push whose -C dir does not exist resolves no branch there; the hook falls back to the cwd's.
_MISSING_DIR_PUSH = "git -C /nonexistent-dir push"
_ADMIN_MERGE = "gh pr merge 5 --admin"
_ADMIN_MERGE_MESSAGE = "admin merge"


class _BatterySettings(BaseSettings):
    """The env switches this module reads; case-sensitive like the os.environ lookups it replaced."""

    GUARD_BATTERY_GH: str = ""
    GITHUB_ACTIONS: str = ""
    CI: str = ""

    model_config = SettingsConfigDict(extra="ignore", case_sensitive=True)


def _load_jsonl(path: Path) -> list[dict]:
    entries: list[dict] = []
    for index, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError as err:
            raise ValueError(f"{path.name} line {index}: invalid JSON: {err}") from err
    return entries


_PROBES = _load_jsonl(_BATTERY)
_RELAXATION_ENTRIES = _load_jsonl(_RELAXATIONS)
_IDS = [
    p.get("why", f"line-{i}") if isinstance(p, dict) else f"line-{i}"
    for i, p in enumerate(_PROBES, start=1)
]


def _needs_gh(probe: dict) -> bool:
    return probe.get("needs") == "gh"


def _is_known_gap(probe: dict) -> bool:
    return "known_gap" in probe


def _branch_of(probe: dict) -> str:
    return probe.get("branch", _NEUTRAL_BRANCH)


def _run_hook(
    hook: Path, cmd: str, env: dict[str, str]
) -> subprocess.CompletedProcess[str]:
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
    try:
        return subprocess.run(
            ["bash", str(hook)],
            input=payload,
            capture_output=True,
            text=True,
            cwd=_REPO_ROOT,
            env=env,
            timeout=_PROBE_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            ["bash", str(hook)], _TIMEOUT_RETURNCODE, "", "timeout"
        )


def _git(
    args: list[str], env: dict[str, str], cwd: Path = _REPO_ROOT
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            ["git", *args],
            capture_output=True,
            text=True,
            cwd=cwd,
            env={**env, **_GIT_NO_PROMPT_ENV},
            timeout=_GIT_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(
            ["git", *args], _TIMEOUT_RETURNCODE, "", "timeout"
        )


# ─────────────────────────────────────────────
# Fixtures (every environment read happens here)
# ─────────────────────────────────────────────


@pytest.fixture(scope="session")
def battery_settings() -> _BatterySettings:
    return _BatterySettings()


@pytest.fixture(scope="session")
def run_gh_probes(battery_settings: _BatterySettings) -> bool:
    return battery_settings.GUARD_BATTERY_GH == "1"


@pytest.fixture(scope="session")
def in_ci(battery_settings: _BatterySettings) -> bool:
    return (
        battery_settings.GITHUB_ACTIONS == "true"
        or battery_settings.CI.lower() not in _CI_FALSE_VALUES
    )


@pytest.fixture(scope="session")
def outer_env() -> dict[str, str]:
    """The test process env minus bash startup files; the base for git calls and probe envs."""
    return {k: v for k, v in os.environ.items() if k not in _SHELL_STARTUP_VARS}


@pytest.fixture(scope="session")
def pool() -> Iterator[ThreadPoolExecutor]:
    """One thread pool for every hook run in the module (~75 ms each sequentially is too slow)."""
    with ThreadPoolExecutor(max_workers=_POOL_WORKERS) as executor:
        yield executor


@pytest.fixture(scope="session")
def branch_git_dirs(
    tmp_path_factory: pytest.TempPathFactory, outer_env: dict[str, str]
) -> dict[str, Path]:
    """A scratch repo per probe/relaxation branch, HEAD on that branch: the GIT_DIR every probe runs against."""
    root = tmp_path_factory.mktemp("branch-repos")
    git_env = {k: v for k, v in outer_env.items() if not k.startswith(_GIT_ENV_PREFIX)}
    branches = {_branch_of(p) for p in [*_PROBES, *_RELAXATION_ENTRIES]}
    dirs: dict[str, Path] = {}
    for branch in sorted(branches | set(_DIFFERENTIAL_BRANCHES)):
        repo = root / branch.replace("/", "-")
        init = _git(["init", "-q", "-b", branch, str(repo)], git_env, cwd=root)
        assert init.returncode == 0, f"git init -b {branch}: {init.stderr.strip()}"
        dirs[branch] = repo / ".git"
    return dirs


@pytest.fixture(scope="session")
def probe_env(
    tmp_path_factory: pytest.TempPathFactory,
    outer_env: dict[str, str],
    branch_git_dirs: dict[str, Path],
) -> ProbeEnvBuilder:
    """Builds the hermetic env for one probe (or relaxation entry); the same env feeds the old and new hook."""
    gh_config_dir = tmp_path_factory.mktemp("empty-gh-config")
    base = {k: v for k, v in outer_env.items() if not k.startswith(_GIT_ENV_PREFIX)}

    def build(probe: dict, branch: str) -> dict[str, str]:
        env = dict(base)
        if not _needs_gh(probe):
            for var in _GH_TOKEN_VARS:
                env.pop(var, None)
            env["GH_CONFIG_DIR"] = str(gh_config_dir)
        env["CLAUDE_PROJECT_DIR"] = str(_REPO_ROOT)
        # the hook honours GUARD_CURRENT_BRANCH only in test mode
        env["GUARD_TEST_MODE"] = "1"
        env["GUARD_CURRENT_BRANCH"] = branch
        env["GIT_DIR"] = str(branch_git_dirs[branch])
        return env

    return build


@pytest.fixture(scope="session")
def hook_results(
    run_gh_probes: bool, pool: ThreadPoolExecutor, probe_env: ProbeEnvBuilder
) -> HookResults:
    """Runs every runnable probe once through the head hook, in parallel. Keyed by line position."""
    if shutil.which("node") is None:
        pytest.fail(
            "bash-guard.sh needs `node` to parse its JSON input; install node — this gate must not be skipped"
        )
    runnable = [
        (i, p) for i, p in enumerate(_PROBES) if not _needs_gh(p) or run_gh_probes
    ]
    results = pool.map(
        lambda item: _run_hook(
            _HOOK, item[1]["cmd"], probe_env(item[1], _branch_of(item[1]))
        ),
        runnable,
    )
    return {i: r for (i, _), r in zip(runnable, results)}


@pytest.fixture(scope="session")
def origin_dev_hook(
    tmp_path_factory: pytest.TempPathFactory, outer_env: dict[str, str], in_ci: bool
) -> Path:
    """origin/dev's bash-guard.sh written to a tmp file; fetches dev once if the ref is missing (CI checkout)."""
    show_args = ["show", f"{_BASE_REF}:{_HOOK_REL_PATH}"]
    shown = _git(show_args, outer_env)
    fetch_note = "not attempted"
    if shown.returncode != 0:
        # CI's actions/checkout is a depth-1 clone with no origin/dev; its persisted credentials let
        # this fetch work. --depth=1 only on an already-shallow clone, so a full local clone stays full.
        shallow = _git(["rev-parse", "--is-shallow-repository"], outer_env)
        depth = ["--depth=1"] if shallow.stdout.strip() == "true" else []
        fetched = _git(
            [*_FETCH_HYGIENE, "fetch", "--no-tags", *depth, _BASE_REMOTE, _BASE_BRANCH],
            outer_env,
        )
        fetch_note = f"exit {fetched.returncode}: {fetched.stderr.strip()[-300:]!r}"
        shown = _git(show_args, outer_env)
        if shown.returncode != 0 and fetched.returncode == 0:
            shown = _git(["show", f"FETCH_HEAD:{_HOOK_REL_PATH}"], outer_env)
    if shown.returncode != 0 or not shown.stdout:
        reason = (
            f"cannot read {_BASE_REF}:{_HOOK_REL_PATH} (show: {shown.stderr.strip()[-300:]!r}; "
            f"fetch {_BASE_REMOTE} {_BASE_BRANCH}: {fetch_note})"
        )
        if in_ci:
            pytest.fail(
                f"{reason}; the differential needs the base hook — this gate must not be skipped in CI"
            )
        pytest.skip(f"{reason}; the differential needs the base hook (local run)")
    path = tmp_path_factory.mktemp("origin-dev-hook") / "bash-guard.sh"
    path.write_text(shown.stdout)
    return path


# ─────────────────────────────────────────────
# Battery integrity
# ─────────────────────────────────────────────


def test_battery_lines_are_well_formed() -> None:
    for index, probe in enumerate(_PROBES, start=1):
        assert isinstance(probe, dict), f"line {index}: not a JSON object"
        assert _REQUIRED_KEYS <= probe.keys(), (
            f"line {index}: missing {_REQUIRED_KEYS - probe.keys()}"
        )
        assert probe.keys() <= _ALLOWED_KEYS, (
            f"line {index}: unknown keys {probe.keys() - _ALLOWED_KEYS}"
        )
        assert isinstance(probe["why"], str) and probe["why"], (
            f"line {index}: why must be a non-empty str"
        )
        assert isinstance(probe["cmd"], str) and probe["cmd"], (
            f"line {index}: cmd must be a non-empty str"
        )
        assert probe["expect"] in _EXIT_CODES, (
            f"line {index}: expect={probe['expect']!r}"
        )
        assert probe.get("needs", "gh") == "gh", (
            f"line {index}: needs={probe['needs']!r}"
        )
        for key in ("branch", "known_gap"):
            if key in probe:
                assert isinstance(probe[key], str) and probe[key], (
                    f"line {index}: {key} must be a non-empty str, got {probe[key]!r}"
                )
    duplicates = sorted(
        why for why, count in Counter(p["why"] for p in _PROBES).items() if count > 1
    )
    assert not duplicates, f"duplicate why ids: {duplicates}"
    assert len(_PROBES) >= _MIN_PROBES, (
        f"battery shrank to {len(_PROBES)} probes (minimum {_MIN_PROBES})"
    )


def test_battery_keeps_a_floor_of_offline_block_and_pass_probes() -> None:
    offline = Counter(
        p["expect"] for p in _PROBES if not _needs_gh(p) and not _is_known_gap(p)
    )
    assert offline["block"] > 0, "no offline block probes"
    assert offline["pass"] >= _MIN_OFFLINE_PASS_PROBES, (
        f"only {offline['pass']} offline pass probes (minimum {_MIN_OFFLINE_PASS_PROBES}): false positives go unguarded"
    )


def test_relaxation_lines_are_well_formed() -> None:
    for index, entry in enumerate(_RELAXATION_ENTRIES, start=1):
        where = f"{_RELAXATIONS.name} line {index}"
        assert isinstance(entry, dict), f"{where}: not a JSON object"
        assert _RELAXATION_REQUIRED_KEYS <= entry.keys(), (
            f"{where}: missing {sorted(_RELAXATION_REQUIRED_KEYS - entry.keys())}"
        )
        assert entry.keys() <= _RELAXATION_ALLOWED_KEYS, (
            f"{where}: unknown keys {sorted(entry.keys() - _RELAXATION_ALLOWED_KEYS)}"
        )
        for key in entry.keys():
            assert isinstance(entry[key], str) and entry[key], (
                f"{where}: {key} must be a non-empty str"
            )
    duplicates = sorted(
        key
        for key, count in Counter(
            (e["cmd"], _branch_of(e)) for e in _RELAXATION_ENTRIES
        ).items()
        if count > 1
    )
    assert not duplicates, f"duplicate relaxation (cmd, branch) pairs: {duplicates}"


# ─────────────────────────────────────────────
# Hook verdicts
# ─────────────────────────────────────────────


@pytest.mark.parametrize("index", range(len(_PROBES)), ids=_IDS)
def test_guard_returns_expected_verdict(
    index: int,
    hook_results: HookResults,
    run_gh_probes: bool,
    request: pytest.FixtureRequest,
) -> None:
    probe = _PROBES[index]
    if _needs_gh(probe) and not run_gh_probes:
        pytest.skip(
            "verdict comes from a live `gh pr view` lookup; set GUARD_BATTERY_GH=1 with an authenticated gh"
        )
    result = hook_results[index]
    # A timeout (-1) or a crash (1) is a hard failure on every row, a known_gap row included.
    assert result.returncode in _EXIT_CODES.values(), (
        f"{probe['why']}: abnormal hook exit {result.returncode}\n"
        f"cmd={probe['cmd']!r}\nstderr={result.stderr.strip()!r}"
    )
    if _is_known_gap(probe):
        # strict: once the hook gets the row right, the XPASS fails and the known_gap key must go;
        # raises=AssertionError: only the verdict assertion below counts as the expected failure.
        request.applymarker(
            pytest.mark.xfail(
                strict=True,
                raises=AssertionError,
                reason=f"known gap: {probe['known_gap']}",
            )
        )
    want = _EXIT_CODES[probe["expect"]]
    assert result.returncode == want, (
        f"{probe['why']}: expected {probe['expect']} (exit {want}), got exit {result.returncode}\n"
        f"cmd={probe['cmd']!r}\nstderr={result.stderr.strip()!r}"
    )


# ─────────────────────────────────────────────
# Differential against origin/dev's hook
# ─────────────────────────────────────────────


def test_guard_is_never_weaker_than_origin_dev(
    origin_dev_hook: Path,
    hook_results: HookResults,
    pool: ThreadPoolExecutor,
    probe_env: ProbeEnvBuilder,
) -> None:
    # The hook is self-contained (it sources nothing), so identical bytes give identical verdicts:
    # on a PR that does not touch it the comparison cannot fail and is skipped for speed.
    if origin_dev_hook.read_bytes() == _HOOK.read_bytes():
        return
    # A probe with a "branch" key runs on that branch only; every other probe on BOTH dev and the
    # neutral branch, so a weakened current-branch check shows up without a dev-tagged twin (it
    # still only sees the commands that are in the battery).
    # origin/dev's hook ignores the GUARD_CURRENT_BRANCH injection, but GIT_DIR points it at a scratch
    # repo whose HEAD is the same branch, so both hooks see the same one.
    cases = [
        (i, p, branch)
        for i, p in enumerate(_PROBES)
        if not _needs_gh(p)
        for branch in ((p["branch"],) if "branch" in p else _DIFFERENTIAL_BRANCHES)
    ]
    # An offline probe's env depends only on its branch, so a verdict is a function of (cmd, branch):
    # each pair runs once per hook (a branchless probe and its dev twin share the dev run), and the
    # head hook's verdicts already in hook_results are reused.
    first_probe: dict[tuple[str, str], dict] = {}
    for _, p, b in cases:
        first_probe.setdefault((p["cmd"], b), p)
    new_by_key: dict[tuple[str, str], subprocess.CompletedProcess[str]] = {}
    for i, p, b in cases:
        if b == _branch_of(p):
            new_by_key.setdefault((p["cmd"], b), hook_results[i])
    keys = list(first_probe)
    missing = [k for k in keys if k not in new_by_key]
    new_runs = pool.map(
        lambda k: _run_hook(_HOOK, k[0], probe_env(first_probe[k], k[1])), missing
    )
    new_by_key.update(zip(missing, new_runs))
    # Only a pair the head hook does NOT block can be a weakening, so origin/dev's hook runs only
    # for those (it halves the module's runtime); a head-hook timeout is reported below either way.
    to_compare = [k for k in keys if new_by_key[k].returncode != _EXIT_CODES["block"]]
    old_by_key = dict(
        zip(
            to_compare,
            pool.map(
                lambda k: _run_hook(
                    origin_dev_hook, k[0], probe_env(first_probe[k], k[1])
                ),
                to_compare,
            ),
        )
    )
    runs = [("new", k, r) for k, r in new_by_key.items() if k in first_probe]
    runs += [("old", k, r) for k, r in old_by_key.items()]
    timed_out = [
        f"  {side}: {first_probe[k]['why']}: branch={k[1]} cmd={k[0]!r}"
        for side, k, result in runs
        if result.returncode == _TIMEOUT_RETURNCODE
    ]
    assert not timed_out, (
        f"{len(timed_out)} hook run(s) timed out after {_PROBE_TIMEOUT_S}s; a timeout could hide a weakening:\n"
        + "\n".join(timed_out)
    )
    relaxed = {(e["cmd"], _branch_of(e)) for e in _RELAXATION_ENTRIES}
    weakened = [
        (first_probe[k], k[1])
        for k, old in old_by_key.items()
        if old.returncode == _EXIT_CODES["block"]
        # Not "== pass": Claude Code treats ANY exit but 2 as non-blocking, so a head hook that
        # crashes (exit 1) where origin/dev blocked is a weakening too.
        and new_by_key[k].returncode != _EXIT_CODES["block"]
        and k not in relaxed
    ]
    assert not weakened, (
        f"{len(weakened)} (probe, branch) run(s) blocked by {_BASE_REF}'s hook now pass; add a line to "
        f"{_RELAXATIONS.name} only if the relaxation is intended:\n"
        + "\n".join(f"  {p['why']}: branch={b} cmd={p['cmd']!r}" for p, b in weakened)
    )


def test_every_relaxation_is_implemented(
    request: pytest.FixtureRequest,
    pool: ThreadPoolExecutor,
    probe_env: ProbeEnvBuilder,
) -> None:
    if not _RELAXATION_ENTRIES:
        return
    old_hook: Path = request.getfixturevalue("origin_dev_hook")
    pairs = list(
        pool.map(
            lambda entry: (
                _run_hook(
                    old_hook, entry["cmd"], probe_env(entry, _branch_of(entry))
                ).returncode,
                _run_hook(
                    _HOOK, entry["cmd"], probe_env(entry, _branch_of(entry))
                ).returncode,
            ),
            _RELAXATION_ENTRIES,
        )
    )
    # An entry origin/dev's hook already allows is inert: its relaxation has been merged into dev.
    # It is ignored, not failed, so a leftover line never breaks an unrelated PR (cleanup is optional).
    # Only an entry the head hook still blocks fails: that relaxation was never implemented.
    unimplemented = [
        (entry, old, new)
        for entry, (old, new) in zip(_RELAXATION_ENTRIES, pairs)
        if old != _EXIT_CODES["pass"] and new != _EXIT_CODES["pass"]
    ]
    assert not unimplemented, (
        f"{len(unimplemented)} line(s) in {_RELAXATIONS.name} are still blocked by the head hook "
        f"(a relaxation must be allowed by it):\n"
        + "\n".join(
            f"  {e['why']}: branch={_branch_of(e)} old exit {old}, new exit {new}, cmd={e['cmd']!r}"
            for e, old, new in unimplemented
        )
    )


# ─────────────────────────────────────────────
# Real branch resolution and block messages (outside the battery's injection)
# ─────────────────────────────────────────────


@pytest.fixture(scope="session")
def real_branch_env(
    tmp_path_factory: pytest.TempPathFactory, outer_env: dict[str, str]
) -> dict[str, str]:
    """An offline env with NO test-mode injection and no GIT_*: the hook must ask git for the branch."""
    env = {k: v for k, v in outer_env.items() if not k.startswith(_GIT_ENV_PREFIX)}
    for var in (*_GH_TOKEN_VARS, "GUARD_TEST_MODE", "GUARD_CURRENT_BRANCH"):
        env.pop(var, None)
    env["GH_CONFIG_DIR"] = str(tmp_path_factory.mktemp("empty-gh-config-real-branch"))
    env["CLAUDE_PROJECT_DIR"] = str(_REPO_ROOT)
    # no user/system git config (init.templateDir, …) leaks into the scratch repos or the hook
    env["GIT_CONFIG_GLOBAL"] = os.devnull
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    return env


def _run_hook_in(
    cwd: Path, cmd: str, env: dict[str, str]
) -> subprocess.CompletedProcess[str]:
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
    return subprocess.run(
        ["bash", str(_HOOK)],
        input=payload,
        capture_output=True,
        text=True,
        cwd=cwd,
        env=env,
        timeout=_PROBE_TIMEOUT_S,
    )


@pytest.mark.parametrize(
    ("branch", "want"), [("dev", "block"), ("feat/x", "pass")], ids=["dev", "feat-x"]
)
def test_push_with_missing_c_dir_falls_back_to_cwd_branch(
    branch: str,
    want: str,
    tmp_path: Path,
    real_branch_env: dict[str, str],
) -> None:
    repo = tmp_path / branch.replace("/", "-")
    init = _git(["init", "-q", "-b", branch, str(repo)], real_branch_env, cwd=tmp_path)
    assert init.returncode == 0, f"git init -b {branch}: {init.stderr.strip()}"

    result = _run_hook_in(repo, _MISSING_DIR_PUSH, real_branch_env)

    assert result.returncode == _EXIT_CODES[want], (
        f"cwd on {branch}: expected {want} for {_MISSING_DIR_PUSH!r}, got exit {result.returncode}\n"
        f"stderr={result.stderr.strip()!r}"
    )


def test_admin_merge_is_blocked_with_the_admin_message_offline(
    probe_env: ProbeEnvBuilder,
) -> None:
    probe = {"cmd": _ADMIN_MERGE, "expect": "block", "why": "s6a-admin-message"}

    result = _run_hook(_HOOK, _ADMIN_MERGE, probe_env(probe, _NEUTRAL_BRANCH))

    assert result.returncode == _EXIT_CODES["block"], (
        f"expected block, got exit {result.returncode}: {result.stderr.strip()!r}"
    )
    # the admin check must answer before the gh base lookup (which fails offline with its own message)
    assert _ADMIN_MERGE_MESSAGE in result.stderr, (
        f"blocked for the wrong reason: {result.stderr.strip()!r}"
    )
