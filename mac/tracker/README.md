# Agent tracker (phone status board)

Shows every Claude Code session on this Mac — who waits on you (red), who reports to Cowork (yellow),
who waits on CI/tests (blue), who works, who died — and pushes the red ones to your phone via ntfy.
UI language: Ukrainian.

- `hook.mjs` — user-level Claude Code hook; writes `state/<session_id>.json` on every session event.
  A permission prompt shows the exact command being asked about.
- `server.mjs` — LAN server (no deps): `GET /api/sessions` + `public/index.html`. Token-protected.
- `install.mjs` — adds/removes the hooks in `~/.claude/settings.json` (backup first).

```bash
node install.mjs          # once; then restart running Claude Code sessions
node server.mjs           # or let ../launchd/install.sh run it at login (recommended)
node install.mjs --uninstall
```
Open the printed `http://<name>.local:7777/?k=…` URL on the phone (same Wi-Fi) and "Add to Home Screen".
Prefer the `.local` URL: the numeric IP changes when the router hands out a new one.

States: `waiting` (red) — an interactive terminal prompt (permission, question, plan approval) or a
bridge report with `needs: human`; `idle` — turn finished (a blocked/failed report without
`needs: human` is Cowork's to handle → yellow headline); `external` (blue) — only waiting on a shell
command it started (CI watch, tests); `working`; `dead` — process gone, hidden after 2 h.

Push: install the ntfy app and subscribe to the topic in `ntfy-topic` (printed at start; keep it secret —
anyone with the topic name can read the pushes). Buzzes on waiting (after 20 s, reminder at 15 min),
idle for 10 min, unexpected death. `NTFY=0` turns it off; `NTFY_SERVER` points at a self-hosted ntfy.
