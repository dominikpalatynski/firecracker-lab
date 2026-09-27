```bash
#!/usr/bin/env bash

set -e

SOCKET="$1"

KERNEL="$(pwd)/$(ls vmlinux-* | tail -1)"
ROOTFS="$(pwd)/$(ls ubuntu-*.ext4 | tail -1)"

echo "Socket: $SOCKET"
echo "Kernel: $KERNEL"
echo "Rootfs: $ROOTFS"

echo
echo "==> Configuring machine"

curl --unix-socket "$SOCKET" \
  -X PUT \
  http://localhost/machine-config \
  -H 'Content-Type: application/json' \
  -d '{
    "vcpu_count": 1,
    "mem_size_mib": 512
  }'

echo
echo "==> Configuring kernel"

curl --unix-socket "$SOCKET" \
  -X PUT \
  http://localhost/boot-source \
  -H 'Content-Type: application/json' \
  -d "{
    \"kernel_image_path\": \"$KERNEL\",
    \"boot_args\": \"console=ttyS0 reboot=k panic=1 pci=off\"
  }"

echo
echo "==> Configuring rootfs"

curl --unix-socket "$SOCKET" \
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
echo "==> Starting microVM"

curl --unix-socket "$SOCKET" \
  -X PUT \
  http://localhost/actions \
  -H 'Content-Type: application/json' \
  -d '{
    "action_type": "InstanceStart"
  }'

echo
echo "microVM started"
```