// mpd-virt — `diag <NNN>` verb.
//
// macOS-side diagnostic + completion of the post-setup steps that
// `mpd-virt setup` deliberately doesn't run (routing, DNS, optional
// CA trust). Setup is for VM-side state; diag is for the Mac-side
// wiring and end-to-end verification.
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
//   6. /etc/resolver/<id>.mpd.test exists and points at this VM's
//      dnsmasq.
//   7. Routing to this VM's container subnet. Each VM has its own /24,
//      so reaching 10.163.<id>.3 at all already implies it is this VM's
//      dnsmasq. We still ask it directly (dig, bypassing /etc/resolver)
//      for `vm.service.<zone>` — one packet, and it confirms the answer
//      comes from the VM we think it does.
//   8. End-to-end: curl https://<id>.mpd.test/ and read the VM id back
//      out of the portal's page title — resolver + routing + portal
//      + CA trust in a single real transaction.
//   If 7 or 8 fails: walk the dev through the static route that
//   exposes the container subnet on the Mac. Wait for confirmation;
//   re-test.
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
        // sees exactly what's left to do for this VM's zone to
        // reach it, without the workflow blocking on a prompt.

        // Three INDEPENDENT checks. Resolver file existence and
        // routing reachability are orthogonal: you can have either
        // without the other. Reporting them as separate sections
        // tells the dev exactly which one needs fixing.

        let vmOctet = entry.octet
        let zone = MpdVirt.Net.zone(octet: vmOctet)
        let dns = MpdVirt.Net.containerDNS(octet: vmOctet)
        let subnet = MpdVirt.Net.containerSubnet(octet: vmOctet)
        let resolverFile = MpdVirt.Net.resolverFile(octet: vmOctet)

        section("\(resolverFile) (scoped DNS for *.\(zone))")
        if resolverFileLooksRight(octet: vmOctet) {
            ok("\(resolverFile) → nameserver \(dns)")
        } else {
            warn("\(resolverFile) missing or doesn't point at \(dns)")
            print("    Paste to create it (macOS scopes this — only *.\(zone) queries go to this VM):")
            print("        sudo mkdir -p /etc/resolver")
            print("        echo \"nameserver \(dns)\" | sudo tee \(resolverFile)")
            promptReTest(nonInteractive: nonInteractive, label: resolverFile) {
                resolverFileLooksRight(octet: vmOctet)
            }
        }
        // Left over from when every VM shared one flat `mpd.test` zone.
        // Harmless for this VM (longest-suffix match means the per-VM file
        // still wins), but it sends bare *.mpd.test lookups to an address
        // that no longer answers.
        if FileManager.default.fileExists(atPath: MpdVirt.Net.legacyResolverFile) {
            warn("\(MpdVirt.Net.legacyResolverFile) is left over from before per-VM zones")
            print("        sudo rm -f \(MpdVirt.Net.legacyResolverFile)")
        }

        // This VM's /24 is its own, so a reply from 10.163.<id>.3 can only
        // be this VM's dnsmasq — cross-VM confusion is structurally
        // impossible now, where under the old shared 10.163.0.0/24 it was
        // the normal failure mode. We still ask the dnsmasq we reached who
        // it is, via `dig` straight at it: one packet, and it proves the
        // answer came from the VM's own records. dig ignores
        // /etc/resolver, so this describes the ROUTE, with the resolver
        // config (checked above) factored out.
        section("Routing to \(subnet) (so the resolver can reach \(dns))")
        if !pingOK(dns) {
            warn("\(dns) NOT reachable — add the static route:")
            printRoutingFix(entry: entry)
            promptReTest(nonInteractive: nonInteractive, label: "routing to \(dns)") {
                pingOK(dns)
            }
        } else {
            switch dnsmasqIdentity(octet: vmOctet) {
            case .some(let ip) where ip == entry.ip:
                ok("\(dns) reachable — and it's \(entry.name)'s own dnsmasq (\(entry.ip))")
            case .some(let ip):
                // Can't be another VM: this subnet belongs to this one.
                // So the registry's record of the VM's LAN IP is stale.
                warn("\(dns) answers with \(ip), but the registry says \(entry.name) is \(entry.ip)")
                print("    \(subnet) is unique to \(entry.name), so this is IP drift, not a wrong route.")
                print("    Reconcile with: mpd-virt setup \(MpdVirt.vmId(octet: vmOctet))")
            case .none:
                // Route works, but the VM publishes no identity record:
                // older mpd, or a sandbox VM (mpd only emits
                // host-record=vm.service.<zone> when MPD_VM_IP is set).
                warn("\(dns) reachable, but it doesn't answer for `\(MpdVirt.Net.vmServiceRecord(octet: vmOctet))` —")
                print("    routing looks right; this VM just publishes no identity record (sandbox, or older mpd).")
            }
        }

        // CA trust — purely for Safari/curl UX, never blocks. Always
        // print the trust command when missing, regardless of mode.
        // Checked BEFORE the end-to-end section because that section
        // curls the zone apex: an untrusted CA fails the TLS
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

        section("End-to-end *.\(zone)")
        if !resolverFileLooksRight(octet: vmOctet) || !pingOK(dns) {
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
            let portal = portalIdentity(octet: vmOctet)
            let url = "https://\(zone)/"
            switch portal.vmId {
            case .some(let id) where id == expectedID:
                ok("`curl \(url)` → mpd-\(id) — resolver + routing + portal + TLS all live")
            case .some(let id):
                warn("`curl \(url)` → mpd-\(id), expected mpd-\(expectedID) — another VM is answering for this zone")
                print("    Each VM owns its own zone, so \(zone) is resolving somewhere unexpected.")
            case .none:
                switch portal.exitCode {
                case 6:
                    warn("`curl \(url)` couldn't resolve the name — DNS path is broken despite \(resolverFile) looking right")
                    print("    Try: sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder")
                case 7, 28:
                    warn("`curl \(url)` couldn't connect (curl \(portal.exitCode)) — DNS resolves but the portal isn't reachable")
                    print("    Routing to \(MpdVirt.Net.containerPortal(octet: vmOctet)) (the portal container), or the portal isn't running in \(entry.name).")
                case 35, 51, 60:
                    warn("`curl \(url)` failed TLS verification (curl \(portal.exitCode)) — '\(MpdVirt.CA.commonName)' isn't trusted by this Mac")
                    print("    See the CA trust section above.")
                case 0:
                    warn("`curl \(url)` answered, but the page has no `mpd-NNN` title — is that really the mpd portal?")
                default:
                    warn("`curl \(url)` failed (curl exit \(portal.exitCode))")
                }
            }
        }

        print("")
    }

    // MARK: - Routing remediation

    /// The one way to put this VM's /24 on this Mac: a static route via
    /// the VM's LAN IP. The delete-then-add form also repoints a route
    /// left over from a previous IP.
    ///
    /// Deliberately not persistent across reboots — re-add it when you
    /// need it. Automating that (a LaunchDaemon) is held back until the
    /// manual step proves annoying enough to be worth the machinery.
    private static func printRoutingFix(entry: MpdVirt.Registry.Entry) {
        let subnet = MpdVirt.Net.containerSubnet(octet: entry.octet)
        print("        sudo route -n delete \(subnet) 2>/dev/null; sudo route -n add \(subnet) \(entry.ip)")
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

    /// True iff this VM's resolver file exists and contains the expected
    /// nameserver line. Loose match (any line `nameserver 10.163.<id>.3`)
    /// so a hand-edited file with comments or extra options still
    /// passes the check.
    private static func resolverFileLooksRight(octet: Int) -> Bool {
        let path = MpdVirt.Net.resolverFile(octet: octet)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        let needle = "nameserver \(MpdVirt.Net.containerDNS(octet: octet))"
        return raw.split(whereSeparator: { $0 == "\n" }).contains { line in
            line.trimmingCharacters(in: .whitespaces) == needle
        }
    }

    // MARK: - Probes
    //
    // All probes share a 2-second hard cap. /etc/resolver pointing at
    // an unreachable dnsmasq makes dscacheutil block for the full
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

    /// Ask this VM's dnsmasq which VM it belongs to. Returns the IP from
    /// its `vm.service.<zone>` record (mpd emits
    /// `host-record=vm.service.<zone>,<MPD_VM_IP>`), or nil if it doesn't
    /// answer for that name — an older mpd, or a sandbox VM, which skips
    /// the record because it has no static IP.
    ///
    /// `dig` deliberately: it talks to the container DNS directly and
    /// ignores /etc/resolver, so the answer describes the route with the
    /// resolver config factored out.
    private static func dnsmasqIdentity(octet: Int) -> String? {
        let r = MpdVirt.Host.Ssh.runWithTimeout(
            argv: [
                "/usr/bin/dig", "+short", "+time=1", "+tries=1",
                "@\(MpdVirt.Net.containerDNS(octet: octet))",
                MpdVirt.Net.vmServiceRecord(octet: octet), "A",
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
    private static func portalIdentity(octet: Int) -> (vmId: String?, exitCode: Int32) {
        let r = MpdVirt.Host.Ssh.runWithTimeout(
            argv: ["/usr/bin/curl", "-sS", "--max-time", "3",
                   "https://\(MpdVirt.Net.zone(octet: octet))/"],
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
