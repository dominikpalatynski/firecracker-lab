#!/usr/bin/env bash

set -euo pipefail

SOCKET="${1:?Usage: $0 /path/to/firecracker.socket [tap_name]}"
TAP_DEV="${2:-tap0}"

if [[ ! "$TAP_DEV" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}$ ]]; then
  echo "Invalid TAP name: use 1-15 letters, digits, dots, underscores or hyphens; start with a letter or digit." >&2
  exit 1
fi

KERNEL="$(pwd)/$(ls vmlinux-* | sort -V | tail -1)"
ROOTFS="$(pwd)/$(ls ubuntu-*.ext4 | tail -1)"

echo "Socket: $SOCKET"
echo "Kernel: $KERNEL"
echo "Rootfs: $ROOTFS"
echo "TAP: $TAP_DEV"

echo
echo "==> Configuring machine"

# Reject an already-running microVM before deleting its TAP.
curl --fail-with-body --silent --show-error --unix-socket "$SOCKET" \
  -X PUT \
  http://localhost/machine-config \
  -H 'Content-Type: application/json' \
  -d '{
    "vcpu_count": 1,
    "mem_size_mib": 512
  }'

echo
echo "==> Preparing host networking"

sudo ip link del "$TAP_DEV" 2>/dev/null || true
sudo ip tuntap add dev "$TAP_DEV" mode tap user "$(id -un)"
sudo ip addr add 10.200.1.1/24 dev "$TAP_DEV"
sudo ip link set "$TAP_DEV" up

echo
echo "==> Configuring kernel"

curl --fail-with-body --silent --show-error --unix-socket "$SOCKET" \
  -X PUT \
  http://localhost/boot-source \
  -H 'Content-Type: application/json' \
  -d "{
    \"kernel_image_path\": \"$KERNEL\",
    \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off\"
  }"

echo
echo "==> Configuring rootfs"

curl --fail-with-body --silent --show-error --unix-socket "$SOCKET" \
  -X PUT \
  http://localhost/drives/rootfs \
  -H 'Content-Type: application/json' \
  -d "{
    \"drive_id\": \"rootfs\",
    \"path_on_host\": \"$ROOTFS\",
    \"is_root_device\": true,
    \"is_read_only\": false
  }"

echo
echo "==> Setup Networking"

curl --fail-with-body --silent --show-error --unix-socket "$SOCKET" \
  -X PUT 'http://localhost/network-interfaces/eth0' \
  -H 'Content-Type: application/json' \
  -d "{
    \"iface_id\": \"eth0\",
    \"guest_mac\": \"06:00:AC:10:00:02\",
    \"host_dev_name\": \"$TAP_DEV\"
  }"

echo
echo "==> Starting microVM"

curl --fail-with-body --silent --show-error --unix-socket "$SOCKET" \
  -X PUT \
  http://localhost/actions \
  -H 'Content-Type: application/json' \
  -d '{
    "action_type": "InstanceStart"
  }'

echo
echo "microVM started"
