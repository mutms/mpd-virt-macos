// mpd-virt — `uninstall` verb.
//
// Per-machine cleanup. The complement of `delete <NNN>` (per-VM):
//
//   delete   <NNN>   — removes one VM + its registry entry; preserves
//                       conf/ (CA + shared WG identity persist).
//   uninstall        — removes everything per-machine: CA from System
//                       Keychain, /etc/resolver/mpd.test, any static
//                       route to the container subnet, ~/.mpd-virt/conf/
//                       (CA files, WG identity, backend.env), and
//                       (with --force) any leftover per-VM dirs.
//
// All sudo-requiring steps are batched into ONE sudo recipe so the
// user types their password / does Touch ID at most once for the
// whole uninstall.
//
// Refuses to run while VMs are still registered unless `--force` is
// passed; otherwise the dev silently leaves per-VM WG.app tunnels +
// SSH-config blocks dangling against a CA that's about to disappear.

import Foundation

extension MpdVirt.Uninstall {
    static func run(force: Bool, assumeYes: Bool) throws {
        let fm = FileManager.default
        let known = try MpdVirt.Registry.knownOctets()

        header("Uninstalling mpd-virt host state")

        // 1. Pre-flight: registered VMs.
        section("Registered VMs")
        if known.isEmpty {
            ok("none")
        } else {
            let list = known.map { MpdVirt.vmId(octet: $0) }.joined(separator: ", ")
            if force {
                warn("\(known.count) still registered (\(list)) — --force will wipe their bookkeeping too")
            } else {
                fail("\(known.count) still registered (\(list))")
                MpdVirt.Ui.indent("`mpd-virt delete <NNN>` them first, or re-run with --force.")
                return
            }
        }

        // 2. Inventory + recipe. The closure inspects current host
        // state and returns the still-pending sudo steps. SudoRecipe
        // calls it twice (once for the printed recipe, once after the
        // optional manual pause), so anything the dev did by hand
        // drops out automatically.
        let resolverFile = "/etc/resolver/mpd.test"
        let buildSteps: () -> [MpdVirt.Host.SudoRecipe.Step] = {
            var s: [MpdVirt.Host.SudoRecipe.Step] = []
            if MpdVirt.Host.Keychain.isTrusted() {
                s.append(MpdVirt.Host.SudoRecipe.Step(
                    title: "Remove mpd CA from System Keychain",
                    argv: [
                        "/usr/bin/security", "delete-certificate",
                        "-c", MpdVirt.CA.commonName,
                        MpdVirt.Host.Keychain.systemKeychain,
                    ]
                ))
            }
            if fm.fileExists(atPath: resolverFile) {
                s.append(MpdVirt.Host.SudoRecipe.Step(
                    title: "Remove \(resolverFile)",
                    argv: ["/bin/rm", "-f", resolverFile]
                ))
            }
            if hasContainerSubnetRoute() {
                s.append(MpdVirt.Host.SudoRecipe.Step(
                    title: "Remove static route to \(MpdVirt.WireGuard.containerSubnet)",
                    argv: ["/sbin/route", "-n", "delete", MpdVirt.WireGuard.containerSubnet]
                ))
            }
            return s
        }

        section("Sudo-required cleanups (detected)")
        let initialSteps = buildSteps()
        if MpdVirt.Host.Keychain.isTrusted() {
            ok("'\(MpdVirt.CA.commonName)' in System Keychain")
        } else {
            MpdVirt.Ui.info("CA not in System Keychain")
        }
        if fm.fileExists(atPath: resolverFile) {
            ok("\(resolverFile) present")
        } else {
            MpdVirt.Ui.info("\(resolverFile) not present")
        }
        if hasContainerSubnetRoute() {
            ok("static route to \(MpdVirt.WireGuard.containerSubnet) present")
        } else {
            MpdVirt.Ui.info("no static route to \(MpdVirt.WireGuard.containerSubnet)")
        }
        if initialSteps.isEmpty {
            MpdVirt.Ui.info("nothing root-owned to clean up")
        }

        // 3. Confirm + execute.
        section("Confirm")
        let confirmed = MpdVirt.Ui.confirm(
            "Proceed with uninstall? This removes host trust material; per-Mac, irreversible.",
            assumeYes: assumeYes
        )
        if !confirmed {
            MpdVirt.Ui.info("aborted by user — nothing was changed")
            return
        }

        if !initialSteps.isEmpty {
            section("Running sudo recipe")
            try MpdVirt.Host.SudoRecipe.run(
                mode: assumeYes ? .yes : .interactive,
                build: buildSteps
            )
        }

        // 4. Local files (no sudo).
        section("Local files")
        if fm.fileExists(atPath: MpdVirt.confDir) {
            try fm.removeItem(atPath: MpdVirt.confDir)
            ok("removed \(MpdVirt.confDir)")
        } else {
            MpdVirt.Ui.info("\(MpdVirt.confDir) already gone")
        }

        // 5. Per-VM leftovers only when --force was used; otherwise we
        // already returned above.
        if !known.isEmpty {
            section("Per-VM leftovers (--force)")
            for octet in known {
                let dir = MpdVirt.vmDir(octet: octet)
                if fm.fileExists(atPath: dir) {
                    try? fm.removeItem(atPath: dir)
                    ok("removed \(dir)")
                }
                try? MpdVirt.Host.SSHConfig.strip(octet: octet)
            }
            warn("WG.app still has tunnels for: \(known.map { MpdVirt.vmName(octet: $0) }.joined(separator: ", ")) — remove them by hand.")
        }

        // 6. Drop the top-level dir if it's empty now.
        section("Top-level dir")
        if let remaining = try? fm.contentsOfDirectory(atPath: MpdVirt.rootDir),
           remaining.isEmpty {
            try? fm.removeItem(atPath: MpdVirt.rootDir)
            ok("removed empty \(MpdVirt.rootDir)")
        } else {
            MpdVirt.Ui.info("\(MpdVirt.rootDir) not empty — left alone")
        }

        print("")
        ok("uninstall complete.")
    }

    /// True iff macOS's route table has an entry for the container
    /// subnet. `route -n get` exits 0 when a matching route exists
    /// (the default route doesn't satisfy a `/24` lookup).
    private static func hasContainerSubnetRoute() -> Bool {
        let r = MpdVirt.Host.Ssh.runWithTimeout(
            argv: ["/sbin/route", "-n", "get", MpdVirt.WireGuard.containerSubnet],
            timeoutSeconds: 2.0
        )
        if r.timedOut || r.exitCode != 0 { return false }
        // `route -n get` returns 0 even when only the default route
        // matches. To detect a SPECIFIC route we check the "destination"
        // line in its output — should match exactly.
        for line in r.stdout.split(whereSeparator: { $0 == "\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("destination:") {
                let dest = trimmed
                    .dropFirst("destination:".count)
                    .trimmingCharacters(in: .whitespaces)
                // Match the literal subnet (e.g. "10.163.0.0") or any
                // host inside it ("10.163.x.x"). We installed
                // 10.163.0.0/24 so a /24-rooted destination is the
                // match we want.
                return dest.hasPrefix("10.163.")
            }
        }
        return false
    }

    // MARK: - Output shims

    private static func header(_ s: String) { MpdVirt.Ui.header(s) }
    private static func section(_ s: String) { MpdVirt.Ui.section(s) }
    private static func ok(_ s: String) { MpdVirt.Ui.ok(s) }
    private static func warn(_ s: String) { MpdVirt.Ui.warn(s) }
    private static func fail(_ s: String) { MpdVirt.Ui.fail(s) }
}
