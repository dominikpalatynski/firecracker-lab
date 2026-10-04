#!/usr/bin/env bash

set -euo pipefail

sudo apt update
sudo apt install -y curl wget squashfs-tools e2fsprogs tmux jq iproute2 iptables golang-go

ARCH="$(uname -m)"

echo "==> Downloading Firecracker"

RELEASE_URL="https://github.com/firecracker-microvm/firecracker/releases"
LATEST="$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASE_URL/latest")")"

curl -fsSL "$RELEASE_URL/download/$LATEST/firecracker-$LATEST-$ARCH.tgz" \
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

sudo rm -rf squashfs-root

sudo unsquashfs "ubuntu-$UBUNTU_VERSION.squashfs"

sudo chown -R root:root squashfs-root

truncate -s 1G "ubuntu-$UBUNTU_VERSION.ext4"

sudo mkfs.ext4 \
  -d squashfs-root \
  -F "ubuntu-$UBUNTU_VERSION.ext4"

echo "==> Installing CNI plugins"

case "$ARCH" in
  x86_64) CNI_ARCH="amd64" ;;
  aarch64) CNI_ARCH="arm64" ;;
  *) echo "Unsupported CNI architecture: $ARCH" >&2; exit 1 ;;
esac

CNI_VERSION="v1.9.1"
TC_REDIRECT_TAP_REV="34bf829e9a5c99df47318c7feeb637576df239fc"
CNI_TMP="$(mktemp -d)"
trap 'rm -rf -- "$CNI_TMP"' EXIT
CNI_ARCHIVE="cni-plugins-linux-$CNI_ARCH-$CNI_VERSION.tgz"
CNI_RELEASE_URL="https://github.com/containernetworking/plugins/releases/download/$CNI_VERSION"

curl -fsSL "$CNI_RELEASE_URL/$CNI_ARCHIVE" -o "$CNI_TMP/$CNI_ARCHIVE"
curl -fsSL "$CNI_RELEASE_URL/$CNI_ARCHIVE.sha256" -o "$CNI_TMP/$CNI_ARCHIVE.sha256"
(cd "$CNI_TMP" && sha256sum -c "$CNI_ARCHIVE.sha256")
tar -xzf "$CNI_TMP/$CNI_ARCHIVE" -C "$CNI_TMP"

# The TAP adapter is distributed as Go source, separately from the reference plugins.
# Go downloads a newer toolchain automatically if the Ubuntu package is too old.
CGO_ENABLED=0 GOTOOLCHAIN=auto GOBIN="$CNI_TMP" \
  go install "github.com/awslabs/tc-redirect-tap/cmd/tc-redirect-tap@$TC_REDIRECT_TAP_REV"

sudo install -d /opt/cni/bin /etc/cni/net.d
sudo install -m 0755 \
  "$CNI_TMP/ptp" "$CNI_TMP/host-local" "$CNI_TMP/firewall" "$CNI_TMP/tc-redirect-tap" \
  /opt/cni/bin/

echo
echo "Installed:"
echo "Firecracker: $(pwd)/firecracker"
echo "Kernel:      $(pwd)/$(ls vmlinux-* | tail -1)"
echo "Rootfs:      $(pwd)/$(ls ubuntu-*.ext4 | tail -1)"
echo "CNI plugins: /opt/cni/bin (reference plugins $CNI_VERSION + tc-redirect-tap)"
echo "CNI guide:   docs/cni-setup-example/README.md"
