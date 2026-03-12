#!/usr/bin/env bun
/**
 * aid-sessions — orchestrator session navigator.
 *
 * Runs as the persistent left pane inside every aid@<name> tmux session.
 * Replaces the bash+fzf implementation with a self-contained Bun/TypeScript
 * process: own terminal renderer, raw key input, native fetch() for HTTP,
 * Bun.spawn() for tmux calls, setInterval for auto-refresh.
 *
 * Env (required):
 *   AID_DIR   — aid install root
 *   AID_DATA  — aid runtime data root (sessions.json lives here)
 *
 * Env (optional):
 *   AID_DEBUG_LOG      — path to debug log file; enables debug logging when set
 *   AID_CALLER_CLIENT  — tmux client tty; used for switch-client -c targeting
 *   TMUX_PANE          — pane id of this pane (set by tmux automatically)
 */

import { appendFileSync, readFileSync, writeFileSync } from "fs";
import { join } from "path";

// ── Env ───────────────────────────────────────────────────────────────────────

const AID_DIR = process.env.AID_DIR ?? "";
const AID_DATA = process.env.AID_DATA ?? "";
const AID_DEBUG_LOG = process.env.AID_DEBUG_LOG ?? "";
const TMUX_PANE = process.env.TMUX_PANE ?? "";
let AID_CALLER_CLIENT = process.env.AID_CALLER_CLIENT ?? "";

if (!AID_DIR || !AID_DATA) {
  process.stderr.write("aid-sessions: AID_DIR and AID_DATA must be set\n");
  process.exit(1);
}

// ── Debug logging ─────────────────────────────────────────────────────────────

function dbg(cat: string, msg: string): void {
  if (!AID_DEBUG_LOG) return;
  const ms = Date.now();
  const line = `${ms} ${cat.padEnd(6)}${msg}\n`;
  try { appendFileSync(AID_DEBUG_LOG, line); } catch { /* best-effort */ }
}

// ── tmux helpers ──────────────────────────────────────────────────────────────

async function tmuxOutput(...args: string[]): Promise<string> {
  try {
    const proc = Bun.spawn(["tmux", "-L", "aid", ...args], {
      stdout: "pipe",
      stderr: "ignore",
    });
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    return out.trim();
  } catch {
    return "";
  }
}

// Returns true if exit code was 0
async function tmuxRun(...args: string[]): Promise<boolean> {
  try {
    const proc = Bun.spawn(["tmux", "-L", "aid", ...args], {
      stdout: "ignore",
      stderr: "ignore",
    });
    const code = await proc.exited;
    return code === 0;
  } catch {
    return false;
  }
}

// ── Sessions metadata (sessions.json) ─────────────────────────────────────────

interface SessionMeta {
  tmux_session: string;
  repo_path: string;
  branch?: string;
  created_at?: string;
  last_active?: string;
}

function readMeta(): SessionMeta[] {
  const path = join(AID_DATA, "sessions.json");
  try {
    const raw = readFileSync(path, "utf-8");
    return JSON.parse(raw) as SessionMeta[];
  } catch {
    return [];
  }
}

function writeMeta(meta: SessionMeta[]): void {
  const path = join(AID_DATA, "sessions.json");
  try { writeFileSync(path, JSON.stringify(meta, null, 2)); } catch { /* best-effort */ }
}

function metaFor(session: string): SessionMeta | undefined {
  return readMeta().find((m) => m.tmux_session === session);
}

// ── opencode HTTP API ─────────────────────────────────────────────────────────

interface OrcConversation {
  id: string;
  title?: string;
  time: { updated: number };
  directory?: string;
}

async function orcPort(session: string): Promise<number> {
  const val = await tmuxOutput("show-environment", "-t", session, "AID_ORC_PORT");
  const m = val.match(/AID_ORC_PORT=(\d+)/);
  if (!m) return 0;
  return parseInt(m[1], 10);
}

async function orcConversations(
  port: number,
  repoPath: string,
): Promise<OrcConversation[]> {
  if (!port) return [];
  try {
    const resp = await fetch(`http://127.0.0.1:${port}/session`, {
      headers: { Accept: "application/json" },
      signal: AbortSignal.timeout(2000),
    });
    if (!resp.ok) return [];
    const all = (await resp.json()) as OrcConversation[];
    return all
      .filter((c) => !repoPath || c.directory === repoPath)
      .sort((a, b) => b.time.updated - a.time.updated);
  } catch {
    return [];
  }
}

async function orcActiveConv(session: string): Promise<string> {
  const val = await tmuxOutput("show-environment", "-t", session, "AID_ORC_ACTIVE_CONV");
  const m = val.match(/AID_ORC_ACTIVE_CONV=(.+)/);
  return m ? m[1].trim() : "";
}

async function orcNewConversation(port: number): Promise<string> {
  if (!port) return "";
  try {
    const resp = await fetch(`http://127.0.0.1:${port}/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
      signal: AbortSignal.timeout(5000),
    });
    if (!resp.ok) return "";
    const data = (await resp.json()) as { id: string };
    return data.id ?? "";
  } catch {
    return "";
  }
}

async function orcSelectConversation(port: number, sessionID: string): Promise<void> {
  if (!port || !sessionID) return;
  try {
    await fetch(`http://127.0.0.1:${port}/tui/select-session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionID }),
      signal: AbortSignal.timeout(3000),
    });
  } catch { /* best-effort */ }
}

async function orcRenameConversation(port: number, convId: string, title: string): Promise<boolean> {
  if (!port || !convId) return false;
  try {
    const resp = await fetch(`http://127.0.0.1:${port}/session/${convId}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ title }),
      signal: AbortSignal.timeout(5000),
    });
    return resp.ok;
  } catch {
    return false;
  }
}

async function orcDeleteConversation(port: number, convId: string): Promise<void> {
  if (!port || !convId) return;
  try {
    await fetch(`http://127.0.0.1:${port}/session/${convId}`, {
      method: "DELETE",
      signal: AbortSignal.timeout(5000),
    });
  } catch { /* best-effort */ }
}

// ── List data model ───────────────────────────────────────────────────────────

type ItemKind =
  | { type: "session"; session: string; isCurrent: boolean }
  | { type: "conv"; convId: string; session: string; title: string; age: string; active: boolean }
  | { type: "dead"; session: string; age: string }
  | { type: "sep" }
  | { type: "empty"; reason: "no-convs" | "no-sessions" };

interface ListItem {
  kind: ItemKind;
  selectable: boolean;
}

function relativeTime(epochMs: number): string {
  if (!epochMs) return "unknown";
  const diff = Math.floor((Date.now() - epochMs) / 1000);
  if (diff < 60) return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

async function buildList(): Promise<ListItem[]> {
  // Live orchestrator sessions — use field-exact match on column 2 == "orchestrator"
  const rawSessions = await tmuxOutput(
    "list-sessions",
    "-F",
    "#{session_last_attached} #{@aid_mode} #{session_name}",
  );

  const liveSessions: string[] = rawSessions
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .filter((l) => {
      const parts = l.split(/\s+/);
      return parts[1] === "orchestrator";
    })
    .map((l) => l.trim().split(/\s+/)[2])
    .filter(Boolean)
    .sort();

  const meta = readMeta();
  const liveSet = new Set(liveSessions);

  // Dead sessions: in metadata but not in tmux
  const deadSessions = meta
    .map((m) => m.tmux_session)
    .filter((s) => !liveSet.has(s));

  // Current session (the one this navigator is running inside)
  const currentSession = TMUX_PANE
    ? await tmuxOutput("display-message", "-t", TMUX_PANE, "-p", "#{session_name}")
    : "";

  const items: ListItem[] = [];
  let first = true;

  for (const session of liveSessions) {
    if (!first) items.push({ kind: { type: "sep" }, selectable: false });
    first = false;

    const isCurrent = session === currentSession;
    items.push({
      kind: { type: "session", session, isCurrent },
      selectable: true,
    });

    const m = metaFor(session);
    const repo = m?.repo_path ?? "";
    const port = await orcPort(session);
    const convs = await orcConversations(port, repo);
    const activeConvId = await orcActiveConv(session);

    if (convs.length === 0) {
      items.push({ kind: { type: "empty", reason: "no-convs" }, selectable: false });
    } else {
      for (const conv of convs) {
        const raw = conv.title ?? "(untitled)";
        const title = raw.length > 48 ? raw.slice(0, 47) + "…" : raw;
        items.push({
          kind: {
            type: "conv",
            convId: conv.id,
            session,
            title,
            age: relativeTime(conv.time.updated),
            active: conv.id === activeConvId,
          },
          selectable: true,
        });
      }
    }
  }

  for (const session of deadSessions) {
    if (!first) items.push({ kind: { type: "sep" }, selectable: false });
    first = false;

    const m = metaFor(session);
    const lastActive = m?.last_active
      ? relativeTime(new Date(m.last_active).getTime())
      : "unknown";

    items.push({
      kind: { type: "dead", session, age: lastActive },
      selectable: true,
    });
  }

  if (items.length === 0) {
    items.push({ kind: { type: "empty", reason: "no-sessions" }, selectable: false });
  }

  return items;
}

// ── ANSI terminal rendering ───────────────────────────────────────────────────

const A = {
  reset:      "\x1b[0m",
  bold:       "\x1b[1m",
  dim:        "\x1b[2m",
  italic:     "\x1b[3m",
  fgGreen:    "\x1b[32m",
  fgRed:      "\x1b[31m",
  fgBlue:     "\x1b[34m",
  fgYellow:   "\x1b[33m",
  fgGray:     "\x1b[90m",
  bgSelected: "\x1b[48;5;236m",
  // Alternate screen buffer — no scrollback, no history leak
  altScreenOn:  "\x1b[?1049h",
  altScreenOff: "\x1b[?1049l",
  clearScreen:  "\x1b[2J\x1b[H",
  hideCursor:   "\x1b[?25l",
  showCursor:   "\x1b[?25h",
  // Move cursor to absolute row (1-based), column 1, then erase to end of line
  moveTo: (row: number) => `\x1b[${row};1H\x1b[K`,
};

function termSize(): { cols: number; rows: number } {
  return {
    cols: process.stdout.columns ?? 80,
    rows: process.stdout.rows ?? 24,
  };
}

function stripAnsi(s: string): string {
  // eslint-disable-next-line no-control-regex
  return s.replace(/\x1b\[[0-9;]*[mGKHABCDJsuhl?]/g, "");
}

function renderItem(item: ListItem, selected: boolean, cols: number): string {
  const bg = selected ? A.bgSelected : "";
  const rst = A.reset;

  let content = "";

  switch (item.kind.type) {
    case "session": {
      const { session, isCurrent } = item.kind;
      const name = session.replace(/^aid@/, "");
      const m = metaFor(session);
      const marker = isCurrent ? `${A.fgBlue}▶${rst}${bg} ` : "  ";
      const repo = m?.repo_path ? `  ${A.dim}${m.repo_path}${rst}${bg}` : "";
      const branch = m?.branch ? `  ${A.dim}(${m.branch})${rst}${bg}` : "";
      content = `${bg}${marker}${A.bold}aid@${name}${rst}${bg}  ${A.fgGreen}[live]${rst}${bg}${repo}${branch}`;
      break;
    }
    case "dead": {
      const { session, age } = item.kind;
      const name = session.replace(/^aid@/, "");
      const m = metaFor(session);
      const repo = m?.repo_path ? `  ${m.repo_path}` : "";
      content = `${bg}  ${A.dim}aid@${name}  [dead]  ${age}${repo}${rst}`;
      break;
    }
    case "conv": {
      const { title, age, active } = item.kind;
      const marker = active ? `${A.fgBlue}▶${rst}${bg} ` : "  ";
      content = `${bg}    ${marker}${title}  ${A.dim}${age}${rst}`;
      break;
    }
    case "sep": {
      return `${A.dim}${"─".repeat(cols)}${rst}`;
    }
    case "empty": {
      const msg = item.kind.reason === "no-sessions"
        ? "(no sessions yet)"
        : "(no conversations yet)";
      content = `${bg}    ${A.dim}${msg}${rst}`;
      break;
    }
  }

  // Pad to full width so the selected background covers the whole line
  const visLen = stripAnsi(content).length;
  const pad = Math.max(0, cols - visLen);
  return content + " ".repeat(pad) + rst;
}

// ── State ─────────────────────────────────────────────────────────────────────

type Mode =
  | { type: "nav" }
  | { type: "rename"; target: { kind: "session"; session: string } | { kind: "conv"; convId: string; session: string }; input: string }
  | { type: "delete-confirm"; item: ListItem }
  | { type: "loading" };

interface AppState {
  items: ListItem[];
  cursor: number;  // index into selectable items only
  mode: Mode;
  refreshing: boolean;
  statusMsg: string;
}

const state: AppState = {
  items: [],
  cursor: 0,
  mode: { type: "loading" },
  refreshing: false,
  statusMsg: "",
};

// ── Rendering ─────────────────────────────────────────────────────────────────

let statusClearTimer: ReturnType<typeof setTimeout> | null = null;

function safeWrite(s: string): void {
  try {
    process.stdout.write(s);
  } catch {
    // EIO / broken pipe — terminal is gone, exit cleanly
    cleanup();
    process.exit(0);
  }
}

function buildFrame(): string[] {
  const { cols, rows } = termSize();
  const lines: string[] = [];

  // Row 1: title bar
  lines.push(`${A.bold}${A.fgBlue} aid sessions ${A.reset}`);

  // Body area: rows minus title(1) + status(1) + footer(1) + spare(1)
  const bodyRows = Math.max(1, rows - 4);

  if (state.mode.type === "loading") {
    lines.push(`  ${A.dim}loading…${A.reset}`);
    for (let i = 1; i < bodyRows; i++) lines.push("");
  } else {
    const selectableIndices = state.items
      .map((item, i) => (item.selectable ? i : -1))
      .filter((i) => i >= 0);

    const cursorItemIdx = selectableIndices[state.cursor] ?? 0;

    // Scroll: keep cursor vertically centered
    const scrollStart = Math.max(
      0,
      Math.min(
        cursorItemIdx - Math.floor(bodyRows / 2),
        Math.max(0, state.items.length - bodyRows),
      ),
    );

    const visible = state.items.slice(scrollStart, scrollStart + bodyRows);
    for (let i = 0; i < visible.length; i++) {
      const globalIdx = scrollStart + i;
      const item = visible[i];
      const isCursorItem =
        item.selectable && selectableIndices[state.cursor] === globalIdx;

      // In rename mode: replace the cursor row with the inline input field
      if (isCursorItem && state.mode.type === "rename") {
        const indent = item.kind.type === "conv" ? "    " : "  ";
        const input = state.mode.input;
        const line = `${A.bgSelected}${indent}${A.bold}rename:${A.reset}${A.bgSelected} ${input}${A.fgBlue}█${A.reset}`;
        const visLen = stripAnsi(line).length;
        const pad = Math.max(0, cols - visLen);
        lines.push(line + " ".repeat(pad) + A.reset);
      } else {
        lines.push(renderItem(item, isCursorItem, cols));
      }
    }
    // Pad body to bodyRows so footer stays pinned
    while (lines.length < 1 + bodyRows) lines.push("");
  }

  // Blank separator
  lines.push("");

  // Status line
  if (state.statusMsg) {
    lines.push(`  ${A.fgYellow}${state.statusMsg}${A.reset}`);
  } else {
    lines.push("");
  }

  // Footer (last row)
  lines.push(buildFooter(state.mode, cols));

  return lines;
}

function render(): void {
  const frame = buildFrame();
  const buf: string[] = [];

  // Hide cursor, clear screen, then write every line using absolute positioning.
  // Never use \n — that would advance the scrollback buffer and cause lines to
  // pile up below the visible area on refresh.
  buf.push(A.hideCursor);
  buf.push(A.clearScreen);
  for (let i = 0; i < frame.length; i++) {
    buf.push(A.moveTo(i + 1) + frame[i]);
  }

  safeWrite(buf.join(""));
}

function buildFooter(mode: Mode, _cols: number): string {
  switch (mode.type) {
    case "nav":
    case "loading":
      return (
        `  ${A.dim}` +
        `${A.reset}${A.italic}enter${A.reset}${A.dim} open  ` +
        `${A.italic}n${A.reset}${A.dim} new conv  ` +
        `${A.italic}r${A.reset}${A.dim} rename  ` +
        `${A.italic}d${A.reset}${A.dim} delete  ` +
        `${A.italic}^r${A.reset}${A.dim} refresh  ` +
        `${A.italic}q${A.reset}${A.dim} quit${A.reset}`
      );
    case "rename":  // input is shown inline on the row; footer shows rename hints
      return (
        `  ${A.dim}` +
        `${A.reset}${A.italic}enter${A.reset}${A.dim} confirm  ` +
        `${A.italic}esc${A.reset}${A.dim} cancel${A.reset}`
      );
    case "delete-confirm": {
      const label = itemLabel(mode.item);
      return (
        `  ${A.fgRed}${A.bold}delete${A.reset} ` +
        `${A.dim}${label}${A.reset}  ` +
        `${A.bold}y${A.reset}${A.dim}/n?${A.reset}`
      );
    }
  }
}

function itemLabel(item: ListItem): string {
  switch (item.kind.type) {
    case "session": return item.kind.session;
    case "dead": return item.kind.session;
    case "conv": return item.kind.title;
    default: return "";
  }
}

function setStatus(msg: string, clearAfterMs = 2500): void {
  state.statusMsg = msg;
  render();
  if (statusClearTimer) clearTimeout(statusClearTimer);
  if (msg) {
    statusClearTimer = setTimeout(() => {
      state.statusMsg = "";
      render();
    }, clearAfterMs);
  }
}

// ── Cursor navigation ─────────────────────────────────────────────────────────

function selectableItems(): ListItem[] {
  return state.items.filter((i) => i.selectable);
}

function moveCursor(delta: number): void {
  const n = selectableItems().length;
  if (n === 0) return;
  state.cursor = Math.max(0, Math.min(n - 1, state.cursor + delta));
  render();
}

function currentItem(): ListItem | undefined {
  return selectableItems()[state.cursor];
}

// ── Actions ───────────────────────────────────────────────────────────────────

async function switchToSession(session: string): Promise<void> {
  dbg("ACTN", `switch-client -> ${session}`);
  if (AID_CALLER_CLIENT) {
    await tmuxRun("switch-client", "-c", AID_CALLER_CLIENT, "-t", session);
  } else {
    await tmuxRun("switch-client", "-t", session);
  }
}

async function loadConversation(convId: string, session: string): Promise<void> {
  dbg("CONV", `load convId=${convId} session=${session}`);
  const port = await orcPort(session);
  if (!port) { setStatus("no opencode port for session"); return; }

  await tmuxRun("set-environment", "-t", session, "AID_ORC_ACTIVE_CONV", convId);
  await orcSelectConversation(port, convId);

  const cur = TMUX_PANE
    ? await tmuxOutput("display-message", "-t", TMUX_PANE, "-p", "#{session_name}")
    : "";
  if (cur && cur !== session) {
    await switchToSession(session);
  }
}

async function newConversation(): Promise<void> {
  // Always create the new conversation in the current session (the one this
  // navigator pane is running inside). We never spawn new aid sessions here.
  let targetSession = "";
  if (TMUX_PANE) {
    targetSession = await tmuxOutput(
      "display-message", "-t", TMUX_PANE, "-p", "#{session_name}",
    );
  }
  if (!targetSession) { setStatus("cannot determine current session"); return; }

  dbg("ACTN", `new conversation in session=${targetSession}`);
  const port = await orcPort(targetSession);
  if (!port) { setStatus(`no opencode port for ${targetSession}`); return; }

  const newId = await orcNewConversation(port);
  if (!newId) { setStatus("failed to create conversation"); return; }

  dbg("ACTN", `new conv created id=${newId}`);
  await orcSelectConversation(port, newId);
  await refresh();
}

async function doRename(
  target: { kind: "session"; session: string } | { kind: "conv"; convId: string; session: string },
  rawInput: string,
): Promise<void> {
  if (target.kind === "conv") {
    const title = rawInput.trim();
    if (!title) return;
    dbg("RENAME", `conv ${target.convId} -> "${title}"`);
    const port = await orcPort(target.session);
    const ok = await orcRenameConversation(port, target.convId, title);
    if (!ok) { setStatus("rename failed"); return; }
    dbg("RENAME", "conv rename done");
    await refresh();
    return;
  }

  // Session rename
  const newShortName = rawInput
    .trim()
    .replace(/[^a-zA-Z0-9\-_.]/g, "-")
    .replace(/-+$/, "");
  if (!newShortName) return;

  const oldShortName = target.session.replace(/^aid@/, "");
  if (newShortName === oldShortName) return;

  const newSession = `aid@${newShortName}`;
  const exists = await tmuxRun("has-session", "-t", newSession);
  if (exists) { setStatus(`${newSession} already exists`); return; }

  dbg("RENAME", `${target.session} -> ${newSession}`);
  const ok = await tmuxRun("rename-session", "-t", target.session, newSession);
  if (!ok) { setStatus("rename failed"); return; }

  // Update metadata
  const allMeta = readMeta().map((m) =>
    m.tmux_session === target.session ? { ...m, tmux_session: newSession } : m
  );
  writeMeta(allMeta);
  dbg("RENAME", "session rename done");
  await refresh();
}

async function doDelete(item: ListItem): Promise<void> {
  switch (item.kind.type) {
    case "conv": {
      const { convId, session } = item.kind;
      dbg("DEL", `conv ${convId} from ${session}`);
      const port = await orcPort(session);
      await orcDeleteConversation(port, convId);
      break;
    }
    case "session": {
      const { session } = item.kind;
      dbg("DEL", `all convs in ${session}`);
      const port = await orcPort(session);
      if (port) {
        const m = metaFor(session);
        const convs = await orcConversations(port, m?.repo_path ?? "");
        for (const c of convs) await orcDeleteConversation(port, c.id);
      }
      break;
    }
    case "dead": {
      const { session } = item.kind;
      dbg("DEL", `removing dead session metadata: ${session}`);
      writeMeta(readMeta().filter((m) => m.tmux_session !== session));
      break;
    }
    default:
      break;
  }
  await refresh();
}

async function resurrectSession(session: string): Promise<void> {
  const m = metaFor(session);
  if (!m?.repo_path) { setStatus(`no repo path for ${session}`); return; }
  const name = session.replace(/^aid@/, "");
  dbg("ACTN", `resurrect ${session} repo=${m.repo_path}`);
  const proc = Bun.spawn(
    ["bash", join(AID_DIR, "lib/orchestrator.sh"), "--resurrect", name, m.repo_path],
    { env: { ...process.env, AID_DIR, AID_DATA }, stdout: "ignore", stderr: "ignore" },
  );
  await proc.exited;
  await refresh();
}

// ── Refresh ───────────────────────────────────────────────────────────────────

let refreshTimer: ReturnType<typeof setInterval> | null = null;

async function refresh(): Promise<void> {
  if (state.refreshing) return;
  state.refreshing = true;
  dbg("SYNC", "refresh start");
  try {
    const newItems = await buildList();
    state.items = newItems;
    // Clamp cursor to valid range after list change
    const n = selectableItems().length;
    if (state.cursor >= n) state.cursor = Math.max(0, n - 1);
    dbg("SYNC", `refresh done: ${state.items.length} items`);
  } catch (e) {
    dbg("ERR", `refresh failed: ${e}`);
  } finally {
    state.refreshing = false;
  }
  // Only transition out of loading; leave rename/delete-confirm intact
  if (state.mode.type === "loading") {
    state.mode = { type: "nav" };
  }
  render();
}

// ── Key input ─────────────────────────────────────────────────────────────────

function onEnter(): void {
  const item = currentItem();
  if (!item) return;
  switch (item.kind.type) {
    case "session": break; // already in this session; n to add a conversation
    case "dead": resurrectSession(item.kind.session); break;
    case "conv": loadConversation(item.kind.convId, item.kind.session); break;
    default: break;
  }
}

function startRename(): void {
  const item = currentItem();
  if (!item) return;
  if (item.kind.type === "conv") {
    // Rename conversation — default to current title (strip the truncation ellipsis)
    const rawTitle = item.kind.title.replace(/…$/, "");
    state.mode = {
      type: "rename",
      target: { kind: "conv", convId: item.kind.convId, session: item.kind.session },
      input: rawTitle,
    };
    render();
    return;
  }
  if (item.kind.type === "session" || item.kind.type === "dead") {
    const defaultName = item.kind.session.replace(/^aid@/, "");
    state.mode = {
      type: "rename",
      target: { kind: "session", session: item.kind.session },
      input: defaultName,
    };
    render();
    return;
  }
}

function startDelete(): void {
  const item = currentItem();
  if (!item) return;
  if (item.kind.type === "sep" || item.kind.type === "empty") return;
  state.mode = { type: "delete-confirm", item };
  render();
}

function handleRenameKey(key: Buffer): void {
  if (state.mode.type !== "rename") return;
  // Enter — commit
  if (key[0] === 0x0d || key[0] === 0x0a) {
    const { target, input } = state.mode;
    state.mode = { type: "nav" };
    doRename(target, input);
    return;
  }
  // Escape / Ctrl-C — cancel (bare ESC only; multi-byte ESC sequences are arrow keys etc.)
  if ((key[0] === 0x1b && key.length === 1) || key[0] === 0x03) {
    state.mode = { type: "nav" };
    render();
    return;
  }
  // Backspace
  if (key[0] === 0x7f || key[0] === 0x08) {
    state.mode = { ...state.mode, input: state.mode.input.slice(0, -1) };
    render();
    return;
  }
  // Printable chars (including unicode)
  const ch = key.toString("utf-8");
  if (ch.length >= 1 && key[0] >= 0x20) {
    state.mode = { ...state.mode, input: state.mode.input + ch };
    render();
  }
}

function handleDeleteKey(key: Buffer): void {
  if (state.mode.type !== "delete-confirm") return;
  const ch = key.toString("utf-8").toLowerCase();
  if (ch === "y") {
    const item = state.mode.item;
    state.mode = { type: "nav" };
    doDelete(item);
  } else {
    state.mode = { type: "nav" };
    render();
  }
}

function handleNavKey(key: Buffer): void {
  const ch = key.toString("utf-8");

  // Arrow keys: ESC [ A (up) / B (down) / 5~ (page-up) / 6~ (page-down)
  // Must be checked BEFORE the bare-ESC quit so ESC sequences aren't swallowed.
  if (key[0] === 0x1b && key[1] === 0x5b) {
    if (key[2] === 0x41) { moveCursor(-1); return; }  // up
    if (key[2] === 0x42) { moveCursor(1); return; }   // down
    if (key[2] === 0x35) { moveCursor(-10); return; } // page-up  (ESC[5~)
    if (key[2] === 0x36) { moveCursor(10); return; }  // page-down (ESC[6~)
  }

  // q / bare Escape / Ctrl-C → quit
  if (ch === "q" || (key[0] === 0x1b && key.length === 1) || key[0] === 0x03) {
    cleanup();
    process.exit(0);
  }

  // vim-style navigation
  if (ch === "j") { moveCursor(1); return; }
  if (ch === "k") { moveCursor(-1); return; }

  // Enter
  if (key[0] === 0x0d || key[0] === 0x0a) { onEnter(); return; }

  // n — new conversation
  if (ch === "n") { newConversation(); return; }

  // r — rename (inline)
  if (ch === "r") { startRename(); return; }

  // d — delete (inline confirm)
  if (ch === "d") { startDelete(); return; }

  // Ctrl-R — force refresh
  if (key[0] === 0x12) { dbg("KEY", "ctrl-r"); refresh(); return; }
}

function handleKey(key: Buffer): void {
  dbg("KEY", `raw: ${[...key].map((b) => b.toString(16).padStart(2, "0")).join(" ")}`);
  switch (state.mode.type) {
    case "rename": handleRenameKey(key); break;
    case "delete-confirm": handleDeleteKey(key); break;
    default: handleNavKey(key); break;
  }
}

// ── Cleanup ───────────────────────────────────────────────────────────────────

function cleanup(): void {
  if (refreshTimer) clearInterval(refreshTimer);
  if (statusClearTimer) clearTimeout(statusClearTimer);
  // Leave alternate screen buffer, restore cursor and terminal state
  try { process.stdout.write(A.altScreenOff + A.showCursor + A.reset); } catch { /* EIO — tty gone */ }
  try { process.stdout.write("\x1b[?1000l\x1b[?1002l\x1b[?1006l"); } catch { /* ignore */ }
  try {
    if (process.stdin.isTTY) process.stdin.setRawMode(false);
  } catch { /* ignore */ }
}

process.on("exit", cleanup);
process.on("SIGTERM", () => { cleanup(); process.exit(0); });
process.on("SIGINT", () => { cleanup(); process.exit(0); });
// SIGHUP: survive tmux respawn-pane -k which sends SIGHUP to the pane process group
process.on("SIGHUP", () => { /* ignore */ });
// Safety net: always restore terminal on any unhandled error before dying
process.on("uncaughtException", (e) => { dbg("ERR", `uncaught: ${e}`); try { cleanup(); } catch { /* ignore */ } process.exit(1); });
process.on("unhandledRejection", (e) => { dbg("ERR", `unhandledRejection: ${e}`); try { cleanup(); } catch { /* ignore */ } process.exit(1); });
process.stdout.on("resize", () => { render(); });

// ── Background dead-session prune ─────────────────────────────────────────────

async function pruneDead(): Promise<void> {
  const meta = readMeta();
  const kept: SessionMeta[] = [];
  let pruned = 0;
  for (const m of meta) {
    const exists = await tmuxRun("has-session", "-t", m.tmux_session);
    if (exists) {
      kept.push(m);
    } else {
      dbg("PRUNE", `removing dead session: ${m.tmux_session}`);
      pruned++;
    }
  }
  if (pruned > 0) writeMeta(kept);
}

// ── Boot ──────────────────────────────────────────────────────────────────────

async function boot(): Promise<void> {
  dbg("INIT", `aid-sessions.ts starting (pid=${process.pid} pane=${TMUX_PANE})`);

  // Resolve caller client tty
  if (!AID_CALLER_CLIENT && TMUX_PANE) {
    AID_CALLER_CLIENT = await tmuxOutput(
      "display-message", "-t", TMUX_PANE, "-p", "#{client_tty}",
    ).catch(() => "");
  }
  if (!AID_CALLER_CLIENT) {
    try {
      const ttyProc = Bun.spawn(["tty"], { stdout: "pipe", stderr: "ignore" });
      AID_CALLER_CLIENT = (await new Response(ttyProc.stdout).text()).trim();
    } catch { /* ignore */ }
  }
  dbg("INIT", `caller client: ${AID_CALLER_CLIENT || "<none>"}`);

  // Self-heal: ensure own session is tagged as orchestrator
  if (TMUX_PANE) {
    const selfSession = await tmuxOutput(
      "display-message", "-t", TMUX_PANE, "-p", "#{session_name}",
    ).catch(() => "");
    if (selfSession) {
      await tmuxRun("set-option", "-t", selfSession, "@aid_mode", "orchestrator");
      dbg("INIT", `self-heal: tagged ${selfSession} as orchestrator`);
    }
  }

  // Prune dead sessions from metadata (background, non-blocking)
  pruneDead().catch(() => { });

  // Set up raw stdin
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
  }
  process.stdin.resume();
  process.stdin.on("data", handleKey);

  // Enter alternate screen buffer — no scrollback, no history leak
  try { process.stdout.write(A.altScreenOn); } catch { /* ignore */ }

  // Initial loading render
  state.mode = { type: "loading" };
  render();

  // First data load
  await refresh();

  // Auto-refresh every 5s (only while in nav mode to avoid interrupting rename/delete)
  refreshTimer = setInterval(() => {
    if (state.mode.type === "nav") refresh().catch((e) => dbg("ERR", `interval refresh: ${e}`));
  }, 5000);

  dbg("INIT", "boot complete");
}

boot().catch((e) => {
  dbg("ERR", `boot failed: ${e}`);
  process.stderr.write(`aid-sessions: ${e}\n`);
  process.exit(1);
});
