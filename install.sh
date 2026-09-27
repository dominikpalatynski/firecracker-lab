```bash
#!/usr/bin/env bash

set -e

sudo apt update
sudo apt install -y curl wget squashfs-tools e2fsprogs

ARCH="$(uname -m)"

echo "==> Downloading Firecracker"

RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"
LATEST="$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASE_URL/latest")")"

curl -L "$RELEASE_URL/download/$LATEST/firecracker-$LATEST-$ARCH.tgz" \
  | tar -xz

mv "release-$LATEST-$ARCH/firecracker-$LATEST-$ARCH" firecracker
chmod +x firecracker

echo "==> Downloading guest kernel"

S3="https://s3.amazonaws.com/spec.ccfc.min"

CI_ARTIFACTS_PREFIX="$(
  curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" \
    | grep -oP '(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)' \
    | sort \
    | tail -1
)"

LATEST_KERNEL_KEY="$(
  curl -fsSL "$S3?list-type=2&prefix=${CI_ARTIFACTS_PREFIX}${ARCH}/vmlinux-" \
    | grep -oP "(?<=<Key>)(${CI_ARTIFACTS_PREFIX}${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" \
    | sort -V \
    | tail -1
)"

wget "$S3/$LATEST_KERNEL_KEY"

echo "==> Downloading Ubuntu rootfs"

LATEST_UBUNTU_KEY="$(
  curl -fsSL "$S3?list-type=2&prefix=${CI_ARTIFACTS_PREFIX}${ARCH}/ubuntu-" \
    | grep -oP "(?<=<Key>)(${CI_ARTIFACTS_PREFIX}${ARCH}/ubuntu-[0-9]+\.[0-9]+\.squashfs)(?=</Key>)" \
    | sort -V \
    | tail -1
)"

UBUNTU_VERSION="$(
  basename "$LATEST_UBUNTU_KEY" .squashfs \
    | grep -oE '[0-9]+\.[0-9]+'
)"

wget \
  -O "ubuntu-$UBUNTU_VERSION.squashfs" \
  "$S3/$LATEST_UBUNTU_KEY"

echo "==> Creating ext4 rootfs"

rm -rf squashfs-root

unsquashfs "ubuntu-$UBUNTU_VERSION.squashfs"

sudo chown -R root:root squashfs-root

truncate -s 1G "ubuntu-$UBUNTU_VERSION.ext4"

sudo mkfs.ext4 \
  -d squashfs-root \
  -F "ubuntu-$UBUNTU_VERSION.ext4"

echo
echo "Installed:"
echo "Firecracker: $(pwd)/firecracker"
echo "Kernel:      $(pwd)/$(ls vmlinux-* | tail -1)"
echo "Rootfs:      $(pwd)/$(ls ubuntu-*.ext4 | tail -1)"
```