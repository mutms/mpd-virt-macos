# Proposals

Designs for work we'd like done but haven't committed to a timeline for.
Each proposal is precise enough that a contributor (human or AI) can
implement it end-to-end without needing to re-derive the design.

These describe the `mpd-virt-macos` binary's architecture; the
in-VM `mpd` binary's proposals (if any) live in
[the main mpd repo](https://github.com/mutms/mpd).

## Index

- [`per-vm-addressing-and-wireguard-removal.md`](per-vm-addressing-and-wireguard-removal.md) —
  Per-VM DNS zones (`222.mpd.test`) and container subnets
  (`10.163.222.0/24`), with reachability via a persistent static route
  instead of WireGuard. Makes concurrent VMs possible and frees the
  Mac's single tunnel slot for other VPNs. Cross-repo: ships in
  lockstep with the matching change in the mpd repo.
- [`macos-host-state-and-wireguard.md`](macos-host-state-and-wireguard.md) —
  State model + WireGuard architecture for the macOS host. Defines
  `~/.mpd-virt/conf/` for persistent identity, `~/.mpd-virt/<octet>/`
  for per-VM bookkeeping, and a WireGuard-based networking model that
  eliminates daily sudo. **The WireGuard half is superseded** by
  `per-vm-addressing-and-wireguard-removal.md`; the state model
  stands.
- [`mpd-virt.md`](mpd-virt.md) — `mpd-virt`'s verb surface, sudo-recipe
  UX, VM identity model (octet as canonical key), and the
  Parallels-Desktop-Pro backend specifics.
- [`utm-backend.md`](utm-backend.md) — **high priority.** Second backend
  for macOS: UTM (free, native AVF on Apple Silicon). Removes the
  paid-Parallels-license barrier for evaluation. Simplified by the in-VM
  `bootstrap/` chain being hypervisor-agnostic; UTM platform existed in
  git history before the `mpd-virt` split — lift as reference.
- [`sandbox-takeover-and-ca-refresh.md`](sandbox-takeover-and-ca-refresh.md) —
  One mechanism, two use cases: adopting an existing `mpd-sandbox` VM
  as a managed `mpd-<NNN>` VM, and rotating the local CA before its
  ~1-year expiry. Both share a `mpd-virt refresh-trust <vm>` primitive
  plus a new in-VM `mpd --refresh-trust` verb. CA expiry is a fixed
  deadline; schedule before the first user hits it.
- [`pluggable-backends-and-adopt.md`](pluggable-backends-and-adopt.md) —
  **read first if you're starting `mpd-virt` implementation.** The
  architectural shape that ties the other proposals together: backends
  are reduced to a single `provision(octet, username, sshPubKey) → ip`
  call, after which a shared `adopt(ip, octet, username)` core does
  every Mac-side step. Doubles as the dev wedge — `mpd-virt adopt
  <ip>` works against any reachable VM, so the whole Mac side is
  testable before the first backend is written.
