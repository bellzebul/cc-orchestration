#!/usr/bin/env node
// Cowork <-> Claude Code bridge: a Claude Code *channel* MCP server.
//
// Inbound : any *.md dropped into .claude/bridge/inbox/ is pushed into the running
//           Claude Code session as a <channel source="cowork-bridge"> event.
// Outbound: Claude answers with the `bridge_reply` tool, which writes
//           .claude/bridge/outbox/<id>.md. Cowork polls that folder.
//
// Polling (not fs.watch) on purpose: inbox files are written from a VM through a
// shared mount and FSEvents may not fire for them.
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const INBOX = path.join(ROOT, 'inbox');
const OUTBOX = path.join(ROOT, 'outbox');
const PROCESSED = path.join(ROOT, 'processed');
const POLL_MS = Number(process.env.BRIDGE_POLL_MS ?? 1500);
const SESSION = process.env.BRIDGE_SESSION_NAME ?? path.basename(process.cwd());

// validateNeedsAction:begin  (the kit's tests/reference/test_bridge_yaml_scalar.py runs the code between the markers)
const NEEDS = ['human', 'orchestrator'];
const ACTION_MAX = 200;

const log = (...a) => console.error('[cowork-bridge]', ...a); // stdout is the MCP transport

const fail = (text) => ({ content: [{ type: 'text', text }], isError: true });

// `needs` / `action` feed the agent tracker (red + push only for needs=human), so they are
// validated here rather than trusted: a bad value must fail loudly, not page the phone.
function validateNeedsAction(status, needs, action) {
  if (needs !== undefined && !NEEDS.includes(needs)) {
    return `needs must be ${NEEDS.join(' | ')}, got ${JSON.stringify(needs)}`;
  }
  if (needs !== undefined && status === 'done') return 'needs must not be set on a done reply';
  if (action !== undefined) {
    if (typeof action !== 'string' || !action.trim()) return 'action must be a non-empty string';
    // Every line break a reader may honour: CR, LF, NEL, LINE / PARAGRAPH SEPARATOR.
    if (/[\r\n\u0085\u2028\u2029]/.test(action)) return 'action must be a single line (no line breaks)';
    // C0 / DEL / C1 controls (TAB excepted) and the BOM / non-characters: a YAML reader rejects or eats them.
    if (/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f\ufeff\ufffe\uffff]/.test(action)) {
      return 'action must not contain control characters (other than tab) or U+FEFF / U+FFFE / U+FFFF';
    }
    if (action.length > ACTION_MAX) return `action must be <= ${ACTION_MAX} chars, got ${action.length}`;
  }
  if (needs !== undefined && action === undefined) return 'action is required when needs is set';
  return null;
}
// validateNeedsAction:end

// `action` stays bare in the common case, so a line-based reader sees no quotes. It is
// double-quoted (with \ and " escaped) wherever a YAML reader would not read it back bare as the
// same string: a comment (` #`), a nested mapping (`: `), a tab, a leading indicator character,
// a trailing `:` or whitespace, or a value YAML 1.1 / 1.2 types as a non-string (bool, null,
// number, date). The non-string patterns are deliberately generous: quoting a string that would
// have read back fine is harmless, leaving one bare that would not is the bug.
// yamlScalar:begin  (the kit's tests/reference/test_bridge_yaml_scalar.py runs the code between the markers)
const YAML_UNSAFE_START = /^[\s"'[\]{}&*!|>%@#?:,`-]/;
const YAML_UNSAFE_END = /[\s:]$/;
const YAML_NON_STRING = [
  /^(true|false|yes|no|on|off|null|~|=|<<)$/i, // bool / null (YAML 1.1 + 1.2), the 1.1 value / merge keys
  /^[-+]?(0b[01_]+|0o?[0-7_]+|0x[0-9a-f_]+)$/i, // binary / octal / hex
  /^[-+]?([0-9][0-9_]*(\.[0-9_]*)?|\.[0-9][0-9_]*)(e[-+]?[0-9]+)?$/i, // int / float / exponent
  /^[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+(\.[0-9_]*)?$/, // YAML 1.1 base-60 (1:20 reads as 80)
  /^[-+]?\.(inf|nan)$/i, // infinity / not-a-number
  /^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}([Tt\s]|$)/, // date / timestamp
];
function yamlScalar(value) {
  const bareIsSafe =
    value !== '' &&
    !YAML_UNSAFE_START.test(value) &&
    !YAML_UNSAFE_END.test(value) &&
    !value.includes(' #') &&
    !value.includes(': ') &&
    !value.includes('\t') &&
    !YAML_NON_STRING.some((re) => re.test(value));
  if (bareIsSafe) return value;
  return `"${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}
// yamlScalar:end

const mcp = new Server(
  { name: 'cowork-bridge', version: '0.1.0' },
  {
    capabilities: { experimental: { 'claude/channel': {} }, tools: {} },
    instructions: [
      'Events from the cowork-bridge channel arrive as <channel source="cowork-bridge" id="..." file="...">.',
      'Each event is a task from the Cowork orchestrator. Do the work it asks for.',
      'When the task is finished (or blocked), you MUST call the `bridge_reply` tool with the same `id`,',
      'a `status` (done | blocked | failed) and a `report` (markdown: what was done, what changed, test results,',
      'open questions). The orchestrator only sees what you put in `bridge_reply` — nothing else reaches it.',
      'On blocked | failed, also set `needs` (human | orchestrator) and `action` (one line, one concrete command or',
      'action): `needs: human` only for what by policy only @@OWNER@@ clears (a missing .env key/secret, a schema',
      'migration to apply, an unapproved @@CONTRACTS@@ contract change, a paid run >= $@@HUMAN_USD@@) — it pages the phone;',
      'everything else is `needs: orchestrator`. Never set `needs` on a done reply.',
    ].join(' '),
  },
);

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'bridge_reply',
      description: 'Send the final report for a cowork-bridge task back to the Cowork orchestrator. Call exactly once per task id when the task is done, blocked or failed. On blocked/failed, say who must act (`needs`) and what exactly (`action`).',
      inputSchema: {
        type: 'object',
        properties: {
          id: { type: 'string', description: 'The id attribute of the <channel> event being answered.' },
          status: { type: 'string', enum: ['done', 'blocked', 'failed'] },
          report: { type: 'string', description: 'Markdown report for the orchestrator.' },
          needs: {
            type: 'string',
            enum: NEEDS,
            description: 'Who must act to unblock. `human` (pages @@OWNER@@\'s phone) ONLY for: a key/secret missing from .env, a schema migration to apply, a @@CONTRACTS@@ contract change not pre-approved, a paid run >= $@@HUMAN_USD@@. Everything else is `orchestrator`. Omit on done. Requires `action`.',
          },
          action: {
            type: 'string',
            maxLength: ACTION_MAX,
            description: `One line (no newlines, <= ${ACTION_MAX} chars): the single concrete command or action that unblocks, e.g. "apply migration 20261016120000_add_orders_table". Never prose.`,
          },
        },
        required: ['id', 'status', 'report'],
      },
    },
  ],
}));

mcp.setRequestHandler(CallToolRequestSchema, async (req) => {
  if (req.params.name !== 'bridge_reply') {
    return { content: [{ type: 'text', text: `unknown tool ${req.params.name}` }], isError: true };
  }
  const { id, status, report, needs, action } = req.params.arguments ?? {};
  if (!['done', 'blocked', 'failed'].includes(status)) {
    return fail(`status must be done | blocked | failed, got ${JSON.stringify(status)}`);
  }
  const invalid = validateNeedsAction(status, needs, action);
  if (invalid) return fail(invalid);
  const safeId = String(id).replace(/[^A-Za-z0-9._-]/g, '_');
  // Line order is part of the tracker's contract: id, status, needs?, action?, session, at.
  // Absent fields add no lines, so a reply without them is byte-identical to the old format.
  const extra = (needs !== undefined ? `needs: ${needs}\n` : '') + (action !== undefined ? `action: ${yamlScalar(action.trim())}\n` : '');
  const body = `---\nid: ${safeId}\nstatus: ${status}\n${extra}session: ${SESSION}\nat: ${new Date().toISOString()}\n---\n${report}\n`;
  const tmp = path.join(OUTBOX, `.${safeId}.tmp`);
  const final = path.join(OUTBOX, `${safeId}.md`);
  await fs.writeFile(tmp, body, 'utf8');
  await fs.rename(tmp, final); // atomic: the poller never sees a half-written file
  log('reply written', final);
  return { content: [{ type: 'text', text: `reply for ${safeId} delivered (${status})` }] };
});

async function pollInbox() {
  let names;
  try { names = (await fs.readdir(INBOX)).filter((n) => n.endsWith('.md') && !n.startsWith('.')).sort(); }
  catch (e) { log('inbox read failed', e.message); return; }
  for (const name of names) {
    const src = path.join(INBOX, name);
    let content;
    try { content = await fs.readFile(src, 'utf8'); } catch { continue; }
    if (!content.trim()) continue; // still being written
    const id = name.replace(/\.md$/, '');
    // claim it first so a crash mid-send can't deliver twice
    await fs.rename(src, path.join(PROCESSED, `${Date.now()}-${name}`));
    await mcp.notification({
      method: 'notifications/claude/channel',
      params: { content, meta: { id, file: name } },
    });
    log('delivered', name);
  }
}

await Promise.all([INBOX, OUTBOX, PROCESSED].map((d) => fs.mkdir(d, { recursive: true })));
await mcp.connect(new StdioServerTransport());
log(`connected; polling ${INBOX} every ${POLL_MS}ms as session "${SESSION}"`);
setInterval(() => pollInbox().catch((e) => log('poll error', e.message)), POLL_MS);
