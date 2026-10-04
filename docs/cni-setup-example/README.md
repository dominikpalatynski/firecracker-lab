# CNI → Firecracker: an example without an SDK or Kubernetes

Imagine you want to launch a single microVM. First, you prepare its network
connection on the host, then attach it to Firecracker, and finally configure
an address inside the VM. CNI helps with the first part:

| Component | What it does |
|---|---|
| `ptp` | Creates a veth pair, routes, and NAT for outbound access through the host. |
| `host-local` | Called by `ptp`; reserves an IP address from a local pool. |
| `firewall` | Adds rules allowing VM traffic through the host. |
| `tc-redirect-tap` | Creates a TAP device and redirects packets between it and veth. |
| Us | Create the namespace, call the plugins, configure the VM, and clean up. |

A plugin is a local program: **JSON on stdin, a JSON result on stdout**, and
parameters in `CNI_*` environment variables. We do not send it HTTP requests.
Once configuration is complete, the plugin exits; the kernel handles packets.
HTTP is used later to call the Firecracker API.

## 1. Prepare the host

This example uses one VM, IPv4, and Ubuntu 24.04 with KVM. Run the commands
from the repository root on the **Firecracker host**, not inside the microVM.
First run `./install.sh`; it also installs the required plugins in `/opt/cni/bin`.
Go is needed only to build the adapter; this example does not use the Go SDK.

In terminal A, open Bash as root. This is how we run this manual lab example
(the TAP device will be owned by root):

```bash
sudo bash
export CNI_PATH=/opt/cni/bin
export CNI_CONTAINERID=vm-001
export CNI_NETNS=/run/netns/vm-001
export CNI_IFNAME=veth0
export CNI_ARGS=
export FC_SOCKET=/tmp/firecracker-vm-001.socket
STATE_DIR="$(mktemp -d /tmp/firecracker-cni-vm-001.XXXXXX)"
echo "Results and configurations: $STATE_DIR"

for plugin in ptp host-local firewall tc-redirect-tap; do
  CNI_COMMAND=VERSION "$CNI_PATH/$plugin"
done

cp docs/cni-setup-example/network.conflist "$STATE_DIR/network.conflist"
printf 'null\n' > "$STATE_DIR/result.json"
ip netns add vm-001
ip -n vm-001 link set lo up
```

Use a fresh namespace and an unused `10.200.1.0/24` address pool. `STATE_DIR`
stores inputs and results until resource cleanup; do not delete it earlier.
We read the configuration directly from a file, so it does not need to be
registered in `/etc/cni/net.d`.

## 2. Call each plugin's `ADD` directly, in order

The complete list is in [network.conflist](./network.conflist). Each binary
receives only its own object from the list, the shared `name` and `cniVersion`,
and, starting with the second plugin, `prevResult`. `jq` only assembles these
JSON objects.

**`ptp` → `host-local`:** creates the veth pair, IP allocation, routing, and
masquerading. `ptp` enables the required IPv4 forwarding on the host itself.

```bash
export CNI_COMMAND=ADD
jq '.plugins[0] + {name, cniVersion}' \
  "$STATE_DIR/network.conflist" > "$STATE_DIR/ptp.json"
"$CNI_PATH/ptp" < "$STATE_DIR/ptp.json" > "$STATE_DIR/ptp-result.json" &&
  cp "$STATE_DIR/ptp-result.json" "$STATE_DIR/result.json"
```

**`firewall`:** receives the `ptp` result and adds packet forwarding rules.

```bash
jq --slurpfile prev "$STATE_DIR/result.json" \
  '.plugins[1] + {name, cniVersion, prevResult: $prev[0]}' \
  "$STATE_DIR/network.conflist" > "$STATE_DIR/firewall.json"
"$CNI_PATH/firewall" < "$STATE_DIR/firewall.json" > "$STATE_DIR/firewall-result.json" &&
  cp "$STATE_DIR/firewall-result.json" "$STATE_DIR/result.json"
```

**`tc-redirect-tap`:** creates the TAP device and veth ↔ TAP traffic redirection.

```bash
jq --slurpfile prev "$STATE_DIR/result.json" \
  '.plugins[2] + {name, cniVersion, prevResult: $prev[0]}' \
  "$STATE_DIR/network.conflist" > "$STATE_DIR/tap.json"
"$CNI_PATH/tc-redirect-tap" < "$STATE_DIR/tap.json" > "$STATE_DIR/tap-result.json" &&
  cp "$STATE_DIR/tap-result.json" "$STATE_DIR/result.json"

cat "$STATE_DIR/tap.json"     # exact input to the last ADD
jq . "$STATE_DIR/result.json" # result of the entire chain
```

After an error, **stop and proceed to cleanup** instead of calling further
`ADD` operations. `result.json` keeps the last successful result. This is a
manual example with no automatic rollback. The `firewall` rules allow traffic
but do not constitute a complete sandbox isolation policy.

## 3. Launch the Firecracker process in the namespace

In **terminal B**, also from the repository directory:

```bash
sudo ip netns exec vm-001 ./firecracker --api-sock /tmp/firecracker-vm-001.socket
```

Leave this terminal open. The TAP device exists inside `vm-001`, so Firecracker
must run in the same network namespace. Do not remove a running VM's socket;
if a socket remains from an earlier VM, first make sure that its process has exited.

## 4. Pass the result to Firecracker and the guest

Return to **terminal A**. First configure the CPU, memory, kernel, and disk:

```bash
./init-firecracker "$FC_SOCKET"
```

The adapter result contains two entries associated with the TAP: the host entry
has its `sandbox` set to the namespace path, while the guest interface description
has `sandbox: "vm-001"`. We select the latter: its `name` identifies the TAP,
and its `mac` is the address to assign to the **guest**.

```bash
jq -e --arg vm "$CNI_CONTAINERID" '
  (.interfaces | to_entries[] | select(.value.sandbox == $vm)) as $nic
  | .ips[] | select(.interface == $nic.key)
  | {tap: $nic.value.name, mac: $nic.value.mac, address, gateway}
' "$STATE_DIR/result.json" > "$STATE_DIR/vm.json"
jq . "$STATE_DIR/vm.json"
```

Firecracker does not accept CNI configuration directly. We pass the
**existing TAP name and the guest MAC address** to its API:

```bash
jq '{iface_id: "eth0", host_dev_name: .tap, guest_mac: .mac}' \
  "$STATE_DIR/vm.json" > "$STATE_DIR/firecracker-network.json"
cat "$STATE_DIR/firecracker-network.json"

curl --fail-with-body --silent --show-error --unix-socket "$FC_SOCKET" \
  -X PUT http://localhost/network-interfaces/eth0 \
  -H 'Content-Type: application/json' \
  --data-binary @"$STATE_DIR/firecracker-network.json"
```

**The IP address and gateway belong to the Linux configuration inside the VM**,
not to this API endpoint. We pass them through the `ip=` kernel parameter.
The netmask below corresponds to `/24` in our CNI file; if you change the subnet,
you must also adjust the netmask.

```bash
GUEST_CIDR="$(jq -er '.address' "$STATE_DIR/vm.json")"
GUEST_IP="${GUEST_CIDR%/*}"
GUEST_GATEWAY="$(jq -er '.gateway' "$STATE_DIR/vm.json")"
KERNEL="$(pwd)/$(ls vmlinux-* | sort -V | tail -1)"
BOOT_ARGS="console=ttyS0 reboot=k panic=1 pci=off ip=$GUEST_IP::$GUEST_GATEWAY:255.255.255.0::eth0:off"

jq -n --arg kernel "$KERNEL" --arg args "$BOOT_ARGS" \
  '{kernel_image_path: $kernel, boot_args: $args}' > "$STATE_DIR/boot-source.json"
curl --fail-with-body --silent --show-error --unix-socket "$FC_SOCKET" \
  -X PUT http://localhost/boot-source \
  -H 'Content-Type: application/json' \
  --data-binary @"$STATE_DIR/boot-source.json"

./start-firecracker.sh "$FC_SOCKET"
```

The second `PUT /boot-source` updates the configuration from `init-firecracker`
before the VM starts. The kernel must support `CONFIG_IP_PNP`. If `eth0` has no
address after boot, run `ip addr add <address> dev eth0` and
`ip route replace default via <gateway>` in the guest console, using the values
from `vm.json`.

## 5. Check connectivity and clean up

In the **guest** console in terminal B, as root:

```bash
ip link set eth0 up mtu 1400
ip -4 addr show eth0
ip route
printf 'nameserver 1.1.1.1\n' > /etc/resolv.conf
ping -c 3 10.200.1.1
ping -c 3 1.1.1.1
getent hosts example.com
```

We explicitly set MTU and DNS to match `network.conflist`; the CNI JSON alone
does not update the guest's `/etc/resolv.conf`. These example settings are not
persistent. You can also run `ping -c 3 "$GUEST_IP"` from the host in terminal A.

Finally, run `poweroff` **inside the guest** and wait for the Firecracker process
in terminal B to exit. In terminal A, remove the network in reverse order:

```bash
export CNI_COMMAND=DEL
for index in 2 1 0; do
  jq --argjson index "$index" --slurpfile prev "$STATE_DIR/result.json" '
    .plugins[$index] + {name, cniVersion}
    + (if $prev[0] == null then {} else {prevResult: $prev[0]} end)
  ' "$STATE_DIR/network.conflist" > "$STATE_DIR/delete.json"
  plugin="$(jq -r '.type' "$STATE_DIR/delete.json")"
  "$CNI_PATH/$plugin" < "$STATE_DIR/delete.json"
done
```

Each `DEL` receives the last saved result and the same allocation identity.
`ptp` also calls `host-local DEL` to release the address. Check all three calls
for errors; if any fail, keep `STATE_DIR` and retry cleanup. After success:

```bash
ip netns del vm-001
rm -f -- "$FC_SOCKET"
rm -rf -- "$STATE_DIR"
```

After a partial `ADD` failure, run the same `DEL` calls. Deleting the namespace
also removes any TAP that the plugin did not manage to include in its result.
Do not delete the entire `/var/lib/cni` directory: it contains reservations for
other allocations. `ptp` leaves global packet forwarding enabled because other
networks may be using it.

Sources: [CNI contract](https://www.cni.dev/docs/spec/),
[ptp](https://www.cni.dev/plugins/current/main/ptp/),
[TAP adapter](https://github.com/awslabs/tc-redirect-tap),
[Firecracker networking](https://github.com/firecracker-microvm/firecracker/blob/main/docs/network-setup.md).
