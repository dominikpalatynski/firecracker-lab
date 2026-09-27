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

and starts the microVM.

The guest boot output will appear in the terminal where the Firecracker process is running.

## Delete the Google Cloud VM

When you are finished with the lab:

```bash
gcloud compute instances delete "$VM_NAME" \
  --zone="$ZONE"
```