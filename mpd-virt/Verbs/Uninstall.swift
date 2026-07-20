// mpd-virt — `uninstall` verb.
//
// Per-machine cleanup. The complement of `delete <NNN>` (per-VM):
//
//   delete   <NNN>   — removes one VM + its registry entry; preserves
//                       conf/ (the CA persists).
//   uninstall        — removes everything per-machine: CA from System
//                       Keychain, every /etc/resolver/<id>.mpd.test,
//                       every static route to an mpd container subnet,
//                       ~/.mpd-virt/conf/
//                       (CA files, backend.env), and (with --force) any
//                       leftover per-VM dirs.
//
// All sudo-requiring steps are batched into ONE sudo recipe so the
// user types their password / does Touch ID at most once for the
// whole uninstall.
//
// Refuses to run while VMs are still registered unless `--force` is
// passed; otherwise the dev silently leaves per-VM SSH-config blocks
// dangling against a CA that's about to disappear.

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
        // Per-VM addressing means there is no single resolver file and no
        // single route to clean up — each VM has its own of both. Candidate
        // octets come from the registry *and* from whatever `/etc/resolver`
        // still holds, so a VM deleted earlier (registry entry gone, its
        // resolver file left behind) is still cleaned up here.
        let candidateOctets = Array(Set(known + discoverResolverOctets())).sorted()

        func pendingResolverFiles() -> [String] {
            let perVM = candidateOctets.map { MpdVirt.Net.resolverFile(octet: $0) }
            return (perVM + [MpdVirt.Net.legacyResolverFile])
                .filter { fm.fileExists(atPath: $0) }
        }
        func pendingRoutes() -> [String] {
            let perVM = candidateOctets.map { MpdVirt.Net.containerSubnet(octet: $0) }
            return (perVM + [MpdVirt.Net.legacySubnet]).filter { hasRoute($0) }
        }

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
            for file in pendingResolverFiles() {
                s.append(MpdVirt.Host.SudoRecipe.Step(
                    title: "Remove \(file)",
                    argv: ["/bin/rm", "-f", file]
                ))
            }
            for subnet in pendingRoutes() {
                s.append(MpdVirt.Host.SudoRecipe.Step(
                    title: "Remove static route to \(subnet)",
                    argv: ["/sbin/route", "-n", "delete", subnet]
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
        let foundResolvers = pendingResolverFiles()
        if foundResolvers.isEmpty {
            MpdVirt.Ui.info("no mpd resolver files in /etc/resolver")
        } else {
            for file in foundResolvers { ok("\(file) present") }
        }
        let foundRoutes = pendingRoutes()
        if foundRoutes.isEmpty {
            MpdVirt.Ui.info("no static routes to mpd container subnets")
        } else {
            for subnet in foundRoutes { ok("static route to \(subnet) present") }
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

    /// Octets that `/etc/resolver` still has a zone file for. Filenames
    /// are the match domain — `150.mpd.test` — so the VM id is the first
    /// label. Catches VMs whose registry entry is already gone but whose
    /// resolver file was left behind.
    private static func discoverResolverOctets() -> [Int] {
        let suffix = ".\(MpdVirt.Net.rootDomain)"
        guard let entries = try? FileManager.default
            .contentsOfDirectory(atPath: "/etc/resolver") else { return [] }
        return entries.compactMap { name in
            guard name.hasSuffix(suffix) else { return nil }
            let label = String(name.dropLast(suffix.count))
            guard label.count == 3, let octet = Int(label) else { return nil }
            return octet
        }
    }

    /// True iff macOS's route table has an entry for `subnet`.
    /// `route -n get` exits 0 when a matching route exists (the default
    /// route doesn't satisfy a `/24` lookup).
    private static func hasRoute(_ subnet: String) -> Bool {
        let r = MpdVirt.Host.Ssh.runWithTimeout(
            argv: ["/sbin/route", "-n", "get", subnet],
            timeoutSeconds: 2.0
        )
        if r.timedOut || r.exitCode != 0 { return false }
        // `route -n get` returns 0 even when only the default route
        // matches. To detect a SPECIFIC route we check the "destination"
        // line in its output.
        //
        // Matching on the shared `10.163.` prefix rather than the exact
        // subnet is deliberate: macOS prints the destination in
        // abbreviated form (`10.163.150`), which never equals the CIDR we
        // asked about. Any 10.163.* destination means *some* mpd route
        // matched, and uninstall wants all of them gone anyway.
        for line in r.stdout.split(whereSeparator: { $0 == "\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("destination:") {
                let dest = trimmed
                    .dropFirst("destination:".count)
                    .trimmingCharacters(in: .whitespaces)
                return dest.hasPrefix("\(MpdVirt.Net.subnetPrefix).")
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
