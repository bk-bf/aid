#!/usr/bin/env bash
# provision-vms.sh — download ISOs and create all 10 test VMs for T-003/T-022.
# Run on the Arch host after host-setup.sh has been executed.
# Usage: bash provision-vms.sh [--download-only | --vms-only | --vm <name>]
#
# Requires: virt-install, virsh, wget, libvirtd running, user in libvirt group.

set -euo pipefail

ISO_DIR="${ISO_DIR:-$HOME/iso/aid-test}"
DISK_DIR="${DISK_DIR:-$HOME/vm/aid-test}"   # user-owned disk image directory

# ── VM definitions ────────────────────────────────────────────────────────────
# Fields: name  ram_mb  disk_gb  iso_url  os_variant  extra_args
declare -A VM_RAM VM_DISK VM_ISO VM_OSVAR

VM_RAM[ubuntu-2404]=2048; VM_DISK[ubuntu-2404]=12
VM_ISO[ubuntu-2404]="https://releases.ubuntu.com/24.04/ubuntu-24.04.4-live-server-amd64.iso"
VM_OSVAR[ubuntu-2404]="ubuntu24.04"

VM_RAM[ubuntu-2204]=2048; VM_DISK[ubuntu-2204]=12
VM_ISO[ubuntu-2204]="https://releases.ubuntu.com/22.04/ubuntu-22.04.5-live-server-amd64.iso"
VM_OSVAR[ubuntu-2204]="ubuntu22.04"

VM_RAM[ubuntu-2004]=2048; VM_DISK[ubuntu-2004]=12
VM_ISO[ubuntu-2004]="https://releases.ubuntu.com/20.04/ubuntu-20.04.6-live-server-amd64.iso"
VM_OSVAR[ubuntu-2004]="ubuntu20.04"

VM_RAM[debian-12]=1024;   VM_DISK[debian-12]=12
VM_ISO[debian-12]="https://cdimage.debian.org/cdimage/archive/12.13.0/amd64/iso-cd/debian-12.13.0-amd64-netinst.iso"
VM_OSVAR[debian-12]="debian12"

VM_RAM[debian-11]=1024;   VM_DISK[debian-11]=12
VM_ISO[debian-11]="https://cdimage.debian.org/cdimage/archive/11.11.0/amd64/iso-cd/debian-11.11.0-amd64-netinst.iso"
VM_OSVAR[debian-11]="debian11"

VM_RAM[fedora-42]=2048;   VM_DISK[fedora-42]=12
VM_ISO[fedora-42]="https://download.fedoraproject.org/pub/fedora/linux/releases/42/Server/x86_64/iso/Fedora-Server-netinst-x86_64-42-1.1.iso"
VM_OSVAR[fedora-42]="fedora42"

VM_RAM[arch]=1024;        VM_DISK[arch]=12
VM_ISO[arch]="https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso"
VM_OSVAR[arch]="archlinux"

VM_RAM[alpine-319]=256;   VM_DISK[alpine-319]=8
VM_ISO[alpine-319]="https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/alpine-virt-3.19.7-x86_64.iso"
VM_OSVAR[alpine-319]="alpinelinux3.19"

VM_RAM[rocky-9]=2048;     VM_DISK[rocky-9]=12
VM_ISO[rocky-9]="https://download.rockylinux.org/pub/rocky/9/isos/x86_64/Rocky-9-latest-x86_64-minimal.iso"
VM_OSVAR[rocky-9]="rocky9"

VM_RAM[opensuse-tw]=1024; VM_DISK[opensuse-tw]=12
VM_ISO[opensuse-tw]="https://download.opensuse.org/tumbleweed/iso/openSUSE-Tumbleweed-NET-x86_64-Current.iso"
VM_OSVAR[opensuse-tw]="opensusetumbleweed"

VM_ORDER=(ubuntu-2404 ubuntu-2204 debian-12 debian-11 fedora-42 arch alpine-319 rocky-9 opensuse-tw ubuntu-2004)

# ── Helpers ───────────────────────────────────────────────────────────────────
_iso_path() { echo "$ISO_DIR/$1.iso"; }

_download_iso() {
  local name="$1"
  local url="${VM_ISO[$name]}"
  local dest; dest="$(_iso_path "$name")"
  if [[ -f "$dest" ]]; then
    echo "  [skip] $name ISO already present: $dest"
    return 0
  fi
  echo "  [dl]   $name  ->  $dest"
  mkdir -p "$ISO_DIR"
  wget -q --show-progress -O "$dest.tmp" "$url" && mv "$dest.tmp" "$dest"
  echo "  [ok]   $name"
}

_vm_exists() { virsh dominfo "$1" &>/dev/null; }

_create_vm() {
  local name="$1"
  local iso; iso="$(_iso_path "$name")"

  if _vm_exists "$name"; then
    echo "  [skip] VM '$name' already exists"
    return 0
  fi

  if [[ ! -f "$iso" ]]; then
    echo "  [err]  ISO not found for $name: $iso" >&2
    return 1
  fi

  echo "  [vm]   Creating '$name' (RAM=${VM_RAM[$name]}MB, disk=${VM_DISK[$name]}GB)..."
  virt-install \
    --name "$name" \
    --memory "${VM_RAM[$name]}" \
    --vcpus 2 \
    --disk "path=$DISK_DIR/$name.qcow2,size=${VM_DISK[$name]},format=qcow2" \
    --cdrom "$iso" \
    --os-variant "${VM_OSVAR[$name]}" \
    --network user \
    --graphics spice \
    --video virtio \
    --noautoconsole
  echo "  [ok]   $name created — open virt-manager to complete OS install, then take snapshot 'clean'"
}

# ── Argument parsing ──────────────────────────────────────────────────────────
MODE="all"
TARGET=""
case "${1:-}" in
  --download-only) MODE="download" ;;
  --vms-only)      MODE="vms" ;;
  --vm)            MODE="one"; TARGET="${2:?usage: --vm <name>}" ;;
  "") ;;
  *) echo "Usage: $0 [--download-only | --vms-only | --vm <name>]"; exit 1 ;;
esac

# ── Main ──────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "one" ]]; then
  echo "==> Downloading ISO for $TARGET..."
  _download_iso "$TARGET"
  mkdir -p "$DISK_DIR"
  echo "==> Creating VM $TARGET..."
  _create_vm "$TARGET"
  exit 0
fi

if [[ "$MODE" == "all" || "$MODE" == "download" ]]; then
  echo "==> Downloading ISOs (parallel, max 4)..."
  mkdir -p "$ISO_DIR"

  # Run up to 4 downloads concurrently using background jobs + a simple semaphore.
  _slots=4
  _active=0
  declare -a _pids=()

  _wait_one() {
    # Wait for any one background job to finish; decrement counter.
    wait -n 2>/dev/null || true
    (( _active-- )) || true
  }

  for name in "${VM_ORDER[@]}"; do
    # Throttle: if at capacity, wait for one slot to free up.
    while (( _active >= _slots )); do _wait_one; done
    (
      url="${VM_ISO[$name]}"
      dest="$ISO_DIR/$name.iso"
      if [[ -f "$dest" ]]; then
        echo "  [skip] $name ISO already present"
        exit 0
      fi
      echo "  [dl]   $name"
      wget -q --show-progress -O "$dest.tmp" "$url" \
        && mv "$dest.tmp" "$dest" \
        && echo "  [ok]   $name" \
        || { echo "  [err]  $name download failed" >&2; rm -f "$dest.tmp"; exit 1; }
    ) &
    _pids+=($!)
    (( _active++ )) || true
  done

  # Wait for all remaining background jobs.
  for pid in "${_pids[@]}"; do wait "$pid" || true; done
  echo "==> ISO downloads complete."
fi

if [[ "$MODE" == "all" || "$MODE" == "vms" ]]; then
  # Check QEMU/KVM is accessible (works for both system and session connections)
  if ! virsh list --all &>/dev/null; then
    echo "ERROR: Cannot connect to libvirt. Ensure libvirtd or the user session is running." >&2
    exit 1
  fi
  mkdir -p "$DISK_DIR"
  echo "==> Creating VMs (disks in $DISK_DIR)..."
  for name in "${VM_ORDER[@]}"; do
    _create_vm "$name"
  done
fi

echo ""
echo "==> Done. Next steps:"
echo "  1. Open virt-manager to complete OS installs on each VM"
echo "  2. Create user 'tester' with sudo on each VM"
echo "  3. Take a snapshot named 'clean' on each VM before testing"
echo "  4. Run the aid install test:"
echo "       ssh tester@<vm-ip>"
echo "       git clone https://github.com/anomalyco/aid ~/aid"
echo "       bash ~/aid/install.sh"
