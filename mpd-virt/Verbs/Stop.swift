// mpd-virt — `stop <NNN>` verb.
//
// Suspends the VM via its backend (or hard-stops with --kill). No
// diag at the end — the VM is going down, there's nothing to check.

import Foundation

extension MpdVirt.Stop {
    static func run(octet: Int, kill: Bool) throws {
        try validateOctet(octet)
        let entry = try MpdVirt.Registry.load(octet: octet)

        // General (no hypervisor): we can't stop anything. Just ping
        // and report what we see. Same shape as Start's general path.
        if !entry.backend.capabilities.lifecycle {
            header("\(entry.name) (\(entry.backend.rawValue) — no hypervisor lifecycle)")
            MpdVirt.Start.printTargetSection(entry: entry)
            MpdVirt.Start.reportReachability(entry: entry)
            return
        }

        header("Stopping \(entry.name)")

        section("Target")
        MpdVirt.Ui.indent("identifier: \(entry.name)")
        MpdVirt.Ui.indent("backend:    \(entry.backend.rawValue)")
        MpdVirt.Ui.indent("IP:         \(entry.ip)")
        MpdVirt.Ui.indent("mode:       \(kill ? "kill (hard stop)" : "suspend")")

        section("Hypervisor")
        let preState = (try? entry.backend.describe(octet: octet))?.state ?? "unknown"
        if preState == "stopped" {
            ok("\(entry.name) already stopped")
            return
        }
        if !kill, preState == "suspended" {
            ok("\(entry.name) already suspended")
            return
        }
        do {
            try entry.backend.stop(octet: octet, kill: kill)
            ok("\(entry.backend.rawValue) \(kill ? "stop --kill" : "suspend") \(entry.name)")
        } catch {
            fail("\(error)")
        }
    }

    // MARK: - Output shims

    private static func header(_ s: String) { MpdVirt.Ui.header(s) }
    private static func section(_ s: String) { MpdVirt.Ui.section(s) }
    private static func ok(_ s: String) { MpdVirt.Ui.ok(s) }
    private static func warn(_ s: String) { MpdVirt.Ui.warn(s) }
    private static func fail(_ s: String) { MpdVirt.Ui.fail(s) }
}
