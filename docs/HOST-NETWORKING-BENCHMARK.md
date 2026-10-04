# Firecracker host networking: a custom daemon module or CNI?

Notes for further analysis, prepared on 2026-10-03.

**Question:** how can a process running on a single Linux host prepare, allocate, and remove networking for microVMs without manually running commands for every launch?

We compare two approaches:

- **A — a custom networking module in the daemon**, using libraries to manage interfaces, namespaces, routes, and firewall rules. E2B's open-source code is the reference implementation.
- **B — a daemon that delegates configuration to CNI plugins**, with a TAP adapter for Firecracker. The reference implementations are the Firecracker Go SDK and firecracker-containerd.

The scope covers only local host networking and its lifecycle. Passing configuration to the guest is discussed only as an integration boundary. This is an **architectural comparison and a measurement plan**; no performance measurements have been taken, and neither approach is assumed to be faster.

## 1. The starting point in our lab

In the original version of the lab, `start-firecracker.sh` performed these operations:

1. Delete the selected TAP device if it already exists.
2. Create a TAP device owned by the user running the script.
3. Assign the host address `10.200.1.1/24` and bring the interface up.
4. Pass the TAP name and MAC address to Firecracker.

That original version provided host–guest connectivity; routing and NAT for Internet access required additional work. Changing the TAP name did not change the fixed addresses, so the script itself did not allocate independent addresses to multiple VMs.

Currently, [init-firecracker](../init-firecracker) prepares the VM without networking, and [start-firecracker.sh](../start-firecracker.sh) only starts it. The current [README](../README.md#7-network-configuration) points to the [CNI example](./cni-setup-example/README.md), which demonstrates host and guest configuration separately. The rest of this comparison concerns the architectural approaches described below.

Moving these commands into a background process automates their execution. A meaningful comparison also needs to establish who owns the created resources, how partial failures are detected, and when resources can be removed or reused.

## 2. A shared contract: what the networking layer should provide

The following contract is a proposal for this comparison, not an existing E2B or CNI API.

| Input | Meaning |
|---|---|
| Network allocation ID | Associates interfaces, addresses, and rules with a specific owner |
| Network name/profile | Selected topology, address pool, and access policy |
| Firecracker process permissions | TAP ownership and namespace access |
| Expected connectivity | Host–VM, outbound Internet access, and possibly VM–VM communication |

| Output | Purpose |
|---|---|
| TAP name and namespace path | Launch Firecracker in the correct network context |
| MAC address, IP/prefix, and gateway | Consistent device and address configuration |
| MTU and, optionally, DNS settings | Complete connection configuration when required by the profile |
| Cleanup information | Recover resources even after the managing process restarts |

**Preparing a TAP device on the host and configuring an IP address inside the guest are separate operations.** Success in the first does not prove success in the second. The contract should identify who delivers the result to the guest initialization mechanism.

## 3. Approach A: a custom networking module in the daemon

### How it works

The daemon contains code describing the chosen topology. It calls libraries to configure Linux and tracks the resources belonging to each allocation. This can be viewed as “prepare connection” and “release connection” operations backed by specific interfaces, addresses, routes, and rules.

This does not mean writing a TCP/IP stack. The kernel still handles basic routing and NAT. The custom part is the logic that prepares kernel state and manages the resource lifecycle.

### A concrete example: E2B

The [E2B runtime](https://github.com/e2b-dev/runtime/blob/92197909dce5a1bef33e764ae4af76f0732fd7a8/README.md) is public code used by its sandbox platform. The module examined here prepares a separate namespace, a veth pair, a TAP device, addresses, and routes for each sandbox. In the v1 implementation, it configures NAT and forwarding rules through `go-iptables`, interfaces and routes through `vishvananda/netlink`, and namespaces through `vishvananda/netns`.

`CreateNetwork` also handles failures partway through configuration and attempts to remove partially created resources. `RemoveNetwork` removes rules, the route, veth, and namespace while allowing failed cleanup to be retried. [Network creation and removal code](https://github.com/e2b-dev/runtime/blob/92197909dce5a1bef33e764ae4af76f0732fd7a8/packages/orchestrator/pkg/sandbox/network/network.go).

A simplified topology of this implementation:

```text
host's main network namespace
  external interface
          ↕ forwarding / NAT
  host end of veth
          ↕ veth pair
sandbox namespace on the host
  other end of veth
          ↕ routing / NAT
  TAP
          ↕ Firecracker / virtio-net
  microVM
```

The namespace in this diagram belongs to the host's Linux system; the microVM also has its own kernel and network stack.

### How the daemon replaces shell commands

| Goal | Mechanism used in E2B |
|---|---|
| Create a namespace | `netns.NewNamed` |
| Create a veth pair | `netlink.Veth` and `netlink.LinkAdd` |
| Move an interface between namespaces | `netlink.LinkSetNsFd` |
| Create a TAP device | `netlink.Tuntap` and `netlink.LinkAdd` |
| Assign an IP address | `netlink.AddrAdd` |
| Bring an interface UP | `netlink.LinkSetUp` |
| Add a route | `netlink.RouteAdd` |
| Configure NAT and forwarding in v1 | Calls to the `go-iptables` library |

The library hides system-call details, but the application still determines the order and meaning of the operations. Using the `go-iptables` wrapper does not mean that firewall configuration happens without launching external programs. [E2B implementation](https://github.com/e2b-dev/runtime/blob/92197909dce5a1bef33e764ae4af76f0732fd7a8/packages/orchestrator/pkg/sandbox/network/network.go), [go-iptables](https://github.com/coreos/go-iptables).

### Addressing and preallocation

E2B represents the configuration as a `Slot`. The slot index determines the address reachable from the host and the addresses of both veth endpoints. The TAP has a fixed name inside a separate namespace. Separate network contexts allow local device names to be reused, while NAT maps internal addressing to the address assigned to the slot. [Slot and addressing definitions](https://github.com/e2b-dev/runtime/blob/92197909dce5a1bef33e764ae4af76f0732fd7a8/packages/orchestrator/pkg/sandbox/network/slot.go).

`Pool.Populate` prepares slots, `Pool.Get` allocates a ready slot and adjusts its Internet configuration, and `recycle` resets settings before returning the slot to the pool. When reuse is not possible, the resources are removed. The implementation also supports delayed returns and release notifications to avoid reallocating a slot too early. [Pool code](https://github.com/e2b-dev/runtime/blob/92197909dce5a1bef33e764ae4af76f0732fd7a8/packages/orchestrator/pkg/sandbox/network/pool.go).

After a restart, `ReclaimLeakedSlots` searches for remaining namespaces and attempts to remove their corresponding slots. This is a specific mechanism for reclaiming leftover resources, not evidence that every application should delete all its namespaces after a restart. [Reclaim code](https://github.com/e2b-dev/runtime/blob/92197909dce5a1bef33e764ae4af76f0732fd7a8/packages/orchestrator/pkg/sandbox/network/reclaim.go).

### Benefits and responsibilities

Design assessment for our lab:

- We can tailor the topology and operation order to Firecracker's requirements.
- We have one place to observe allocation and the complete configuration flow.
- We can introduce a pool of ready connections if measurements justify the cost.
- We must define IP allocation, resource ownership, synchronization, rollback, and state recovery ourselves.
- Every topology or rule change requires changes to our code and verification of kernel behavior.

**An important limit of the evidence:** we are examining a public implementation snapshot, without establishing the configuration of every production E2B host. In this snapshot, `NETWORK_VERSION=1` remains the default, while v2, which makes greater use of nftables, is opt-in and described as a canary. We therefore do not assume that all production hosts use v2. [v2 instructions](https://github.com/e2b-dev/runtime/blob/92197909dce5a1bef33e764ae4af76f0732fd7a8/packages/orchestrator/pkg/sandbox/network/v2/OPERATIONS.md).

## 4. Approach B: a daemon calling CNI plugins

### How it works

CNI is a contract between a runtime and networking plugins. A plugin is an executable program. It receives invocation parameters and a JSON configuration, and returns a JSON result. `ADD` prepares the connection; `DEL` removes it. In a plugin chain, each result is passed to the next plugin as `prevResult`; removal happens in reverse order. The runtime should persist the final result for later operations. [CNI specification](https://www.cni.dev/docs/spec/).

**CNI itself is not a daemon.** Our daemon can use CNI without Kubernetes or a full containerd installation. It still owns the allocation and decides when to connect and disconnect the network; it delegates specific operations to plugins.

### A concrete example: Firecracker integration

The Firecracker Go SDK supports both existing TAP devices and interfaces configured through CNI. Its integration example uses `ptp`, `host-local`, `firewall`, and `tc-redirect-tap`. The SDK associates the generated configuration with the VM and passes static network parameters to the guest at boot. Documented limitations include the number of interfaces with automatic IP configuration and how DNS is made available in the rootfs. [SDK README](https://github.com/firecracker-microvm/firecracker-go-sdk/blob/6fb280e993d4516ee6d5d20238572fe8752bc7ca/README.md#network-configuration).

`firecracker-containerd` uses the same integration as part of its container runtime. It serves as a reference for connecting the components; this note does not treat the demo configuration as a ready-made policy for every deployment. [Runtime documentation](https://github.com/firecracker-microvm/firecracker-containerd/blob/be68640a5d2237f5b427c37c1f5809ec154126c5/docs/getting-started.md#networking-support).

### Responsibilities in the example chain

```text
daemon / SDK
  └─ prepare namespace and invoke the CNI list
       ├─ ptp
       │    └─ host-local: allocate IP
       ├─ firewall
       └─ tc-redirect-tap
  └─ read the result and attach the TAP to Firecracker
```

| Component | Responsibility |
|---|---|
| Runtime/SDK | Allocation ID, namespace, configuration selection, invocation, and cleanup |
| `ptp` | A veth pair connecting the namespace to the host, routing, and optional masquerading |
| `host-local` | Allocate and release IP addresses from a local pool |
| `firewall` | Host rules that allow traffic through |
| `tc-redirect-tap` | TAP creation and packet redirection between the TAP and the previously created interface |

`ptp` creates a point-to-point connection using veth; a bridge is not required in this example. [ptp documentation](https://www.cni.dev/plugins/current/main/ptp/).

`host-local` stores allocations on the host's local filesystem, by default under `/var/lib/cni/networks/$NETWORK_NAME`. It ensures address uniqueness within the host, not globally. For a single-host design, preserving this state across restarts and releasing addresses when allocations end are important. [host-local documentation](https://www.cni.dev/plugins/current/ipam/host-local/).

The presence of a plugin named `firewall` does not automatically define a complete isolation policy. For example, its default ingress policy is `open`, and its documented isolation modes also refer to bridges. For a `ptp` profile, the intended communication policy must be defined and tested separately. [firewall documentation](https://www.cni.dev/plugins/current/meta/firewall/).

### Why a TAP adapter is needed

A standard plugin may create a veth interface, while Firecracker requires a TAP device. `tc-redirect-tap` creates a TAP, adds ingress qdiscs, and installs filters that redirect traffic in both directions between the TAP and the selected interface. It adds information to the result that associates the TAP with the configuration of the VM's internal interface. [Adapter code](https://github.com/awslabs/tc-redirect-tap/blob/34bf829e9a5c99df47318c7feeb637576df239fc/cmd/tc-redirect-tap/main.go).

The simplified packet path for this configuration:

```text
host ↔ veth pair ↔ tc redirection ↔ TAP ↔ Firecracker ↔ microVM
```

NAT, when required for outbound access through the host, comes from the configuration of the appropriate plugin. `tc-redirect-tap` acts as a device adapter; it does not allocate the entire network itself.

### Creation and removal lifecycle

In the SDK, CNI preparation includes creating or reusing a namespace, loading configuration, building runtime parameters, and calling `AddNetworkList`. The SDK registers a `DelNetworkList` cleanup function before `ADD` so it can also clean up after partial failures. It also attempts to remove an allocation's previous configuration before creating it again. [SDK integration and cleanup](https://github.com/firecracker-microvm/firecracker-go-sdk/blob/6fb280e993d4516ee6d5d20238572fe8752bc7ca/network.go).

The proposed lifecycle for our own daemon is:

1. Record the allocation ID, selected profile, and information needed to recover the operation.
2. Prepare the namespace and call `ADD` through a CNI integration library.
3. Preserve the result and the parameters needed to repeat cleanup.
4. Pass the TAP and namespace to the layer that launches Firecracker.
5. Once the network is no longer in use, call `DEL`, then remove the namespace belonging to the allocation.
6. After a failure or restart, inspect recorded allocations and retry cleanup for connections that are no longer in use.

This is a proposal for organizing our process. The details must match the CNI, runtime library, and plugin versions; CNI does not automatically recover the entire daemon's state.

### Benefits and responsibilities

Design assessment for our lab:

- Existing plugins handle much of the connection setup, IP allocation, and rule configuration logic.
- A network profile can be described as configuration using an existing contract.
- Allocation identity, results, errors, and cleanup still need to be managed.
- Diagnosis may involve the daemon, several plugin processes, local IPAM state, and kernel state.
- Requirements beyond the available plugins may call for configuration extensions, an adapter, or a custom plugin.

## 5. Architectural comparison

The table below summarizes the design trade-offs; it does not present measurement results.

| Criterion | A: custom module | B: daemon + CNI |
|---|---|---|
| Where the network is defined | Module code and configuration | Plugin list configuration and plugin implementations |
| Local IPAM implementation | Our own code or a chosen library | An existing plugin, such as `host-local` |
| Control over operation order | Directly in our code | Plugin order plus each plugin's internal logic |
| Handling partial failures | Our rollback logic | The runtime invokes cleanup; plugins undo their operations |
| State after a restart | Our ownership and recovery model | Our model plus CNI and IPAM results/state |
| Support for an unusual topology | Freedom to implement it | Depends on plugin and adapter capabilities |
| Pool of ready connections | Can be designed into the module | Possible as an additional layer; not provided by `ADD`/`DEL` alone |
| Host deployment requirements | Daemon binary and the tools it uses | Also versioned plugin binaries and configuration |
| Diagnosis | Our function calls and kernel state | Plugin invocations/results, plugin state, and kernel state |
| Maintaining the networking implementation | More responsibility on our side | Some responsibility is delegated; integration remains ours |
| Permissions | Appropriate privileges for networking and namespace operations | The same classes of operations still require privileges |
| Performance | Must be measured for the selected topology | Must be measured for the selected topology and plugin list |

The SDK's example CNI integration requires `CAP_NET_ADMIN` and `CAP_SYS_ADMIN` to configure networking and namespaces. Choosing an abstraction does not remove these host operations. [SDK requirements](https://github.com/firecracker-microvm/firecracker-go-sdk/blob/6fb280e993d4516ee6d5d20238572fe8752bc7ca/README.md#network-configuration).

**The distinction is not absolute.** CNI plugins also use Linux libraries and mechanisms. The difference is where the implementation lives and which contract the daemon uses. A custom module can also be exposed as a CNI plugin.

## 6. Benchmark: what are we actually comparing?

Three independent decisions need to be separated:

1. **Configuration mechanism:** direct library calls or launching CNI plugins.
2. **Topology:** routing/NAT inside a namespace or, for example, tc redirection between veth and TAP.
3. **Preallocation:** creating a connection on demand or acquiring a ready slot.

Comparing a preallocated E2B slot with on-demand CNI setup would measure two complete designs. It would not allow the entire difference to be attributed to CNI overhead. Similarly, throughput differences between different packet paths do not prove that one configuration mechanism is faster or slower.

### Possible prototype variants

| Variant | Purpose |
|---|---|
| A1: custom module, on-demand configuration | Cost of preparing a complete connection without a pool |
| A2: the same module with a pool | Isolate the effect of preallocation and slot resets |
| B1: CNI `ptp` + IPAM + firewall + TAP adapter | Cost of preparing networking through an existing integration |

A1 and B1 can help select a complete solution for the lab. To isolate **the cost of the CNI contract itself**, compare variants that create identical resources and rules, such as the same module called directly and through a CNI wrapper. This additional experiment is worthwhile only if integration overhead turns out to be significant.

### Measurement boundaries

- `prepare`: from the start of allocation until the TAP, namespace, addresses, and rules are ready.
- `release`: from the start of releasing an unused connection until cleanup completes.
- `acquire from pool`: from requesting a slot until it is ready after its policy has been adjusted.
- `recycle`: the time needed to reset and reclaim a slot for reuse.

The `prepare` measurement excludes image downloads, disk configuration, and guest boot. Time to actual connectivity should be checked separately so that a “ready TAP” does not become the only definition of success.

### Metrics

| Metric | What it helps assess |
|---|---|
| p50, p95, and p99 of `prepare` time | Typical cost and delays in less favorable cases |
| `release` time and failed cleanup count | Whether resources become available for reuse |
| CPU usage and number of launched processes | Configuration cost across many allocations |
| Remaining namespaces, links, and IP allocations | Leaks after complete lifecycle cycles |
| Firewall rule/element counts before and after | Whether state grows with the history of launches |
| Cost and capacity of an idle pool | The price of shortening the allocation path |
| Throughput, RTT, and CPU usage during traffic | Cost of the chosen packet topology |
| Recovery time after a restart | Effectiveness of state recovery or cleanup |

Record the kernel, plugin versions, network profile, number of concurrent operations, and host firewall state with each result. Repeated runs should cover both setup from scratch and setup after earlier lifecycle cycles.

### Correctness scenarios to compare

1. A single allocation → connectivity check → release cycle.
2. A series of cycles after which host state returns to its baseline.
3. Concurrent allocations: no conflicts in names, addresses, or rules.
4. Interrupted configuration after namespace creation, IP allocation, and rule creation.
5. Retrying cleanup of a partially removed connection.
6. A daemon restart: distinguish connections still in use from leftovers.
7. Exhaustion of the IP pool or ready slots: a defined error or wait, without uncontrolled allocation.
8. Verification of the intended VM–VM and host–VM communication policy.
9. For a pool: the next user of a slot receives the correct settings, without the previous user's policy.

This is a verification plan for a future prototype, not a report of completed tests.

## 7. Questions for the next discussion

- What connectivity should the first version provide: host–VM, outbound Internet access, or also VM–VM?
- Do we want one fixed network profile or several profiles selected through configuration?
- Is the goal to learn namespaces and routing, or to minimize our own implementation?
- Should an allocated address survive a daemon restart? What happens to VMs running during that restart?
- Does the network allocation ID identify a VM or a separate reusable slot?
- Is network preparation latency already a measured problem that justifies a pool?
- Does the existing CNI chain implement our policy, or will we need to write a substantial part of the rules ourselves?

Working hypothesis to test: **B should reduce the amount of custom network configuration logic; A provides more direct control over topology and lifecycle.** Integration, maintenance, and execution costs must be assessed for the selected profile. Pooling remains a separate decision in both approaches.

## 8. Code and source reading guide

Implementation links are pinned to commits checked when preparing this note. CNI documentation at `current` URLs may change.

| Order | Source | What to look for |
|---|---|---|
| 1 | [E2B: network.go](https://github.com/e2b-dev/runtime/blob/92197909dce5a1bef33e764ae4af76f0732fd7a8/packages/orchestrator/pkg/sandbox/network/network.go) | `CreateNetwork`, `RemoveNetwork`, operation order, and partial failures |
| 2 | [E2B: slot.go](https://github.com/e2b-dev/runtime/blob/92197909dce5a1bef33e764ae4af76f0732fd7a8/packages/orchestrator/pkg/sandbox/network/slot.go) | How a slot relates to addresses, names, and configuration |
| 3 | [E2B: pool.go](https://github.com/e2b-dev/runtime/blob/92197909dce5a1bef33e764ae4af76f0732fd7a8/packages/orchestrator/pkg/sandbox/network/pool.go) | `Populate`, `Get`, `returnSlot`, `recycle` |
| 4 | [E2B: reclaim.go](https://github.com/e2b-dev/runtime/blob/92197909dce5a1bef33e764ae4af76f0732fd7a8/packages/orchestrator/pkg/sandbox/network/reclaim.go) | Finding resources left over from a previous run |
| 5 | [SDK: network.go](https://github.com/firecracker-microvm/firecracker-go-sdk/blob/6fb280e993d4516ee6d5d20238572fe8752bc7ca/network.go) | `CNIConfiguration`, namespace creation, `AddNetworkList`, `DelNetworkList` |
| 6 | [tc-redirect-tap: main.go](https://github.com/awslabs/tc-redirect-tap/blob/34bf829e9a5c99df47318c7feeb637576df239fc/cmd/tc-redirect-tap/main.go) | `plugin.add`, `plugin.del`, tc filters, and the VM result |
| 7 | [CNI specification](https://www.cni.dev/docs/spec/) | Allocation identity, operation results, and removal order |
| 8 | [ptp](https://www.cni.dev/plugins/current/main/ptp/), [host-local](https://www.cni.dev/plugins/current/ipam/host-local/), [firewall](https://www.cni.dev/plugins/current/meta/firewall/) | Exactly what each plugin provides |
