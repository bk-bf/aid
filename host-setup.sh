#!/usr/bin/env bash
# host-setup.sh — one-time KVM/virt-manager setup on the Arch host.
# Run this once before creating test VMs for the aid cross-distro test matrix.
# See docs/features/open/T-003-T-022-test-environment.md for the full VM matrix.

set -euo pipefail

echo "==> Installing KVM / virt-manager stack..."
sudo pacman -S --needed --noconfirm virt-manager qemu-full libvirt dnsmasq

echo "==> Enabling and starting libvirtd..."
sudo systemctl enable --now libvirtd

echo "==> Adding $USER to libvirt and kvm groups..."
sudo usermod -aG libvirt,kvm "$USER"

echo ""
echo "==> Host setup complete."
echo ""
echo "  IMPORTANT: group membership takes effect in a new login session."
echo "  Either log out and back in, or run:  newgrp libvirt"
echo ""
echo "  Then launch virt-manager to create the test VMs:"
echo "    virt-manager &"
echo ""
echo "  VM matrix (see T-003-T-022-test-environment.md for ISO links):"
echo ""
echo "  #  Name             RAM   Disk  Notes"
echo "  1  ubuntu-2404      512M  12G   nvim 0.9.5 — apt happy path"
echo "  2  ubuntu-2204      512M  12G   nvim 0.6 — AppImage fallback"
echo "  3  debian-12        512M  12G   Debian apt (no Ubuntu quirks)"
echo "  4  debian-11        512M  12G   nvim 0.4 — AppImage fallback"
echo "  5  fedora-42        512M  12G   dnf family, nvim 0.9+ in repo"
echo "  6  arch             512M  12G   pacman baseline (home distro)"
echo "  7  alpine-319       256M  8G    no lsof — /proc/ fallback path"
echo "  8  rocky-9          512M  12G   RHEL-compatible, EPEL"
echo "  9  opensuse-tw      512M  12G   zypper family"
echo "  10 ubuntu-2004      512M  12G   nvim 0.4 — oldest apt case"
echo ""
echo "  Per-VM setup: minimal/server install, user 'tester' with sudo,"
echo "  then VM -> Take Snapshot -> 'clean' before testing."
