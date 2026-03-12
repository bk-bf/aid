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

// ── Session ownership map ─────────────────────────────────────────────────────
//
// Maps opencode conv ID → aid tmux session name.
// Written to $AID_DATA/opencode/session-owners.json and updated whenever we
// fetch a live port's session list (which is the authoritative source for
// which convs belong to which aid session).
// Used to filter SQLite results for offline sessions.

const OWNERS_PATH = join(AID_DATA, "opencode/session-owners.json");

function readOwners(): Record<string, string> {
  try { return JSON.parse(readFileSync(OWNERS_PATH, "utf-8")); } catch { return {}; }
}

function writeOwners(owners: Record<string, string>): void {
  try { writeFileSync(OWNERS_PATH, JSON.stringify(owners, null, 2)); } catch { /* best-effort */ }
}

/** Tag all conv IDs returned by a live port as belonging to `tmuxSession`. Persists to disk. */
function tagConvOwners(convIds: string[], tmuxSession: string): void {
  const owners = readOwners();
  let changed = false;
  for (const id of convIds) {
    if (owners[id] !== tmuxSession) { owners[id] = tmuxSession; changed = true; }
  }
  if (changed) writeOwners(owners);
}

/** Return conv IDs owned by `tmuxSession` according to the persisted owner map. */
function ownedConvIds(tmuxSession: string): Set<string> {
  const owners = readOwners();
  return new Set(Object.entries(owners).filter(([, s]) => s === tmuxSession).map(([id]) => id));
}

/** Read convs from SQLite filtered to those owned by `tmuxSession`. */
function convosFromDbForSession(tmuxSession: string): OrcConversation[] {
  const ids = ownedConvIds(tmuxSession);
  if (ids.size === 0) return [];
  const dbPath = join(AID_DATA, "opencode/opencode.db");
  try {
    const db = new Database(dbPath, { readonly: true, create: false });
    try {
      // SQLite doesn't support array binding — build placeholders dynamically.
      const placeholders = Array.from(ids).map(() => "?").join(",");
      const rows = db
        .query<{ id: string; title: string; directory: string; time_updated: number }, string[]>(
          `SELECT id, title, directory, time_updated FROM session WHERE time_archived IS NULL AND id IN (${placeholders}) ORDER BY time_updated DESC`,
        )
        .all(...Array.from(ids));
      return rows.map((r) => ({ id: r.id, title: r.title, directory: r.directory, time: { updated: r.time_updated } }));
    } finally {
      db.close();
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

async function orcConversations(port: number, tmuxSession: string): Promise<OrcConversation[]> {
  if (port) {
    try {
      const resp = await fetch(`http://127.0.0.1:${port}/session`, {
        headers: { Accept: "application/json" },
        signal: AbortSignal.timeout(2000),
      });
      if (resp.ok) {
        const all = (await resp.json()) as OrcConversation[];
        const sorted = all.sort((a, b) => b.time.updated - a.time.updated);
        // Tag ownership while we have live data — this is how the map gets populated.
        if (sorted.length > 0) tagConvOwners(sorted.map((c) => c.id), tmuxSession);
        return sorted;
      }
    } catch { /* fall through to DB */ }
  }
  // Port offline — use the persisted owner map to filter the shared SQLite DB.
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

/** Look up the directory for a conv ID from the shared opencode SQLite DB. */
function convDirectory(convId: string): string {
  const dbPath = join(AID_DATA, "opencode/opencode.db");
  try {
    const db = new Database(dbPath, { readonly: true, create: false });
    try {
      const row = db
        .query<{ directory: string }, [string]>(
          "SELECT directory FROM session WHERE id = ? LIMIT 1",
        )
        .get(convId);
      return row?.directory ?? "";
    } finally {
      db.close();
    }
  } catch {
    return "";
  }
}

/**
 * Overlay pane system — one persistent pane per foreign aid session.
 *
 * Each foreign aid session gets exactly one overlay pane created on first
 * access. Switching between sessions swaps panes in/out of the "front" slot
 * (the large opencode position) without ever killing them. The original home
 * opencode pane is swapped to the background and keeps running.
 *
 * state.frontPane  — pane ID currently occupying the front (large) slot.
 * state.overlayPanes — foreignSession → pane ID of its overlay.
 */

/** Swap `paneA` and `paneB` positions/sizes in the window. */
async function swapToFront(targetPane: string): Promise<void> {
  const front = state.frontPane;
  if (!front || front === targetPane) return;
  await tmuxRun("swap-pane", "-s", front, "-t", targetPane);
  state.frontPane = targetPane;
}

/**
 * Ensure an overlay pane exists for `foreignSession`, creating it if needed.
 * The pane runs opencode on the foreign session's deterministic port at `directory`.
 * Returns the pane ID, or "" on failure.
 */
async function ensureOverlayPane(
  foreignSession: string,
  directory: string,
): Promise<string> {
  // Return existing pane if still alive.
  const existing = state.overlayPanes.get(foreignSession);
  if (existing) {
    const alive = await tmuxOutput("display-message", "-t", existing, "-p", "#{pane_id}").catch(() => "");
    if (alive.trim() === existing) return existing;
    // Pane died — remove stale entry and recreate.
    state.overlayPanes.delete(foreignSession);
  }

  // We need the front pane to split against.
  if (!state.frontPane) return "";

  const port = await computePort(foreignSession);
  if (!port) return "";

  const cmd = [
    `OPENCODE_CONFIG_DIR=${JSON.stringify(join(AID_DIR, "opencode"))}`,
    `OPENCODE_TUI_CONFIG=${JSON.stringify(join(AID_DIR, "opencode/tui.json"))}`,
    `XDG_DATA_HOME=${JSON.stringify(AID_DATA)}`,
    `opencode --port ${port} ${JSON.stringify(directory)}`,
  ].join(" ");

  // Split the current front pane: new pane gets 99% of space, pushing the
  // existing front pane to a 1-line sliver in the background.
  const newPaneId = await tmuxOutput(
    "split-window", "-v", "-t", state.frontPane, "-p", "99", "-d", "-P", "-F", "#{pane_id}",
    cmd,
  );
  const paneId = newPaneId.trim();
  if (!paneId) return "";

  // After split-window, the new pane is now at the large position and the
  // old front is at the sliver. Update frontPane to reflect this.
  state.frontPane = paneId;
  state.overlayPanes.set(foreignSession, paneId);

  dbg("OVERLAY", `created pane ${paneId} for ${foreignSession} port=${port}`);

  // Poll until opencode is up (max ~10s).
  for (let i = 0; i < 20; i++) {
    await Bun.sleep(500);
    try {
      const resp = await fetch(`http://127.0.0.1:${port}/session`, {
        signal: AbortSignal.timeout(500),
      });
      if (resp.ok) break;
    } catch { /* not up yet */ }
  }

  return paneId;
}

/**
 * Switch to a conv in a foreign aid session:
 * - If the session already has an overlay pane, swap it to front and select the conv.
 * - Otherwise create a new overlay pane (opencode boots in the foreign session's dir),
 *   which naturally lands in the front position.
 * Navigation within the same foreign session never swaps — just tui/select-session.
 */
async function switchToForeignConv(
  curSession: string,
  foreignSession: string,
  convId: string,
  directory: string,
): Promise<boolean> {
  const port = await computePort(foreignSession);
  if (!port) return false;

  const existing = state.overlayPanes.get(foreignSession);

  if (existing) {
    // Pane already exists — bring it to front if it isn't already.
    if (state.frontPane !== existing) {
      await swapToFront(existing);
    }
    // Select the conv inside this already-running opencode.
    await orcSelectConversation(port, convId);
  } else {
    // No overlay yet — create one. ensureOverlayPane boots opencode and
    // sets state.frontPane to the new pane automatically.
    const paneId = await ensureOverlayPane(foreignSession, directory);
    if (!paneId) return false;
    await orcSelectConversation(port, convId);
  }

  await tmuxRun("set-environment", "-t", curSession, "AID_ORC_ACTIVE_CONV", convId);
  // Focus the front pane so the user sees the opencode TUI.
  await tmuxRun("select-pane", "-t", state.frontPane);
  return true;
}

/**
 * Switch back to the home (current session) opencode pane.
 * Swaps `AID_ORC_ORC_PANE` back to the front position.
 */
async function switchToHomePane(curSession: string): Promise<void> {
  const orcPaneRaw = await tmuxOutput("show-environment", "-t", curSession, "AID_ORC_ORC_PANE");
  const m = orcPaneRaw.match(/AID_ORC_ORC_PANE=(%\d+)/);
  if (!m) return;
  const homePane = m[1];
  if (state.frontPane !== homePane) {
    await swapToFront(homePane);
  }
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
      const convs = await orcConversations(port, session);
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
  /** Maps foreign tmux session name → overlay pane ID (%NNN) in the current window. */
  overlayPanes: Map<string, string>;
  /** The pane ID currently occupying the "front" (large) opencode slot. */
  frontPane: string;
}

const state: AppState = {
  items: [],
  cursor: 0,
  mode: { type: "loading" },
  refreshing: false,
  statusMsg: "",
  overlayPanes: new Map(),
  frontPane: "",
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
  const titleRightStr = " sessions ";
  const titleGap = Math.max(1, cols - titleLeftStr.length - titleRightStr.length);
  const titleBar =
    `${A.bgTitleBar}${A.fgWhite}${A.bold}${titleLeftStr}` +
    `${A.reset}${A.bgTitleBar}${" ".repeat(titleGap)}` +
    `${A.dim}${A.fgMatch}${titleRightStr}${A.reset}`;
  lines.push(titleBar);

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

  // Footer (last row)
  lines.push(buildFooter(state.mode, cols));

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

function buildFooter(mode: Mode, _cols: number): string {
  // Key hint: purple bold key, then dim gray description
  const k   = (s: string) => `${A.reset}${A.bold}${A.fgPurple}${s}${A.reset}${A.dim}`;
  const sep = `${A.fgGray}  ·  `;
  switch (mode.type) {
    case "nav":
    case "loading":
      return (
        `${A.dim}  ` +
        `${k("↑↓")} nav${sep}` +
        `${k("↵")} open${sep}` +
        `${k("n")} new${sep}` +
        `${k("r")} rename${sep}` +
        `${k("d")} delete${sep}` +
        `${k("^r")} refresh${sep}` +
        `${k("q")} quit` +
        A.reset
      );
    case "rename":
      return (
        `${A.dim}  ` +
        `${k("↵")} confirm${sep}` +
        `${k("esc")} cancel` +
        A.reset
      );
    case "delete-confirm": {
      const label = itemLabel(mode.item);
      return (
        `  ${A.fgRed}${A.bold}delete${A.reset} ` +
        `${A.dim}${label}${A.reset}  ` +
        `${A.bold}${A.fgAmber}y${A.reset}${A.dim}/${A.reset}${A.bold}n${A.reset}${A.dim}?${A.reset}`
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

  // Determine the current tmux session (the one this navigator pane lives in).
  const curSession = TMUX_PANE
    ? await tmuxOutput("display-message", "-t", TMUX_PANE, "-p", "#{session_name}")
    : "";

  // Conv belongs to a different session — use the persistent overlay pane system.
  if (curSession && session !== curSession) {
    const dir = convDirectory(convId);
    if (!dir) { setStatus("could not find conv directory"); return; }
    setStatus("loading…");
    render();
    const ok = await switchToForeignConv(curSession, session, convId, dir);
    if (!ok) { setStatus("failed to open overlay pane"); return; }
    for (const item of state.items) {
      if (item.kind.type !== "conv") continue;
      item.kind.active = item.kind.convId === convId;
    }
    setStatus("");
    render();
    return;
  }

  // Conv belongs to the current session — bring home pane to front if an
  // overlay is currently showing, then select via the live opencode.
  await switchToHomePane(curSession);

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
  tagConvOwners([newId], targetSession);
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

  if (!AID_CALLER_CLIENT && TMUX_PANE) {
    initTasks.push(
      tmuxOutput("display-message", "-t", TMUX_PANE, "-p", "#{client_tty}")
        .catch(() => "")
        .then((tty) => { if (tty) AID_CALLER_CLIENT = tty; }),
    );
  }
  if (!AID_CALLER_CLIENT) {
    initTasks.push(
      (async () => {
        try {
          const ttyProc = Bun.spawn(["tty"], { stdout: "pipe", stderr: "ignore" });
          AID_CALLER_CLIENT = (await new Response(ttyProc.stdout).text()).trim();
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

  // Seed frontPane from AID_ORC_ORC_PANE so overlay swaps know the home position.
  if (TMUX_PANE) {
    const selfSession = await tmuxOutput("display-message", "-t", TMUX_PANE, "-p", "#{session_name}").catch(() => "");
    if (selfSession) {
      const orcPaneRaw = await tmuxOutput("show-environment", "-t", selfSession, "AID_ORC_ORC_PANE").catch(() => "");
      const m = orcPaneRaw.match(/AID_ORC_ORC_PANE=(%\d+)/);
      if (m) { state.frontPane = m[1]; dbg("INIT", `frontPane=${state.frontPane}`); }
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
