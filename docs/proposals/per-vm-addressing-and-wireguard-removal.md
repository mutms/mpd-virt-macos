# Proposal: per-VM addressing, static routes, and WireGuard removal

Two changes that only make sense together. Each mpd VM gets its own
DNS zone (`222.mpd.test`) and its own container subnet
(`10.163.222.0/24`), and the WireGuard transport is deleted in favour
of a persistent static route per VM.

The companion proposal in the mpd repo
([`docs/proposals/per-vm-addressing.md`](https://github.com/mutms/mpd/blob/main/docs/proposals/per-vm-addressing.md))
covers the in-VM half: dnsmasq zone, container IPs, service certs.
Read it first — it defines the naming and addressing scheme this
proposal consumes. This document covers only the Mac side.

Supersedes the WireGuard architecture in
[`macos-host-state-and-wireguard.md`](macos-host-state-and-wireguard.md).

## Status

Proposed, not scheduled. Cross-repo: cannot ship without the matching
mpd change landing at the same time. No migration path — VMs are
deleted and recreated.

## Motivation

Two independent problems, one root cause.

**1. Concurrent VMs are impossible.** Every mpd VM today serves an
identical `10.163.0.0/24` with dnsmasq on `10.163.0.3` and an
identical flat `mpd.test` zone. The Mac can only route
`10.163.0.0/24` to one next hop, so only one VM is reachable at a
time. `Verbs/Diag.swift` carries an entire "am I talking to the wrong
VM?" subsystem — `dnsmasqIdentity()` (356-369), `printRepointFix()`
(263-270), the `parseTitleVmId` comparison (391-400) — that exists
solely to detect this collision. All of it becomes dead code once the
subnets differ.

**2. WireGuard cannot deliver concurrency on macOS, ever.** macOS
permits one active packet-tunnel provider, so WireGuard.app runs one
tunnel at a time. `WireGuard.swift:128-130` states this explicitly and
uses it to justify sharing a single VM keypair across every VM:

> *"Plus WireGuard.app exposes only one active tunnel at a time, so
> there's never ambiguity about which VM is 'live'."*

That slot is contended. A developer with an employer VPN has no free
tunnel for mpd at all. Making the tunnel per-VM (`10.164.<NNN>.0/30`
plus un-sharing `vmKeypair()`) would not help: N tunnels still cannot
be simultaneously active. WireGuard is structurally unable to solve
the problem this proposal exists to solve.

Meanwhile `Verbs/Diag.swift:245-247` already prints the static route
as **option A, "simplest, no WireGuard"**. The proposal is to promote
that path to the only path.

## Goals

- Two or more mpd VMs reachable from the Mac simultaneously, with no
  toggling and no interaction with any other VPN.
- `sudo` exactly once per VM at setup, plus once per Mac for CA trust.
  Zero `sudo` in daily use, including across reboots.
- Delete `WireGuard.swift` and every artifact that depends on it.

## Non-goals

- **Off-LAN access.** WireGuard's one genuine advantage was reaching a
  VM from outside the network. Remote hosts (the Proxmox case) are
  served by whatever transport already reaches that host — Cloudflare
  Zero Trust / WARP, which the user runs anyway. mpd-virt-macos
  manages *local* hypervisors; a remote backend brings its own
  transport.
- **Encrypting host↔VM traffic.** For Parallels and UTM the shared
  network is virtual and host-local — packets never reach a physical
  interface. Application traffic is SSH and HTTPS regardless, and the
  local CA's private key never leaves the Mac and the VM, so LAN-side
  interception of TLS is not possible. DNS queries and TLS SNI are
  plaintext; that exposes hostnames, not content.
- **Per-VM CA.** One CA per Mac, unchanged (see below).

## Mechanism

### Addressing, derived from the octet

The octet is already the canonical key for everything
(`README.md:29`, `Registry.Entry.octet`). Extend it to the container
network. A new `MpdVirt.Net` namespace replaces the five static
constants in `WireGuard.swift:22-33`:

```swift
enum Net {
    static func containerSubnet(octet: Int) -> String  // 10.163.222.0/24
    static func containerDNS(octet: Int) -> String     // 10.163.222.3
    static func portalIP(octet: Int) -> String         // 10.163.222.4
    static func zone(octet: Int) -> String             // 222.mpd.test
    static func resolverFile(octet: Int) -> String     // /etc/resolver/222.mpd.test
}
```

Mirror the existing `Backend.canonicalIP(octet:)` shape
(`Backend/Backend.swift:41-43`). No `10.164.x` tunnel addressing
survives.

### Reachability: one persistent route per VM

```
10.163.222.0/24  →  10.211.55.222   (the VM's LAN IP, Registry.Entry.ip)
10.163.150.0/24  →  10.211.55.150
```

Non-overlapping destinations, so they coexist unconditionally and are
invisible to any VPN client. The VM already forwards
(`net.ipv4.ip_forward=1`) and its podman bridge is directly connected,
so the data path is unchanged from the WireGuard case — only the
ingress interface differs.

`route add` does not survive reboot, so mpd-virt must install it
persistently rather than print it. Per VM:

- `/usr/local/libexec/mpd-virt/route-<NNN>.sh` — retries
  `/sbin/route -n add <subnet> <vm-ip>` until the hypervisor's vnic
  exists (it may not at boot), then exits.
- `/Library/LaunchDaemons/test.mpd.mpd-virt.route-<NNN>.plist` —
  `RunAtLoad`, root:wheel, 0644.

Both installed in the same `SudoRecipe` batch as the resolver file, so
the developer authenticates once per VM and never again.

### Resolution: one scoped resolver file per VM

```
/etc/resolver/222.mpd.test   →   nameserver 10.163.222.3
/etc/resolver/150.mpd.test   →   nameserver 10.163.150.3
```

macOS resolver(5) matches the longest suffix, so per-VM files never
conflict — and a stale `mpd.test` file loses to a `222.mpd.test` file,
which makes cleanup non-urgent.

Note this is *already* the mechanism: `WireGuard.swift:183-195`
deliberately omits `DNS =` from the tunnel conf (wireguard-apple
treats it as a global resolver with no `matchDomains` split-DNS, which
would send every Mac DNS query to the untrusted VM), and
`Diag.swift:294-303` checks for `/etc/resolver/mpd.test`. The only
change is per-VM naming, plus creating the file programmatically
instead of printing it for the developer to paste.

### The sudo ledger

| Operation | Frequency |
|---|---|
| CA into System Keychain | once per Mac |
| resolver file + route LaunchDaemon | once per VM |
| daily use, reboots, VM restarts | never |

Strictly better than today, where the WireGuard path additionally
requires a manual paste into WireGuard.app per VM and a tunnel toggle
on every switch.

## What changes in mpd-virt-macos

**Deleted**

- `mpd-virt/WireGuard.swift` — all 243 lines.
- `MpdVirt.wgServerConfFile` and `MpdVirt.vmWireGuardConfFile(octet:)`
  (`MpdVirt.swift:66-70`).
- `Bootstrap/RunInVM.swift:123-129` (scp `server.conf` →
  `/var/lib/mpd/conf/wireguard/mpd0.conf`) and `:192-196` (invoke
  `60-wireguard.sh`).
- `Verbs/Setup.swift:110-115` — the `renderAndSave` call.
- `Verbs/Diag.swift` — `dnsmasqIdentity()` (356-369),
  `printRepointFix()` (263-270), option B in `printRoutingOptions()`
  (248-255), and the wrong-VM branch (215-217). Identity is now
  implied by the subnet: if `222.mpd.test` answers, it came from VM
  222.

**Added**

- `MpdVirt.Net` (above).
- `Host/Route.swift` — render + install the per-VM retry script and
  LaunchDaemon; uninstall by label.
- `Host/Resolver.swift` — render + install `/etc/resolver/<NNN>.mpd.test`.
  Both are `SudoRecipe.Step` producers, not printers.

**Changed**

- `Verbs/Setup.swift` — after in-VM bootstrap, run one `SudoRecipe`
  batch: resolver file, route script, LaunchDaemon, `launchctl load`.
- `Verbs/Diag.swift` — resolver path and needle become per-VM
  (125-136, 290-303); the route check targets
  `Net.containerSubnet(octet:)`; `routePath()` (405-424) drops its
  `utun*` special-casing; the end-to-end curl targets
  `https://<NNN>.mpd.test/` (379-387); the hardcoded `10.163.0.4`
  (225) becomes `Net.portalIP(octet:)`.
- `Verbs/Uninstall.swift:51-76,159-182` — must iterate
  `Registry.knownOctets()` and remove N resolver files, N
  LaunchDaemons, N routes. The existing `dest.hasPrefix("10.163.")`
  test (174-178) is already generic enough.
- `Host/SSHConfig.swift:46` — `HostName \(runtime).runtime.mpd.test`
  becomes `\(runtime).runtime.\(Net.zone(octet:))`. Note this name is
  resolved *inside* the VM after ProxyJump, so it depends on the in-VM
  dnsmasq zone, not the Mac resolver.
- `README.md:29,42` — the "WireGuard.app's active tunnel decides which
  `*.mpd.test` traffic flows to" model is exactly what this removes.
- `docs/proposals/macos-host-state-and-wireguard.md` — add a status
  banner marking Part 2 superseded. Its §"Switching between VMs"
  (226-235) documents the collision this proposal eliminates. Note it
  also describes a `DNS = 10.163.0.3` client conf (110-113) that the
  code never implemented.

**Unchanged**

- `CA.swift` — `nameConstraints = critical, permitted;DNS:mpd.test`
  (line 94) already covers `222.mpd.test` and every depth beneath it.
  One CA per Mac, no rotation triggered by this change.
- `Registry.swift` — zone and subnet are derivable from `octet`, so no
  schema change. Prefer deriving over storing; the parser ignores
  unknown keys (80-88) if that turns out to be wrong.
- `CloudInit.swift`, all three backends, `Host/Keychain.swift`,
  `Host/SudoRecipe.swift` (mechanism only, unchanged).

## What changes in mpd (in-VM)

Detailed in the companion proposal; the parts this one depends on:

- dnsmasq serves `<NNN>.mpd.test` and containers move to
  `10.163.<NNN>.x`.
- **`net.ipv4.ip_forward=1` must move out of
  `bootstrap/60-wireguard.sh`.** That script is gated on the WireGuard
  conf existing (`60-wireguard.sh:36-39` — absent conf, clean no-op),
  so deleting WireGuard naively removes forwarding and makes every
  container unreachable via the static route. The sysctl drop-in
  belongs in `30-networking.sh` or its own step. This is the single
  most likely way to break the migration.
- `bootstrap/60-wireguard.sh` deleted; `wireguard` dropped from
  `40-install-software.sh`; `wg-quick@mpd0` gone.
- `vm.service.mpd.test` retired — the zone name carries the identity
  proof that record existed to provide.
- `docs/NETWORKING.md` rewritten. It currently describes a WireGuard
  tunnel that sets `DNS = 10.163.0.3` and states "No `/etc/resolver/`
  file" — neither has ever been true of this codebase.

## Open questions

1. **LaunchDaemon vs. on-demand route.** The daemon may fire before
   the hypervisor's vnic exists at boot, hence the retry loop. An
   alternative is installing the route during `mpd-virt start <NNN>`,
   which is naturally ordered — but needs sudo per start, defeating
   the goal. Recommend the daemon plus a bounded retry (say 60×1s,
   then exit non-zero and let `diag` report it).
2. **Sandbox (`octet 000`).** It keeps `10.163.0.0/24` and gets zone
   `000.mpd.test`. mpd-virt does not manage sandbox VMs today, so this
   is only a question if `adopt` grows to cover them.
3. **`10.163.0.0/16` reservation.** Per-VM `/24`s consume the whole
   /16 in aggregate. Worth documenting as reserved.
4. **Does `list`/`diag` want a fleet view** now that VMs genuinely
   coexist — one table showing all registered VMs with route/resolver
   status? Previously meaningless (only one could be live), now
   useful. Out of scope here, but the natural follow-up.

## Acceptance

- `mpd-virt create 222` and `mpd-virt create 150` on the same Mac.
  Both complete with exactly one sudo prompt each.
- With **no** WireGuard tunnel active and the employer VPN up:
  `https://moodle45.222.mpd.test/` and `https://mutms.150.mpd.test/`
  both load in Safari, simultaneously, with a valid cert.
- `ssh mpd-222-php` and `ssh mpd-150-php` both work in parallel.
- Reboot the Mac. Both routes come back with no prompt; both URLs load
  without intervention.
- `mpd-virt diag 222` reports green with no mention of WireGuard, and
  no "wrong VM" branch is reachable.
- `mpd-virt uninstall` removes both resolver files, both
  LaunchDaemons, both routes, and the CA.
- `grep -ri wireguard mpd-virt/` returns nothing.
