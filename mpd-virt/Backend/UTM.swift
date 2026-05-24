// mpd-virt — UTM backend (macOS only).
//
// Drives UTM Desktop via osascript (UTM's AppleScript dictionary). The
// App Store distribution of UTM does NOT ship `utmctl`, so AppleScript
// is the only programmatic surface that works for everyone.
//
// Verbs:
//   - `create` — fresh VM from Debian generic-cloud raw + cidata seed
//     (CloudInit.swift). The bootstrap pipeline takes over afterward.
//   - start / stop / delete / describe — thin osascript wrappers.
//
// `clone` is not implemented: UTM's bundle layout makes hand-built
// templates less ergonomic than for Parallels, and cloud-init create is
// the canonical "fresh VM" path for UTM users.
//
// Prerequisites the user is expected to have already configured:
//   - UTM.app installed (App Store or DMG).
//   - UTM's host-side network for VMs routes the 10.211.55.0/24 subnet
//     with gateway 10.211.55.1 — same as Parallels Shared. The historical
//     mpd/setup/macos-utm flow assumed this and we mirror it.

#if os(macOS)
import Foundation

extension MpdVirt.UTM {

    // MARK: - Defaults / paths

    private static let utmAppPath = "/Applications/UTM.app"

    /// Defaults when --vm-ram / --vm-disk are absent. Match the historical
    /// macos-utm flow (8 GiB / 80 GiB / 4 vCPUs).
    private static let defaultMemoryMiB = 8 * 1024
    private static let defaultDiskGiB   = 80
    private static let defaultCPUs      = 4

    /// Hostname cloud-init sets on the freshly-booted VM (matches
    /// `mpd-template-<suffix>` so the bootstrap's naming gate accepts
    /// it). Bootstrap step 30 renames to `mpd-<NNN>` when it runs.
    private static let cloudInitInitialHostname = "mpd-template-cloudinit"

    /// Per-VM staging dir for the materialized raw disk + cidata ISO
    /// before UTM imports them. Lives outside the UTM bundle so a half-
    /// failed import doesn't leave the .utm directory in a weird state.
    private static func stagingDir(octet: Int) -> String {
        "\(MpdVirt.confDir)/utm-staging/\(MpdVirt.vmName(octet: octet))"
    }

    // MARK: - create

    static func create(octet: Int, opts: MpdVirt.CreateOpts) throws -> MpdVirt.Provisioned {
        try requireUTMApp()
        try preflight(octet: octet)
        let target   = MpdVirt.vmName(octet: octet)
        let canonIP  = "10.211.55.\(octet)"

        // 1. Inputs.
        let sshPubKey = try readDefaultSSHPubKey()
        let memoryMiB = parseSizeMiB(opts.vmRam) ?? defaultMemoryMiB
        let diskGiB   = parseSizeGiB(opts.vmDisk) ?? defaultDiskGiB
        let cpus      = defaultCPUs

        // 2. Cached Debian raw image. First call downloads + extracts.
        let cachedRaw = try MpdVirt.CloudInit.ensureBaseRawImage()

        // 3. Per-VM staging dir. Wiped + recreated so a previous half-
        //    failed attempt doesn't poison this run.
        let staging  = stagingDir(octet: octet)
        try? FileManager.default.removeItem(atPath: staging)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: staging),
            withIntermediateDirectories: true
        )
        var cleanupStaging = true
        defer {
            if cleanupStaging {
                try? FileManager.default.removeItem(atPath: staging)
            }
        }

        // 4. Materialize per-VM disk: copy raw, sparse-grow with dd.
        let diskPath = "\(staging)/\(target).raw"
        let seedPath = "\(staging)/seed.iso"
        try cpAndGrow(source: cachedRaw, dest: diskPath, targetGiB: diskGiB)

        // 5. Generate cidata ISO with static IP pinned. The historical
        //    macos-utm flow does this — the VM lands at the canonical IP
        //    from boot one, skipping the bootstrap step-30 IP pin (which
        //    becomes a no-op).
        let networkConfig = """
        version: 2
        ethernets:
          enp0s1:
            addresses: [\(canonIP)/24]
            gateway4: 10.211.55.1
            nameservers:
              addresses: [10.211.55.1]
        """
        FileHandle.standardError.write(Data("  ▶ writing cidata seed → \(seedPath)\n".utf8))
        try MpdVirt.CloudInit.makeCidataISO(
            outputPath: seedPath,
            username: opts.username,
            sshPubKey: sshPubKey,
            localHostname: cloudInitInitialHostname,
            networkConfig: networkConfig
        )

        // 6. Create the VM in UTM. From here on, any failure should
        //    osascript-delete the half-built VM so a retry isn't blocked
        //    by name collision.
        FileHandle.standardError.write(Data(
            "  ▶ creating UTM VM '\(target)' (\(memoryMiB)MiB, \(cpus) cpus)\n".utf8
        ))
        try runAppleScript(createVMScript(
            name: target,
            memoryMiB: memoryMiB,
            cpus: cpus,
            diskPath: diskPath,
            seedPath: seedPath
        ))
        var cleanupVM = true
        defer {
            if cleanupVM {
                FileHandle.standardError.write(Data(
                    "  ⚠ create failed — removing half-built UTM VM '\(target)'\n".utf8
                ))
                _ = try? runAppleScript(deleteVMScript(name: target))
            }
        }

        // 7. Attach memory balloon. UTM's AppleScript-created VMs leave
        //    virtio-balloon off by default; without it the full memoryMiB
        //    stays pinned even when the guest is idle. Mirrors historical
        //    macos-utm/lib/create-vm.sh.
        try runAppleScript(enableBalloonScript(name: target))

        // 8. Start the VM (cloud-init runs on first boot).
        FileHandle.standardError.write(Data("  ▶ starting UTM VM (cloud-init runs on first boot — 1–3 min) …\n".utf8))
        try runAppleScript(startVMScript(name: target))

        // 9. Wait for SSH at canonical IP. cloud-init's user-data lays
        //    down the SSH key; network-config pins the static IP. If the
        //    user's UTM network isn't routing 10.211.55.0/24, this is
        //    where it fails with a timeout pointing them at the prereq.
        let sshTarget = MpdVirt.Host.Ssh.Target(user: opts.username, host: canonIP)
        if !MpdVirt.Host.Ssh.waitUntilReachable(sshTarget, timeoutSeconds: 300) {
            throw MpdVirt.BackendError.other("""
                UTM VM '\(target)' didn't come up at \(canonIP) within 5 min. Check:
                  - UTM's host-side network is configured for 10.211.55.0/24 (gateway 10.211.55.1).
                  - cloud-init didn't fail inside the VM (open the UTM console to inspect).
                """)
        }

        // 10. Wait for cloud-init's boot-finished marker. The historical
        //     macos-utm script does this to ensure user creation + key
        //     install + disk grow have all settled before we touch the
        //     VM further.
        try waitForCloudInitDone(sshTarget, timeoutSeconds: 300)

        // 11. Detach the cidata CD cleanly: graceful shutdown → delete
        //     seed.iso on the host (UTM's AppleScript filters drives by
        //     `host size == 0` to identify the now-orphaned cidata) →
        //     prune the drive entry → restart.
        FileHandle.standardError.write(Data("  ▶ detaching cidata CD (shutdown → prune → restart) …\n".utf8))
        _ = try? MpdVirt.Host.Ssh.exec(sshTarget, "sudo shutdown -h now")
        try waitForVMStopped(name: target, timeoutSeconds: 120)
        try? FileManager.default.removeItem(atPath: seedPath)
        try runAppleScript(detachZeroSizedDrivesScript(name: target))
        try runAppleScript(startVMScript(name: target))
        if !MpdVirt.Host.Ssh.waitUntilReachable(sshTarget, timeoutSeconds: 180) {
            throw MpdVirt.BackendError.other("""
                UTM VM '\(target)' didn't come back at \(canonIP) within 3 min after the cidata \
                detach. Inspect via UTM and re-run with `mpd-virt setup \(MpdVirt.vmId(octet: octet)) \
                --ip=\(canonIP) --username=\(opts.username) --backend=utm`.
                """)
        }

        // 12. Read UUID via AppleScript.
        let uuid = (try? readVMID(name: target)) ?? ""
        FileHandle.standardError.write(Data("  ▶ UTM VM ready: \(canonIP) (\(uuid))\n".utf8))

        cleanupVM = false
        cleanupStaging = false
        return MpdVirt.Provisioned(ip: canonIP, uuid: uuid.isEmpty ? nil : uuid)
    }

    // MARK: - clone (not implemented)

    static func clone(octet: Int, template: String, opts: MpdVirt.CloneOpts) throws -> MpdVirt.Provisioned {
        throw MpdVirt.BackendError.notImplemented(verb: "clone", backend: "utm")
    }

    // MARK: - lifecycle

    static func start(octet: Int) throws {
        try requireUTMApp()
        try runAppleScript(startVMScript(name: MpdVirt.vmName(octet: octet)))
    }

    static func stop(octet: Int, kill: Bool) throws {
        try requireUTMApp()
        let script = kill
            ? killVMScript(name: MpdVirt.vmName(octet: octet))
            : stopVMScript(name: MpdVirt.vmName(octet: octet))
        try runAppleScript(script)
    }

    static func delete(octet: Int) throws {
        try requireUTMApp()
        let name = MpdVirt.vmName(octet: octet)
        _ = try? runAppleScript(killVMScript(name: name))
        try runAppleScript(deleteVMScript(name: name))
        try? FileManager.default.removeItem(atPath: stagingDir(octet: octet))
    }

    static func describe(octet: Int) throws -> MpdVirt.BackendInfo {
        guard FileManager.default.fileExists(atPath: utmAppPath) else {
            return MpdVirt.BackendInfo(state: "unknown")
        }
        let state = (try? readVMStatus(name: MpdVirt.vmName(octet: octet))) ?? "missing"
        return MpdVirt.BackendInfo(state: state)
    }

    // MARK: - preflight / locate / afterCanonicalIPReady

    static func preflight(octet: Int) throws {
        try requireUTMApp()
        let target = MpdVirt.vmName(octet: octet)
        if vmExists(name: target) {
            throw MpdVirt.BackendError.other("""
                UTM already has a VM named '\(target)'. Either pick a different octet \
                or `mpd-virt delete \(MpdVirt.vmId(octet: octet)) --backend=utm` first.
                """)
        }
    }

    static func locate(octet: Int, ipHint: String?) throws -> (ip: String, uuid: String?)? {
        // UTM doesn't expose a guest-IP query as cleanly as Parallels'
        // `prlctl list -i`, so locate trusts the canonical IP whenever
        // the VM exists; for first-time adoption with --ip, mirror the
        // general backend's behavior.
        let target = MpdVirt.vmName(octet: octet)
        if vmExists(name: target) {
            let uuid = try? readVMID(name: target)
            return (ip: "10.211.55.\(octet)", uuid: uuid)
        }
        if let ip = ipHint { return (ip: ip, uuid: nil) }
        return nil
    }

    static func afterCanonicalIPReady(octet: Int, hint: String?, user: String) throws {
        // UTM has no rename-while-running constraint to work around —
        // the VM was created with the canonical name and lives at the
        // canonical IP from boot one. Nothing to do.
    }

    static func printRegistryExtras(entry: MpdVirt.Registry.Entry) {
        let state = (try? readVMStatus(name: entry.name)) ?? "—"
        let uuid  = (try? readVMID(name: entry.name)) ?? "—"
        print("    VM UUID:    \(uuid)")
        if let registered = entry.uuid, uuid != "—", registered != uuid {
            print("                ⚠ stored UUID was \(registered)")
        }
        print("    state:      \(state)")
    }

    // MARK: - AppleScript helpers

    /// Run an AppleScript via `osascript -e <script>`. Captures stdout
    /// (some scripts return values we need to parse, e.g. id of vm).
    @discardableResult
    private static func runAppleScript(_ script: String) throws -> String {
        let r = try MpdVirt.Host.Ssh.runProcess(argv: [
            "/usr/bin/osascript", "-e", script
        ])
        if !r.ok {
            throw MpdVirt.BackendError.other("""
                osascript failed (exit \(r.exitCode)):
                \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                ---
                script:
                \(script)
                """)
        }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func requireUTMApp() throws {
        if !FileManager.default.fileExists(atPath: utmAppPath) {
            throw MpdVirt.BackendError.missingExecutable("""
                \(utmAppPath) not found. Install UTM (App Store or https://mac.getutm.app) \
                and retry.
                """)
        }
    }

    /// AppleScript-safe string quote: escape backslash and double-quote.
    private static func asQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func vmExists(name: String) -> Bool {
        let script = """
        tell application "UTM"
            try
                set _ to id of virtual machine named \(asQuote(name))
                return "yes"
            on error
                return "no"
            end try
        end tell
        """
        let r = (try? runAppleScript(script)) ?? "no"
        return r == "yes"
    }

    private static func readVMID(name: String) throws -> String {
        try runAppleScript("""
        tell application "UTM"
            return id of virtual machine named \(asQuote(name))
        end tell
        """)
    }

    private static func readVMStatus(name: String) throws -> String {
        // UTM's `status` returns a constant like `started`, `stopped`,
        // `paused`, `pausing`, `resuming`, `stopping`, `starting`. Coerce
        // to string so we get the bare word.
        try runAppleScript("""
        tell application "UTM"
            return (status of virtual machine named \(asQuote(name))) as string
        end tell
        """)
    }

    private static func createVMScript(
        name: String,
        memoryMiB: Int,
        cpus: Int,
        diskPath: String,
        seedPath: String
    ) -> String {
        // Mirrors mpd/setup/macos-utm/lib/create-vm.sh: backend=qemu,
        // aarch64, shared network. UTM copies the source files into its
        // own bundle on import, so we can clean up the staging dir
        // afterward.
        return """
        tell application "UTM"
            set diskFile to POSIX file \(asQuote(diskPath))
            set seedFile to POSIX file \(asQuote(seedPath))
            make new virtual machine with properties { ¬
                backend:qemu, ¬
                configuration:{ ¬
                    name:\(asQuote(name)), ¬
                    architecture:"aarch64", ¬
                    memory:\(memoryMiB), ¬
                    cpu cores:\(cpus), ¬
                    drives:{ ¬
                        {source:diskFile}, ¬
                        {source:seedFile} ¬
                    }, ¬
                    network interfaces:{{mode:shared}} ¬
                } ¬
            }
        end tell
        """
    }

    private static func enableBalloonScript(name: String) -> String {
        return """
        tell application "UTM"
            set vm to virtual machine named \(asQuote(name))
            set config to configuration of vm
            set qemu additional arguments of config to {{argument string:"-device"}, {argument string:"virtio-balloon-pci,free-page-reporting=on"}}
            update configuration of vm with config
        end tell
        """
    }

    private static func startVMScript(name: String) -> String {
        return """
        tell application "UTM"
            start virtual machine named \(asQuote(name))
        end tell
        """
    }

    private static func stopVMScript(name: String) -> String {
        // Graceful (sends ACPI). For force, see killVMScript.
        return """
        tell application "UTM"
            stop virtual machine named \(asQuote(name))
        end tell
        """
    }

    private static func killVMScript(name: String) -> String {
        return """
        tell application "UTM"
            stop virtual machine named \(asQuote(name)) by force
        end tell
        """
    }

    private static func deleteVMScript(name: String) -> String {
        return """
        tell application "UTM"
            delete virtual machine named \(asQuote(name))
        end tell
        """
    }

    /// Wait for the named VM's status to become `stopped`. Polls every
    /// 2s up to `timeoutSeconds`. Throws on timeout.
    private static func waitForVMStopped(name: String, timeoutSeconds: Int) throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let state = try? readVMStatus(name: name), state == "stopped" {
                return
            }
            Thread.sleep(forTimeInterval: 2)
        }
        throw MpdVirt.BackendError.other("""
            UTM VM '\(name)' did not reach state=stopped within \(timeoutSeconds)s.
            """)
    }

    /// AppleScript that filters out drives whose host source file has
    /// vanished (host size == 0) — exactly the trick the historical
    /// macos-utm/lib/create-vm.sh uses to drop the cidata CD after we've
    /// `rm`'d the seed.iso on the host.
    private static func detachZeroSizedDrivesScript(name: String) -> String {
        return """
        tell application "UTM"
            set vm to virtual machine named \(asQuote(name))
            set config to configuration of vm
            set vmDrives to drives of config
            set keptDrives to {}
            repeat with vmDrive in vmDrives
                if (host size of vmDrive) is not 0 then
                    set end of keptDrives to vmDrive
                end if
            end repeat
            set drives of config to keptDrives
            update configuration of vm with config
        end tell
        """
    }

    // MARK: - Disk materialization

    /// Copy `source` → `dest`, then sparse-extend `dest` to
    /// `targetGiB`. Refuses to shrink.
    private static func cpAndGrow(source: String, dest: String, targetGiB: Int) throws {
        FileHandle.standardError.write(Data("  ▶ copying base disk → \(dest) …\n".utf8))
        let cp = try MpdVirt.Host.Ssh.runProcess(argv: ["/bin/cp", source, dest])
        if !cp.ok {
            throw MpdVirt.BackendError.other("cp \(source) → \(dest) failed (exit \(cp.exitCode)).")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: dest)
        let currentBytes = (attrs[.size] as? Int) ?? 0
        let targetBytes  = targetGiB * 1024 * 1024 * 1024
        if targetBytes < currentBytes {
            try? FileManager.default.removeItem(atPath: dest)
            throw MpdVirt.BackendError.other("""
                requested disk size \(targetGiB) GB is smaller than the cloud image \
                (\(currentBytes / (1024*1024*1024)) GB). Pick a larger --vm-disk.
                """)
        }
        if targetBytes > currentBytes {
            FileHandle.standardError.write(Data("  ▶ growing disk to \(targetGiB) GB (sparse) …\n".utf8))
            let dd = try MpdVirt.Host.Ssh.runProcess(argv: [
                "/bin/dd", "if=/dev/zero", "of=\(dest)",
                "bs=1", "count=0", "seek=\(targetBytes)"
            ])
            if !dd.ok {
                throw MpdVirt.BackendError.other("dd resize failed (exit \(dd.exitCode)).")
            }
        }
    }

    // MARK: - cloud-init helpers

    private static func waitForCloudInitDone(_ target: MpdVirt.Host.Ssh.Target, timeoutSeconds: Int) throws {
        FileHandle.standardError.write(Data("  ▶ waiting for cloud-init to finish first-boot tasks …\n".utf8))
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if (try? MpdVirt.Host.Ssh.exec(
                target, "test -f /var/lib/cloud/instance/boot-finished"
            ))?.ok == true {
                return
            }
            Thread.sleep(forTimeInterval: 5)
        }
        throw MpdVirt.BackendError.other("""
            cloud-init didn't finish within \(timeoutSeconds)s. Inspect via UTM and the VM \
            console — likely package install or growpart hung.
            """)
    }

    // MARK: - SSH key + sizing

    private static func readDefaultSSHPubKey() throws -> String {
        guard let priv = MpdVirt.Host.Ssh.defaultIdentityFile() else {
            throw MpdVirt.BackendError.other("""
                no SSH identity found in ~/.ssh/. Generate one first, e.g.:
                    ssh-keygen -t ed25519
                Then re-run `mpd-virt create`.
                """)
        }
        let pub = priv + ".pub"
        guard FileManager.default.fileExists(atPath: pub) else {
            throw MpdVirt.BackendError.other("SSH identity \(priv) has no matching \(pub).")
        }
        let raw = try String(contentsOfFile: pub, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            throw MpdVirt.BackendError.other("\(pub) is empty.")
        }
        return raw
    }

    /// "8G" / "8192M" / "8192" → 8192 (MiB).
    private static func parseSizeMiB(_ s: String?) -> Int? {
        guard let raw = s?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.hasSuffix("g") { return Int(lower.dropLast()).map { $0 * 1024 } }
        if lower.hasSuffix("m") { return Int(lower.dropLast()) }
        return Int(lower)
    }

    /// "80G" / "81920M" / "81920" → 80 (GiB).
    private static func parseSizeGiB(_ s: String?) -> Int? {
        guard let raw = s?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.hasSuffix("g") { return Int(lower.dropLast()) }
        if lower.hasSuffix("m") { return Int(lower.dropLast()).map { $0 / 1024 } }
        return Int(lower).map { $0 / 1024 }
    }
}
#endif
