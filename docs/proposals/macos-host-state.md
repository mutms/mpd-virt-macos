# Proposal: macOS host state model

**Status:** implemented — kept for the rationale and the threat model.

How `mpd-virt` lays out its own state on the macOS host: what lives
where, who owns it, and what survives an uninstall.

> **History.** This document also carried a WireGuard architecture,
> which is gone: mpd no longer uses a tunnel. Reachability is a static
> route per VM plus a scoped resolver file, and identity material is
> now just the CA. That half was superseded by the per-VM addressing
> work and removed here rather than left to mislead; see `README.md`
> and the mpd repo's `docs/NETWORKING.md` for the shipped model. Git
> history has the original if you need it.

## Non-goals

- Linux/Windows host equivalents. The state-dir model has plausible
  analogues there but they're out of scope.
- Cross-Mac sync of host identity. Each Mac generates and trusts its
  own CA.

## The one-directory state model on the host

### One sentence per owner

- **`~/.mpd-virt/`** — everything `mpd-virt` owns on the macOS host:
  identity (`conf/`) + per-VM bookkeeping. **The user owns it.**
  Identity material under `conf/` survives every `mpd-virt uninstall`.
- **`~/.mpd/`** is never created on the host — that path is
  exclusively the in-VM runtime state directory.

### Concrete directory layout (macOS host)

```
~/.mpd-virt/                          ← single host dir
├── conf/                             ← identity (survives uninstall)
│   ├── caroot/
│   │   ├── rootCA.pem
│   │   └── rootCA-key.pem
│   └── service/
├── current.env                       # MPD_VM_OCTET pointer (orchestrator bookkeeping)
└── <octet>/
    └── env                           # MPD_VM_OCTET, NAME, IP, USER, UUID (diagnostic)
                                      # (future: per-VM logs, cache)
```

Inside any mpd VM (Linux filesystem):

```
~/.mpd/                               ← in-VM state dir
├── conf/                             ← in-VM identity (pushed in by mpd-virt)
│   ├── caroot/rootCA.pem             ← public cert only; no private key on VM
│   ├── service/
│   └── platform.env
└── (runtime state — machines/, projects/, …)
```

The `~/.mpd/` on the host is **not** present; the `~/.mpd/` inside the
VM is on a different filesystem and only exists in the VM.

### Lifecycle rules

| Action | What it touches |
|---|---|
| `mpd-virt setup` | Reads/writes `~/.mpd-virt/conf/` (idempotent). Creates the per-VM `~/.mpd-virt/<octet>/` and `current.env` pointer. |
| `mpd-virt uninstall` | Removes per-VM `~/.mpd-virt/<octet>/` and host-side networking. **Never** touches `~/.mpd-virt/conf/`. |
| `rm -rf ~/.mpd-virt/conf/` | User's manual nuclear option. Resets identity completely; next `mpd-virt setup` regenerates. |
| Recreate a VM at the same `<octet>` | `~/.mpd-virt/<octet>/env` is overwritten with the new VM's UUID + name snapshot. Identity in `conf/` is untouched, so the CA — and therefore browser trust for that VM's zone — keeps working. |

## Threat model

The model is "the Mac is the trust origin; the VM is disposable":

| Asset | Lives on | Compromise impact |
|---|---|---|
| mpd CA private key | Mac (`~/.mpd-virt/conf/caroot/`) | Can sign arbitrary `*.mpd.test` certs (name-constrained; limited blast radius) |
| SSH private key | Mac (`~/.ssh/`) | Root in any mpd VM (dev user has passwordless sudo) |

A Mac compromise gives you everything.

A *VM* compromise (e.g. via a malicious project) does not climb back to
the Mac: the CA private key is not on the VM (only the cert is), and SSH
is one-way — the VM holds no keys to reach the Mac.

Note this is the host-side half only. The VM-side boundary changed with
WireGuard's removal: reachability is now a routed subnet rather than an
authenticated tunnel, which matters most for a LAN-hosted VM. That is
covered in the mpd repo's `docs/SECURITY.md`.

## Open questions

- **Should the CA be backed up?** Losing `~/.mpd-virt/conf/caroot/`
  means regenerating the CA and re-trusting it on the Mac, plus
  re-pushing to every VM. Worth an `mpd-virt export-identity` /
  `import-identity` flow? Probably defer — Time Machine catches
  `~/.mpd-virt/conf/` by default when enabled.
