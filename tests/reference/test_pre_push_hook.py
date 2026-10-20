"""scripts/git-hooks/pre-push: the resolved-ref barrier that keeps pushes off dev and main.

git feeds the hook one `<local ref> <local sha> <remote ref> <remote sha>` line per ref being pushed.
The table cases drive the hook directly with such lines; the end-to-end case makes a real `git push`
into a scratch bare remote with `core.hooksPath` pointed at the versioned hooks dir, proving git
actually runs it. The sealed-hook section runs scripts/install-git-hooks.sh into a scratch clone and
proves that disarming the TRACKED copy (chmod, truncate, rm, checkout of a hook-less commit), in the
clone or in one of its worktrees, leaves the push to dev refused. No network: the remote is a local path.
"""

import os
import shutil
import stat
import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

_REPO_ROOT = Path(__file__).resolve().parents[3]
_HOOKS_REL = Path("scripts") / "git-hooks"
_HOOKS_DIR = _REPO_ROOT / _HOOKS_REL
_HOOK = _HOOKS_DIR / "pre-push"
_INSTALLER = _REPO_ROOT / "scripts" / "install-git-hooks.sh"
_PROTECTED_DIR_NAME = "protected-hooks"
_HOOKS_PATH_KEY = "core.hooksPath"
_EXECUTABLE_SCRIPTS = (
    "scripts/worker.sh",
    "scripts/worker-up.sh",
    "scripts/worker-spawner.sh",
    "scripts/install-git-hooks.sh",
    (_HOOKS_REL / "pre-push").as_posix(),
)
_COMMIT_IDENTITY = (
    "-c", "user.name=battery",
    "-c", "user.email=battery@example.invalid",
    "-c", "commit.gpgsign=false",
)  # fmt: skip
_OVERRIDE_VAR = "GIT_PUSH_TO_PROTECTED"
_REMOTE_ARGS = ("origin", "git@example:x.git")
_TIMEOUT_S = 30
_REFUSED, _ALLOWED = 1, 0
_SHA = "1" * 40
_ZERO_SHA = "0" * 40
_GIT_ENV_PREFIX = "GIT_"


def _ref_line(remote_ref: str, local_ref: str = "refs/heads/feat/x") -> str:
    return f"{local_ref} {_SHA} {remote_ref} {_ZERO_SHA}\n"


# ─────────────────────────────────────────────
# Fixtures (every environment read happens here)
# ─────────────────────────────────────────────


@pytest.fixture(scope="session")
def hook_env() -> dict[str, str]:
    """The test process env without the human override and without any GIT_* leaking in."""
    return {
        k: v
        for k, v in os.environ.items()
        if not k.startswith(_GIT_ENV_PREFIX) and k not in ("BASH_ENV", "ENV")
    }


@pytest.fixture(scope="session")
def git_env(hook_env: dict[str, str]) -> dict[str, str]:
    """hook_env for real git calls: no global/system config (no signing, no user hooks), no prompts."""
    return {
        **hook_env,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_TERMINAL_PROMPT": "0",
    }


def _run_hook(stdin: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(_HOOK), *_REMOTE_ARGS],
        input=stdin,
        capture_output=True,
        text=True,
        env=env,
        timeout=_TIMEOUT_S,
    )


# ─────────────────────────────────────────────
# Hook verdicts on ref lines
# ─────────────────────────────────────────────


@pytest.mark.parametrize(
    ("stdin", "want"),
    [
        pytest.param(_ref_line("refs/heads/dev"), _REFUSED, id="push-to-dev"),
        pytest.param(_ref_line("refs/heads/main"), _REFUSED, id="push-to-main"),
        pytest.param(_ref_line("refs/heads/feat/x"), _ALLOWED, id="push-to-feature"),
        pytest.param(
            f"(delete) {_ZERO_SHA} refs/heads/dev {_SHA}\n", _REFUSED, id="delete-dev"
        ),
        pytest.param(
            _ref_line("refs/heads/feat/x")
            + _ref_line("refs/heads/dev", "refs/heads/dev")
            + _ref_line("refs/heads/feat/y"),
            _REFUSED,
            id="several-refs-one-is-dev",
        ),
        pytest.param("", _ALLOWED, id="empty-stdin"),
        pytest.param(_ref_line("refs/heads/development"), _ALLOWED, id="development"),
        pytest.param(_ref_line("refs/heads/maintenance"), _ALLOWED, id="maintenance"),
        pytest.param(_ref_line("refs/tags/dev"), _ALLOWED, id="tag-named-dev"),
    ],
)
def test_pre_push_refuses_only_dev_and_main_branch_refs(
    stdin: str, want: int, hook_env: dict[str, str]
) -> None:
    result = _run_hook(stdin, hook_env)
    assert result.returncode == want, (
        f"exit {result.returncode}, want {want}; stderr={result.stderr!r}"
    )
    if want == _REFUSED:
        assert "refusing" in result.stderr, result.stderr
    else:
        assert "refusing" not in result.stderr, result.stderr


def test_pre_push_allows_dev_with_the_human_override(
    hook_env: dict[str, str],
) -> None:
    result = _run_hook(_ref_line("refs/heads/dev"), {**hook_env, _OVERRIDE_VAR: "1"})
    assert result.returncode == _ALLOWED, result.stderr
    assert "human override" in result.stderr


@pytest.mark.parametrize("value", ["true", "yes", "0", ""])
def test_pre_push_ignores_an_override_other_than_1(
    value: str, hook_env: dict[str, str]
) -> None:
    result = _run_hook(_ref_line("refs/heads/dev"), {**hook_env, _OVERRIDE_VAR: value})
    assert result.returncode == _REFUSED, result.stderr
    assert "refusing" in result.stderr


# ─────────────────────────────────────────────
# End to end: git really runs the hook
# ─────────────────────────────────────────────


def _git(
    args: list[str], env: dict[str, str], cwd: Path
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", *args],
        capture_output=True,
        text=True,
        cwd=cwd,
        env=env,
        timeout=_TIMEOUT_S,
    )


def test_git_push_runs_the_versioned_hook(
    tmp_path: Path, git_env: dict[str, str]
) -> None:
    remote = tmp_path / "remote.git"
    work = tmp_path / "work"
    for args in (
        ["init", "-q", "--bare", str(remote)],
        ["init", "-q", "-b", "dev", str(work)],
    ):
        done = _git(args, git_env, tmp_path)
        assert done.returncode == 0, done.stderr
    commit = _git(
        [
            "-c", "user.name=battery",
            "-c", "user.email=battery@example.invalid",
            "-c", "commit.gpgsign=false",
            "commit", "-q", "--allow-empty", "-m", "init",
        ],
        git_env,
        work,
    )  # fmt: skip
    assert commit.returncode == 0, commit.stderr
    hooks = ["-c", f"core.hooksPath={_HOOKS_DIR}"]

    to_dev = _git([*hooks, "push", str(remote), "HEAD:refs/heads/dev"], git_env, work)
    to_feat = _git(
        [*hooks, "push", str(remote), "HEAD:refs/heads/feat/x"], git_env, work
    )

    assert to_dev.returncode != 0, f"push to dev went through: {to_dev.stderr!r}"
    assert "pre-push: refusing" in to_dev.stderr, to_dev.stderr
    assert to_feat.returncode == 0, to_feat.stderr
    refs = _git(["show-ref"], git_env, remote)
    assert "refs/heads/feat/x" in refs.stdout, refs.stdout
    assert "refs/heads/dev" not in refs.stdout, refs.stdout


# ─────────────────────────────────────────────
# Installer: the hook sealed outside every working tree
# ─────────────────────────────────────────────


@dataclass
class InstalledClone:
    work: Path  # a scratch checkout on dev holding a copy of scripts/
    remote: Path  # a scratch bare remote
    protected_dir: Path  # <git-common-dir>/protected-hooks, resolved
    pre_hook_sha: str  # a commit without scripts/ (as before the hook existed)


def _commit(work: Path, env: dict[str, str], message: str) -> str:
    done = _git(
        [*_COMMIT_IDENTITY, "commit", "-q", "--allow-empty", "-m", message], env, work
    )
    assert done.returncode == 0, done.stderr
    return _git(["rev-parse", "HEAD"], env, work).stdout.strip()


def _push(
    work: Path, env: dict[str, str], remote: Path, ref: str
) -> subprocess.CompletedProcess[str]:
    return _git(["push", str(remote), f"HEAD:{ref}"], env, work)


def _remote_refs(remote: Path, env: dict[str, str]) -> str:
    return _git(["show-ref"], env, remote).stdout


def _assert_dev_push_refused(
    clone: InstalledClone, env: dict[str, str], where: Path
) -> None:
    pushed = _push(where, env, clone.remote, "refs/heads/dev")
    assert pushed.returncode != 0, (
        f"push to dev went through from {where}: {pushed.stderr!r}"
    )
    assert "pre-push: refusing" in pushed.stderr, pushed.stderr
    assert "refs/heads/dev" not in _remote_refs(clone.remote, env)


@pytest.fixture
def installed_clone(tmp_path: Path, git_env: dict[str, str]) -> InstalledClone:
    """A scratch clone with a copy of scripts/ committed on dev, after scripts/install-git-hooks.sh ran."""
    remote = tmp_path / "remote.git"
    work = tmp_path / "work"
    for args in (
        ["init", "-q", "--bare", str(remote)],
        ["init", "-q", "-b", "dev", str(work)],
    ):
        done = _git(args, git_env, tmp_path)
        assert done.returncode == 0, done.stderr
    pre_hook_sha = _commit(work, git_env, "before the hook")
    (work / "scripts").mkdir()
    shutil.copy2(_INSTALLER, work / "scripts" / _INSTALLER.name)
    shutil.copytree(_HOOKS_DIR, work / _HOOKS_REL)
    added = _git(["add", "-A"], git_env, work)
    assert added.returncode == 0, added.stderr
    _commit(work, git_env, "add the hook")

    installed = subprocess.run(
        ["bash", str(_INSTALLER), str(work)],
        capture_output=True,
        text=True,
        env=git_env,
        timeout=_TIMEOUT_S,
    )
    assert installed.returncode == 0, installed.stderr
    common = _git(
        ["rev-parse", "--path-format=absolute", "--git-common-dir"], git_env, work
    )
    assert common.returncode == 0, common.stderr
    return InstalledClone(
        work=work,
        remote=remote,
        protected_dir=(Path(common.stdout.strip()) / _PROTECTED_DIR_NAME).resolve(),
        pre_hook_sha=pre_hook_sha,
    )


def test_installer_seals_the_hook_outside_the_tree(
    installed_clone: InstalledClone, git_env: dict[str, str]
) -> None:
    hook = installed_clone.protected_dir / _HOOK.name
    assert hook.is_file(), f"{hook} missing"
    assert stat.S_IMODE(hook.stat().st_mode) == 0o755, oct(hook.stat().st_mode)
    configured = _git(
        ["config", "--get", _HOOKS_PATH_KEY], git_env, installed_clone.work
    )
    assert configured.returncode == 0, configured.stderr
    assert Path(configured.stdout.strip()).resolve() == installed_clone.protected_dir

    _assert_dev_push_refused(installed_clone, git_env, installed_clone.work)
    to_feat = _push(
        installed_clone.work, git_env, installed_clone.remote, "refs/heads/feat/x"
    )
    assert to_feat.returncode == 0, to_feat.stderr
    assert "refs/heads/feat/x" in _remote_refs(installed_clone.remote, git_env)


def _disarm_chmod(clone: InstalledClone, env: dict[str, str]) -> None:
    (clone.work / _HOOKS_REL / _HOOK.name).chmod(0o644)


def _disarm_truncate(clone: InstalledClone, env: dict[str, str]) -> None:
    (clone.work / _HOOKS_REL / _HOOK.name).write_text("")


def _disarm_remove_dir(clone: InstalledClone, env: dict[str, str]) -> None:
    removed = _git(["rm", "-r", "-q", str(_HOOKS_REL)], env, clone.work)
    assert removed.returncode == 0, removed.stderr
    assert not (clone.work / _HOOKS_REL).exists()


def _disarm_checkout_pre_hook_commit(
    clone: InstalledClone, env: dict[str, str]
) -> None:
    switched = _git(["checkout", "-q", clone.pre_hook_sha], env, clone.work)
    assert switched.returncode == 0, switched.stderr
    assert not (clone.work / _HOOKS_REL).exists()


@pytest.mark.parametrize(
    "disarm",
    [
        pytest.param(_disarm_chmod, id="chmod-x-tracked-copy"),
        pytest.param(_disarm_truncate, id="truncate-tracked-copy"),
        pytest.param(_disarm_remove_dir, id="git-rm-r-tracked-dir"),
        pytest.param(
            _disarm_checkout_pre_hook_commit, id="checkout-commit-without-hook"
        ),
    ],
)
def test_disarming_the_tracked_copy_leaves_the_sealed_hook_armed(
    disarm: Callable[[InstalledClone, dict[str, str]], None],
    installed_clone: InstalledClone,
    git_env: dict[str, str],
) -> None:
    disarm(installed_clone, git_env)
    _assert_dev_push_refused(installed_clone, git_env, installed_clone.work)


def test_sealed_hook_covers_a_worktree_of_the_clone(
    installed_clone: InstalledClone, git_env: dict[str, str], tmp_path: Path
) -> None:
    worktree = tmp_path / "wt"
    added = _git(
        ["worktree", "add", "-q", "-b", "feat/wt", str(worktree)],
        git_env,
        installed_clone.work,
    )
    assert added.returncode == 0, added.stderr
    # Disarm the worktree's own tracked copy: with a relative core.hooksPath this alone would let the
    # push through, so the assertion below proves the worktree uses the sealed copy.
    (worktree / _HOOKS_REL / _HOOK.name).chmod(0o644)
    _assert_dev_push_refused(installed_clone, git_env, worktree)


# ─────────────────────────────────────────────
# File modes in the index
# ─────────────────────────────────────────────


@pytest.mark.parametrize("rel_path", _EXECUTABLE_SCRIPTS)
def test_script_is_executable_in_the_index(
    rel_path: str, hook_env: dict[str, str]
) -> None:
    listed = _git(["ls-files", "-s", "--", rel_path], hook_env, _REPO_ROOT)
    assert listed.returncode == 0, listed.stderr
    assert listed.stdout, f"{rel_path} is not tracked"
    mode = listed.stdout.split()[0]
    assert mode == "100755", f"{rel_path} is {mode} in the index, want 100755"


@pytest.mark.parametrize("rel_path", _EXECUTABLE_SCRIPTS)
def test_script_parses_as_bash(rel_path: str, hook_env: dict[str, str]) -> None:
    # Syntax only (`bash -n` never executes the script): the worker scripts drive tmux and Claude Code,
    # so their behaviour is verified end to end by hand, not here.
    parsed = subprocess.run(
        ["bash", "-n", str(_REPO_ROOT / rel_path)],
        capture_output=True,
        text=True,
        env=hook_env,
        timeout=_TIMEOUT_S,
    )
    assert parsed.returncode == 0, parsed.stderr
