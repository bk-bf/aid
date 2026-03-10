<!-- LOC cap: 344 (source: 2457, ratio: 0.14, updated: 2026-03-09) -->
# T-003 / T-022 — Test Environment Setup

KVM test environment for validating aid's cross-distro install support.

## Host setup (one time)

```bash
sudo pacman -S --needed virt-manager qemu-full libvirt dnsmasq
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm $USER
# re-login or: newgrp libvirt
virt-manager &
```

  **Full dependency audit:**

  | Dependency | Role | Arch | Ubuntu/Debian | Fedora/RHEL | macOS |
  |------------|------|------|--------------|-------------|-------|
  | `tmux ≥ 3.2` | core | `pacman -S tmux` | `apt install tmux` (≥3.2 on 22.04+) | `dnf install tmux` | `brew install tmux` |
  | `nvim ≥ 0.9` | editor | `pacman -S neovim` | **blocker**: 24.04 ships 0.9.5 ✅; 22.04 ships 0.6 ❌ — needs PPA (`ppa:neovim-ppa/unstable`) or AppImage | `dnf install neovim` (0.9+ on F38+) | `brew install neovim` |
  | `python3-pynvim` | treemux cwd tracking (Python scripts call pynvim) | `pacman -S python-pynvim` ✅ done | `apt install python3-neovim` or `pip3 install pynvim` | `pip3 install pynvim` | `pip3 install pynvim` |
  | `lsof` | `watch_and_update.sh` reads cwd via `lsof -a -d cwd -p <pid>` | pre-installed | `apt install lsof` (often missing on minimal images) | pre-installed | pre-installed |
  | `node` + `npm` | opencode runtime; `markdown-preview.nvim` build step | `pacman -S nodejs npm` | `apt install nodejs npm` (or nvm) | `dnf install nodejs npm` | `brew install node` |
  | `git` | repo clone, TPM, lazy.nvim bootstrap | pre-installed | pre-installed | pre-installed | pre-installed (Xcode CLT) |
  | `curl` | `boot.sh` bootstrapper | pre-installed | pre-installed | pre-installed | pre-installed |

  **Known hard cases:**
  - **Ubuntu 22.04 LTS**: nvim 0.6 in the default repo is too old. The fix is either (a) add `ppa:neovim-ppa/unstable` automatically, or (b) download the official AppImage from GitHub releases and install to `~/.local/bin/nvim`. Option (b) is safer (no PPA trust/key ceremony) and works identically across all distros.
  - **Alpine / minimal containers**: `lsof` absent; alternative is `readlink /proc/<pid>/cwd` (Linux-only, already commented out in `watch_and_update.sh`). Should use `/proc/` on Linux and `lsof` only as macOS fallback.
  - **macOS**: `readlink -f` doesn't exist (BSD readlink); `lsof` is present; Homebrew required for tmux/nvim. macOS support is a separate sub-scope.
  - **`/proc/` vs `lsof` in `watch_and_update.sh`**: the upstream script already has the `/proc/` path commented out. On Linux, `/proc/<pid>/cwd` is faster, needs no extra tool, and works on all distros. A one-line OS detection (`[[ "$OSTYPE" == linux* ]]`) would let us use `/proc/` on Linux and fall back to `lsof` on macOS.

  **Proposed install.sh changes:**
  1. Add a `_detect_distro()` function returning `arch | debian | fedora | alpine | macos | unknown`.
  2. Add a `_require <cmd> [install-hint]` helper that checks `command -v` and prints a clear error with distro-specific install instructions if missing — rather than silently failing mid-install.
  3. Replace the bare `pacman`-only `python-pynvim` block with a distro-dispatch block covering all four Linux families + macOS.
  4. Add pre-flight checks (before TPM/lazy bootstrap) for `tmux`, `nvim`, `git`, `node`, `lsof` — abort with actionable message if any are missing or below minimum version.
  5. For nvim < 0.9 on Debian/Ubuntu: offer to install the official AppImage into `~/.local/bin/nvim` automatically.
  6. In `watch_and_update.sh`: switch cwd detection to `readlink /proc/<pid>/cwd` on Linux (no external tool), `lsof` only on macOS.

  **Scope boundary**: aid does not become a full package manager or attempt to install opencode (it has its own installer). The goal is: on a stock Ubuntu 24.04 / Fedora 40 / Arch image with only `git`, `curl`, and the system package manager available, `bash boot.sh` should produce a working aid session without manual intervention. macOS (Homebrew) is a stretch goal for this task; track separately if needed.

## VM matrix

| # | Name | ISO | RAM | Disk | What it tests |
|---|------|-----|-----|------|---------------|
| 1 | `ubuntu-2404` | [Ubuntu 24.04 LTS server](https://ubuntu.com/download/server) | 512 MB | 12 GB | nvim 0.9.5 in repo — apt happy path |
| 2 | `ubuntu-2204` | [Ubuntu 22.04 LTS server](https://releases.ubuntu.com/22.04/) | 512 MB | 12 GB | nvim 0.6 in repo — AppImage fallback |
| 3 | `debian-12` | [Debian 12 netinst](https://www.debian.org/distrib/netinst) | 512 MB | 12 GB | Debian apt (no Ubuntu quirks) |
| 4 | `debian-11` | [Debian 11 netinst](https://www.debian.org/releases/bullseye/debian-installer/) | 512 MB | 12 GB | Older Debian, nvim 0.4 — AppImage |
| 5 | `fedora-42` | [Fedora 42 Server](https://fedoraproject.org/server/download) | 512 MB | 12 GB | dnf family, nvim 0.9+ in repo |
| 6 | `arch` | [Arch Linux](https://archlinux.org/download/) | 512 MB | 12 GB | pacman baseline (home distro) |
| 7 | `alpine-319` | [Alpine 3.19 virtual](https://alpinelinux.org/downloads/) | 256 MB | 8 GB | No `lsof` — `/proc/` fallback path |
| 8 | `rocky-9` | [Rocky Linux 9 minimal](https://rockylinux.org/download) | 512 MB | 12 GB | RHEL-compatible, EPEL |
| 9 | `opensuse-tw` | [openSUSE Tumbleweed NET](https://get.opensuse.org/tumbleweed/) | 512 MB | 12 GB | zypper family |
| 10 | `ubuntu-2004` | [Ubuntu 20.04 LTS server](https://releases.ubuntu.com/20.04/) | 512 MB | 12 GB | nvim 0.4 in repo — oldest apt case |

Total disk: ~50–60 GB across all 10 VMs (thin-provisioned).

## Per-VM setup in virt-manager

1. **New VM** → Local install media → select ISO
2. Set RAM / disk per table above; 1 vCPU is enough
3. Install OS — minimal/server profile, create user `tester` with sudo
4. First boot: **VM → Take Snapshot** → name `clean`

## Running a test

```bash
ssh tester@<vm-ip>
git clone https://github.com/anomalyco/aid ~/aid
bash ~/aid/install.sh
```

Reset to clean state at any time: right-click snapshot → **Revert**.

## What to look for per distro

| VM | Expected behaviour |
|----|--------------------|
| `ubuntu-2404` | install.sh completes without intervention |
| `ubuntu-2204` | install.sh detects nvim 0.6, downloads AppImage to `~/.local/bin/nvim` |
| `debian-12` | same AppImage path as ubuntu-2204 (nvim 0.7 in repo) |
| `debian-11` | AppImage path (nvim 0.4 in repo) |
| `fedora-42` | install.sh completes; pynvim via `pip3 install pynvim` |
| `arch` | existing pacman path still works |
| `alpine-319` | `watch_and_update.sh` uses `/proc/<pid>/cwd` not `lsof` |
| `rocky-9` | EPEL enabled automatically; pynvim via pip3 |
| `opensuse-tw` | install.sh completes; zypper path |
| `ubuntu-2004` | AppImage path (nvim 0.4 in repo) |
