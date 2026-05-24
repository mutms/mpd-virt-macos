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
//   6. *.mpd.test DNS reachability (queries dnsmasq inside the VM).
//   7. If DNS fails: walk the dev through routing OR WG.app tunnel
//      import (either works — both expose the container subnet on
//      the Mac). Wait for confirmation; re-test.
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

        section("Routing to \(MpdVirt.WireGuard.containerSubnet) (so the resolver can reach \(MpdVirt.WireGuard.containerDNS))")
        if pingOK(MpdVirt.WireGuard.containerDNS) {
            ok("\(MpdVirt.WireGuard.containerDNS) reachable from this Mac")
        } else {
            warn("\(MpdVirt.WireGuard.containerDNS) NOT reachable — set up one of:")
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
            promptReTest(nonInteractive: nonInteractive, label: "routing to \(MpdVirt.WireGuard.containerDNS)") {
                pingOK(MpdVirt.WireGuard.containerDNS)
            }
        }

        section("End-to-end *.mpd.test")
        if !resolverFileLooksRight() || !pingOK(MpdVirt.WireGuard.containerDNS) {
            print("    skipped — resolver file or routing still missing (see above)")
        } else {
            // Two-part check, both via ping (= getaddrinfo path = same
            // view the user's shell sees).
            //
            // 1. `mpd.test` resolves to 10.163.0.4 (portal container)
            //    and the packet reaches it. Confirms DNS path AND
            //    container subnet routing both work for real workloads.
            //
            // 2. `vm.service.mpd.test` is served by THIS VM's dnsmasq
            //    as `host-record=vm.service.mpd.test,<MPD_VM_IP>`. If
            //    the resolved IP matches our canonical, we know we're
            //    talking to the RIGHT VM's resolver (catches "wrong WG
            //    tunnel is active" when juggling multiple VMs).
            if let ip = pingResolveAndProbe("mpd.test") {
                ok("`ping mpd.test` → \(ip) — DNS + routing path is live")
            } else {
                warn("`ping mpd.test` failed — DNS doesn't resolve or the resolved IP isn't reachable")
            }

            switch pingResolveAndProbe("vm.service.mpd.test") {
            case .none:
                warn("`vm.service.mpd.test` doesn't resolve — is this VM running an mpd version that publishes this record?")
            case .some(let ip) where ip == entry.ip:
                ok("`vm.service.mpd.test` → \(ip) — confirmed talking to \(entry.name)'s own dnsmasq")
            case .some(let ip):
                warn("`vm.service.mpd.test` → \(ip), expected \(entry.ip) — DNS is resolving via a different VM's dnsmasq")
            }
        }

        // CA trust — purely for Safari/curl UX, never blocks. Always
        // print the trust command when missing, regardless of mode.
        section("CA trust in System Keychain (for Safari / curl)")
        if MpdVirt.Host.Keychain.isTrusted() {
            ok("'\(MpdVirt.CA.commonName)' already trusted")
        } else {
            warn("'\(MpdVirt.CA.commonName)' is NOT trusted")
            print("    To trust (paste as a single line):")
            print("        sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain \(MpdVirt.CA.certPath)")
        }

        print("")
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

    /// Resolve a hostname AND probe its reachability in one shot, via
    /// `/sbin/ping`. Returns the resolved IP (parsed from `PING name
    /// (ip):` in the first line of output) when both resolution and
    /// the first ICMP echo succeed; nil otherwise.
    ///
    /// Why not `dscacheutil`: it queries the DirectoryServices cache,
    /// which has its own stale-NXDOMAIN window separate from
    /// mDNSResponder's. After dnsmasq starts serving a new record,
    /// dscacheutil can keep returning "no such host" for a while even
    /// when `ping` (via `getaddrinfo` → mDNSResponder) already sees
    /// the right answer. Using ping makes diag's view match the
    /// user's actual shell experience.
    private static func pingResolveAndProbe(_ name: String) -> String? {
        let r = MpdVirt.Host.Ssh.runWithTimeout(
            argv: ["/sbin/ping", "-c", "1", "-W", "1000", "-t", "2", name],
            timeoutSeconds: probeTimeoutSec
        )
        if r.timedOut || r.exitCode != 0 { return nil }
        // First line shape: "PING name (10.211.55.126): 56 data bytes"
        guard let firstLine = r.stdout.split(whereSeparator: { $0 == "\n" }).first,
              let open = firstLine.firstIndex(of: "("),
              let close = firstLine.firstIndex(of: ")")
        else { return nil }
        return String(firstLine[firstLine.index(after: open)..<close])
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
