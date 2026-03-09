# T-003 / T-022 — Test Environment Setup

**Branch**: dev-docs  
**Updated**: 2026-03-09

KVM test environment for validating aid's cross-distro install support.

## Host setup (one time)

```bash
sudo pacman -S --needed virt-manager qemu-full libvirt dnsmasq
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm $USER
# re-login or: newgrp libvirt
virt-manager &
```

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
