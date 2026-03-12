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
import { Database } from "bun:sqlite";

// ── Env ───────────────────────────────────────────────────────────────────────

const AID_DIR = process.env.AID_DIR ?? "";
const AID_DATA = process.env.AID_DATA ?? "";
const AID_DEBUG_LOG = process.env.AID_DEBUG_LOG ?? "";
const TMUX_PANE = process.env.TMUX_PANE ?? "";
const AID_ORC_NAME = process.env.AID_ORC_NAME ?? "";   // short session name (e.g. "aid")
// Filter out "not a tty" which is what the `tty` command prints when stdin
// is not connected to a terminal (e.g. respawn-pane).
const _rawCallerClient = process.env.AID_CALLER_CLIENT ?? "";
let AID_CALLER_CLIENT = _rawCallerClient.includes("not a tty") ? "" : _rawCallerClient;

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

// ── Conv ownership sidecar DB ─────────────────────────────────────────────────
//
// We cannot write to opencode's DB while it is running (bun:sqlite crashes
// with "bad parameter or other API misuse" when a WAL-mode DB is locked by
// another writer). Instead we maintain our own tiny sidecar:
//
//   $AID_DIR/opencode/aid-conv-owners.db
//   table: conv_owner (id TEXT PRIMARY KEY, tmux_session TEXT NOT NULL)
//
// INSERT OR IGNORE gives us first-writer-wins for free: whichever nav process
// inserts a conv_id first owns it; subsequent inserts for the same id are
// silently dropped. On session restart the rows survive and the session
// re-adopts its history immediately.

const OWNERS_DB_PATH = join(AID_DIR, "opencode/aid-conv-owners.db");
// opencode's DB — opened readonly only, for the offline fallback.
const OPENCODE_DB = join(AID_DIR, "opencode/opencode.db");

function openOwnersDb(readonly = false): Database {
  const db = new Database(OWNERS_DB_PATH, { create: !readonly, readonly });
  db.run(`CREATE TABLE IF NOT EXISTS conv_owner (
    id           TEXT PRIMARY KEY,
    tmux_session TEXT NOT NULL
  )`);
  return db;
}

/** Claim any unowned conv IDs for `tmuxSession`. First-writer-wins via INSERT OR IGNORE. */
function tagConvsInDb(convIds: string[], tmuxSession: string): void {
  if (convIds.length === 0) return;
  try {
    const db = openOwnersDb();
    try {
      const insert = db.prepare("INSERT OR IGNORE INTO conv_owner (id, tmux_session) VALUES (?, ?)");
      const insertMany = db.transaction((ids: string[]) => {
        for (const id of ids) insert.run(id, tmuxSession);
      });
      insertMany(convIds);
    } finally {
      db.close();
    }
  } catch (e) {
    dbg("SQLITE", `tagConvsInDb failed: ${e}`);
  }
}

/** Return a map of conv_id → tmux_session for the given IDs (only those with an owner). */
function readConvOwners(convIds: string[]): Map<string, string> {
  const result = new Map<string, string>();
  if (convIds.length === 0) return result;
  try {
    const db = openOwnersDb(true);
    try {
      const placeholders = convIds.map(() => "?").join(",");
      const rows = db
        .query<{ id: string; tmux_session: string }, string[]>(
          `SELECT id, tmux_session FROM conv_owner WHERE id IN (${placeholders})`,
        )
        .all(...convIds);
      for (const r of rows) result.set(r.id, r.tmux_session);
    } finally {
      db.close();
    }
  } catch (e) {
    dbg("SQLITE", `readConvOwners failed: ${e}`);
  }
  return result;
}

/** Read convs from opencode's SQLite for IDs owned by `tmuxSession` (offline fallback). */
function convosFromDbForSession(tmuxSession: string): OrcConversation[] {
  try {
    // Get owned IDs from our sidecar.
    const db = openOwnersDb(true);
    let ids: string[] = [];
    try {
      ids = db
        .query<{ id: string }, [string]>("SELECT id FROM conv_owner WHERE tmux_session = ?")
        .all(tmuxSession)
        .map((r) => r.id);
    } finally {
      db.close();
    }
    if (ids.length === 0) return [];
    // Fetch conv details from opencode's DB (readonly — safe while opencode runs).
    const oc = new Database(OPENCODE_DB, { readonly: true, create: false });
    try {
      const placeholders = ids.map(() => "?").join(",");
      const rows = oc
        .query<{ id: string; title: string; directory: string; time_updated: number }, string[]>(
          `SELECT id, title, directory, time_updated FROM session
           WHERE time_archived IS NULL AND id IN (${placeholders})
           ORDER BY time_updated DESC`,
        )
        .all(...ids);
      return rows.map((r) => ({ id: r.id, title: r.title, directory: r.directory, time: { updated: r.time_updated } }));
    } finally {
      oc.close();
    }
  } catch (e) {
    dbg("SQLITE", `convosFromDbForSession failed: ${e}`);
    return [];
  }
}


interface OrcConversation {
  id: string;
  title?: string;
  time: { updated: number };
  directory?: string;
}

/** Compute the deterministic opencode port for a session name (mirrors orchestrator.sh). */
async function computePort(session: string): Promise<number> {
  const name = session.replace(/^aid@/, "");
  try {
    const proc = Bun.spawn(["sh", "-c", `printf '%s' ${JSON.stringify(name)} | cksum | cut -d' ' -f1`], {
      stdout: "pipe", stderr: "ignore",
    });
    const out = (await new Response(proc.stdout).text()).trim();
    await proc.exited;
    const crc = parseInt(out, 10);
    if (isNaN(crc)) return 0;
    return 4200 + (crc % 1000);
  } catch {
    return 0;
  }
}

async function orcPort(session: string): Promise<number> {
  const val = await tmuxOutput("show-environment", "-t", session, "AID_ORC_PORT");
  const m = val.match(/AID_ORC_PORT=(\d+)/);
  if (m) return parseInt(m[1], 10);
  // Not set in tmux env — session wasn't spawned by orchestrator.sh yet, but
  // the port is deterministic so compute it from the session name.
  return computePort(session);
}

async function orcConversations(port: number, tmuxSession: string, filter: boolean): Promise<OrcConversation[]> {
  if (port) {
    try {
      const resp = await fetch(`http://127.0.0.1:${port}/session`, {
        headers: { Accept: "application/json" },
        signal: AbortSignal.timeout(2000),
      });
      if (resp.ok) {
        const all = (await resp.json()) as OrcConversation[];
        // Always tag — ownership must be recorded regardless of filter state.
        tagConvsInDb(all.map((c) => c.id), tmuxSession);
        if (!filter) {
          return all.sort((a, b) => b.time.updated - a.time.updated);
        }
        // Read back ownership and keep only ours.
        const owners = readConvOwners(all.map((c) => c.id));
        const owned = all.filter((c) => owners.get(c.id) === tmuxSession);
        const sorted = owned.sort((a, b) => b.time.updated - a.time.updated);
        dbg("ORC", `port=${port} all=${all.length} owned=${owned.length}`);
        return sorted;
      }
    } catch { /* fall through to DB */ }
  }
  // Port offline — look up owned IDs from sidecar, fetch details from opencode DB.
  // When filter is off, we can't enumerate all convs offline (no port), so fall back to owned only.
  return convosFromDbForSession(tmuxSession);
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

/**
 * Resolve the tmux client tty to use with switch-client -c.
 * Prefers AID_CALLER_CLIENT (set by orchestrator.sh when available).
 * Falls back to listing all clients on the server and taking the most
 * recently active one — necessary when the nav process was spawned via
 * respawn-pane (stdin is not a tty) so AID_CALLER_CLIENT is empty, and
 * the user's terminal may be attached to a *different* session than the
 * one this nav pane lives in.
 */
async function resolveClient(): Promise<string> {
  if (AID_CALLER_CLIENT) return AID_CALLER_CLIENT;
  // Sort by activity descending so the most recently used client is first.
  const raw = await tmuxOutput(
    "list-clients", "-F", "#{client_activity} #{client_name}",
  ).catch(() => "");
  const client = raw.trim().split("\n")
    .map((l) => l.trim().split(/\s+/))
    .filter((p) => p.length >= 2)
    .sort((a, b) => Number(b[0]) - Number(a[0]))[0]?.[1] ?? "";
  dbg("CLIENT", `resolved client: ${client || "<none>"}`);
  return client;
}

/**
 * Select a conv in a foreign aid session by switching the tmux client to
 * that session.  Tells the foreign opencode to show the conv via HTTP first,
 * then jumps the terminal there with switch-client.
 */
async function switchToForeignConv(
  foreignSession: string,
  convId: string,
): Promise<boolean> {
  // Tell the foreign opencode to select the conv before we jump there.
  const port = await computePort(foreignSession);
  if (port) {
    await orcSelectConversation(port, convId);
    await tmuxRun("set-environment", "-t", foreignSession, "AID_ORC_ACTIVE_CONV", convId);
  }
  // Jump the terminal to the foreign session.
  const client = await resolveClient();
  dbg("SWITCH", `client=${client || "<none>"} foreignSession=${foreignSession}`);
  if (client) {
    const rc = await tmuxRun("switch-client", "-c", client, "-t", foreignSession);
    dbg("SWITCH", `switch-client -c ${client} -t ${foreignSession} rc=${rc}`);
  } else {
    const rc = await tmuxRun("switch-client", "-t", foreignSession);
    dbg("SWITCH", `switch-client -t ${foreignSession} (no client) rc=${rc}`);
  }
  return true;
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
  // ── Phase 1: all tmux queries in parallel ─────────────────────────────────
  const [rawSessions, currentSession] = await Promise.all([
    tmuxOutput(
      "list-sessions",
      "-F",
      "#{session_last_attached} #{session_name}",
    ),
    TMUX_PANE
      ? tmuxOutput("display-message", "-t", TMUX_PANE, "-p", "#{session_name}")
      : Promise.resolve(""),
  ]);

  const liveSessions: string[] = rawSessions
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => l.trim().split(/\s+/)[1])
    .filter(Boolean)
    .sort();

  // Always pin the current session to the top.
  if (currentSession && liveSessions.includes(currentSession)) {
    liveSessions.splice(liveSessions.indexOf(currentSession), 1);
    liveSessions.unshift(currentSession);
  }

  const meta = readMeta();
  const liveSet = new Set(liveSessions);
  const deadSessions = meta.map((m) => m.tmux_session).filter((s) => !liveSet.has(s));

  // ── Phase 2: per-session HTTP + tmux queries — all sessions in parallel ───
  interface SessionData {
    session: string;
    port: number;
    convs: OrcConversation[];
    activeConvId: string;
  }

  const sessionData: SessionData[] = await Promise.all(
    liveSessions.map(async (session): Promise<SessionData> => {
      const [port, activeConvId] = await Promise.all([
        orcPort(session),
        orcActiveConv(session),
      ]);
      const convs = await orcConversations(port, session, state.filterBySession);
      return { session, port, convs, activeConvId };
    }),
  );

  // ── Phase 3: assemble items list ──────────────────────────────────────────
  const items: ListItem[] = [];
  let first = true;

  for (const { session, convs, activeConvId } of sessionData) {
    if (!first) items.push({ kind: { type: "sep" }, selectable: false });
    first = false;

    items.push({
      kind: { type: "session", session, isCurrent: session === currentSession },
      selectable: true,
    });

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
//
// Colors are loaded at runtime from nvim/lua/palette.lua (the single source of
// truth for all aid theming). The Lua file uses a consistent line format:
//   M.key = "#rrggbb"   -- optional comment
// which is trivial to parse with a regex — no Lua runtime needed.

/** Parse nvim/lua/palette.lua and return a key→hex map. */
function loadPalette(): Record<string, string> {
  const luaPath = join(AID_DIR, "nvim/lua/palette.lua");
  let src = "";
  try { src = readFileSync(luaPath, "utf-8"); } catch {
    dbg("WARN", `palette.lua not found at ${luaPath}, using fallbacks`);
  }
  const map: Record<string, string> = {};
  for (const line of src.split("\n")) {
    const m = line.match(/^\s*M\.(\w+)\s*=\s*"(#[0-9a-fA-F]{6})"/);
    if (m) map[m[1]] = m[2];
  }
  return map;
}

/** Parse a #rrggbb hex string into [r, g, b]. */
function hex(h: string): [number, number, number] {
  const n = parseInt(h.slice(1), 16);
  return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
}

const tc = (r: number, g: number, b: number) => `\x1b[38;2;${r};${g};${b}m`;
const bc = (r: number, g: number, b: number) => `\x1b[48;2;${r};${g};${b}m`;

function buildAnsi(p: Record<string, string>) {
  // Helper: fg/bg from a palette key, with a fallback hex if the key is absent.
  const pfg = (key: string, fb: string) => { const [r,g,b] = hex(p[key] ?? fb); return tc(r,g,b); };
  const pbg = (key: string, fb: string) => { const [r,g,b] = hex(p[key] ?? fb); return bc(r,g,b); };

  return {
    reset:  "\x1b[0m",
    bold:   "\x1b[1m",
    dim:    "\x1b[2m",
    italic: "\x1b[3m",

    // Foreground
    fgWhite:    pfg("fg",        "#ffffff"),
    fgPurple:   pfg("purple",    "#b57bee"),
    fgBlue:     pfg("blue",      "#6180C5"),
    fgLavender: pfg("lavender",  "#A284C6"),
    fgGreen:    pfg("git_add",   "#50fa7b"),
    fgRed:      pfg("git_del",   "#ff5555"),
    fgAmber:    pfg("git_chg",   "#ffaa00"),
    fgMatch:    pfg("cmp_match", "#caa5f7"),
    fgGray:     pfg("cmp_menu",  "#7a6e96"),

    // Background
    bgTitleBar:  pbg("blue",       "#6180C5"),
    bgSelected:  pbg("cmp_sel_bg", "#3a3450"),
    bgLiveBadge: pbg("tab_sel",    "#a06a45"),
    bgDeadBadge: pbg("git_del_ln", "#3d1a1a"),

    // Terminal control
    altScreenOn:  "\x1b[?1049h",
    altScreenOff: "\x1b[?1049l",
    clearScreen:  "\x1b[2J\x1b[H",
    hideCursor:   "\x1b[?25l",
    showCursor:   "\x1b[?25h",
    moveTo: (row: number) => `\x1b[${row};1H\x1b[K`,
  };
}

// Populated in boot() after AID_DIR is validated; safe to use in any function
// called after boot() has started (all rendering happens after).
let A = buildAnsi({});  // fallback colors until palette is loaded

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

/**
 * Hard-clamp a string to `maxCols` visible characters.
 * Walks the string rune-by-rune, skipping ANSI escape sequences (they are
 * zero-width), counting printable chars. Once we hit `maxCols` printable
 * chars we stop and append reset so colours don't bleed into the next line.
 */
function clampLine(s: string, maxCols: number): string {
  if (maxCols <= 0) return A.reset;
  let visible = 0;
  let i = 0;
  let out = "";
  // eslint-disable-next-line no-control-regex
  const ESC_RE = /^\x1b\[[0-9;]*[mGKHABCDJsuhl?]/;
  while (i < s.length) {
    // Check for ESC sequence — consume it verbatim (zero width)
    const rest = s.slice(i);
    const m = rest.match(ESC_RE);
    if (m) {
      out += m[0];
      i += m[0].length;
      continue;
    }
    if (visible >= maxCols) break;
    out += s[i];
    visible++;
    i++;
  }
  return out + A.reset;
}

/**
 * Right-align `right` within `totalCols`.
 * If there isn't enough room for both sides, the right part is dropped
 * and the left is clamped to `totalCols`.
 */
function rightAlign(left: string, right: string, totalCols: number): string {
  const leftLen  = stripAnsi(left).length;
  const rightLen = stripAnsi(right).length;
  const needed   = leftLen + 1 + rightLen;
  if (needed > totalCols) {
    // Not enough room — just return left clamped to totalCols
    return clampLine(left, totalCols);
  }
  const gap = totalCols - leftLen - rightLen;
  return left + " ".repeat(gap) + right;
}

function renderItem(
  item: ListItem,
  selected: boolean,
  cols: number,
  /** index of this item within the conv list of its session (0-based) */
  convIndex = 0,
  /** total number of convs in this session's group */
  convTotal = 0,
): string {
  const rst = A.reset;

  // Selection is shown as a purple left-edge bar (▌) so the full-line background
  // tint never competes with the text colors, bold markers, or icons on the row.
  // We still apply a very subtle bg tint for the full row so the eye can track it,
  // but keep it extremely dark so fg colors/bold punch through unimpeded.
  const selBar = selected ? `${A.fgPurple}▌${rst}` : " ";
  const selBg  = selected ? A.bgSelected : "";
  // rfg: restore only the bg after an inline fg color change — does NOT reset bold/dim.
  // \x1b[39m = "default foreground color" (fg reset only).
  const rfg = `\x1b[39m${selBg}`;

  let content = "";

  switch (item.kind.type) {

    // ── session header ────────────────────────────────────────────────────────
    case "session": {
      const { session, isCurrent } = item.kind;
      const name = session.replace(/^aid@/, "");

      // Current session: purple caret; others: dim gray dot
      const caret = isCurrent
        ? `${A.fgPurple}${A.bold}❯${rfg} `
        : `${A.fgGray}·${rfg} `;
      const m = metaFor(session);
      const branch = m?.branch
        ? ` ${A.fgGray}(${m.branch})${rfg}`
        : "";
      // Session name: purple when current, lavender otherwise
      const nameColor = isCurrent ? A.fgPurple : A.fgLavender;
      const left = `${selBg}${selBar}${caret}${A.bold}${nameColor}${name}${rfg}${branch}`;

      // live indicator: dim green text, no background box
      const liveBadge = ` ${A.fgGreen}${A.dim}live${rfg}`;

      content = rightAlign(left, liveBadge, cols);
      break;
    }

    // ── dead session ──────────────────────────────────────────────────────────
    case "dead": {
      const { session, age } = item.kind;
      const name = session.replace(/^aid@/, "");

      const left  = `${selBg}${selBar} ${A.dim}${A.fgGray}${name}${rfg}`;
      const right = `${A.dim}${A.fgGray}${age} ${A.bgDeadBadge}${A.fgRed}${A.bold} dead ${rst}`;
      content = rightAlign(left, right, cols);
      break;
    }

    // ── conversation row ──────────────────────────────────────────────────────
    case "conv": {
      const { title, age, active } = item.kind;

      const isLast   = convIndex === convTotal - 1;
      const treeChar = isLast ? "└─" : "├─";
      // Tree connector: lavender
      const treePfx  = `${A.fgLavender}${treeChar}${rfg}`;

      // Active: purple filled circle; inactive: dim gray hollow circle
      const marker = active
        ? `${A.fgPurple}${A.bold}●${rfg} `
        : `${A.fgGray}${A.dim}○${rfg} `;

      // Title: bright white when active, muted otherwise; bold preserved via rfg
      const titleFmt = active ? `${A.bold}${A.fgWhite}` : `${A.dim}`;

      const left  = `${selBg}${selBar} ${treePfx} ${marker}${titleFmt}${title}${rfg}`;
      // Age: dim gray
      const right = `${A.fgGray}${A.dim}${age}`;
      content = rightAlign(left, right, cols);
      break;
    }

    // ── separator between session groups ─────────────────────────────────────
    case "sep": {
      // Blue tinted dim rule (matches title bar hue)
      return `${A.fgBlue}${A.dim}${"─".repeat(cols)}${rst}`;
    }

    // ── empty placeholder ─────────────────────────────────────────────────────
    case "empty": {
      const msg = item.kind.reason === "no-sessions"
        ? "no sessions yet"
        : "no conversations yet";
      content = `${selBg}${selBar} ${A.fgLavender}└─ ${A.dim}${A.fgGray}${msg}${rfg}`;
      break;
    }
  }

  // Pad to full width so the selected background covers the whole line
  const visLen = stripAnsi(content).length;
  const pad    = Math.max(0, cols - visLen);
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
  /** When true (default), each session only shows convs it owns. Toggle with 'f'. */
  filterBySession: boolean;
}

const state: AppState = {
  items: [],
  cursor: 0,
  mode: { type: "loading" },
  refreshing: false,
  statusMsg: "",
  filterBySession: true,
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

  // ── Row 1: title bar — full-width blue background ─────────────────────────
  // Build the full-width bar explicitly so the gap chars carry the bg color.
  // rightAlign() only inserts plain spaces (no escape codes) so we can't use
  // it here — the gap would revert to terminal default background.
  const titleLeftStr  = ` aid@${AID_ORC_NAME || "aid"}`;
  const filterTag     = state.filterBySession ? "" : ` ${A.reset}${A.bgTitleBar}${A.fgAmber}[all]`;
  const titleRightStr = " sessions ";
  const filterTagLen  = state.filterBySession ? 0 : 6; // " [all]" = 6 visible chars
  const titleGap = Math.max(1, cols - titleLeftStr.length - filterTagLen - titleRightStr.length);
  const titleBar =
    `${A.bgTitleBar}${A.fgWhite}${A.bold}${titleLeftStr}${filterTag}` +
    `${A.reset}${A.bgTitleBar}${" ".repeat(titleGap)}` +
    `${A.dim}${A.fgMatch}${titleRightStr}${A.reset}`;
  lines.push(titleBar);

  // Footer lines (computed first so we know how many rows it consumes)
  const footerLines = buildFooter(state.mode, cols);

  // Body area: rows minus title(1) + blank(1) + status(1) + footer lines
  const bodyRows = Math.max(1, rows - 3 - footerLines.length);

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

    // Pre-compute convIndex/convTotal for each item so renderItem can draw tree lines.
    // A "group" is the run of conv/empty items after each session header.
    const convMeta: Array<{ convIndex: number; convTotal: number }> =
      state.items.map(() => ({ convIndex: 0, convTotal: 0 }));

    {
      let groupConvIndices: number[] = [];
      const flush = () => {
        const total = groupConvIndices.length;
        groupConvIndices.forEach((idx, pos) => {
          convMeta[idx] = { convIndex: pos, convTotal: total };
        });
        groupConvIndices = [];
      };
      for (let i = 0; i < state.items.length; i++) {
        const k = state.items[i].kind.type;
        if (k === "session" || k === "dead" || k === "sep") {
          flush();
        } else if (k === "conv" || k === "empty") {
          groupConvIndices.push(i);
        }
      }
      flush();
    }

    const visible = state.items.slice(scrollStart, scrollStart + bodyRows);
    for (let i = 0; i < visible.length; i++) {
      const globalIdx = scrollStart + i;
      const item = visible[i];
      const isCursorItem =
        item.selectable && selectableIndices[state.cursor] === globalIdx;

      // In rename mode: replace the cursor row with the inline input field
      if (isCursorItem && state.mode.type === "rename") {
        const indent = item.kind.type === "conv" ? "    " : "  ";
        const input  = state.mode.input;
        const line   = `${A.bgSelected}${indent}${A.bold}rename:${A.reset}${A.bgSelected} ${input}${A.fgPurple}█${A.reset}`;
        const visLen = stripAnsi(line).length;
        const pad    = Math.max(0, cols - visLen);
        lines.push(line + " ".repeat(pad) + A.reset);
      } else {
        const { convIndex, convTotal } = convMeta[globalIdx];
        lines.push(renderItem(item, isCursorItem, cols, convIndex, convTotal));
      }
    }
    // Pad body to bodyRows so footer stays pinned
    while (lines.length < 1 + bodyRows) lines.push("");
  }

  // Blank separator
  lines.push("");

  // Status line
  if (state.statusMsg) {
    lines.push(`  ${A.fgAmber}${state.statusMsg}${A.reset}`);
  } else {
    lines.push("");
  }

  // Footer
  for (const fl of footerLines) lines.push(fl);

  return lines;
}

function render(): void {
  const { cols } = termSize();
  const frame = buildFrame();
  const buf: string[] = [];

  // Hide cursor, clear screen, then write every line using absolute positioning.
  // Never use \n — that would advance the scrollback buffer and cause lines to
  // pile up below the visible area on refresh.
  // Every line is hard-clamped to `cols` visible chars so nothing ever wraps.
  buf.push(A.hideCursor);
  buf.push(A.clearScreen);
  for (let i = 0; i < frame.length; i++) {
    buf.push(A.moveTo(i + 1) + clampLine(frame[i], cols));
  }

  safeWrite(buf.join(""));
}

function buildFooter(mode: Mode, cols: number): string[] {
  // Key hint: purple bold key, then dim gray description
  const k   = (s: string) => `${A.reset}${A.bold}${A.fgPurple}${s}${A.reset}${A.dim}`;
  const sepStr = "  ·  ";
  const sep = `${A.fgGray}${sepStr}`;

  let hints: Array<{ key: string; label: string }>;
  switch (mode.type) {
    case "nav":
    case "loading":
      hints = [
        { key: "↑↓", label: "nav" },
        { key: "↵",  label: "open" },
        { key: "n",  label: "new" },
        { key: "r",  label: "rename" },
        { key: "d",  label: "delete" },
        { key: "f",  label: "filter" },
        { key: "^r", label: "refresh" },
        { key: "q",  label: "quit" },
      ];
      break;
    case "rename":
      hints = [
        { key: "↵",   label: "confirm" },
        { key: "esc", label: "cancel" },
      ];
      break;
    case "delete-confirm": {
      const label = itemLabel(mode.item);
      return [`  ${A.fgRed}${A.bold}delete${A.reset} ${A.dim}${label}${A.reset}  ${A.bold}${A.fgAmber}y${A.reset}${A.dim}/${A.reset}${A.bold}n${A.reset}${A.dim}?${A.reset}`];
    }
  }

  // Greedily pack hints onto lines, wrapping when a hint would overflow.
  const indent = "  ";
  const indentLen = indent.length;
  const lines: string[] = [];
  let lineStr = `${A.dim}${indent}`;
  let lineLen = indentLen;
  let first = true;

  for (const { key, label } of hints) {
    const hintPlain = `${key} ${label}`;
    const hintLen = hintPlain.length;
    const withSep = first ? hintLen : sepStr.length + hintLen;

    if (!first && lineLen + withSep > cols) {
      // Wrap: close current line, start a new one
      lines.push(lineStr + A.reset);
      lineStr = `${A.dim}${indent}`;
      lineLen = indentLen;
      first = true;
    }

    if (!first) {
      lineStr += sep;
      lineLen += sepStr.length;
    }
    lineStr += `${k(key)} ${label}`;
    lineLen += hintLen;
    first = false;
  }

  if (lineLen > indentLen) lines.push(lineStr + A.reset);
  return lines.length > 0 ? lines : [""];
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
  const client = await resolveClient();
  if (client) {
    await tmuxRun("switch-client", "-c", client, "-t", session);
  } else {
    await tmuxRun("switch-client", "-t", session);
  }
}

async function loadConversation(convId: string, session: string): Promise<void> {
  dbg("CONV", `load convId=${convId} session=${session}`);

  // Determine the current tmux session (the one this navigator pane lives in).
  const curSession = TMUX_PANE
    ? await tmuxOutput("display-message", "-t", TMUX_PANE, "-p", "#{session_name}")
    : "";
  dbg("CONV", `curSession=${curSession || "<empty>"} TMUX_PANE=${TMUX_PANE || "<empty>"} foreign=${curSession && session !== curSession}`);

  // Conv belongs to a different session — tell that opencode to select the
  // conv then jump the client there.
  if (curSession && session !== curSession) {
    setStatus("loading…");
    render();
    const ok = await switchToForeignConv(session, convId);
    if (!ok) { setStatus("failed to switch to foreign session"); return; }
    setStatus("");
    render();
    return;
  }

  // Conv belongs to the current session.

  const port = await orcPort(session);
  if (!port) { setStatus("no opencode port for session"); return; }

  // Optimistically update the active marker in state immediately — no round-trip.
  for (const item of state.items) {
    if (item.kind.type !== "conv" || item.kind.session !== session) continue;
    item.kind.active = item.kind.convId === convId;
  }
  render();

  await tmuxRun("set-environment", "-t", session, "AID_ORC_ACTIVE_CONV", convId);
  await orcSelectConversation(port, convId);
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

  // Optimistic: insert a placeholder conv at the top of this session's group
  const placeholderId = "__placeholder__";
  const placeholder: ListItem = {
    kind: { type: "conv", convId: placeholderId, session: targetSession, title: "new conversation…", age: "now", active: false },
    selectable: false,
  };
  // Insert after the session header (first item for this session), before existing convs
  const insertIdx = state.items.findIndex(
    (i) => i.kind.type === "session" && i.kind.session === targetSession,
  );
  if (insertIdx >= 0) {
    state.items.splice(insertIdx + 1, 0, placeholder);
  } else {
    state.items.unshift(placeholder);
  }
  render();

  const newId = await orcNewConversation(port);

  // Remove placeholder regardless of outcome
  state.items = state.items.filter((i) => !(i.kind.type === "conv" && i.kind.convId === placeholderId));

  if (!newId) { setStatus("failed to create conversation"); render(); return; }

  dbg("ACTN", `new conv created id=${newId}`);
  tagConvsInDb([newId], targetSession);
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
    // Optimistic: patch the title in state immediately
    for (const item of state.items) {
      if (item.kind.type === "conv" && item.kind.convId === target.convId) {
        item.kind.title = title.length > 48 ? title.slice(0, 47) + "…" : title;
      }
    }
    render();
    const port = await orcPort(target.session);
    const ok = await orcRenameConversation(port, target.convId, title);
    if (!ok) { setStatus("rename failed"); await refresh(); return; }
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
  // Optimistic removal — strip the item (and any orphaned sep/empty) from
  // state immediately so the UI updates before the HTTP/tmux calls complete.
  switch (item.kind.type) {
    case "conv": {
      const { convId } = item.kind;
      state.items = state.items.filter((i) => !(i.kind.type === "conv" && i.kind.convId === convId));
      // If the session group is now empty, insert an empty placeholder
      // (the full refresh will fix it properly; this is just visual)
      break;
    }
    case "session": {
      const { session } = item.kind;
      state.items = state.items.filter((i) => {
        if (i.kind.type === "session" && i.kind.session === session) return false;
        if (i.kind.type === "conv"    && i.kind.session === session) return false;
        return true;
      });
      break;
    }
    case "dead": {
      const { session } = item.kind;
      state.items = state.items.filter((i) => !(i.kind.type === "dead" && i.kind.session === session));
      break;
    }
  }
  // Drop any leading/trailing sep rows left stranded after the removal
  while (state.items.length > 0 && state.items[0].kind.type === "sep") state.items.shift();
  while (state.items.length > 0 && state.items[state.items.length - 1].kind.type === "sep") state.items.pop();
  // Clamp cursor
  const n = state.items.filter((i) => i.selectable).length;
  if (state.cursor >= n) state.cursor = Math.max(0, n - 1);
  render();

  // Now do the actual async work in the background, then reconcile with a full refresh
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
        const convs = await orcConversations(port, m?.repo_path ?? "", true);
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

/**
 * Fast partial sync — only re-queries AID_ORC_ACTIVE_CONV for each live
 * session and patches the `active` flag on existing conv items in-place.
 * No HTTP calls, no list rebuild.  Runs in ~1 tmux round-trip per session.
 * Fired after every nav keypress so the ● marker stays current.
 */
let activeSyncing = false;
async function refreshActiveConvs(): Promise<void> {
  if (activeSyncing) return;
  activeSyncing = true;
  try {
    // Collect distinct sessions present in current item list
    const sessions = [...new Set(
      state.items
        .filter((i) => i.kind.type === "conv")
        .map((i) => (i.kind as { session: string }).session),
    )];
    if (sessions.length === 0) return;

    // Fetch active conv id for each session in parallel
    const activeMap = new Map(
      await Promise.all(sessions.map(async (s) => [s, await orcActiveConv(s)] as const)),
    );

    // Patch items in-place — no re-render needed unless something changed
    let changed = false;
    for (const item of state.items) {
      if (item.kind.type !== "conv") continue;
      const wanted = activeMap.get(item.kind.session) === item.kind.convId;
      if (item.kind.active !== wanted) {
        item.kind.active = wanted;
        changed = true;
      }
    }
    if (changed) render();
  } catch { /* best-effort */ } finally {
    activeSyncing = false;
  }
}

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
    case "session": switchToSession(item.kind.session); break; // switch client to this session
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
    if (key[2] === 0x41) { moveCursor(-1); refreshActiveConvs().catch(() => {}); return; }  // up
    if (key[2] === 0x42) { moveCursor(1);  refreshActiveConvs().catch(() => {}); return; }  // down
    if (key[2] === 0x35) { moveCursor(-10); refreshActiveConvs().catch(() => {}); return; } // page-up
    if (key[2] === 0x36) { moveCursor(10);  refreshActiveConvs().catch(() => {}); return; } // page-down
  }

  // q / bare Escape / Ctrl-C → quit
  if (ch === "q" || (key[0] === 0x1b && key.length === 1) || key[0] === 0x03) {
    cleanup();
    process.exit(0);
  }

  // vim-style navigation
  if (ch === "j") { moveCursor(1);  refreshActiveConvs().catch(() => {}); return; }
  if (ch === "k") { moveCursor(-1); refreshActiveConvs().catch(() => {}); return; }

  // Enter
  if (key[0] === 0x0d || key[0] === 0x0a) { onEnter(); return; }

  // n — new conversation
  if (ch === "n") { newConversation(); return; }

  // r — rename (inline)
  if (ch === "r") { startRename(); return; }

  // d — delete (inline confirm)
  if (ch === "d") { startDelete(); return; }

  // f — toggle per-session filter
  if (ch === "f") {
    state.filterBySession = !state.filterBySession;
    setStatus(state.filterBySession ? "filter: on" : "filter: off (showing all)");
    refresh();
    return;
  }

  // Ctrl-R — force full refresh
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

  // Load palette from nvim/lua/palette.lua — must happen before any render.
  A = buildAnsi(loadPalette());
  dbg("INIT", "palette loaded");

  // Resolve caller client tty + self-heal session tag — run in parallel
  const initTasks: Promise<unknown>[] = [];

  // Try to resolve the caller client tty.  The two sources are tried in
  // priority order:
  //   1. tmux display-message #{client_tty} for this pane
  //   2. the `tty` command (only valid when stdin IS a tty; outputs
  //      "not a tty" otherwise — that must be filtered out)
  // We run them sequentially so that the `tty` fallback only fires when
  // the tmux query returns empty (avoids storing "not a tty" in the var).
  if (!AID_CALLER_CLIENT) {
    initTasks.push(
      (async () => {
        // 1. tmux query (works even when stdin is not a tty).
        if (TMUX_PANE) {
          const tty = await tmuxOutput("display-message", "-t", TMUX_PANE, "-p", "#{client_tty}").catch(() => "");
          if (tty) { AID_CALLER_CLIENT = tty; return; }
        }
        // 2. `tty` binary fallback — only useful when stdin IS a real tty.
        try {
          const ttyProc = Bun.spawn(["tty"], { stdout: "pipe", stderr: "ignore" });
          const raw = (await new Response(ttyProc.stdout).text()).trim();
          if (raw && raw !== "not a tty" && !raw.includes("not a tty")) {
            AID_CALLER_CLIENT = raw;
          }
        } catch { /* ignore */ }
      })(),
    );
  }

  // Self-heal: ensure own session is tagged as orchestrator
  if (TMUX_PANE) {
    initTasks.push(
      tmuxOutput("display-message", "-t", TMUX_PANE, "-p", "#{session_name}")
        .catch(() => "")
        .then(async (selfSession) => {
          if (selfSession) {
            await tmuxRun("set-option", "-t", selfSession, "@aid_mode", "orchestrator");
            dbg("INIT", `self-heal: tagged ${selfSession} as orchestrator`);
          }
        }),
    );
  }

  await Promise.all(initTasks);
  dbg("INIT", `caller client: ${AID_CALLER_CLIENT || "<none>"}`);

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

  // Early-retry: if opencode wasn't ready yet (0 convs), poll quickly for up
  // to 3 s before settling into the normal 5 s interval.  This avoids a blank
  // "no conversations yet" for the full first interval when the process starts
  // before opencode's HTTP API is up.
  const hasConvs = () =>
    state.items.some((i) => i.kind.type === "conv");
  if (!hasConvs()) {
    dbg("INIT", "no convs yet — starting early-retry loop");
    const earlyStop = Date.now() + 3000;
    const earlyTimer = setInterval(async () => {
      if (hasConvs() || Date.now() >= earlyStop) {
        clearInterval(earlyTimer);
        dbg("INIT", "early-retry loop done");
        return;
      }
      if (state.mode.type === "nav") await refresh().catch(() => {});
    }, 500);
  }

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
