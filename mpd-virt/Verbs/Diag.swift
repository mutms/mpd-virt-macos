// mpd-virt — `diag <NNN>` verb.
//
// macOS-side diagnostic + completion of the post-setup steps that
// `mpd-virt setup` deliberately doesn't run (routing, DNS, the WG.app
// import, optional CA trust). Setup is for VM-side state; diag is for
// the Mac-side wiring and end-to-end verification.
//
// Two-phase checklist:
//
//   --- mandatory (always runs) ---
//   1. Registry lookup for NNN.
//   2. Backend describe — current hypervisor view (state, UUID).
//   3. ICMP ping to canonical IP.
//   4. SCP /var/lib/mpd/conf/platform.env and compare with registry —
//      catches IP / VM-ID drift. The fix path is `mpd-virt setup`.
//   5. SSH config block re-asserted; ssh-by-alias `mpd-NNN` probed.
//
//   --- optional (only in interactive mode) ---
//   6. /etc/resolver/mpd.test exists and points at the container DNS.
//   7. Routing to the container subnet — reachability AND identity:
//      every mpd VM serves the same 10.163.0.0/24 with dnsmasq on
//      10.163.0.3, so a ping proves only that *some* VM is on the
//      other end. We ask that dnsmasq directly (dig, bypassing
//      /etc/resolver) which VM it belongs to.
//   8. End-to-end: curl https://mpd.test/ and read the VM id back
//      out of the portal's page title — resolver + routing + portal
//      + CA trust in a single real transaction.
//   If 7 or 8 fails: walk the dev through routing OR WG.app tunnel
//   import (either works — both expose the container subnet on the
//   Mac). Wait for confirmation; re-test.
//
// `--non-interactive` stops after step 5. setup calls diag in
// non-interactive mode; clone/create call it interactively (with
// `--yes` from clone/create propagating into --non-interactive).

import Foundation

extension MpdVirt.Diag {
    static func run(octet: Int, nonInteractive: Bool = false) throws {
        try validateOctet(octet)
        header("Diagnosing mpd-\(MpdVirt.vmId(octet: octet))")

        // === Mandatory phase ===

        // 1. Registry — abort hard if not registered. Otherwise the
        //    backend renders the field block (common header + its own
        //    extras: live VM name/UUID/state for Parallels, nothing
        //    extra for General).
        let entry: MpdVirt.Registry.Entry
        do {
            entry = try MpdVirt.Registry.load(octet: octet)
        } catch {
            fail("no registry entry for \(MpdVirt.vmId(octet: octet)) — run `mpd-virt setup \(MpdVirt.vmId(octet: octet)) …` first")
            return
        }
        section("Registry")
        entry.backend.printRegistry(entry: entry)

        // 3. ICMP ping.
        section("Network reachability")
        if pingOK(entry.ip) {
            ok("ICMP ping \(entry.ip) replies")
        } else {
            fail("ping \(entry.ip) — no reply. Is the VM running?")
            return
        }

        // 4. Fetch + compare platform.env.
        section("VM platform identity")
        let sshTarget = MpdVirt.Host.Ssh.Target(user: entry.user, host: entry.ip)
        let tmpEnv = "/tmp/mpd-virt-platform.\(getpid()).env"
        defer { try? FileManager.default.removeItem(atPath: tmpEnv) }
        do {
            try MpdVirt.Host.Ssh.get(
                sshTarget,
                remotePath: "/var/lib/mpd/conf/platform.env",
                localPath: tmpEnv
            )
            let guestKV = try parseEnvFile(tmpEnv)
            let expectedID = MpdVirt.vmId(octet: entry.octet)
            if guestKV["MPD_VM_ID"] == expectedID {
                ok("MPD_VM_ID matches (\(expectedID))")
            } else {
                fail("MPD_VM_ID drift: guest=\(guestKV["MPD_VM_ID"] ?? "—") expected=\(expectedID)")
                print("    → `mpd-virt setup \(expectedID)` to reconcile")
            }
            if guestKV["MPD_VM_IP"] == entry.ip {
                ok("MPD_VM_IP matches (\(entry.ip))")
            } else {
                fail("MPD_VM_IP drift: guest=\(guestKV["MPD_VM_IP"] ?? "—") expected=\(entry.ip)")
                print("    → `mpd-virt setup \(expectedID)` to reconcile")
            }
        } catch {
            fail("couldn't scp /var/lib/mpd/conf/platform.env: \(error)")
        }

        // 5. SSH config block + alias probe.
        section("SSH config")
        try MpdVirt.Host.SSHConfig.write(octet: entry.octet, ip: entry.ip, user: entry.user)
        ok("~/.ssh/config block re-asserted for \(entry.name)")
        // known_hosts is moot — our managed block sets
        // UserKnownHostsFile=/dev/null, so no entries persist.
        if sshByAliasWorks(entry.name) {
            ok("`ssh \(entry.name) true` works (alias resolves + key auth OK)")
        } else {
            fail("`ssh \(entry.name) true` failed — managed block didn't take effect (check ~/.ssh/config)")
        }

        // === Optional phase ===
        //
        // Always *checked* and *reported* — both interactive and
        // non-interactive modes. The only difference: interactive
        // mode pauses for the dev to apply each fix and re-tests
        // after; non-interactive mode just prints the suggested
        // commands and moves on. That keeps `mpd-virt setup` (which
        // runs diag non-interactively) informative — the dev still
        // sees exactly what's left to do for *.mpd.test traffic to
        // reach the VM, without the workflow blocking on a prompt.

        // Three INDEPENDENT checks. Resolver file existence and
        // routing reachability are orthogonal: you can have either
        // without the other. Reporting them as separate sections
        // tells the dev exactly which one needs fixing.

        section("/etc/resolver/mpd.test (scoped DNS for *.mpd.test)")
        if resolverFileLooksRight() {
            ok("/etc/resolver/mpd.test → nameserver \(MpdVirt.WireGuard.containerDNS)")
        } else {
            warn("/etc/resolver/mpd.test missing or doesn't point at \(MpdVirt.WireGuard.containerDNS)")
            print("    Paste to create it (macOS scopes this — only *.mpd.test queries go to the VM):")
            print("        sudo mkdir -p /etc/resolver")
            print("        echo \"nameserver \(MpdVirt.WireGuard.containerDNS)\" | sudo tee /etc/resolver/mpd.test")
            promptReTest(nonInteractive: nonInteractive, label: "/etc/resolver/mpd.test") {
                resolverFileLooksRight()
            }
        }

        // Reachability is necessary but NOT sufficient. Every mpd VM
        // serves the same 10.163.0.0/24 with dnsmasq on the same
        // 10.163.0.3, so once any one VM's route (or WG tunnel) is up,
        // the ping succeeds no matter which VM we're diagnosing — and
        // all *.mpd.test traffic silently lands on that other VM. So
        // after the ping we ask the dnsmasq we just reached who it
        // belongs to, via `dig` straight at 10.163.0.3. dig ignores
        // /etc/resolver, which is exactly what we want here: the answer
        // describes the ROUTE, not the resolver config (checked above).
        section("Routing to \(MpdVirt.WireGuard.containerSubnet) (so the resolver can reach \(MpdVirt.WireGuard.containerDNS))")
        if !pingOK(MpdVirt.WireGuard.containerDNS) {
            warn("\(MpdVirt.WireGuard.containerDNS) NOT reachable — set up one of:")
            printRoutingOptions(entry: entry)
            promptReTest(nonInteractive: nonInteractive, label: "routing to \(MpdVirt.WireGuard.containerDNS)") {
                pingOK(MpdVirt.WireGuard.containerDNS)
            }
        } else {
            switch dnsmasqIdentity() {
            case .some(let ip) where ip == entry.ip:
                ok("\(MpdVirt.WireGuard.containerDNS) reachable — and it's \(entry.name)'s own dnsmasq (\(entry.ip))")
            case .some(let ip):
                warn("\(MpdVirt.WireGuard.containerDNS) answers, but it's a DIFFERENT VM's dnsmasq (\(ip)) — not \(entry.name) (\(entry.ip))")
                print("    Every mpd VM serves the same \(MpdVirt.WireGuard.containerSubnet), so all *.mpd.test")
                print("    traffic is currently landing on \(ip). Repoint it at \(entry.name):")
                print("")
                printRepointFix(entry: entry)
                promptReTest(nonInteractive: nonInteractive, label: "routing to \(entry.name)") {
                    dnsmasqIdentity() == entry.ip
                }
            case .none:
                // Route works, but the VM publishes no identity record:
                // older mpd, or a sandbox VM (mpd only emits
                // host-record=vm.service.mpd.test when MPD_VM_IP is set).
                warn("\(MpdVirt.WireGuard.containerDNS) reachable, but it doesn't answer for `vm.service.mpd.test` —")
                print("    can't confirm the route lands on \(entry.name). Is another VM's route/tunnel active?")
            }
        }

        // CA trust — purely for Safari/curl UX, never blocks. Always
        // print the trust command when missing, regardless of mode.
        // Checked BEFORE the end-to-end section because that section
        // curls https://mpd.test/: an untrusted CA fails the TLS
        // handshake, and we'd rather the dev has already seen the real
        // cause than read it as a routing problem.
        section("CA trust in System Keychain (for Safari / curl)")
        if MpdVirt.Host.Keychain.isTrusted() {
            ok("'\(MpdVirt.CA.commonName)' already trusted")
        } else {
            warn("'\(MpdVirt.CA.commonName)' is NOT trusted")
            print("    To trust (paste as a single line):")
            print("        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \(MpdVirt.CA.certPath)")
        }

        section("End-to-end *.mpd.test")
        if !resolverFileLooksRight() || !pingOK(MpdVirt.WireGuard.containerDNS) {
            print("    skipped — resolver file or routing still missing (see above)")
        } else {
            // The real transaction, not a proxy for it: fetch the portal
            // over HTTPS by name. That exercises, in one shot, every
            // layer the dev actually cares about — /etc/resolver scoping
            // → dnsmasq → container subnet routing → the portal's Apache
            // → the mpd Root CA in the System Keychain.
            //
            // curl goes through getaddrinfo, same as the user's shell
            // (and unlike `dscacheutil`, which reads the DirectoryServices
            // cache and can keep serving a stale NXDOMAIN long after
            // mDNSResponder already has the right answer).
            //
            // The portal has no status API, so identity comes from the
            // page title — mpd renders the VM hostname there, which is
            // `mpd-NNN`. Ugly, but deterministic and near the top of the
            // response.
            let expectedID = MpdVirt.vmId(octet: entry.octet)
            let portal = portalIdentity()
            switch portal.vmId {
            case .some(let id) where id == expectedID:
                ok("`curl https://mpd.test/` → mpd-\(id) — resolver + routing + portal + TLS all live")
            case .some(let id):
                warn("`curl https://mpd.test/` → mpd-\(id), expected mpd-\(expectedID) — you're browsing the WRONG VM")
                print("    Same cause as the routing section above: fix the route, then re-run.")
            case .none:
                switch portal.exitCode {
                case 6:
                    warn("`curl https://mpd.test/` couldn't resolve the name — DNS path is broken despite /etc/resolver looking right")
                    print("    Try: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder")
                case 7, 28:
                    warn("`curl https://mpd.test/` couldn't connect (curl \(portal.exitCode)) — DNS resolves but the portal isn't reachable")
                    print("    Routing to 10.163.0.4 (the portal container), or the portal isn't running in \(entry.name).")
                case 35, 51, 60:
                    warn("`curl https://mpd.test/` failed TLS verification (curl \(portal.exitCode)) — '\(MpdVirt.CA.commonName)' isn't trusted by this Mac")
                    print("    See the CA trust section above.")
                case 0:
                    warn("`curl https://mpd.test/` answered, but the page has no `mpd-NNN` title — is that really the mpd portal?")
                default:
                    warn("`curl https://mpd.test/` failed (curl exit \(portal.exitCode))")
                }
            }
        }

        print("")
    }

    // MARK: - Routing remediation

    /// The two ways to put \(containerSubnet) on this Mac. Printed when
    /// nothing routes there at all.
    private static func printRoutingOptions(entry: MpdVirt.Registry.Entry) {
        print("")
        print("    A) Static route via this VM (simplest, no WireGuard):")
        print("           sudo route -n delete \(MpdVirt.WireGuard.containerSubnet) 2>/dev/null; sudo route -n add \(MpdVirt.WireGuard.containerSubnet) \(entry.ip)")
        print("")
        print("    B) WireGuard tunnel (encrypted, also works off-LAN):")
        let clientConf = MpdVirt.vmWireGuardConfFile(octet: entry.octet)
        print("        - Open WireGuard.app (Mac App Store)")
        print("        - \"+\" → \"Add Empty Tunnel…\", name it \(entry.name)")
        print("        - Paste the contents of \(clientConf)")
        print("          (Tip: `cat \(clientConf) | pbcopy`, then paste)")
        print("        - Save, then toggle the tunnel ON from the menu bar.")
    }

    /// Printed when the subnet routes fine but to the WRONG VM. The fix
    /// depends on WHO owns the route: a live WireGuard tunnel installs
    /// its own route and wins over a static one, so telling the dev to
    /// `route add` while another VM's tunnel is up would be useless
    /// advice. `route -n get` tells us which case we're in.
    private static func printRepointFix(entry: MpdVirt.Registry.Entry) {
        if let iface = routePath()?.interface, iface.hasPrefix("utun") {
            print("        Another VM's WireGuard tunnel is carrying the subnet (\(iface)).")
            print("        Toggle that tunnel OFF in WireGuard.app, then switch on \(entry.name)'s")
            print("        (or, if you'd rather use a static route, turn the tunnel off and run:)")
        }
        print("        sudo route -n delete \(MpdVirt.WireGuard.containerSubnet) 2>/dev/null; sudo route -n add \(MpdVirt.WireGuard.containerSubnet) \(entry.ip)")
    }

    /// Interactive re-test prompt. After printing a fix, optionally
    /// pause for the dev to apply it, then re-evaluate. Non-interactive
    /// is a no-op (setup-driven calls just want the fix printout).
    private static func promptReTest(
        nonInteractive: Bool, label: String, retest: () -> Bool
    ) {
        guard !nonInteractive else { return }
        FileHandle.standardError.write(Data(
            "    Press Enter to re-test \(label) (or Ctrl-C to stop here): ".utf8
        ))
        _ = readLine()
        if retest() {
            ok("\(label) is good now")
        } else {
            warn("\(label) still not working — re-run `mpd-virt diag` once you've applied the fix")
        }
    }

    /// True iff /etc/resolver/mpd.test exists and contains the expected
    /// nameserver line. Loose match (any line `nameserver 10.163.0.3`)
    /// so a hand-edited file with comments or extra options still
    /// passes the check.
    private static func resolverFileLooksRight() -> Bool {
        let path = "/etc/resolver/mpd.test"
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        let needle = "nameserver \(MpdVirt.WireGuard.containerDNS)"
        return raw.split(whereSeparator: { $0 == "\n" }).contains { line in
            line.trimmingCharacters(in: .whitespaces) == needle
        }
    }

    // MARK: - Probes
    //
    // All probes share a 2-second hard cap. /etc/resolver pointing at
    // an unreachable 10.163.0.3 makes dscacheutil block for the full
    // 30+ second DNS timeout; ssh likewise blocks on a half-open TCP.
    // Diag is a fast survey — we don't want it to hang.

    private static let probeTimeoutSec: Double = 2.0

    /// The portal fetch does a TLS handshake plus a PHP render, so it
    /// gets a longer leash than the ping/dig probes — but still bounded,
    /// one second past curl's own --max-time so curl reports the error
    /// itself instead of being SIGKILLed by the wrapper.
    private static let httpProbeTimeoutSec: Double = 4.0

    /// `/sbin/ping -c 1 -W 1 <ip>` — 1-second packet timeout, wrapped
    /// in a 2-second process timeout for safety.
    private static func pingOK(_ ip: String) -> Bool {
        let r = MpdVirt.Host.Ssh.runWithTimeout(
            argv: ["/sbin/ping", "-c", "1", "-W", "1000", ip],
            timeoutSeconds: probeTimeoutSec
        )
        return r.exitCode == 0 && !r.timedOut
    }

    /// `ssh mpd-NNN true` — exercises the alias from ~/.ssh/config.
    /// ConnectTimeout=2 inside ssh plus the 2s wrapper means we fail
    /// fast if the VM is unreachable.
    private static func sshByAliasWorks(_ alias: String) -> Bool {
        let r = MpdVirt.Host.Ssh.runWithTimeout(
            argv: [
                "/usr/bin/ssh",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=2",
                "-o", "LogLevel=ERROR",
                alias, "true",
            ],
            timeoutSeconds: probeTimeoutSec
        )
        return r.exitCode == 0 && !r.timedOut
    }

    /// Ask the dnsmasq we can currently reach at 10.163.0.3 which VM it
    /// belongs to. Returns the IP from its `vm.service.mpd.test` record
    /// (mpd emits `host-record=vm.service.mpd.test,<MPD_VM_IP>`), or nil
    /// if it doesn't answer for that name — an older mpd, or a sandbox
    /// VM, which skips the record because it has no static IP.
    ///
    /// `dig` deliberately: it talks to 10.163.0.3 directly and ignores
    /// /etc/resolver, so a wrong answer here means the ROUTE is wrong,
    /// with the resolver config factored out.
    private static func dnsmasqIdentity() -> String? {
        let r = MpdVirt.Host.Ssh.runWithTimeout(
            argv: [
                "/usr/bin/dig", "+short", "+time=1", "+tries=1",
                "@\(MpdVirt.WireGuard.containerDNS)", "vm.service.mpd.test", "A",
            ],
            timeoutSeconds: probeTimeoutSec
        )
        if r.timedOut || r.exitCode != 0 { return nil }
        return r.stdout
            .split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Fetch the portal over HTTPS by name and pull the VM id out of the
    /// page title (`<title>mpd-NNN</title>` — mpd renders the VM
    /// hostname there; there is no status endpoint to ask instead).
    ///
    /// Returns the id when it could be parsed, plus curl's raw exit code
    /// so the caller can tell apart the failure modes: 6 = DNS, 7 =
    /// connect refused/unreachable, 28 = timeout, 35/51/60 = TLS (i.e.
    /// the mpd Root CA isn't trusted on this Mac).
    private static func portalIdentity() -> (vmId: String?, exitCode: Int32) {
        let r = MpdVirt.Host.Ssh.runWithTimeout(
            argv: ["/usr/bin/curl", "-sS", "--max-time", "3", "https://mpd.test/"],
            timeoutSeconds: httpProbeTimeoutSec
        )
        if r.timedOut { return (nil, 28) }
        if r.exitCode != 0 { return (nil, r.exitCode) }
        return (parseTitleVmId(r.stdout), 0)
    }

    /// `<title>mpd-158</title>` → "158". nil if the title is missing or
    /// isn't an mpd VM hostname.
    private static func parseTitleVmId(_ html: String) -> String? {
        guard let open = html.range(of: "<title>"),
              let close = html.range(of: "</title>", range: open.upperBound..<html.endIndex)
        else { return nil }
        let title = html[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.hasPrefix("mpd-") else { return nil }
        let id = String(title.dropFirst("mpd-".count))
        return id.isEmpty ? nil : id
    }

    /// Which interface/gateway macOS currently uses for the container
    /// subnet, per `route -n get`. Only used to word the remediation:
    /// a `utun*` interface means WireGuard owns the route.
    private static func routePath() -> (gateway: String?, interface: String?)? {
        let r = MpdVirt.Host.Ssh.runWithTimeout(
            argv: ["/sbin/route", "-n", "get", MpdVirt.WireGuard.containerSubnet],
            timeoutSeconds: probeTimeoutSec
        )
        if r.timedOut || r.exitCode != 0 { return nil }
        var gateway: String?
        var interface: String?
        for line in r.stdout.split(whereSeparator: { $0 == "\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if gateway == nil, trimmed.hasPrefix("gateway:") {
                gateway = String(trimmed.dropFirst("gateway:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if interface == nil, trimmed.hasPrefix("interface:") {
                interface = String(trimmed.dropFirst("interface:".count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return (gateway, interface)
    }

    // MARK: - platform.env parser

    private static func parseEnvFile(_ path: String) throws -> [String: String] {
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        var kv: [String: String] = [:]
        for line in raw.split(whereSeparator: { $0 == "\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            kv[String(parts[0]).trimmingCharacters(in: .whitespaces)] =
                String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        return kv
    }

    // MARK: - Output — thin shims over MpdVirt.Ui so the rest of
    // this file reads with bare `section("...")` / `ok("...")` etc.

    private static func header(_ s: String) { MpdVirt.Ui.header(s) }
    private static func section(_ s: String) { MpdVirt.Ui.section(s) }
    private static func ok(_ s: String) { MpdVirt.Ui.ok(s) }
    private static func warn(_ s: String) { MpdVirt.Ui.warn(s) }
    private static func fail(_ s: String) { MpdVirt.Ui.fail(s) }
}
