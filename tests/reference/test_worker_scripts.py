"""The bridge-worker shell scripts: the branch-trust gate, worker.sh's start flow and the spawner.

`check_branch_trust` / `valid_worker_branch` / `reset_bridge_deps` (scripts/lib/branch-trust.sh) run
against scratch repos under tmp_path: a bare origin with a `dev` branch carrying every trust path, a
clone of it (the TRUSTED repo, passed as the 3rd argument) and one worktree per case — including the
py-reviewer and pr-reviewer bypass probes (ref shadowing, index flags, ignored files, symlinks, a
redirected `.git`, per-worktree git config). `worker.sh` runs as a committed copy in a scratch clone with
claude / npm / gh stubbed first on PATH. `worker-spawner.sh` runs as a scratch copy next to a STUB
worker-up.sh (no tmux, no Claude), driven to a SIGTERM while a start is in flight. No network: every
remote is a local path. The executable scripts' `bash -n` + index-mode pins live in
test_pre_push_hook.py; the sourced libs (not executable) are parsed here.
"""

import os
import shutil
import signal
import subprocess
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

_REPO_ROOT = Path(__file__).resolve().parents[3]
_SCRIPTS = _REPO_ROOT / "scripts"
_LIB_DIR = _SCRIPTS / "lib"
_TRUST_LIB = _LIB_DIR / "branch-trust.sh"
_SPAWNER = _SCRIPTS / "worker-spawner.sh"
_WORKER = _SCRIPTS / "worker.sh"
_INSTALLER = _SCRIPTS / "install-git-hooks.sh"
_TIMEOUT_S = 30
_GIT_ENV_PREFIX = "GIT_"
_BASE = "origin/dev"
_BASE_REF = "refs/remotes/origin/dev"
_REFUSED = 1

# Trust paths, built from parts (never spelled whole on a shell line).
_CLAUDE = Path(".claude")
_SETTINGS = _CLAUDE / "settings.json"
_SETTINGS_LOCAL = _CLAUDE / "settings.local.json"
_MCP = Path(".mcp.json")
_AGENT_HOOKS = _CLAUDE / "hooks"
_GIT_HOOKS = Path("scripts", "git-" + "hooks")
_BRIDGE = _CLAUDE / "bridge"
_BRIDGE_SERVER = _BRIDGE / "server.mjs"
_BRIDGE_PACKAGE = _BRIDGE / "package.json"
_BRIDGE_NPMRC = _BRIDGE / ".npmrc"
_BRIDGE_LOCK = _BRIDGE / "package-lock.json"
_BRIDGE_MODULES = _BRIDGE / "node_modules"
_APP = Path("app.py")
# Ignored on dev like in the real repo: settings.local.json and the bridge's generated artefacts.
_GITIGNORE = "\n".join(
    [
        _SETTINGS_LOCAL.as_posix(),
        _BRIDGE_MODULES.as_posix() + "/",
        (_BRIDGE / "inbox").as_posix() + "/",
        _BRIDGE_LOCK.as_posix(),
        "",
    ]
)
# The files dev carries under the trust paths (plus non-trust ones).
_DEV_FILES: tuple[tuple[Path, str], ...] = (
    (_SETTINGS, '{"a":1}\n'),
    (_MCP, '{"mcpServers":{}}\n'),
    (_AGENT_HOOKS / "guard.sh", "echo guard\n"),
    (_GIT_HOOKS / "pre-push", "#!/bin/sh\nexit 0\n"),
    (_BRIDGE_SERVER, "// bridge\n"),
    (_BRIDGE_PACKAGE, '{"name":"bridge"}\n'),
    (Path(".gitignore"), _GITIGNORE),
    (_APP, "code\n"),
)

# Labels check_branch_trust puts after each path.
_DIFFERS = "(content differs from dev)"
_CONFIG_WORKTREE_REFUSAL = "config.worktree exists (per-worktree git config)"
_NOT_ON_DEV = "(not on dev)"  # an extra file under a path dev does carry
_MUST_BE_ABSENT = (
    "(not on dev — must be absent)"  # anything at a path dev does not carry
)
_HARD_LINK = "(hard link: more than one link)"


# ─────────────────────────────────────────────
# Environment
# ─────────────────────────────────────────────


@pytest.fixture(scope="session")
def git_env() -> dict[str, str]:
    """The test env without any GIT_* leaking in, no global/system config, no prompts, a fixed identity."""
    base = {
        k: v
        for k, v in os.environ.items()
        if not k.startswith(_GIT_ENV_PREFIX)
        and k not in ("BASH_ENV", "ENV", "WORKER_RC")
    }
    return {
        **base,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_AUTHOR_NAME": "battery",
        "GIT_AUTHOR_EMAIL": "battery@example.invalid",
        "GIT_COMMITTER_NAME": "battery",
        "GIT_COMMITTER_EMAIL": "battery@example.invalid",
    }


def _git(args: list[str], env: dict[str, str], cwd: Path) -> str:
    done = subprocess.run(
        ["git", "-c", "commit.gpgsign=false", *args],
        capture_output=True,
        text=True,
        cwd=cwd,
        env=env,
        timeout=_TIMEOUT_S,
    )
    assert done.returncode == 0, f"git {args}: {done.stderr}"
    return done.stdout


def _bash_lib(
    snippet: str, args: list[str], env: dict[str, str]
) -> subprocess.CompletedProcess[str]:
    """Source branch-trust.sh, then run `snippet` with `args` as $1.. (never interpolated)."""
    return subprocess.run(
        ["bash", "-c", f'source "{_TRUST_LIB}"; {snippet}', "_", *args],
        capture_output=True,
        text=True,
        env=env,
        timeout=_TIMEOUT_S,
    )


def _write(root: Path, rel: Path, body: str) -> None:
    (root / rel).parent.mkdir(parents=True, exist_ok=True)
    (root / rel).write_text(body)


def _make_origin(
    root: Path, env: dict[str, str], extra: dict[Path, Path] | None = None
) -> Path:
    """A bare origin whose dev carries _DEV_FILES, plus `extra` (dest rel path → source file) copies."""
    origin = root / "origin.git"
    seed = root / "seed"
    _git(["init", "-q", "--bare", "-b", "dev", str(origin)], env, root)
    _git(["init", "-q", "-b", "dev", str(seed)], env, root)
    for rel, body in _DEV_FILES:
        _write(seed, rel, body)
    for rel, src in (extra or {}).items():
        (seed / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, seed / rel)
    _git(["add", "-A"], env, seed)
    _git(["commit", "-q", "-m", "base"], env, seed)
    _git(["push", "-q", str(origin), "dev"], env, seed)
    return origin


# ─────────────────────────────────────────────
# Syntax of the sourced libs
# ─────────────────────────────────────────────


def _sourced_libs() -> list[Path]:
    return sorted(_LIB_DIR.glob("*.sh"))


def test_branch_trust_lib_is_among_the_parsed_libs() -> None:
    assert _TRUST_LIB in _sourced_libs()


@pytest.mark.parametrize("lib", _sourced_libs(), ids=lambda p: p.name)
def test_sourced_lib_parses_as_bash(lib: Path, git_env: dict[str, str]) -> None:
    parsed = subprocess.run(
        ["bash", "-n", str(lib)],
        capture_output=True,
        text=True,
        env=git_env,
        timeout=_TIMEOUT_S,
    )
    assert parsed.returncode == 0, parsed.stderr


# ─────────────────────────────────────────────
# valid_worker_branch
# ─────────────────────────────────────────────


@pytest.mark.parametrize("branch", ["feat/x", "chore/a.b-c", "fix_1"])
def test_valid_worker_branch_allows_a_plain_branch(
    branch: str, git_env: dict[str, str]
) -> None:
    result = _bash_lib('valid_worker_branch "$1"', [branch], git_env)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize(
    "branch",
    [
        "dev",
        "main",
        "HEAD",
        "origin/dev",
        "origin/feat/x",
        "refs/heads/x",
        "a@{1}",
        "a..b",
        "-x",
        "x;y",
        "",
    ],
)
def test_valid_worker_branch_rejects_protected_and_ref_like_names(
    branch: str, git_env: dict[str, str]
) -> None:
    result = _bash_lib('valid_worker_branch "$1"', [branch], git_env)
    assert result.returncode == 1, f"{branch!r} accepted"


# ─────────────────────────────────────────────
# check_branch_trust
# ─────────────────────────────────────────────


@dataclass
class TrustRepo:
    root: Path
    main: Path  # the trusted clone of origin, where worktrees are registered
    env: dict[str, str]

    def worktree(self, name: str, branch: str | None = None) -> Path:
        wt = self.root / f"wt-{name}"
        _git(
            [
                "worktree",
                "add",
                "-q",
                "-b",
                branch or f"feat/{name}",
                str(wt),
                _BASE_REF,
            ],
            self.env,
            self.main,
        )
        return wt

    def commit_all(self, wt: Path, message: str, *, force: bool = False) -> None:
        _git(["add", "-A", *(["-f"] if force else [])], self.env, wt)
        _git(["commit", "-q", "-m", message], self.env, wt)


@pytest.fixture(scope="module")
def trust_origin(
    tmp_path_factory: pytest.TempPathFactory, git_env: dict[str, str]
) -> Path:
    """Built once: every test clones it (cheap), so no test can leak into another."""
    root = tmp_path_factory.mktemp("trust-origin")
    return _make_origin(root, git_env)


@pytest.fixture
def trust_repo(
    trust_origin: Path, tmp_path: Path, git_env: dict[str, str]
) -> TrustRepo:
    main = tmp_path / "main"
    _git(["clone", "-q", "-b", "dev", str(trust_origin), str(main)], git_env, tmp_path)
    return TrustRepo(root=tmp_path, main=main, env=git_env)


def _check_trust(
    repo: TrustRepo, wt: Path, base: str | None = _BASE
) -> subprocess.CompletedProcess[str]:
    if base is None:  # the helper's own default base
        return _bash_lib(
            'check_branch_trust "$1" "" "$2"', [str(wt), str(repo.main)], repo.env
        )
    return _bash_lib(
        'check_branch_trust "$1" "$2" "$3"', [str(wt), base, str(repo.main)], repo.env
    )


def _reset_bridge_deps(repo: TrustRepo, wt: Path) -> None:
    reset = _bash_lib('reset_bridge_deps "$1"', [str(wt)], repo.env)
    assert reset.returncode == 0, reset.stderr


def _assert_refused(
    result: subprocess.CompletedProcess[str], *named: tuple[Path, str]
) -> None:
    """Refused, and stderr lists each (path, label) as `  <path> <label>`."""
    assert result.returncode == _REFUSED, f"accepted; stderr={result.stderr!r}"
    for rel, label in named:
        assert f"  {rel.as_posix()} {label}" in result.stderr, result.stderr


def test_trust_accepts_a_branch_changing_only_non_trust_files(
    trust_repo: TrustRepo,
) -> None:
    wt = trust_repo.worktree("same")
    (wt / _APP).write_text("more code\n")
    trust_repo.commit_all(wt, "app only")

    result = _check_trust(trust_repo, wt)

    assert result.returncode == 0, result.stderr


def _plant_bridge_artefacts(wt: Path) -> Path:
    planted = _BRIDGE_MODULES / "dep" / "index.js"
    for rel, body in (
        (planted, "module.exports = 1\n"),
        (_BRIDGE / "inbox" / "msg.json", "{}\n"),
        (_BRIDGE_LOCK, '{"lockfileVersion":3}\n'),
    ):
        _write(wt, rel, body)
    return planted


def test_trust_accepts_the_bridge_artefacts_after_reset_bridge_deps(
    trust_repo: TrustRepo,
) -> None:
    wt = trust_repo.worktree("artefacts")
    _plant_bridge_artefacts(wt)

    _reset_bridge_deps(trust_repo, wt)
    result = _check_trust(trust_repo, wt)

    assert result.returncode == 0, result.stderr
    assert not (wt / _BRIDGE_MODULES).exists()
    assert not (wt / _BRIDGE_LOCK).exists()
    assert (wt / _BRIDGE / "inbox" / "msg.json").exists(), "inbox is not a dep — kept"


def test_trust_refuses_bridge_deps_left_without_a_reset(
    trust_repo: TrustRepo,
) -> None:
    # Probe U is the node_modules half: a planted module would run as the bridge's code.
    wt = trust_repo.worktree("noreset")
    planted = _plant_bridge_artefacts(wt)

    _assert_refused(
        _check_trust(trust_repo, wt),
        (_BRIDGE_MODULES, _MUST_BE_ABSENT),
        (_BRIDGE_LOCK, _MUST_BE_ABSENT),
    )
    assert (wt / planted).exists(), "the check must never clean up by itself"


def test_trust_refuses_a_committed_settings_change_and_names_it(
    trust_repo: TrustRepo,
) -> None:
    wt = trust_repo.worktree("settings")
    (wt / _SETTINGS).write_text('{"a":2}\n')
    trust_repo.commit_all(wt, "settings")

    result = _check_trust(trust_repo, wt)

    _assert_refused(result, (_SETTINGS, _DIFFERS))
    assert f"trust files differ from {_BASE_REF}:" in result.stderr, result.stderr


def test_trust_refuses_an_uncommitted_settings_edit(trust_repo: TrustRepo) -> None:
    wt = trust_repo.worktree("dirty")
    (wt / _SETTINGS).write_text('{"a":3}\n')

    _assert_refused(_check_trust(trust_repo, wt), (_SETTINGS, _DIFFERS))


def test_trust_refuses_a_committed_git_hook_and_mcp_change(
    trust_repo: TrustRepo,
) -> None:
    wt = trust_repo.worktree("hooks")
    (wt / _GIT_HOOKS / "pre-push").write_text("exit 0\n")
    (wt / _MCP).write_text('{"mcpServers":{"x":{}}}\n')
    trust_repo.commit_all(wt, "hooks+mcp")

    _assert_refused(
        _check_trust(trust_repo, wt),
        (_GIT_HOOKS / "pre-push", _DIFFERS),
        (_MCP, _DIFFERS),
    )


def test_trust_refuses_an_untracked_file_in_agent_hooks(
    trust_repo: TrustRepo,
) -> None:
    wt = trust_repo.worktree("untracked")
    (wt / _AGENT_HOOKS / "new.sh").write_text("evil\n")

    _assert_refused(
        _check_trust(trust_repo, wt), (_AGENT_HOOKS / "new.sh", _NOT_ON_DEV)
    )


def test_trust_refuses_a_trust_file_removed_from_the_worktree(
    trust_repo: TrustRepo,
) -> None:
    wt = trust_repo.worktree("removed")
    (wt / _AGENT_HOOKS / "guard.sh").unlink()

    _assert_refused(
        _check_trust(trust_repo, wt),
        (_AGENT_HOOKS / "guard.sh", "(on dev, missing here)"),
    )


def test_trust_fetches_a_missing_origin_dev_then_accepts(
    trust_repo: TrustRepo,
) -> None:
    wt = trust_repo.worktree("fetch")
    _git(["update-ref", "-d", _BASE_REF], trust_repo.env, trust_repo.main)

    result = _check_trust(trust_repo, wt)

    assert result.returncode == 0, result.stderr
    restored = _git(
        ["rev-parse", "--verify", _BASE_REF], trust_repo.env, trust_repo.main
    )
    assert restored.strip(), "origin/dev was not fetched back"


def test_trust_refuses_an_unresolvable_base(trust_repo: TrustRepo) -> None:
    wt = trust_repo.worktree("nobase")

    result = _check_trust(trust_repo, wt, base="origin/nope")

    assert result.returncode == _REFUSED, result.stderr
    assert "cannot resolve refs/remotes/origin/nope" in result.stderr, result.stderr


def test_trust_refuses_a_missing_worktree_dir(trust_repo: TrustRepo) -> None:
    result = _check_trust(trust_repo, trust_repo.root / "does-not-exist")

    assert result.returncode == _REFUSED, result.stderr
    assert "not found" in result.stderr, result.stderr


# py-reviewer's bypass probes (round 1) — each one must be refused.


def _commit_evil_settings(repo: TrustRepo, wt: Path, tag: str) -> None:
    (wt / _SETTINGS).write_text(f'{{"evil":"{tag}"}}\n')
    repo.commit_all(wt, tag)


def test_trust_refuses_a_local_branch_shadowing_origin_dev(
    trust_repo: TrustRepo,
) -> None:
    # Probe A: with a short-name base, `origin/dev` would resolve to this branch and compare it to itself.
    wt = trust_repo.worktree("A", branch=_BASE)
    _commit_evil_settings(trust_repo, wt, "A")

    _assert_refused(_check_trust(trust_repo, wt, base=None), (_SETTINGS, _DIFFERS))


def test_trust_refuses_a_tag_shadowing_origin_dev(trust_repo: TrustRepo) -> None:
    # Probe B.
    wt = trust_repo.worktree("B")
    _commit_evil_settings(trust_repo, wt, "B")
    _git(["tag", _BASE, "HEAD"], trust_repo.env, wt)

    _assert_refused(_check_trust(trust_repo, wt), (_SETTINGS, _DIFFERS))


@pytest.mark.parametrize(
    "flag",
    [
        pytest.param("--skip-worktree", id="C-skip-worktree"),
        pytest.param("--assume-unchanged", id="D-assume-unchanged"),
    ],
)
def test_trust_refuses_an_index_flag_hiding_a_dirty_edit(
    flag: str, trust_repo: TrustRepo
) -> None:
    # The gate hashes the disk, never the worktree's index: the flag is irrelevant, the bytes refuse.
    wt = trust_repo.worktree("flag")
    _git(["update-index", flag, _SETTINGS.as_posix()], trust_repo.env, wt)
    (wt / _SETTINGS).write_text('{"evil":"flag"}\n')

    _assert_refused(_check_trust(trust_repo, wt), (_SETTINGS, _DIFFERS))


def test_trust_refuses_a_committed_settings_local(trust_repo: TrustRepo) -> None:
    # Probe E: force-added past .gitignore.
    wt = trust_repo.worktree("E")
    (wt / _SETTINGS_LOCAL).write_text("{}\n")
    trust_repo.commit_all(wt, "E", force=True)

    _assert_refused(_check_trust(trust_repo, wt), (_SETTINGS_LOCAL, _MUST_BE_ABSENT))


def test_trust_refuses_an_ignored_untracked_settings_local(
    trust_repo: TrustRepo,
) -> None:
    # Probe E2: ignored by .gitignore, still read by Claude Code.
    wt = trust_repo.worktree("E2")
    (wt / _SETTINGS_LOCAL).write_text('{"permissions":{"allow":["Bash"]}}\n')

    _assert_refused(_check_trust(trust_repo, wt), (_SETTINGS_LOCAL, _MUST_BE_ABSENT))


def test_trust_refuses_a_changed_bridge_server(trust_repo: TrustRepo) -> None:
    # Probe F.
    wt = trust_repo.worktree("F")
    (wt / _BRIDGE_SERVER).write_text("// evil\n")
    trust_repo.commit_all(wt, "F")

    _assert_refused(_check_trust(trust_repo, wt), (_BRIDGE_SERVER, _DIFFERS))


def test_trust_refuses_an_ignored_untracked_file_in_agent_hooks(
    trust_repo: TrustRepo,
) -> None:
    # Probe G: the branch ignores its own planted hook.
    wt = trust_repo.worktree("G")
    evil = _AGENT_HOOKS / "evil.sh"
    (wt / ".gitignore").write_text(_GITIGNORE + evil.as_posix() + "\n")
    (wt / evil).write_text("x\n")

    _assert_refused(_check_trust(trust_repo, wt), (evil, _NOT_ON_DEV))


def test_trust_refuses_a_committed_claude_dir_symlink(
    trust_repo: TrustRepo,
) -> None:
    # Probe J: .claude replaced by a symlink to a directory outside the worktree.
    wt = trust_repo.worktree("J")
    outside = trust_repo.root / "evilclaude"
    shutil.copytree(wt / _CLAUDE, outside)
    (outside / _SETTINGS.name).write_text('{"evil":"J"}\n')
    _git(["rm", "-r", "-q", _CLAUDE.as_posix()], trust_repo.env, wt)
    (wt / _CLAUDE).symlink_to(outside, target_is_directory=True)
    trust_repo.commit_all(wt, "J")

    result = _check_trust(trust_repo, wt)

    assert result.returncode == _REFUSED, result.stderr
    assert f"{_CLAUDE.as_posix()} (symlink)" in result.stderr, result.stderr


# pr-reviewer's bypass probes (#231): the worktree's own git data must never be consulted.


def test_trust_refuses_a_git_file_redirected_to_a_fake_repo(
    trust_repo: TrustRepo,
) -> None:
    # Probe K: the fake repo's own refs/remotes/origin/dev carries the evil settings.
    wt = trust_repo.worktree("K")
    (wt / _SETTINGS).write_text('{"evil":"K"}\n')
    fake = trust_repo.root / "fakeK.git"
    _git(["init", "-q", "--bare", str(fake)], trust_repo.env, trust_repo.root)
    fake_env = {**trust_repo.env, "GIT_DIR": str(fake), "GIT_WORK_TREE": str(wt)}
    _git(["add", "-A"], fake_env, wt)
    _git(["commit", "-q", "-m", "evil"], fake_env, wt)
    _git(["update-ref", _BASE_REF, "HEAD"], fake_env, wt)
    (wt / ".git").write_text(f"gitdir: {fake}\n")

    result = _check_trust(trust_repo, wt)

    assert result.returncode == _REFUSED, result.stderr
    assert ".git points outside" in result.stderr, result.stderr


def test_trust_refuses_a_core_worktree_redirect_with_a_planted_file(
    trust_repo: TrustRepo,
) -> None:
    # Probe M: the worktree's git would look at a clean decoy instead of the planted settings.local.
    wt = trust_repo.worktree("M")
    decoy = trust_repo.worktree("Mdecoy")
    _git(
        ["config", "extensions.worktreeConfig", "true"], trust_repo.env, trust_repo.main
    )
    _git(["config", "--worktree", "core.worktree", str(decoy)], trust_repo.env, wt)
    (wt / _SETTINGS_LOCAL).write_text('{"hooks":"evil"}\n')

    result = _check_trust(trust_repo, wt)

    assert result.returncode == _REFUSED, result.stderr
    assert _CONFIG_WORKTREE_REFUSAL in result.stderr, result.stderr


def _install_marker_fsmonitor(root: Path) -> tuple[Path, Path]:
    marker = root / "FSMONITOR_RAN"
    script = root / "fsmon.sh"
    script.write_text(f'#!/bin/sh\n: > "{marker}"\nexit 1\n')
    script.chmod(0o755)
    return script, marker


def _configure_per_worktree_fsmonitor(repo: TrustRepo, wt: Path, script: Path) -> None:
    # Probe L.
    _git(["config", "extensions.worktreeConfig", "true"], repo.env, repo.main)
    _git(["config", "--worktree", "core.fsmonitor", str(script)], repo.env, wt)


def _configure_include_if_fsmonitor(repo: TrustRepo, wt: Path, script: Path) -> None:
    # Probe Q: the trusted repo's config includes a file (for any gitdir under the scratch root).
    included = repo.root / "inc.cfg"
    included.write_text(f"[core]\n\tfsmonitor = {script}\n")
    _git(
        ["config", f"includeIf.gitdir:{repo.root}/**.path", str(included)],
        repo.env,
        repo.main,
    )


@pytest.mark.parametrize(
    ("configure", "refusal"),
    [
        # A per-worktree config file is refused outright (it would steer every later git call).
        pytest.param(
            _configure_per_worktree_fsmonitor,
            _CONFIG_WORKTREE_REFUSAL,
            id="L-per-worktree",
        ),
        # The trusted repo's own config: clean tree, accepted — the probe is about execution only.
        pytest.param(_configure_include_if_fsmonitor, None, id="Q-includeIf"),
    ],
)
def test_trust_never_runs_a_configured_fsmonitor(
    configure: Callable[[TrustRepo, Path, Path], None],
    refusal: str | None,
    trust_repo: TrustRepo,
) -> None:
    wt = trust_repo.worktree("fsmon")
    script, marker = _install_marker_fsmonitor(trust_repo.root)
    configure(trust_repo, wt, script)

    result = _check_trust(trust_repo, wt)

    if refusal is None:
        assert result.returncode == 0, result.stderr
    else:
        assert result.returncode == _REFUSED, result.stderr
        assert refusal in result.stderr, result.stderr
    assert not marker.exists(), "the fsmonitor command ran during check_branch_trust"
    # Positive control: the planted command is live — a plain git status in the worktree runs it.
    subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=wt,
        env=trust_repo.env,
        capture_output=True,
        timeout=_TIMEOUT_S,
    )
    assert marker.exists(), "probe setup is inert: git status did not run the fsmonitor"


def test_trust_refuses_a_committed_npmrc_and_lockfile_even_after_reset(
    trust_repo: TrustRepo,
) -> None:
    # Probe V: reset_bridge_deps drops the lockfile, never .npmrc — that one still refuses.
    wt = trust_repo.worktree("V")
    (wt / _BRIDGE_NPMRC).write_text("registry=http://127.0.0.1:9/\n")
    (wt / _BRIDGE_LOCK).write_text('{"lockfileVersion":3}\n')
    trust_repo.commit_all(wt, "npmrc+lock", force=True)

    _assert_refused(
        _check_trust(trust_repo, wt),
        (_BRIDGE_NPMRC, _MUST_BE_ABSENT),
        (_BRIDGE_LOCK, _MUST_BE_ABSENT),
    )

    _reset_bridge_deps(trust_repo, wt)
    after = _check_trust(trust_repo, wt)

    _assert_refused(after, (_BRIDGE_NPMRC, _MUST_BE_ABSENT))
    assert _BRIDGE_LOCK.as_posix() not in after.stderr, after.stderr


# pr-reviewer's second round (#231): npm's project root, hard links, the worktree admin dir.


def test_trust_refuses_a_root_workspace_redirecting_the_bridge_sdk(
    trust_repo: TrustRepo,
) -> None:
    # Repro of r231/ws_e2e2.sh: a root package.json makes the bridge a workspace and overrides its SDK
    # with a vendored copy, so a plain `npm install` in the bridge dir would load the planted code.
    wt = trust_repo.worktree("ws")
    root_package = (
        '{"name":"root","private":true,"workspaces":["%s"],'
        '"overrides":{"@modelcontextprotocol/sdk":"file:./vendor/sdk"}}\n'
    ) % _BRIDGE.as_posix()
    _write(wt, Path("package.json"), root_package)
    sdk = Path("vendor", "sdk")
    _write(
        wt,
        sdk / "package.json",
        '{"name":"@modelcontextprotocol/sdk","version":"1.99.0"}\n',
    )
    _write(wt, sdk / "server" / "index.js", "export class Server {}\n")
    trust_repo.commit_all(wt, "add workspace root", force=True)

    _reset_bridge_deps(trust_repo, wt)  # as worker.sh does — the root is never cleaned
    _assert_refused(
        _check_trust(trust_repo, wt), (Path("package.json"), _MUST_BE_ABSENT)
    )


@pytest.mark.parametrize(
    "rel",
    [
        pytest.param(Path(".npmrc"), id="root"),
        pytest.param(_CLAUDE / ".npmrc", id="claude"),
    ],
)
def test_trust_refuses_an_npmrc_above_the_bridge(
    rel: Path, trust_repo: TrustRepo
) -> None:
    wt = trust_repo.worktree("npmrc")
    _write(wt, rel, "registry=http://127.0.0.1:9/\n")

    _assert_refused(_check_trust(trust_repo, wt), (rel, _MUST_BE_ABSENT))


@pytest.mark.parametrize(
    "modules",
    [
        pytest.param(Path("node_modules"), id="root"),
        pytest.param(_CLAUDE / "node_modules", id="claude"),
    ],
)
def test_trust_refuses_node_modules_above_the_bridge_and_reset_keeps_them(
    modules: Path, trust_repo: TrustRepo
) -> None:
    # Node resolves the bridge's imports upward through these: their presence refuses, never cleaned.
    wt = trust_repo.worktree("nm")
    planted = modules / "@modelcontextprotocol" / "sdk" / "index.js"
    _write(wt, planted, "evil\n")

    _reset_bridge_deps(trust_repo, wt)

    assert (wt / planted).exists(), (
        "reset_bridge_deps removed a non-bridge node_modules"
    )
    _assert_refused(_check_trust(trust_repo, wt), (modules, _MUST_BE_ABSENT))


def test_trust_accepts_must_be_absent_paths_holding_only_empty_dirs(
    trust_repo: TrustRepo,
) -> None:
    wt = trust_repo.worktree("emptydirs")
    for rel in (
        Path("node_modules", "a", "b"),
        _CLAUDE / "node_modules" / "x",
        _BRIDGE_MODULES / "y",
    ):
        (wt / rel).mkdir(parents=True)

    result = _check_trust(trust_repo, wt)

    assert result.returncode == 0, result.stderr


def test_trust_refuses_a_hardlinked_hook_file(trust_repo: TrustRepo) -> None:
    # Identical bytes, but a second link lets an outside writer change the hook after the check.
    wt = trust_repo.worktree("hardlink")
    hook = _AGENT_HOOKS / "guard.sh"
    os.link(wt / hook, trust_repo.root / "outside-link.sh")

    _assert_refused(_check_trust(trust_repo, wt), (hook, _HARD_LINK))


def _admin_dir(repo: TrustRepo, wt: Path) -> Path:
    return Path(_git(["rev-parse", "--absolute-git-dir"], repo.env, wt).strip())


def test_trust_refuses_an_admin_config_worktree(trust_repo: TrustRepo) -> None:
    # Even an empty one, and without extensions.worktreeConfig set.
    wt = trust_repo.worktree("cfgwt")
    (_admin_dir(trust_repo, wt) / "config.worktree").write_text("")

    result = _check_trust(trust_repo, wt)

    assert result.returncode == _REFUSED, result.stderr
    assert _CONFIG_WORKTREE_REFUSAL in result.stderr, result.stderr


def test_trust_refuses_a_commondir_pointing_at_another_repo(
    trust_repo: TrustRepo,
) -> None:
    wt = trust_repo.worktree("commondir")
    other = trust_repo.root / "other.git"
    _git(["init", "-q", "--bare", str(other)], trust_repo.env, trust_repo.root)
    (_admin_dir(trust_repo, wt) / "commondir").write_text(f"{other}\n")

    result = _check_trust(trust_repo, wt)

    assert result.returncode == _REFUSED, result.stderr
    assert "commondir points at" in result.stderr, result.stderr


# ─────────────────────────────────────────────
# worker.sh start flow (claude / npm / gh stubbed)
# ─────────────────────────────────────────────

_STUB_CLAUDE = '#!/bin/sh\necho "STUB-CLAUDE started in $(pwd -P)"\n'
_STUB_NPM = '#!/bin/sh\necho "$*" >> "$STUB_LOG_DIR/npm.log"\nmkdir -p node_modules\n'
_STUB_GH = "#!/bin/sh\nexit 0\n"
_WORKER_REFUSED = "REFUSED"
_STUB_STARTED = "STUB-CLAUDE started in "


@dataclass
class WorkerFlow:
    wt_root: Path  # <scratch>/app-wt, where worker.sh puts worktrees
    npm_log: Path
    results: dict[str, subprocess.CompletedProcess[str]]
    w1_after_reuse: dict[str, bool]  # stale artefacts present after case (b)


@pytest.fixture(scope="module")
def worker_flow(
    tmp_path_factory: pytest.TempPathFactory, git_env: dict[str, str]
) -> Iterator[WorkerFlow]:
    """Runs worker.sh's cases once, in order (each later case builds on w1 / ends with origin gone)."""
    root = tmp_path_factory.mktemp("workersh")
    stubs = root / "bin"
    stubs.mkdir()
    for name, body in (("claude", _STUB_CLAUDE), ("npm", _STUB_NPM), ("gh", _STUB_GH)):
        (stubs / name).write_text(body)
        (stubs / name).chmod(0o755)
    env = {
        **git_env,
        "PATH": f"{stubs}{os.pathsep}{git_env.get('PATH', '')}",
        "STUB_LOG_DIR": str(root),
    }
    origin = _make_origin(
        root,
        env,
        extra={
            Path("scripts") / _WORKER.name: _WORKER,
            Path("scripts") / _INSTALLER.name: _INSTALLER,
            Path("scripts", "lib") / _TRUST_LIB.name: _TRUST_LIB,
        },
    )
    main = root / "main"
    _git(["clone", "-q", "-b", "dev", str(origin), str(main)], env, root)
    (main / ".env").write_text("K=V\n")
    wt_root = root / "app-wt"
    w1 = wt_root / "w1"

    def run(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(main / "scripts" / _WORKER.name), *args],
            cwd=main,
            env=env,
            capture_output=True,
            text=True,
            timeout=_TIMEOUT_S,
        )

    results: dict[str, subprocess.CompletedProcess[str]] = {}
    results["a-fresh"] = run("w1")
    stale_module = w1 / _BRIDGE_MODULES / "stale" / "index.js"
    _write(w1, stale_module.relative_to(w1), "evil\n")
    _write(w1, _BRIDGE_LOCK, "{}\n")
    results["b-reuse-stale-deps"] = run("w1")
    w1_after_reuse = {
        "stale_module": stale_module.exists(),
        "lockfile": (w1 / _BRIDGE_LOCK).exists(),
    }
    results["c-reuse-other-branch"] = run("w1", "feat/other")
    _write(w1, _BRIDGE_NPMRC, "registry=http://127.0.0.1:9/\n")
    _git(["add", "-f", _BRIDGE_NPMRC.as_posix()], env, w1)
    _git(["commit", "-q", "-m", "npmrc"], env, w1)
    results["d-committed-npmrc"] = run("w1")
    results["e-dev-branch"] = run("w5", "dev")
    origin.rename(root / "origin.gone")
    results["f-fetch-fails"] = run("w6")
    yield WorkerFlow(
        wt_root=wt_root,
        npm_log=root / "npm.log",
        results=results,
        w1_after_reuse=w1_after_reuse,
    )


def _output(result: subprocess.CompletedProcess[str]) -> str:
    return result.stdout + result.stderr


def _assert_started_in(result: subprocess.CompletedProcess[str], wt: Path) -> None:
    assert result.returncode == 0, _output(result)
    assert f"{_STUB_STARTED}{wt.resolve()}" in result.stdout, _output(result)


def _assert_worker_refused(
    result: subprocess.CompletedProcess[str], reason: str
) -> None:
    assert result.returncode == _REFUSED, _output(result)
    assert _WORKER_REFUSED in result.stderr and reason in result.stderr, _output(result)
    assert _STUB_STARTED not in result.stdout, _output(result)


def test_worker_starts_a_fresh_worker_with_a_pinned_scriptless_lockless_npm_install(
    worker_flow: WorkerFlow,
) -> None:
    _assert_started_in(worker_flow.results["a-fresh"], worker_flow.wt_root / "w1")
    installs = worker_flow.npm_log.read_text().splitlines()
    assert installs, "npm was not called"
    bridge = (worker_flow.wt_root / "w1" / _BRIDGE).resolve()
    for line in installs:
        args = line.split()
        assert args[0] == "install", line
        for flag in ("--ignore-scripts", "--no-package-lock", "--workspaces=false"):
            assert flag in args, line
        # --prefix pins npm's project to the bridge dir: it never walks up to a root package.json.
        assert "--prefix" in args, line
        assert Path(args[args.index("--prefix") + 1]).resolve() == bridge, line


def test_worker_resets_stale_bridge_deps_on_a_reused_worktree(
    worker_flow: WorkerFlow,
) -> None:
    _assert_started_in(
        worker_flow.results["b-reuse-stale-deps"], worker_flow.wt_root / "w1"
    )
    assert worker_flow.w1_after_reuse == {"stale_module": False, "lockfile": False}


def test_worker_refuses_a_reused_worktree_on_another_branch(
    worker_flow: WorkerFlow,
) -> None:
    _assert_worker_refused(
        worker_flow.results["c-reuse-other-branch"],
        "is on 'feat/w1', not the requested 'feat/other'",
    )


def test_worker_refuses_a_branch_with_a_committed_npmrc(
    worker_flow: WorkerFlow,
) -> None:
    result = worker_flow.results["d-committed-npmrc"]
    _assert_worker_refused(result, "changes trust files")
    assert f"{_BRIDGE_NPMRC.as_posix()} {_MUST_BE_ABSENT}" in result.stderr, _output(
        result
    )


def test_worker_refuses_the_dev_branch(worker_flow: WorkerFlow) -> None:
    _assert_worker_refused(
        worker_flow.results["e-dev-branch"], "is not a branch a worker may use"
    )
    assert not (worker_flow.wt_root / "w5").exists()


def test_worker_refuses_when_the_dev_fetch_fails(worker_flow: WorkerFlow) -> None:
    _assert_worker_refused(
        worker_flow.results["f-fetch-fails"], "could not fetch origin dev"
    )
    assert not (worker_flow.wt_root / "w6").exists()


# ─────────────────────────────────────────────
# worker-spawner.sh with a stubbed worker-up.sh
# ─────────────────────────────────────────────

# `bad` fails, `slow` signals that it started then blocks until the test releases it (deterministic:
# no sleeps to race against), anything else comes up.
_STUB_WORKER_UP = """#!/usr/bin/env bash
case "$1" in
  bad)  echo "worker 'bad' REFUSED: branch changes trust files" >&2; exit 1 ;;
  slow) : > "$STUB_DIR/slow.started"
        for _ in $(seq 1 100); do [ -e "$STUB_DIR/slow.release" ] && break; sleep 0.05; done
        echo "up" ;;
  *)    echo "worker '$1' is up (branch=${2:-})" ;;
esac
"""
_SPAWNER_DEADLINE_S = 10
_SIGTERM_EXIT = 143
_SLOW_BRANCH = "feat/s\n"
_NEWER_SLOW_BRANCH = "feat/newer\n"
_FOREIGN_BRANCH = "feat/foreign\n"


@dataclass
class SpawnerRun:
    spawn: Path
    log: Path
    returncode: int
    output: str


def _wait_for(path: Path, deadline: float) -> None:
    while not path.exists():
        assert time.monotonic() < deadline, f"timed out waiting for {path}"
        time.sleep(0.02)


def _run_spawner(
    root: Path,
    env: dict[str, str],
    requests: dict[str, str],
    newer_slow: str | None = None,
    foreign_starting: dict[str, str] | None = None,
) -> SpawnerRun:
    """Run a scratch spawner over `requests` (all handled in the first tick, in glob order), SIGTERM it
    while `slow` is starting. `newer_slow`: a newer `slow` request lands in spawn/ before the TERM.
    `foreign_starting`: spawn-log/<name>.starting files this spawner never claimed."""
    repo = root / "r"
    _git(["init", "-q", str(repo)], env, root)
    (repo / "scripts" / "lib").mkdir(parents=True)
    shutil.copy2(_SPAWNER, repo / "scripts" / _SPAWNER.name)
    shutil.copy2(_TRUST_LIB, repo / "scripts" / "lib" / _TRUST_LIB.name)
    (repo / "scripts" / "worker-up.sh").write_text(_STUB_WORKER_UP)
    spawn = repo / ".claude" / "bridge" / "spawn"
    log = repo / ".claude" / "bridge" / "spawn-log"
    spawn.mkdir(parents=True)
    log.mkdir(parents=True)
    for name, body in requests.items():
        (spawn / name).write_text(body)
    for name, body in (foreign_starting or {}).items():
        (log / f"{name}.starting").write_text(body)

    stub_dir = root / "stub"
    stub_dir.mkdir()
    deadline = time.monotonic() + _SPAWNER_DEADLINE_S
    proc = subprocess.Popen(
        ["bash", str(repo / "scripts" / _SPAWNER.name)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env={**env, "STUB_DIR": str(stub_dir)},
        start_new_session=True,
    )
    try:
        _wait_for(stub_dir / "slow.started", deadline)
        assert (log / "slow.starting").exists(), "slow was not claimed before start-up"
        if newer_slow is not None:
            (spawn / "slow").write_text(newer_slow)
        proc.send_signal(signal.SIGTERM)
        (stub_dir / "slow.release").touch()
        output, _ = proc.communicate(timeout=_SPAWNER_DEADLINE_S)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.communicate(timeout=_TIMEOUT_S)
    return SpawnerRun(spawn=spawn, log=log, returncode=proc.returncode, output=output)


@pytest.fixture(scope="module")
def spawner_run(
    tmp_path_factory: pytest.TempPathFactory, git_env: dict[str, str]
) -> Iterator[SpawnerRun]:
    yield _run_spawner(
        tmp_path_factory.mktemp("spawner"),
        git_env,
        {
            ".alpha": "feat/a\n",  # dotfile: bash's * never matches it
            "beta.tmp": "feat/a\n",  # in-flight write: the *.tmp arm skips it
            "bad": "feat/x\n",  # worker-up fails
            "devreq": "dev\n",  # a worker must never sit on dev: rejected
            "evil": "feat/$(x)\n",  # shell syntax in the branch: rejected
            "ok": "feat/ok\n",  # comes up, after `bad` failed (glob order)
            "slow": _SLOW_BRANCH,  # in flight when the TERM arrives
        },
        foreign_starting={"x": _FOREIGN_BRANCH},  # another spawner's claim
    )


@pytest.fixture(scope="module")
def spawner_run_with_newer_request(
    tmp_path_factory: pytest.TempPathFactory, git_env: dict[str, str]
) -> Iterator[SpawnerRun]:
    yield _run_spawner(
        tmp_path_factory.mktemp("spawner-newer"),
        git_env,
        {"slow": _SLOW_BRANCH},
        newer_slow=_NEWER_SLOW_BRANCH,
    )


def test_spawner_exits_on_term_with_the_signal_status(spawner_run: SpawnerRun) -> None:
    assert spawner_run.returncode == _SIGTERM_EXIT, spawner_run.output


def test_spawner_never_picks_up_a_dotfile(spawner_run: SpawnerRun) -> None:
    # Bash's glob skips dotfiles before the `.*` case arm is reached; this pins the outcome, not the arm.
    assert (spawner_run.spawn / ".alpha").read_text() == "feat/a\n"
    assert not any("alpha" in p.name for p in spawner_run.log.iterdir())


def test_spawner_skips_a_tmp_request(spawner_run: SpawnerRun) -> None:
    assert (spawner_run.spawn / "beta.tmp").read_text() == "feat/a\n"
    assert not any("beta" in p.name for p in spawner_run.log.iterdir())


def test_spawner_rejects_invalid_and_protected_branches(
    spawner_run: SpawnerRun,
) -> None:
    for name in ("evil", "devreq"):
        assert not (spawner_run.spawn / name).exists(), name
        assert not (spawner_run.log / f"{name}.starting").exists(), name
        assert not (spawner_run.log / f"{name}.up").exists(), name
    rejected = sorted(p.read_text() for p in spawner_run.log.glob("rejected.*"))
    assert rejected == sorted(["feat/$(x)\n", "dev\n"]), rejected
    assert spawner_run.output.count("REJECTED") == 2, spawner_run.output


def test_spawner_records_a_failed_start_and_carries_on(
    spawner_run: SpawnerRun,
) -> None:
    failed = spawner_run.log / "bad.failed"
    assert failed.is_file(), list(spawner_run.log.iterdir())
    assert "REFUSED" in failed.read_text()
    assert not (spawner_run.log / "bad.starting").exists()
    assert not (spawner_run.spawn / "bad").exists()
    # `ok` sorts after `bad`: it came up, so the failure did not stop the loop.
    assert "is up (branch=feat/ok)" in (spawner_run.log / "ok.up").read_text()
    assert not (spawner_run.log / "ok.starting").exists()


def test_spawner_requeues_an_in_flight_request_on_term(
    spawner_run: SpawnerRun,
) -> None:
    assert (spawner_run.spawn / "slow").read_text() == _SLOW_BRANCH
    assert not (spawner_run.log / "slow.starting").exists()
    assert not (spawner_run.log / "slow.up").exists()
    assert "requeued: slow" in spawner_run.output, spawner_run.output


def test_spawner_never_requeues_a_claim_it_did_not_make(
    spawner_run: SpawnerRun,
) -> None:
    assert (spawner_run.log / "x.starting").read_text() == _FOREIGN_BRANCH
    assert not (spawner_run.spawn / "x").exists()
    assert "requeued: x" not in spawner_run.output, spawner_run.output


def test_spawner_requeue_never_clobbers_a_newer_request(
    spawner_run_with_newer_request: SpawnerRun,
) -> None:
    run = spawner_run_with_newer_request
    assert run.returncode == _SIGTERM_EXIT, run.output
    assert (run.spawn / "slow").read_text() == _NEWER_SLOW_BRANCH
    # The claimed request is kept, not lost.
    assert (run.log / "slow.starting").read_text() == _SLOW_BRANCH
    assert "could not requeue slow" in run.output, run.output
