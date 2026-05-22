# Proposals

Designs for work we'd like done but haven't committed to a timeline for.
Each proposal is precise enough that a contributor (human or AI) can
implement it end-to-end without needing to re-derive the design.

These describe the `mpd-virt-macos` binary's architecture; the
in-VM `mpd` binary's proposals (if any) live in
[the main mpd repo](https://github.com/mutms/mpd).

## Index

- [`macos-host-state-and-wireguard.md`](macos-host-state-and-wireguard.md) —
  State model + WireGuard architecture for the macOS host. Defines
  `~/.mpd-virt/conf/` for persistent identity, `~/.mpd-virt/<octet>/`
  for per-VM bookkeeping, and a WireGuard-based networking model that
  eliminates daily sudo.
- [`mpd-virt.md`](mpd-virt.md) — `mpd-virt`'s verb surface, sudo-recipe
  UX, VM identity model (octet as canonical key), and the
  Parallels-Desktop-Pro backend specifics.
