# Firecracker Lab

A minimal lab for experimenting with Firecracker microVMs on Google Cloud.

## 1. Authenticate with Google Cloud

```bash
gcloud auth login
```

Set your project:

```bash
export PROJECT_ID="your-project-id"

gcloud config set project "$PROJECT_ID"
```

Enable the Compute Engine API:

```bash
gcloud services enable compute.googleapis.com
```

## 2. Create the VM

We use an N2 VM because Firecracker requires KVM and nested virtualization.

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

Verify that KVM is available:

```bash
ls -l /dev/kvm
```

You should see something similar to:

```text
crw-rw---- 1 root kvm ... /dev/kvm
```

If your user does not have access to KVM:

```bash
sudo usermod -aG kvm $USER
```

Then disconnect and SSH into the machine again.

Verify access:

```bash
test -r /dev/kvm && test -w /dev/kvm && echo "KVM OK"
```

## 4. Install Firecracker, kernel and rootfs

Clone this repository and run:

```bash
chmod +x install.sh
./install.sh
```

The script downloads:

- Firecracker
- Linux guest kernel
- Ubuntu root filesystem

## 5. Start the Firecracker API

Firecracker exposes its HTTP API through a Unix socket.

Start Firecracker:

```bash
export FC_SOCKET="/tmp/firecracker.socket"

rm -f "$FC_SOCKET"

./firecracker --api-sock "$FC_SOCKET"
```

Leave this terminal running.

Open another SSH session:

```bash
gcloud compute ssh "$VM_NAME" \
  --zone="$ZONE"
```

## 6. Start a microVM

Run:

```bash
chmod +x start-firecracker.sh

./start-firecracker.sh /tmp/firecracker.socket
```

This configures:

- 1 vCPU
- 512 MiB RAM
- Linux kernel
- root filesystem
- a TAP interface with host IP `10.200.1.1/24`, connected to the guest

and starts the microVM.

The guest boot output will appear in the terminal where the Firecracker process is running.

## 7. Networking

The start script deletes and recreates the selected TAP, assigns it
`10.200.1.1/24`, and brings it up. It gives ownership to the invoking user so
Firecracker can open the TAP without running as root. The TAP name is the
second argument; it defaults to `tap0`:

```bash
# Default TAP
./start-firecracker.sh /tmp/firecracker.socket

# Or choose a different TAP
./start-firecracker.sh /tmp/firecracker.socket tap1
```

Use a fresh Firecracker process, and stop any guest using the selected TAP
before running the script. Changing the TAP name does not change the fixed IP
addresses; these examples configure one microVM.

After each guest boot, run these commands as root in the guest console:

```bash
ip link set eth0 up
ip addr add 10.200.1.2/24 dev eth0

# Ping the host from the guest
ping -c 3 10.200.1.1
```

From a separate host SSH shell, ping the guest:

```bash
ping -c 3 -I tap0 10.200.1.2
```

Replace `tap0` with your chosen TAP name in the host ping command. This provides
host-to-guest connectivity; Internet access requires additional routing and NAT.
The IP settings in the guest must be applied again after reboot.

## 8. Stop the microVM

Run in the host shell:

```bash
export FC_SOCKET="/tmp/firecracker.socket"
./delete-firecracker.sh
```

`FC_SOCKET` defaults to `/tmp/firecracker.socket` when unset. The script sends
`SendCtrlAltDel` and removes the socket immediately after a successful API call.
If the API rejects the request, the socket is kept. The guest must be running
rather than paused to handle Ctrl-Alt-Del.


## Delete the Google Cloud VM

When you are finished with the lab:

```bash
gcloud compute instances delete "$VM_NAME" \
  --zone="$ZONE"
```
