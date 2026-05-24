// mpd-virt — `start <NNN>` verb.
//
// Boots the VM via its backend, then waits for SSH to come back up
// (boot can take 10–30s) and runs `diag --non-interactive` so the
// dev gets the "yes, the VM is actually ready" confirmation in the
// same output stream.

import Foundation

extension MpdVirt.Start {
    static func run(octet: Int) throws {
        try validateOctet(octet)
        let entry = try MpdVirt.Registry.load(octet: octet)

        // Backends without a hypervisor (general) can't actually start
        // anything — report VM liveness via ping and bail. Don't pretend
        // to "Start" what we have no power to start.
        if !entry.backend.capabilities.lifecycle {
            header("\(entry.name) (\(entry.backend.rawValue) — no hypervisor lifecycle)")
            printTargetSection(entry: entry)
            reportReachability(entry: entry)
            return
        }

        header("Starting \(entry.name)")
        printTargetSection(entry: entry)

        section("Hypervisor")
        let preState = (try? entry.backend.describe(octet: octet))?.state ?? "unknown"
        if preState == "running" {
            ok("\(entry.name) already running")
        } else {
            do {
                try entry.backend.start(octet: octet)
                ok("\(entry.backend.rawValue) start \(entry.name)")
            } catch {
                fail("\(error)")
                return
            }
        }

        // 2. Wait for SSH at the registered IP. Skip if already
        //    reachable (already-running VMs answer immediately).
        section("Waiting for SSH")
        let target = MpdVirt.Host.Ssh.Target(user: entry.user, host: entry.ip)
        if MpdVirt.Host.Ssh.reachable(target) {
            ok("\(entry.ip) responds")
        } else if MpdVirt.Host.Ssh.waitUntilReachable(target, timeoutSeconds: 60) {
            ok("\(entry.ip) responds (after wait)")
        } else {
            warn("\(entry.ip) still unreachable after 60s — VM may still be booting")
            MpdVirt.Ui.indent("Re-run `mpd-virt diag \(entry.octet)` once it's up.")
            return
        }

        // 3. Non-interactive diag — single-page health check.
        print("")
        try MpdVirt.Diag.run(octet: octet, nonInteractive: true)
    }

    /// Render the standard Target block — id, backend, IP. Used by
    /// both the normal start path and the general-backend no-op path.
    static func printTargetSection(entry: MpdVirt.Registry.Entry) {
        section("Target")
        MpdVirt.Ui.indent("identifier: \(entry.name)")
        MpdVirt.Ui.indent("backend:    \(entry.backend.rawValue)")
        MpdVirt.Ui.indent("IP:         \(entry.ip)")
    }

    /// For general-backend (no hypervisor) verbs: just ping the
    /// recorded IP and report. Same helper is used by Stop.
    static func reportReachability(entry: MpdVirt.Registry.Entry) {
        section("VM reachability")
        let info = (try? entry.backend.describe(octet: entry.octet))
            ?? MpdVirt.BackendInfo(state: "unknown")
        switch info.state {
        case "running":
            ok("\(entry.ip) responds — VM is alive")
        case "unreachable":
            warn("\(entry.ip) does NOT respond — VM appears down or off-LAN")
        default:
            warn("state=\(info.state)")
        }
        MpdVirt.Ui.indent("(this verb is a no-op for \(entry.backend.rawValue) — VM lifecycle is managed externally)")
    }

    // MARK: - Output shims

    private static func header(_ s: String) { MpdVirt.Ui.header(s) }
    private static func section(_ s: String) { MpdVirt.Ui.section(s) }
    private static func ok(_ s: String) { MpdVirt.Ui.ok(s) }
    private static func warn(_ s: String) { MpdVirt.Ui.warn(s) }
    private static func fail(_ s: String) { MpdVirt.Ui.fail(s) }
}
