# Proposal: sandbox takeover + CA refresh (one mechanism, two use cases)

A single `mpd-virt` capability that, on demand, **replaces the CA in
an existing VM, regenerates all derivative certs, and
installs/updates the WireGuard configuration**. Two real use cases
share this implementation:

1. **Sandbox → managed adoption.** Take an existing
   `mpd-sandbox` VM (originally provisioned via
   `setup/sandbox/take-over-sandbox-vm.sh` inside the VM) and adopt
   it as a normal `mpd-<NNN>` VM managed by `mpd-virt`. The user
   keeps their projects, runtime containers, and data volume; the
   Mac host gets WireGuard reachability and CA trust.
2. **Annual CA refresh.** mpd's local CA expires after ~1 year (the
   mkcert convention this codebase inherits). Without a renewal
   path, every project's HTTPS breaks on the anniversary. A
   `mpd-virt rotate-ca <vm>` command (or `--rotate-ca` flag on an
   existing verb) regenerates the CA on the Mac, pushes it into the
   VM, and triggers in-VM cert re-issuance for every project and
   service.

Both flows boil down to the same primitive: **push a fresh CA into
the VM, regenerate downstream certs, refresh trust.** Implementing
one gives you the other for ~free.

## Status

Parked, but real. The CA expiry is a fixed-deadline problem — every
mpd VM currently in use will hit it 12 months after first setup,
and the only workaround today is "rebuild the VM from scratch."
That's the wrong UX. Schedule before the first user's CA expires.

The sandbox-takeover use case is a nice-to-have that falls out of
the same plumbing — users who start with sandbox and decide they
want host-browser reachability shouldn't have to rebuild.

## Goals

1. **One shared primitive** — `mpd-virt refresh-trust <vm>` (or
   similar) — handles both use cases.
2. **Non-destructive to project state.** Projects, runtime
   containers, data volume, mpd.env files: all preserved. Only
   trust material rotates.
3. **Idempotent.** Safe to re-run if interrupted mid-way.
4. **Auditable.** Output names every cert it's about to replace
   before doing it; user can ctrl-C on the prompt.

## Non-goals

- **No automatic scheduling.** mpd-virt doesn't run cron jobs; the
  user invokes the refresh when they want to. (A "your CA expires
  in <N> days" warning in `mpd-virt doctor` is a reasonable
  add-on but not part of this proposal.)
- **No selective refresh** (CA but not service certs, etc.). The
  whole trust chain rotates atomically — partial states are a
  footgun.
- **No support for refreshing the CA *without* host access** to the
  VM. If the user has lost SSH access to the VM, that's a separate
  recovery problem.

## Mechanism (shared between both flows)

```
Mac host                                  VM
  generate new CA                       
  (or reuse existing host CA            
   if rotating to a different VM)       
                                         
  upload new CA via scp                 
  ──────────────────────────────►       /var/lib/mpd/conf/caroot/
                                         (overwrite existing)
                                         
  invoke in-VM cert refresh             
  ──────────────────────────────►       mpd --vm-refresh-trust
                                         (new in-VM verb — see below)
                                         
                                         in-VM steps:
                                         1. Re-import CA into system
                                            trust store
                                         2. Re-import into Firefox + NSS DB
                                         3. Re-generate service cert from
                                            new CA (Mpd.VM.Certificate)
                                         4. Re-generate per-project certs
                                            (frontdoor sidecar regenerates
                                             on next podman restart, or via
                                             explicit `mpd --vm-rotate-certs`)
                                         5. Restart portal + frontdoor
                                            sidecars to pick up new certs
                                         
  push new WireGuard conf               
  ──────────────────────────────►       /var/lib/mpd/conf/wireguard/mpd0.conf
                                         (only on sandbox-takeover —
                                          existing managed VMs already
                                          have WG configured)
                                         
                                         systemctl restart wg-quick@mpd0
  update Mac WireGuard config           
  with the new VM peer pubkey           
  (only on sandbox-takeover)            
```

## Per-flow specifics

### Flow A: Sandbox takeover (mpd-sandbox → mpd-NNN)

Preconditions:
- The sandbox VM is running, SSH-reachable from the Mac
- The sandbox already has `mpd --vm-setup` completed (its own self-issued CA, dnsmasq running, etc.)
- The Mac has `mpd-virt` installed

Steps:
1. **Pick an octet** (`mpd-virt adopt-sandbox --octet=158`)
2. **Rename hostname** in the VM: `mpd-sandbox` → `mpd-158`. Re-run
   `bootstrap/30-networking.sh 158` to also pin the static IP.
3. **Push the host's CA** (overwriting the sandbox's self-issued one)
4. **Push WireGuard conf** + Mac-side tunnel setup
5. **Run in-VM refresh-trust verb** to regenerate everything downstream
6. **Update `~/.mpd-virt/<158>/env`** so mpd-virt now tracks this VM as one of its own
7. **Verify**: `mpd-virt doctor 158` → all green

Caveats:
- The sandbox VM's existing certs (for `mpd.test`, runtime URLs, project URLs) all become invalid the moment the new CA lands. The in-VM refresh step regenerates them, but there's a window of seconds where things are mid-rotation.
- Existing browser-cached `*.mpd.test` certs on devices that were trusting the sandbox's old CA become invalid — irrelevant if "the browser" was Firefox-in-the-VM (no longer in use after adoption); needs noting if it wasn't.

### Flow B: Annual CA refresh (managed VM)

Preconditions:
- The VM is running and `mpd-virt` already tracks it
- The host's CA is about to expire (or has expired)

Steps:
1. **Generate a new CA** on the Mac (same generator used by
   first-time setup)
2. **Re-import into the Mac's System keychain**
3. **Push new CA into the VM** (overwrites
   `/var/lib/mpd/conf/caroot/rootCA*.pem`)
4. **Run in-VM refresh-trust verb** to regenerate service cert +
   per-project certs, re-import into VM's system trust store +
   Firefox + NSS DB, restart portal/frontdoor
5. **Verify**: `mpd-virt doctor <octet>` → all green; user opens
   `https://mpd.test/` in the Mac browser, no warnings

The WireGuard conf stays unchanged on this flow (key material is
separate from CA material).

## What changes in mpd (in-VM)

A new lifecycle verb: `mpd --vm-refresh-trust`. Implementation:

- Re-run `Mpd.VM.Certificate.trustCA` (system trust store)
- Re-run NSS DB import (`Mpd.VM.installCAInNSS`)
- Re-run Firefox policy install
- Re-run service-cert generation (`Mpd.Service.Portal.setup` for
  the cert path, or a dedicated `Mpd.Action.RefreshTrust`)
- For per-project certs: walk all projects, regenerate each via
  the existing frontdoor sidecar's cert path, restart the
  frontdoor sidecar to pick them up
- Update `/var/lib/mpd/conf/service/rootCA.fingerprint` so the
  next `mpd --vm-setup`/`mpd --vm-start` sees the new CA correctly

This is **`mpd --vm-refresh-trust` as a verb on the in-VM binary**,
invokable by `mpd-virt` over SSH (`ssh mpd-158 mpd --vm-refresh-trust`)
or by the dev directly when troubleshooting.

## What changes in mpd-virt

A new verb: `mpd-virt refresh-trust <vm>` (Flow B) and
`mpd-virt adopt-sandbox --octet=<N>` (Flow A). Both are thin
orchestrators around:

1. Generate or reuse the host CA (whatever
   `prepare_host_ca` already does)
2. Push to VM via scp
3. `ssh <vm> mpd --vm-refresh-trust`
4. For adopt-sandbox: also rename hostname, configure static IP,
   push WG conf, register the VM in `~/.mpd-virt/<octet>/`

## Open questions

1. **CA continuity vs CA rotation.** When refreshing, do we keep
   the same CA subject (renew with same key, extend validity) or
   issue a brand-new CA with a fresh key? Renewal-with-same-key is
   less invasive (any device that had the old CA in its trust
   store still trusts the new one). Brand-new CA is cleaner from a
   security-hygiene standpoint (compromise of the old key doesn't
   carry forward). I'd default to renewal-with-same-key for the
   annual refresh and brand-new for the sandbox takeover (since
   the sandbox CA was never on the Mac in the first place).
2. **Per-project cert regeneration trigger.** The current frontdoor
   sidecar regenerates certs on first request after CA fingerprint
   changes. Should `mpd --vm-refresh-trust` pre-warm all projects
   (visit each to force regeneration) or leave it lazy?
3. **Trust-import flow on the Mac side.** On macOS, importing a
   new CA into the System keychain requires sudo. Use the existing
   sudo-recipe affordance pattern from `setup.command` —
   number-to-clipboard list of `sudo` commands, then proceed.
4. **WG key rotation as part of CA refresh?** Optional. CA and WG
   key material are independent; rotating WG keys yearly is a
   defensible add-on but doesn't have the same hard-deadline
   character that CA expiry has.

## Acceptance

- `mpd-virt refresh-trust 158` on a managed VM: regenerates all
  certs in-place, Mac browser sees `https://mpd.test/` without
  warnings, no project state lost.
- `mpd-virt adopt-sandbox --octet=158` on a sandbox VM: VM renamed
  to `mpd-158`, static IP pinned, host CA + WG installed, Mac
  browser reaches `https://mpd.test/` via tunnel; projects from
  the sandbox era are still present and working.
- Both flows are idempotent — re-running mid-way (e.g. after a
  network blip during scp) completes cleanly.
