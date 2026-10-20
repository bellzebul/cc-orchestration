"""yamlScalar in .claude/bridge/server.mjs: every value it emits reads back as the same string.

The bridge writes a blocked reply's `action:` into YAML frontmatter through yamlScalar, so a value a
YAML reader would retype (a bool, a number, a date) or misparse (a leading indicator, a trailing
colon, an inline comment) must come out double-quoted, and a plain command must stay bare. The
function's source is cut from between its `// yamlScalar:begin` / `// yamlScalar:end` markers and run
with `node -e`; PyYAML's safe_load is the reader.

The same file's validateNeedsAction (between `// validateNeedsAction:begin` / `:end`) is run the same
way to pin that `action` refuses control characters a YAML reader rejects or eats, tab excepted.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

pytestmark = pytest.mark.unit

_REPO_ROOT = Path(__file__).resolve().parents[3]
_SERVER = _REPO_ROOT / ".claude" / "bridge" / "server.mjs"
_SCALAR_FN = "yamlScalar"
_VALIDATE_FN = "validateNeedsAction"
_NODE_TIMEOUT_S = 30
_KEY = "action"
# reads a JSON list of strings on stdin, prints the JSON list of yamlScalar(value)
_DRIVER = (
    "let raw = '';"
    "process.stdin.on('data', (chunk) => { raw += chunk; });"
    "process.stdin.on('end', () => {"
    "  process.stdout.write(JSON.stringify(JSON.parse(raw).map((v) => yamlScalar(v))));"
    "});"
)

# Values a bare emit would NOT read back as the same string.
_TRICKY = [
    "# c",
    "- x",
    "? x",
    ": x",
    ", x",
    "`x`",
    "x:",
    "x ",
    " x",
    "",
    "true",
    "No",
    "NULL",
    "ON",
    "~",
    "=",
    "1",
    "-2.5",
    "+1",
    "010",
    "1_000",
    "0x1f",
    "1e3",
    "1:20",
    ".inf",
    "-.NaN",
    "<<",
    "2026-10-17",
    "2026-10-17T10:00:00",
    "a: b",
    "a #b",
    "x\ty",
    '"x',
    "'x",
    "@x",
    "%x",
    "|x",
    ">x",
    "!x",
    "*x",
    "&x",
    "{x",
    "[x",
    'say "hi" \\ ok:',
]
# Plain values that must be emitted bare (unquoted) and still round-trip.
_BARE = [
    "gh pr merge 5",
    "plain git fetch origin dev",
    "gh pr view 5 -R o/r",
    "a#b",
    'say "hi" \\ ok',
    "run uv sync then retry",
]


# reads a JSON list of action strings on stdin, prints the JSON list of the validator's verdicts
# (null = accepted, else the error message) for a blocked reply that needs the orchestrator
_VALIDATE_DRIVER = (
    "let raw = '';"
    "process.stdin.on('data', (chunk) => { raw += chunk; });"
    "process.stdin.on('end', () => {"
    "  process.stdout.write(JSON.stringify("
    "    JSON.parse(raw).map((a) => validateNeedsAction('blocked', 'orchestrator', a))));"
    "});"
)
# Characters a YAML reader rejects or silently eats: C0 (BEL, NUL), ESC, DEL, C1, the BOM and a
# non-character. Line breaks are refused by their own (earlier) rule, so none is listed here.
_CONTROL_ACTIONS = [
    "gh pr view 5\x07",
    "\x1b[31mgh pr view 5",
    "gh pr\x7f view 5",
    "\ufeffgh pr view 5",
    "gh pr view\x00 5",
    "gh pr view 5\x9f",
    "gh pr view 5\uffff",
]
_ACCEPTED_ACTIONS = [
    "gh pr view 5\t-R o/r",
    "run uv sync then retry",
]


def _marked_source(fn: str) -> str:
    """The code between `// <fn>:begin` and `// <fn>:end` in server.mjs."""
    begin, end_marker = f"// {fn}:begin", f"// {fn}:end"
    text = _SERVER.read_text()
    assert text.count(begin) == 1 and text.count(end_marker) == 1, (
        f"{_SERVER.name} must hold exactly one {begin!r} / {end_marker!r} pair"
    )
    start = text.index(begin)
    end = text.index(end_marker)
    assert start < end, f"{begin!r} must come before {end_marker!r}"
    source = text[text.index("\n", start) + 1 : end]
    assert f"function {fn}" in source, f"the markers no longer wrap {fn}"
    return source


def _run_in_node(source: str, driver: str, values: list[str]) -> list:
    """Run `source` + `driver` under node with `values` as JSON on stdin; return the parsed output."""
    node = shutil.which("node")
    if node is None:
        pytest.fail(
            "server.mjs code is checked by running it under `node`; install node — this test must not be skipped"
        )
    run = subprocess.run(
        [node, "-e", source + "\n" + driver],
        input=json.dumps(values),
        capture_output=True,
        text=True,
        timeout=_NODE_TIMEOUT_S,
    )
    assert run.returncode == 0, f"node exit {run.returncode}: {run.stderr.strip()}"
    outputs = json.loads(run.stdout)
    assert len(outputs) == len(values)
    return outputs


@pytest.fixture(scope="module")
def emitted() -> dict[str, str]:
    """value -> yamlScalar(value), all values in one node run."""
    values = [*_TRICKY, *_BARE]
    return dict(zip(values, _run_in_node(_marked_source(_SCALAR_FN), _DRIVER, values)))


@pytest.fixture(scope="module")
def verdicts() -> dict[str, str | None]:
    """action -> validateNeedsAction('blocked', 'orchestrator', action), all in one node run."""
    values = [*_CONTROL_ACTIONS, *_ACCEPTED_ACTIONS]
    return dict(zip(values, _run_in_node(_marked_source(_VALIDATE_FN), _VALIDATE_DRIVER, values)))


@pytest.mark.parametrize("value", [*_TRICKY, *_BARE], ids=repr)
def test_yaml_scalar_round_trips_through_a_yaml_reader(
    value: str, emitted: dict[str, str]
) -> None:
    line = f"{_KEY}: {emitted[value]}"

    loaded = yaml.safe_load(line)

    assert loaded == {_KEY: value}, f"{line!r} read back as {loaded!r}"


@pytest.mark.parametrize("value", _TRICKY, ids=repr)
def test_yaml_scalar_quotes_values_a_bare_emit_would_change(
    value: str, emitted: dict[str, str]
) -> None:
    assert emitted[value].startswith('"') and emitted[value].endswith('"'), (
        f"{value!r} emitted bare as {emitted[value]!r}"
    )


@pytest.mark.parametrize("value", _BARE, ids=repr)
def test_yaml_scalar_leaves_plain_values_bare(
    value: str, emitted: dict[str, str]
) -> None:
    assert emitted[value] == value, f"{value!r} needlessly quoted as {emitted[value]!r}"


@pytest.mark.parametrize("action", _CONTROL_ACTIONS, ids=ascii)
def test_validate_needs_action_rejects_control_characters(
    action: str, verdicts: dict[str, str | None]
) -> None:
    verdict = verdicts[action]

    assert verdict is not None and "control characters" in verdict, (
        f"{action!r} accepted (verdict {verdict!r})"
    )


@pytest.mark.parametrize("action", _ACCEPTED_ACTIONS, ids=ascii)
def test_validate_needs_action_accepts_tab_and_plain_actions(
    action: str, verdicts: dict[str, str | None]
) -> None:
    assert verdicts[action] is None, f"{action!r} rejected: {verdicts[action]!r}"
