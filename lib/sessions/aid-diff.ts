#!/usr/bin/env bun
/**
 * aid-diff — orchestrator diff review pane.
 *
 * Runs as the persistent right pane inside every aid@<name> tmux session.
 * Shows a live, file-change-triggered view of `git diff HEAD` for the
 * session's repo.  Layout:
 *
 *   ┌──────────────────────────────────┐
 *   │  git diff HEAD   [t]oggle  [?]   │  ← title bar
 *   │                                  │
 *   │  src/foo.ts        +12 -3        │  ← stat list (cursor)
 *   │  lib/bar.ts         +5 -1        │
 *   │  README.md          +2 -0        │
 *   │  ─── src/foo.ts ───────────────  │  ← expanded diff (toggle with Enter)
 *   │  @@ -10,7 +10,7 @@               │
 *   │  -  return old;                  │
 *   │  +  return new;                  │
 *   └──────────────────────────────────┘
 *
 * Keys:
 *   j / ↓     cursor down
 *   k / ↑     cursor up
 *   Enter/Space  toggle expand selected file
 *   t         cycle diff mode: HEAD → staged → unstaged → HEAD
 *   r / ^r    force refresh
 *   q         exit
 *
 * Env (required):
 *   AID_DIR      — aid install root (for palette.lua)
 *   AID_ORC_REPO — git repo path to watch and diff
 *
 * Env (optional):
 *   AID_DEBUG_LOG — path to debug log; enables debug logging when set
 */

import { appendFileSync, readFileSync } from "fs";
import { join } from "path";

// ── Env ───────────────────────────────────────────────────────────────────────

const AID_DIR      = process.env.AID_DIR      ?? "";
const AID_ORC_REPO = process.env.AID_ORC_REPO ?? process.cwd();
const AID_DEBUG_LOG = process.env.AID_DEBUG_LOG ?? "";

if (!AID_DIR) {
  process.stderr.write("aid-diff: AID_DIR must be set\n");
  process.exit(1);
}

// ── Debug logging ─────────────────────────────────────────────────────────────

function dbg(cat: string, msg: string): void {
  if (!AID_DEBUG_LOG) return;
  const ms = Date.now();
  const line = `${ms} DIFF  ${cat.padEnd(6)}${msg}\n`;
  try { appendFileSync(AID_DEBUG_LOG, line); } catch { /* best-effort */ }
}

// ── ANSI / palette ────────────────────────────────────────────────────────────

function loadPalette(): Record<string, string> {
  const luaPath = join(AID_DIR, "nvim/lua/palette.lua");
  let src = "";
  try { src = readFileSync(luaPath, "utf-8"); } catch {
    dbg("WARN", `palette.lua not found at ${luaPath}`);
  }
  const map: Record<string, string> = {};
  for (const line of src.split("\n")) {
    const m = line.match(/^\s*M\.(\w+)\s*=\s*"(#[0-9a-fA-F]{6})"/);
    if (m) map[m[1]] = m[2];
  }
  return map;
}

function hex(h: string): [number, number, number] {
  const n = parseInt(h.slice(1), 16);
  return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
}

const tc = (r: number, g: number, b: number) => `\x1b[38;2;${r};${g};${b}m`;
const bc = (r: number, g: number, b: number) => `\x1b[48;2;${r};${g};${b}m`;

function buildAnsi(p: Record<string, string>) {
  const pfg = (key: string, fb: string) => { const [r,g,b] = hex(p[key] ?? fb); return tc(r,g,b); };
  const pbg = (key: string, fb: string) => { const [r,g,b] = hex(p[key] ?? fb); return bc(r,g,b); };

  return {
    reset:   "\x1b[0m",
    bold:    "\x1b[1m",
    dim:     "\x1b[2m",
    italic:  "\x1b[3m",

    fgWhite:    pfg("fg",        "#ffffff"),
    fgPurple:   pfg("purple",    "#b57bee"),
    fgBlue:     pfg("blue",      "#6180C5"),
    fgLavender: pfg("lavender",  "#A284C6"),
    fgGreen:    pfg("git_add",   "#50fa7b"),
    fgRed:      pfg("git_del",   "#ff5555"),
    fgAmber:    pfg("git_chg",   "#ffaa00"),
    fgGray:     pfg("cmp_menu",  "#7a6e96"),

    bgTitleBar:  pbg("blue",      "#6180C5"),
    bgSelected:  pbg("cmp_sel_bg","#3a3450"),
    bgAddLine:   pbg("git_add",   "#50fa7b"),  // unused directly — delta handles hunk bg
    bgDelLine:   pbg("git_del_ln","#3d1a1a"),

    altScreenOn:  "\x1b[?1049h",
    altScreenOff: "\x1b[?1049l",
    clearScreen:  "\x1b[2J\x1b[H",
    hideCursor:   "\x1b[?25l",
    showCursor:   "\x1b[?25h",
    moveTo: (row: number) => `\x1b[${row};1H\x1b[K`,
  };
}

let A = buildAnsi({});

// ── Terminal helpers ──────────────────────────────────────────────────────────

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

function clampLine(s: string, maxCols: number): string {
  if (maxCols <= 0) return A.reset;
  let visible = 0;
  let i = 0;
  let out = "";
  // eslint-disable-next-line no-control-regex
  const ESC_RE = /^\x1b\[[0-9;]*[mGKHABCDJsuhl?]/;
  while (i < s.length) {
    const rest = s.slice(i);
    const m = rest.match(ESC_RE);
    if (m) { out += m[0]; i += m[0].length; continue; }
    if (visible >= maxCols) break;
    out += s[i]; visible++; i++;
  }
  return out + A.reset;
}

function safeWrite(s: string): void {
  try {
    process.stdout.write(s);
  } catch {
    cleanup();
    process.exit(0);
  }
}

// ── Git helpers ───────────────────────────────────────────────────────────────

type DiffMode = "HEAD" | "staged" | "unstaged";

function modeArgs(mode: DiffMode): string[] {
  switch (mode) {
    case "HEAD":     return ["HEAD"];
    case "staged":   return ["--cached"];
    case "unstaged": return [];
  }
}

function modeLabel(mode: DiffMode): string {
  switch (mode) {
    case "HEAD":     return "HEAD";
    case "staged":   return "staged";
    case "unstaged": return "unstaged";
  }
}

interface StatEntry {
  file:     string;
  added:    number;
  removed:  number;
  binary:   boolean;
}

async function runGit(...args: string[]): Promise<string> {
  try {
    const proc = Bun.spawn(["git", "-C", AID_ORC_REPO, ...args], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    return out;
  } catch {
    return "";
  }
}

/**
 * Parse `git diff --stat` output into StatEntry[].
 *
 * Typical line formats:
 *   " src/foo.ts | 12 ++---"      (plain)
 *   " src/foo.ts |  Bin 0 -> 512" (binary)
 *
 * The final summary line ("N files changed, …") is skipped.
 */
function parseStat(raw: string): StatEntry[] {
  const entries: StatEntry[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.match(/^\d+ file/)) continue;  // skip summary line

    // Binary file line
    const binMatch = trimmed.match(/^(.+?)\s+\|\s+Bin /);
    if (binMatch) {
      entries.push({ file: binMatch[1].trim(), added: 0, removed: 0, binary: true });
      continue;
    }

    // Normal line: "file | N +++---"
    const m = trimmed.match(/^(.+?)\s+\|\s+(\d+)\s*([+\-]*)/);
    if (!m) continue;

    const file    = m[1].trim();
    const bars    = m[3] ?? "";
    const added   = (bars.match(/\+/g) ?? []).length;
    const removed = (bars.match(/-/g) ?? []).length;
    entries.push({ file, added, removed, binary: false });
  }
  return entries;
}

/**
 * Fetch the diff for a single file.  Pipes through `delta` if available
 * for syntax-highlighted output; falls back to raw git diff.
 */
async function fileDiff(file: string, mode: DiffMode, cols: number): Promise<string[]> {
  const args = ["diff", ...modeArgs(mode), "--", file];
  const raw = await runGit(...args);
  if (!raw.trim()) return [];

  // Try delta for syntax highlighting.
  let rendered = raw;
  try {
    const proc = Bun.spawn(
      ["delta", "--no-gitconfig", `--width=${cols}`, "--paging=never"],
      { stdin: "pipe", stdout: "pipe", stderr: "ignore" },
    );
    proc.stdin.write(raw);
    proc.stdin.end();
    const out = await new Response(proc.stdout).text();
    await proc.exited;
    if (out.trim()) rendered = out;
  } catch {
    // delta not available — use coloured git diff output directly
    try {
      const proc2 = Bun.spawn(
        ["git", "-C", AID_ORC_REPO, "diff", "--color=always", ...modeArgs(mode), "--", file],
        { stdout: "pipe", stderr: "ignore" },
      );
      const out2 = await new Response(proc2.stdout).text();
      await proc2.exited;
      if (out2.trim()) rendered = out2;
    } catch { /* use plain raw */ }
  }

  return rendered.split("\n");
}

// ── File watcher ──────────────────────────────────────────────────────────────

let watcherProc: ReturnType<typeof Bun.spawn> | null = null;
let debounceTimer: ReturnType<typeof setTimeout> | null = null;

function startWatcher(): void {
  // inotifywait -m -r -q: monitor recursively, quiet, machine-readable
  // Events: close_write (file saved), create, delete, move
  // Exclude aid debug log files (log-*.txt in repo root) to avoid a
  // self-triggering event storm from the log file being written each refresh.
  // inotifywait --exclude matches against the full path, so we anchor with
  // the repo root prefix.
  const excludePattern = `${AID_ORC_REPO}/log-[^/]+\\.txt`;
  try {
    const proc = Bun.spawn(
      [
        "inotifywait",
        "-m", "-r", "-q",
        "--format", "%e",
        "-e", "close_write,create,delete,move",
        "--exclude", excludePattern,
        AID_ORC_REPO,
      ],
      { stdout: "pipe", stderr: "ignore", stdin: "ignore" },
    );
    watcherProc = proc;

    // Consume lines from the watcher's stdout asynchronously.
    (async () => {
      try {
        const { stdout } = proc;
        if (typeof stdout === "number") return;  // shouldn't happen with stdout:"pipe"
        const reader = stdout.getReader();
        const decoder = new TextDecoder();
        let buf = "";
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          buf += decoder.decode(value, { stream: true });
          let nl: number;
          while ((nl = buf.indexOf("\n")) >= 0) {
            const evt = buf.slice(0, nl).trim();
            buf = buf.slice(nl + 1);
            if (evt) scheduleRefresh("watch:" + evt);
          }
        }
      } catch {
        // Watcher died — try to restart after a short delay.
        setTimeout(() => { startWatcher(); }, 2000);
      }
    })();

    dbg("WATCH", `inotifywait started on ${AID_ORC_REPO}`);
  } catch {
    dbg("WATCH", "inotifywait not available — polling disabled");
  }
}

function scheduleRefresh(reason: string): void {
  if (debounceTimer) clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    debounceTimer = null;
    dbg("WATCH", `refresh triggered by ${reason}`);
    void refresh();
  }, 150);
}

// ── State ─────────────────────────────────────────────────────────────────────

type AppMode = "view" | "loading";

interface AppState {
  mode:      AppMode;
  diffMode:  DiffMode;
  entries:   StatEntry[];
  cursor:    number;
  expanded:  Set<string>;   // files currently showing inline diff
  diffCache: Map<string, string[]>;  // file → rendered diff lines
  loadingDiff: Set<string>; // files currently being fetched
  statusMsg: string;
  isRepo:    boolean;       // false if cwd is not a git repo
}

const state: AppState = {
  mode:        "loading",
  diffMode:    "HEAD",
  entries:     [],
  cursor:      0,
  expanded:    new Set(),
  diffCache:   new Map(),
  loadingDiff: new Set(),
  statusMsg:   "",
  isRepo:      true,
};

// ── Data refresh ──────────────────────────────────────────────────────────────

let refreshing = false;

async function refresh(): Promise<void> {
  if (refreshing) return;
  refreshing = true;
  dbg("DATA", `refresh diffMode=${state.diffMode}`);

  try {
    // Check if this is a git repo.
    const revParse = await runGit("rev-parse", "--git-dir");
    state.isRepo = revParse.trim().length > 0;

    if (!state.isRepo) {
      state.entries = [];
      state.mode = "view";
      refreshing = false;
      render();
      return;
    }

    const statRaw = await runGit("diff", ...modeArgs(state.diffMode), "--stat");
    const newEntries = parseStat(statRaw);

    // Clamp cursor to new list length.
    if (state.cursor >= newEntries.length) {
      state.cursor = Math.max(0, newEntries.length - 1);
    }

    // Invalidate diff cache for files whose stat changed or that no longer exist.
    const newFileSet = new Set(newEntries.map((e) => e.file));
    for (const f of state.diffCache.keys()) {
      if (!newFileSet.has(f)) state.diffCache.delete(f);
    }
    // Also close expanded files that have disappeared.
    for (const f of state.expanded) {
      if (!newFileSet.has(f)) state.expanded.delete(f);
    }

    state.entries = newEntries;
    state.mode = "view";
    refreshing = false;
    render();

    // Re-fetch diff for all currently expanded files (stat changed = diff may have changed).
    for (const file of state.expanded) {
      void fetchDiff(file);
    }
  } catch (e) {
    dbg("ERR", `refresh failed: ${e}`);
    refreshing = false;
    render();
  }
}

async function fetchDiff(file: string): Promise<void> {
  if (state.loadingDiff.has(file)) return;
  state.loadingDiff.add(file);
  const { cols } = termSize();
  const lines = await fileDiff(file, state.diffMode, cols);
  state.loadingDiff.delete(file);
  state.diffCache.set(file, lines);
  render();
}

// ── Rendering ─────────────────────────────────────────────────────────────────

/**
 * Render a single stat entry row.
 * Format:  [cursor] filename      +N -N
 */
function renderStatRow(entry: StatEntry, selected: boolean, cols: number): string {
  const selBar = selected ? `${A.fgPurple}▌${A.reset}` : " ";
  const selBg  = selected ? A.bgSelected : "";
  const rfg    = `\x1b[39m${selBg}`;

  const isExpanded = state.expanded.has(entry.file);

  // Expand indicator: ▾ (expanded) or ▸ (collapsed), colored by state
  const expandIcon = isExpanded
    ? `${A.fgPurple}▾${rfg}`
    : `${A.fgGray}${A.dim}▸${rfg}`;

  // File name: white if selected, lavender otherwise
  const nameColor = selected ? A.fgWhite : A.fgLavender;
  const namePart  = `${selBg}${selBar}${expandIcon} ${nameColor}${entry.file}${rfg}`;

  if (entry.binary) {
    const rightPart = `${A.fgGray}${A.dim}binary${A.reset}`;
    return buildStatRow(namePart, rightPart, cols);
  }

  // +N -N with green/red colors; show "clean" if both zero (shouldn't happen
  // in practice but guard against empty stat lines)
  const plusStr  = entry.added   > 0 ? `${A.fgGreen}+${entry.added}${rfg}` : "";
  const minusStr = entry.removed > 0 ? `${A.fgRed}-${entry.removed}${rfg}` : "";
  const spacer   = plusStr && minusStr ? " " : "";
  const rightPart = (plusStr || minusStr)
    ? plusStr + spacer + minusStr
    : `${A.fgGray}${A.dim}~${rfg}`;

  return buildStatRow(namePart, rightPart, cols);
}

function buildStatRow(left: string, right: string, cols: number): string {
  const leftLen  = stripAnsi(left).length;
  const rightLen = stripAnsi(right).length;
  const totalNeeded = leftLen + 2 + rightLen;
  if (totalNeeded > cols) {
    // Not enough room for right side — just clamp left
    return clampLine(left, cols);
  }
  const gap = cols - leftLen - rightLen;
  return left + " ".repeat(gap) + right + A.reset;
}

/**
 * Render the inline diff section for an expanded file.
 * Returns an array of display lines (already clamped to cols).
 */
function renderDiffSection(file: string, cols: number): string[] {
  const lines: string[] = [];

  // Separator header: "─── filename ───────"
  const label  = ` ${file} `;
  const dashes = Math.max(0, cols - label.length - 1);
  const header = `${A.fgBlue}${A.dim}───${A.reset}${A.fgLavender}${label}${A.fgBlue}${A.dim}${"─".repeat(dashes)}${A.reset}`;
  lines.push(clampLine(header, cols));

  if (state.loadingDiff.has(file)) {
    lines.push(`  ${A.dim}loading…${A.reset}`);
    return lines;
  }

  const cached = state.diffCache.get(file);
  if (!cached) {
    lines.push(`  ${A.fgGray}${A.dim}(empty diff)${A.reset}`);
    return lines;
  }

  for (const rawLine of cached) {
    lines.push(clampLine(rawLine, cols));
  }

  return lines;
}

function buildFrame(): string[] {
  const { cols, rows } = termSize();
  const lines: string[] = [];

  // ── Title bar ─────────────────────────────────────────────────────────────
  const modeLabel_ = modeLabel(state.diffMode);
  const titleLeft  = ` diff · ${modeLabel_}`;
  const titleRight = " diff ";
  const titleGap   = Math.max(1, cols - titleLeft.length - titleRight.length);
  const titleBar   =
    `${A.bgTitleBar}${A.fgWhite}${A.bold}${titleLeft}` +
    `${A.reset}${A.bgTitleBar}${"  ".repeat(Math.ceil(titleGap / 2))}` +
    `${A.dim}${A.fgWhite}${titleRight}${A.reset}`;
  lines.push(titleBar);

  // ── Footer (computed early to know height) ────────────────────────────────
  const footerLine = buildFooter(cols);

  // Body rows: rows - title(1) - blank(1) - status(1) - footer(1)
  const bodyRows = Math.max(1, rows - 4);

  // ── Body ──────────────────────────────────────────────────────────────────
  const bodyLines: string[] = [];

  if (state.mode === "loading") {
    bodyLines.push(`  ${A.dim}loading…${A.reset}`);
  } else if (!state.isRepo) {
    bodyLines.push(`  ${A.fgGray}${A.dim}not a git repository${A.reset}`);
  } else if (state.entries.length === 0) {
    bodyLines.push(`  ${A.fgGray}${A.dim}no changes (${modeLabel_})${A.reset}`);
  } else {
    for (let i = 0; i < state.entries.length; i++) {
      const entry    = state.entries[i];
      const selected = i === state.cursor;
      bodyLines.push(renderStatRow(entry, selected, cols));

      if (state.expanded.has(entry.file)) {
        for (const dl of renderDiffSection(entry.file, cols)) {
          bodyLines.push(dl);
        }
      }
    }
  }

  // Scroll to keep cursor in view.
  // Find the screen-row of the cursor entry within bodyLines.
  let cursorScreenRow = 0;
  {
    let row = 0;
    for (let i = 0; i <= state.cursor && i < state.entries.length; i++) {
      if (i === state.cursor) { cursorScreenRow = row; break; }
      row++;  // stat row
      if (state.expanded.has(state.entries[i].file)) {
        row += renderDiffSection(state.entries[i].file, cols).length;
      }
    }
  }

  const scrollStart = Math.max(
    0,
    Math.min(
      cursorScreenRow - Math.floor(bodyRows / 2),
      Math.max(0, bodyLines.length - bodyRows),
    ),
  );

  const visibleBody = bodyLines.slice(scrollStart, scrollStart + bodyRows);
  for (const bl of visibleBody) lines.push(bl);
  // Pad remainder of body area
  while (lines.length < 1 + bodyRows) lines.push("");

  // ── Status + footer ───────────────────────────────────────────────────────
  lines.push("");
  if (state.statusMsg) {
    lines.push(`  ${A.fgAmber}${state.statusMsg}${A.reset}`);
  } else {
    lines.push("");
  }
  lines.push(footerLine);

  return lines;
}

function buildFooter(cols: number): string {
  const k = (s: string) => `${A.reset}${A.bold}${A.fgPurple}${s}${A.reset}${A.dim}`;
  const sep = `${A.fgGray}  ·  `;

  const hints: Array<{ key: string; label: string }> = [
    { key: "↑↓",    label: "nav" },
    { key: "↵",     label: "expand" },
    { key: "t",     label: "mode" },
    { key: "^r",    label: "refresh" },
    { key: "q",     label: "quit" },
  ];

  const indent = "  ";
  let line = `${A.dim}${indent}`;
  let len  = indent.length;
  let first = true;

  for (const { key, label } of hints) {
    const plain = `${key} ${label}`;
    const withSep = first ? plain.length : 5 + plain.length;
    if (!first && len + withSep > cols) break;  // drop trailing hints if too narrow
    if (!first) { line += sep; len += 5; }
    line += `${k(key)} ${label}`;
    len  += plain.length;
    first = false;
  }

  return line + A.reset;
}

function render(): void {
  const { cols } = termSize();
  const frame = buildFrame();
  const buf: string[] = [];
  buf.push(A.hideCursor);
  buf.push(A.clearScreen);
  for (let i = 0; i < frame.length; i++) {
    buf.push(A.moveTo(i + 1) + clampLine(frame[i], cols));
  }
  safeWrite(buf.join(""));
}

// ── Actions ───────────────────────────────────────────────────────────────────

function moveCursor(delta: number): void {
  const n = state.entries.length;
  if (n === 0) return;
  state.cursor = Math.max(0, Math.min(n - 1, state.cursor + delta));
  render();
}

function toggleExpand(): void {
  if (state.entries.length === 0) return;
  const entry = state.entries[state.cursor];
  if (!entry) return;

  if (state.expanded.has(entry.file)) {
    state.expanded.delete(entry.file);
    render();
  } else {
    state.expanded.add(entry.file);
    // Load diff if not already cached.
    if (!state.diffCache.has(entry.file)) {
      void fetchDiff(entry.file);
    }
    render();
  }
}

function cycleDiffMode(): void {
  const cycle: DiffMode[] = ["HEAD", "staged", "unstaged"];
  const idx = cycle.indexOf(state.diffMode);
  state.diffMode = cycle[(idx + 1) % cycle.length];
  // Clear diff cache — old mode's diffs are invalid.
  state.diffCache.clear();
  state.expanded.clear();
  void refresh();
}

// ── Input handling ────────────────────────────────────────────────────────────

function handleInput(data: Buffer): void {
  const s = data.toString("binary");

  // Arrow keys: ESC [ A/B/C/D
  if (s === "\x1b[A") { moveCursor(-1); return; }  // up
  if (s === "\x1b[B") { moveCursor(+1); return; }  // down

  for (const ch of s) {
    const code = ch.charCodeAt(0);

    if (code === 0x1b) continue;  // bare ESC — ignore

    switch (ch) {
      case "k": moveCursor(-1); break;
      case "j": moveCursor(+1); break;
      case "\r":  // Enter
      case " ":   // Space
        toggleExpand(); break;
      case "t": cycleDiffMode(); break;
      case "r": void refresh(); break;
      case "\x12": void refresh(); break;  // Ctrl-R
      case "q":
      case "\x03":  // Ctrl-C
        cleanup(); process.exit(0);
    }
  }
}

// ── Cleanup ───────────────────────────────────────────────────────────────────

function cleanup(): void {
  if (watcherProc) {
    try { watcherProc.kill(); } catch { /* best-effort */ }
    watcherProc = null;
  }
  if (debounceTimer)    { clearTimeout(debounceTimer);    debounceTimer = null; }
  safeWrite(A.showCursor + A.altScreenOff);
}

// ── Boot ──────────────────────────────────────────────────────────────────────

async function boot(): Promise<void> {
  // Load palette.
  const palette = loadPalette();
  A = buildAnsi(palette);

  // Enter alt screen, hide cursor.
  safeWrite(A.altScreenOn + A.hideCursor);

  // Initial render with loading state.
  render();

  // Start file watcher.
  startWatcher();

  // Initial data load.
  await refresh();

  // Raw key input.
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
  }
  process.stdin.resume();
  process.stdin.on("data", handleInput);

  // SIGWINCH — terminal resize.
  process.on("SIGWINCH", () => { render(); });

  // SIGTERM / SIGHUP — clean exit.
  process.on("SIGTERM", () => { cleanup(); process.exit(0); });
  process.on("SIGHUP",  () => { cleanup(); process.exit(0); });

  // Periodic refresh every 30s as a backstop in case inotifywait misses an event.
  setInterval(() => { void refresh(); }, 30_000);

  dbg("BOOT", `ready repo=${AID_ORC_REPO} diffMode=${state.diffMode}`);
}

boot().catch((e) => {
  process.stderr.write(`aid-diff: fatal: ${e}\n`);
  process.exit(1);
});
