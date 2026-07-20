// mpd-virt — `delete <NNN>` verb.
//
// Same visual shape as `diag`: a header line + sectioned checklist.
// Each step is one of:
//   - executed and reported (`✓`)
//   - intentionally skipped (`→ note`)
//   - manual follow-up the dev has to do (`⚠`)
//
// What delete actually touches:
//   - The VM in the hypervisor (Parallels / UTM) — destroyed unless
//     `--keep-vm` is set. General-backend VMs have no hypervisor, so
//     this step is always a "nothing to do".
//   - The `~/.ssh/config` managed block for the VM.
//   - The registry entry under `~/.mpd-virt/<NNN>/`.
//
// What delete deliberately does NOT touch:
//   - The CA at `~/.mpd-virt/conf/caroot/` (per-machine; uninstall's job).
//   - Any static route to the container subnet (per-machine; uninstall's job).

import Foundation

extension MpdVirt.Delete {
    static func run(octet: Int, keepVM: Bool, assumeYes: Bool) throws {
        try validateOctet(octet)
        let entry = try MpdVirt.Registry.load(octet: octet)

        header("Deleting \(entry.name)")

        section("Target")
        MpdVirt.Ui.indent("identifier: \(entry.name)")
        MpdVirt.Ui.indent("backend:    \(entry.backend.rawValue)")
        MpdVirt.Ui.indent("IP:         \(entry.ip)")
        MpdVirt.Ui.indent("hypervisor: \(keepVM ? "kept (--keep-vm)" : (entry.backend.capabilities.lifecycle ? "DESTROYED" : "n/a (general backend)"))")

        section("Confirm")
        let confirmed = MpdVirt.Ui.confirm(
            "Proceed with delete of \(entry.name)?",
            assumeYes: assumeYes
        )
        if !confirmed {
            MpdVirt.Ui.info("aborted by user — nothing was changed")
            return
        }
        ok("confirmed")

        // 1. Hypervisor VM.
        section("Hypervisor VM")
        if keepVM {
            MpdVirt.Ui.info("--keep-vm — skipping hypervisor destroy")
        } else if !entry.backend.capabilities.lifecycle {
            MpdVirt.Ui.info("backend=\(entry.backend.rawValue) — no hypervisor to destroy")
        } else {
            do {
                try entry.backend.delete(octet: octet)
                ok("destroyed via \(entry.backend.rawValue)")
            } catch {
                fail("backend.delete failed: \(error)")
                print("    (continuing — bookkeeping wipe below still happens)")
            }
        }

        // 2. SSH config block.
        section("SSH config block")
        if (try? MpdVirt.Host.SSHConfig.contains(octet: octet)) == true {
            try MpdVirt.Host.SSHConfig.strip(octet: octet)
            ok("stripped \(MpdVirt.Host.SSHConfig.path)")
        } else {
            MpdVirt.Ui.info("no block present in \(MpdVirt.Host.SSHConfig.path)")
        }

        // 3. Registry entry.
        section("Registry entry")
        try MpdVirt.Registry.remove(octet: octet)
        ok("removed \(MpdVirt.vmDir(octet: octet))")

        print("")
        ok("delete \(entry.name) complete.")
    }

    // MARK: - Output shims (match diag's bare-name call sites)

    private static func header(_ s: String) { MpdVirt.Ui.header(s) }
    private static func section(_ s: String) { MpdVirt.Ui.section(s) }
    private static func ok(_ s: String) { MpdVirt.Ui.ok(s) }
    private static func fail(_ s: String) { MpdVirt.Ui.fail(s) }
}
