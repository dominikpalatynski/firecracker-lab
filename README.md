# Firecracker Lab

A simple lab for experimenting with Firecracker microVMs on Google Cloud.

## 1. Authenticate with Google Cloud

```bash
gcloud auth login
```

Select your project:

```bash
export PROJECT_ID="your-project-id"

gcloud config set project "$PROJECT_ID"
```

Enable the Compute Engine API:

```bash
gcloud services enable compute.googleapis.com
```

## 2. Create the virtual machine

We use an N2 machine with nested virtualization enabled. This allows Firecracker
to use KVM and run its own microVMs inside the machine.

```bash
export VM_NAME="firecracker-lab"
export ZONE="europe-west4-a"

gcloud compute instances create "$VM_NAME" \
  --zone="$ZONE" \
  --machine-type=n2-standard-2 \
  --image-family=ubuntu-2404-lts-amd64 \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=20GB \
  --enable-nested-virtualization
```

## 3. Connect over SSH

```bash
gcloud compute ssh "$VM_NAME" \
  --zone="$ZONE"
```

Check that KVM is available:

```bash
ls -l /dev/kvm
```

The output should look similar to:

```text
crw-rw---- 1 root kvm ... /dev/kvm
```

If your user does not have access to KVM, add it to the `kvm` group:

```bash
sudo usermod -aG kvm $USER
```

Then disconnect your SSH session and reconnect.

Verify permissions:

```bash
test -r /dev/kvm && test -w /dev/kvm && echo "KVM OK"
```

## 4. Install Firecracker, the kernel, rootfs, and CNI plugins

Clone this repository, change into its directory, and run:

```bash
chmod +x install.sh
./install.sh
```

The script downloads and prepares:

- Firecracker
- A Linux kernel for the guest
- An Ubuntu root filesystem (`rootfs`)
- The CNI reference plugins `ptp`, `host-local`, and `firewall` (v1.9.1)
- The `tc-redirect-tap` adapter, built with Go from a pinned source revision

The CNI binaries are installed in `/opt/cni/bin`. The script also installs
`jq`, `iproute2`, and `iptables`, which are needed for the networking example.

## 5. Start the Firecracker API

To run a VM **with networking**, follow the
[CNI setup guide](./docs/cni-setup-example/README.md) instead of steps 5–7.
It shows how to prepare the network and launch Firecracker in the network
namespace containing its TAP device.
The commands below boot a VM without a network interface.

Firecracker exposes its HTTP API through a Unix socket.

Start the Firecracker process:

```bash
export FC_SOCKET="/tmp/firecracker.socket"

rm -f "$FC_SOCKET"

./firecracker --api-sock "$FC_SOCKET"
```

Leave this terminal open.

Open a second SSH session:

```bash
gcloud compute ssh "$VM_NAME" \
  --zone="$ZONE"
```

## 6. Start a microVM

From the repository directory, run:

```bash
chmod +x init-firecracker start-firecracker.sh

./init-firecracker /tmp/firecracker.socket
./start-firecracker.sh /tmp/firecracker.socket
```

`init-firecracker` configures:

- 1 vCPU
- 512 MiB RAM
- The Linux kernel
- The root filesystem

This script prepares the VM without configuring networking or booting the guest.
`start-firecracker.sh` sends only the `InstanceStart` action.
If you are using networking, configure the network interface and guest boot
parameters between these two commands.

Guest boot messages will appear in the terminal running the Firecracker process.

## 7. Network configuration

The [CNI setup example](./docs/cni-setup-example/README.md) includes
direct plugin invocations, JSON inputs and results, Firecracker API requests,
guest IP configuration, connectivity checks, and resource cleanup.
It uses `ptp` + `host-local` + `firewall` + `tc-redirect-tap`, without Kubernetes
or the Go SDK.

A comparison of a custom networking module and CNI, along with a measurement
plan, is available in the [host networking document](./docs/HOST-NETWORKING-BENCHMARK.md).

Follow the example from the beginning with a fresh Firecracker process. A process
already running in the default network namespace cannot see the TAP device
inside the example's `vm-001` namespace.

## 8. Stop the microVM

Run on the host:

```bash
export FC_SOCKET="/tmp/firecracker.socket"
./delete-firecracker.sh
```

If `FC_SOCKET` is unset, the script uses `/tmp/firecracker.socket`.
It sends `SendCtrlAltDel` and removes the socket immediately after a successful
API call. If the API rejects the request, the socket is kept. The guest must be
running, rather than paused, to handle Ctrl-Alt-Del.


## Delete the Google Cloud VM

When you have finished experimenting, delete the machine:

```bash
gcloud compute instances delete "$VM_NAME" \
  --zone="$ZONE"
```
