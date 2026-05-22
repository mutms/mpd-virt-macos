# mpd-virt-macos-prl

macOS host-side orchestrator for [mpd](https://github.com/mutms/mpd) that
drives **Parallels Desktop Pro** to create and manage `mpd` VMs.
The binary is called `mpd-virt`.

This is the Swift replacement for the bash scripts that previously lived
under `setup/macos/` in the mpd repo.

## Sibling repos (planned)

- `mpd-virt-linux-kvm` — libvirt/KVM backend on Linux hosts.
- `mpd-virt-windows-hyperv` — Hyper-V backend on Windows hosts.

Each backend is its own self-contained Swift project with its own
`mpd-virt` binary. No source sharing between them; small repos, simple
builds.

## Verbs

CRUD-shaped, per VM. Multiple VMs can be tracked + running simultaneously;
WireGuard.app's active tunnel determines which one the Mac's
`*.mpd.test` traffic flows to — `mpd-virt` doesn't track a "current"
VM on its own.

```
mpd-virt create  <octet>      Clone the template into mpd-<NNN>,
                              provision it, write SSH config block, import
                              the WireGuard tunnel into WireGuard.app.
mpd-virt delete  <octet>      Delete mpd-<NNN>. Removes the per-VM
                              bookkeeping under ~/.mpd-virt/<octet>/ and the
                              VM's SSH config entries; preserves
                              ~/.mpd-virt/conf/ (CA + WG identity persist).
mpd-virt start   <octet>      prlctl start mpd-<NNN>.
mpd-virt stop    <octet>      prlctl suspend mpd-<NNN>.
                              With --kill: prlctl stop --kill.
mpd-virt list                 List every tracked VM with its Parallels state.
                              Default verb when invoked with no args.
mpd-virt show    <octet>      Detail view: state, IP, UUID, WG tunnel status.
mpd-virt doctor               Re-assert host-side setup: CA trust in System
                              Keychain, SSH config block, WG tunnels imported.
```

The octet is the last byte of the VM's static IP on the Parallels Shared
network and is also the suffix in the VM name (`mpd-<NNN>`) and
its WG tunnel name. One number, encoded everywhere.

## What `mpd-virt create <octet>` does

Functional contract (mirrors the bash flow from the old
`setup/macos/lib/setup.sh`):

1. Verify prerequisites: Parallels Desktop Pro installed, `prlctl` on PATH,
   a Parallels VM template named `mpd-template`, host tooling
   (`ssh`, `ssh-keygen`, `scp`, `security`, `route`).
2. SSH key: use `~/.ssh/id_ed25519.pub` if present; offer to generate it
   otherwise.
3. Refuse if Parallels already has a VM named `mpd-<NNN>`.
4. Generate / reuse persistent identity in `~/.mpd-virt/conf/`:
   - mpd CA (`caroot/`) — generated on the first `create` ever.
   - Mac-side WG keypair (`wireguard/mac.{private,public}`) — generated
     on the first `create` ever.
   - Per-VM WG keypair + configs (`wireguard/<octet>/…`) —
     generated on the first `create` for this octet. **Reused on
     re-create at the same octet**, so WireGuard.app's existing tunnel
     keeps working.
5. Trust the CA in the macOS System Keychain (idempotent).
6. Clone `mpd-template` as `mpd-<NNN>`. Boot, wait for
   SSH.
7. Push CA + WG server.conf into the VM as
   `~/.mpd/conf/{caroot/rootCA.pem, wireguard/mpd0.conf}`. Write
   `~/.mpd/conf/platform.env` (`MPD_PLATFORM=managed`, …).
8. Kick `mpd --setup` over SSH inside the VM.
9. Write `~/.mpd-virt/<octet>/env` (VM metadata: UUID, IP, user — diagnostic).
10. Import the WG `client.conf` into WireGuard.app as
    `mpd-<NNN>`.
11. Add `~/.ssh/config` entries:
    - `Host mpd-<NNN>` → Parallels Shared IP.
    - `Host mpd-<NNN>-{php,node,util}` → `ProxyJump
      mpd-<NNN>`.

After `create`, daily use needs no sudo and no `/etc/resolver/` files —
WireGuard.app owns route + DNS while the tunnel is up.

## State / secrets layout (on the Mac)

```
~/.mpd-virt/                       ← everything mpd-virt owns
├── conf/                          ← identity (survives every `delete`)
│   ├── caroot/{rootCA.pem,rootCA-key.pem}
│   ├── wireguard/
│   │   ├── mac.{private,public}
│   │   └── <NNN>/{private,public,server.conf,client.conf}
│   └── service/
└── <NNN>/env                      ← per-VM bookkeeping (UUID, IP, …)
```

Octet range for managed VMs: `100–254` (Parallels Shared DHCP owns 1–99).
The sandbox VM uses ID `000` and lives in the main mpd repo's sandbox
flow, not here.

`~/.mpd/` is **not** created on the host — that path is exclusively the
in-VM runtime state directory inside each mpd VM.

Full design rationale: see [`docs/proposals/macos-host-state-and-wireguard.md`](docs/proposals/macos-host-state-and-wireguard.md).

## Build

```bash
make install      # produces ./bin/mpd-virt
```

Requires Xcode command-line tools.
