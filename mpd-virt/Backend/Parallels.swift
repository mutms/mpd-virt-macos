// mpd-virt — Parallels backend (macOS only).
//
// Wraps `prlctl` (Parallels Desktop Pro CLI) for VM lifecycle. Verbs:
//   - `clone`  — duplicate an existing `mpd-template-<suffix>` VM.
//   - start / stop / delete / describe — thin prlctl wrappers.
//
// `create` is intentionally not implemented for Parallels: Parallels
// Desktop has first-class template + snapshot UX (build it once with
// Parallels Tools, take a snapshot, clone from there), which beats a
// cloud-init seed ISO for the typical workflow. Use `mpd-virt clone`
// against your hand-built `mpd-template-…` instead.
//
// `prlctl` must be on PATH; it ships with Parallels Desktop Pro. If
// missing, every operation throws BackendError.missingExecutable with
// a pointer at why.

#if os(macOS)
import Foundation

extension MpdVirt.Parallels {

    // MARK: - canonical addressing

    /// Parallels Desktop Shared = `10.211.55.0/24` (configurable in
    /// Parallels Preferences → Network → Shared; mpd-virt assumes the
    /// default). VMs land at `10.211.55.<NNN>` after bootstrap step 30.
    static let canonicalSubnet = "10.211.55"

    // MARK: - prlctl probe

    private static let prlctlPath = "/usr/local/bin/prlctl"

    private static func requirePrlctl() throws {
        if !FileManager.default.fileExists(atPath: prlctlPath) {
            throw MpdVirt.BackendError.missingExecutable("""
                \(prlctlPath) (Parallels Desktop Pro CLI). Install Parallels Desktop \
                Pro and ensure `prlctl --version` works.
                """)
        }
    }

    /// Run prlctl with captured output. Throws on non-zero exit.
    @discardableResult
    private static func prl(_ args: [String]) throws -> String {
        try requirePrlctl()
        let r = try MpdVirt.Host.Ssh.runProcess(argv: [prlctlPath] + args)
        guard r.ok else {
            throw MpdVirt.BackendError.other("""
                prlctl \(args.joined(separator: " ")) failed (exit \(r.exitCode)):
                \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                """)
        }
        return r.stdout
    }

    // MARK: - create (intentionally not implemented)

    static func create(octet: Int, opts: MpdVirt.CreateOpts) throws -> MpdVirt.Provisioned {
        throw MpdVirt.BackendError.unsupported(verb: "create", backend: "parallels")
    }

    // MARK: - clone

    static func clone(
        octet: Int,
        template: String,
        opts: MpdVirt.CloneOpts
    ) throws -> MpdVirt.Provisioned {
        try requirePrlctl()
        let target = MpdVirt.vmName(octet: octet)

        // Inventory both running VMs and Parallels templates in one
        // shot — `prlctl set --template on` removes a VM from the
        // regular `list -a` view, so a user who's "templified" their
        // mpd-template-trixie source would trip the source-missing
        // check otherwise.
        let names = try allKnownNames()

        // Refuse to overwrite an existing VM/template with this name.
        if names.contains(target) {
            throw MpdVirt.BackendError.other("""
                Parallels already has a VM or template named '\(target)'. Use \
                `mpd-virt delete \(MpdVirt.vmId(octet: octet))` first, or pick a different octet.
                """)
        }

        // Refuse if the source template doesn't exist (as either a VM
        // or a converted template).
        if !names.contains(template) {
            throw MpdVirt.BackendError.other("""
                Parallels has no VM or template named '\(template)'. Build it first \
                (Debian Trixie + GNOME + Parallels Tools), then re-run this command.
                """)
        }

        // 1. Full clone (linked clones are a future flag).
        FileHandle.standardError.write(Data(
            "  ▶ prlctl clone \(template) → \(target)\n".utf8
        ))
        try prl(["clone", template, "--name", target])

        // 2. Apply size overrides if any.
        if let ramMB = parseSizeMB(opts.vmRam) {
            try prl(["set", target, "--memsize", String(ramMB)])
            FileHandle.standardError.write(Data("  ▶ memsize=\(ramMB)Mb\n".utf8))
        }
        if let diskMB = parseSizeMB(opts.vmDisk) {
            // Resize the primary disk (hdd0). Parallels only supports
            // growing the disk; if the template is already larger, this
            // errors — surface that to the user as a soft warning.
            do {
                try prl(["set", target, "--device-set", "hdd0", "--size", String(diskMB)])
                FileHandle.standardError.write(Data("  ▶ disk=\(diskMB)Mb\n".utf8))
            } catch {
                FileHandle.standardError.write(Data(
                    "  ⚠ disk resize skipped: \(error)\n".utf8
                ))
            }
        }

        // 3. Start and wait for the guest agent to report an IP.
        FileHandle.standardError.write(Data("  ▶ prlctl start \(target)\n".utf8))
        try prl(["start", target])

        FileHandle.standardError.write(Data("  ▶ waiting for Parallels Tools to report a guest IP (up to 4 min) …\n".utf8))
        let ip = try waitForGuestIP(target: target, timeoutSeconds: 240)
        let uuid = try readUUID(target: target)
        FileHandle.standardError.write(Data("  ▶ guest IP \(ip), uuid \(uuid)\n".utf8))

        return MpdVirt.Provisioned(ip: ip, uuid: uuid)
    }

    // MARK: - start / stop / delete

    static func start(octet: Int) throws {
        let target = MpdVirt.vmName(octet: octet)
        try prl(["start", target])
    }

    static func stop(octet: Int, kill: Bool) throws {
        let target = MpdVirt.vmName(octet: octet)
        if kill {
            try prl(["stop", target, "--kill"])
        } else {
            try prl(["suspend", target])
        }
    }

    static func delete(octet: Int) throws {
        let target = MpdVirt.vmName(octet: octet)
        // VM must be stopped before delete; suspended → resume → stop.
        // Easiest is `stop --kill`, idempotent if already stopped.
        _ = try? prl(["stop", target, "--kill"])
        try prl(["delete", target])
    }

    // MARK: - preflight

    /// Refuse to start setup if a Parallels VM already uses the name
    /// `mpd-<NNN>` or the canonical IP `10.211.55.<NNN>`. Both would
    /// blow up partway through provisioning; better to surface it now.
    static func preflight(octet: Int) throws {
        try requirePrlctl()
        let targetName = MpdVirt.vmName(octet: octet)
        let canonicalIP = MpdVirt.Backend.parallels.canonicalIP(octet: octet)

        let vms = try listAllVMs()

        if let conflict = vms.first(where: { $0.name == targetName }) {
            throw MpdVirt.BackendError.other("""
                Parallels already has a VM named '\(targetName)' (UUID \(conflict.uuid)).
                Either use a different octet, or delete it first:
                    prlctl delete \(targetName)
                """)
        }
        if let conflict = vms.first(where: { $0.ip == canonicalIP && $0.name != targetName }) {
            throw MpdVirt.BackendError.other("""
                Parallels VM '\(conflict.name)' (UUID \(conflict.uuid)) is already
                using IP \(canonicalIP). Pick a different octet or relocate that VM.
                """)
        }
    }

    // MARK: - afterCanonicalIPReady

    /// Right after the bootstrap renames the guest hostname to
    /// mpd-<NNN> and pins the canonical IP, set the Parallels VM name
    /// to match. Parallels has a guest-hostname → VM-name auto-sync
    /// feature; doing the rename via prlctl makes the change explicit
    /// + deterministic and avoids racing the auto-sync.
    ///
    /// `hint` is whichever identifier we already have for the VM —
    /// from `clone()`/`create()` it's the UUID. For pure `setup` on
    /// a pre-existing Parallels VM, hint is nil and we look the VM up
    /// by its (now-canonical) IP.
    static func afterCanonicalIPReady(octet: Int, hint: String?, user: String) throws {
        try requirePrlctl()
        let targetName = MpdVirt.vmName(octet: octet)
        let canonicalIP = MpdVirt.Backend.parallels.canonicalIP(octet: octet)

        // Resolve a Parallels handle (UUID preferred, name acceptable)
        // for the VM we just renamed.
        let identifier: String
        if let hint = hint {
            identifier = hint
        } else {
            let vms = try listAllVMs()
            guard let found = vms.first(where: { $0.ip == canonicalIP }) else {
                throw MpdVirt.BackendError.other("""
                    no Parallels VM reports IP \(canonicalIP) — can't rename to '\(targetName)'.
                    Inspect manually: `prlctl list -a -j`.
                    """)
            }
            identifier = found.uuid
        }

        // Idempotency: skip if already named correctly. The JSON
        // returned by `prlctl list -i -j` uses CAPITALIZED keys, so
        // the field is "Name", not "name".
        if let info = try? info(target: identifier),
           let currentName = info["Name"] as? String,
           currentName == targetName {
            return
        }

        // `prlctl set --name` is refused while the VM is running. Try
        // the cheap path first — if Parallels' guest-hostname auto-sync
        // already did the rename, or the VM happens to be off, this
        // succeeds and we're done.
        do {
            try prl(["set", identifier, "--name", targetName])
            return
        } catch let MpdVirt.BackendError.other(msg) where isBusyRunningError(msg) {
            // Fall through to suspend → rename → resume.
        }

        // Deterministic path: graceful stop, rename, start, wait for
        // SSH. Parallels' power verbs (start, resume, pause, suspend,
        // restart, reset, reset-uptime, stop) put us in `stopped`
        // state via plain `stop` — that's what unlocks
        // `prlctl set --name`. `--kill` is the forced equivalent
        // we don't want here (could corrupt the in-flight bootstrap
        // state on the guest disk).
        FileHandle.standardError.write(Data("""
              ▸ Parallels refuses to rename a running VM. Stop → rename → start…
                (≈30–60s for clean stop + boot; bootstrap resumes when SSH is back.)

            """.utf8))
        try prl(["stop", identifier])
        guard waitForState(identifier: identifier, target: "stopped", timeoutSeconds: 120) else {
            throw MpdVirt.BackendError.other("""
                Parallels VM \(identifier) did not reach state=stopped within 120s after \
                `prlctl stop`. Renaming aborted; investigate the VM in Parallels.
                """)
        }
        try prl(["set", identifier, "--name", targetName])
        try prl(["start", identifier])

        // Wait for SSH (not just ICMP) — sshd comes up after the
        // kernel and userspace, so ping-then-ssh would race.
        let sshTarget = MpdVirt.Host.Ssh.Target(user: user, host: canonicalIP)
        if !MpdVirt.Host.Ssh.waitUntilReachable(sshTarget, timeoutSeconds: 120) {
            throw MpdVirt.BackendError.other("""
                Renamed to '\(targetName)' but SSH at \(user)@\(canonicalIP) didn't \
                come up within 120s. Investigate via Parallels Desktop.
                """)
        }
    }

    /// Poll `prlctl status <id>` until it reports the desired state
    /// (`stopped`, `running`, etc.) or the deadline passes. The
    /// status line shape is `VM '<name>' exist <state>`.
    private static func waitForState(identifier: String, target: String, timeoutSeconds: Int) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let out = try? prl(["status", identifier]),
               out.contains(" \(target)") {
                return true
            }
            Thread.sleep(forTimeInterval: 2)
        }
        return false
    }

    /// True iff a prlctl error message indicates the VM is busy or
    /// running and the operation must wait. Substring-matches the
    /// English error text Parallels returns; covers both wordings
    /// observed in the wild.
    private static func isBusyRunningError(_ msg: String) -> Bool {
        msg.contains("virtual machine is busy")
            || msg.contains("virtual machine is currently running")
    }


    // MARK: - diag printRegistry extras

    /// Print Parallels-specific extra fields for diag's Registry
    /// section. Pulls live state from `prlctl list -i`; tolerates a
    /// missing/unreachable VM by printing "—".
    static func printRegistryExtras(entry: MpdVirt.Registry.Entry) {
        let info = try? info(target: entry.name)
        let liveName = (info?["Name"] as? String) ?? "—"
        let liveUUID = (info?["ID"]   as? String) ?? "—"
        let liveState = (info?["State"] as? String) ?? "—"

        // Only print VM name when it's drifted from canonical — else
        // it's just the identifier line again.
        if liveName != entry.name, liveName != "—" {
            print("    VM name:    \(liveName)  ⚠ drifted from \(entry.name)")
        }
        print("    VM UUID:    \(liveUUID)")
        if let registered = entry.uuid, liveUUID != "—", registered != liveUUID {
            print("                ⚠ stored UUID was \(registered)")
        }
        print("    state:      \(liveState)")
    }

    // MARK: - locate

    /// Setup's single discovery entry point for Parallels. Two search
    /// strategies in order:
    ///
    ///   1. **By canonical name** `mpd-<NNN>`. If the dev already
    ///      renamed the Parallels VM (or `afterCanonicalIPReady` ran
    ///      on a previous setup), this finds it. ipHint, if present,
    ///      is cross-checked against the live Parallels-reported IP.
    ///
    ///   2. **By IP** (only when ipHint is provided). Scans the full
    ///      `prlctl list -a -j` for any VM currently sitting at that
    ///      IP. Catches the common adoption case: VM is still named
    ///      `mpd-sandbox-2` (or whatever), bootstrap hasn't run yet,
    ///      but the dev knows the IP.
    ///
    /// Returns nil if Parallels isn't installed or both strategies
    /// fail (Setup converts that into a "pass --ip" error).
    static func locate(octet: Int, ipHint: String?) throws -> (ip: String, uuid: String?)? {
        guard FileManager.default.fileExists(atPath: prlctlPath) else { return nil }

        let targetName = MpdVirt.vmName(octet: octet)

        // 1. By canonical name.
        if let info = try? info(target: targetName),
           let uuid = info["ID"] as? String {
            guard let reportedIP = walkForSharedIP(info) else {
                throw MpdVirt.BackendError.other("""
                    Parallels has a VM named '\(targetName)' but Parallels Tools \
                    aren't reporting an IP yet. Start the VM (or wait for it to \
                    finish booting) and re-run.
                    """)
            }
            if let hint = ipHint, hint != reportedIP {
                FileHandle.standardError.write(Data("""
                      ⚠ Parallels reports '\(targetName)' at \(reportedIP) but --ip=\(hint) was passed.
                        Using --ip; mpd-virt will rename + re-IP through the bootstrap pipeline.

                    """.utf8))
                return (ip: hint, uuid: uuid)
            }
            return (ip: reportedIP, uuid: uuid)
        }

        // 2. By IP (only when caller provided one). Finds VMs that
        //    aren't yet renamed to the canonical form — the common
        //    "adopt my hand-built VM" case. Uses listAllVMs's
        //    detailed-IP path so a sandbox VM with a manually-pinned
        //    static IP still matches.
        if let hint = ipHint {
            let vms = try listAllVMs()
            if let found = vms.first(where: { $0.ip == hint }) {
                FileHandle.standardError.write(Data("""
                      ▸ Parallels VM '\(found.name)' is at \(hint) — adopting it as \(targetName).
                        Bootstrap step 30 renames the guest hostname, then
                        afterCanonicalIPReady renames it in Parallels too.

                    """.utf8))
                return (ip: hint, uuid: found.uuid)
            }
        }

        return nil
    }

    // MARK: - list helpers

    /// All names visible to prlctl — regular VMs (`list -a`) PLUS
    /// templates (`list -t`). Parallels treats templates as a
    /// separate listing; without checking both, a converted template
    /// looks like it doesn't exist.
    static func allKnownNames() throws -> Set<String> {
        let vmNames = try (prl(["list", "-a", "-o", "name", "--no-header"]))
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // `prlctl list -t` may not accept `--no-header`; the first line
        // is a header on some Parallels versions. We strip a leading
        // "NAME" line if present.
        let tplLines = (try? prl(["list", "-t", "-o", "name", "--no-header"]))?
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "NAME" } ?? []
        return Set(vmNames + tplLines)
    }

    struct VMInfo {
        let name: String
        let uuid: String
        let ip: String?
    }

    /// Parse `prlctl list -a -j -i` (all VMs, JSON, full info) into a
    /// flat list of (name, uuid, ip). Single call — the full-info JSON
    /// carries the `Network.ipAddresses` block with the live IPv4
    /// even when the brief `prlctl list` shows `IP_ADDR=-` (static
    /// IPs that Parallels' DHCP agent didn't hand out).
    ///
    /// Returns an empty list when prlctl output isn't parseable; the
    /// caller still gets a useful error from the real prlctl call
    /// that follows.
    static func listAllVMs() throws -> [VMInfo] {
        let out = try prl(["list", "-a", "-j", "-i"])
        guard let data = out.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return array.compactMap { dict in
            // Field names are CAPITALIZED in the -i JSON output ("Name",
            // "ID"), unlike the brief `-a -j` view that uses lowercase.
            guard let name = dict["Name"] as? String,
                  let uuid = dict["ID"] as? String
            else { return nil }
            // Prefer the structured Network.ipAddresses block; fall
            // back to a deep walk for older Parallels versions where
            // the JSON shape might differ.
            let ip = ipv4FromNetwork(dict) ?? walkForSharedIP(dict)
            return VMInfo(name: name, uuid: uuid, ip: ip)
        }
    }

    /// Extract the first Shared-network IPv4 from the structured
    /// `Network.ipAddresses: [{"type":"ipv4","ip":"…"},…]` field that
    /// `prlctl list -i -j` writes. Returns nil if the field isn't
    /// present or no entry matches our subnet.
    static func ipv4FromNetwork(_ dict: [String: Any]) -> String? {
        guard let network = dict["Network"] as? [String: Any],
              let addrs = network["ipAddresses"] as? [[String: Any]]
        else { return nil }
        for entry in addrs {
            if entry["type"] as? String == "ipv4",
               let raw = entry["ip"] as? String,
               let bare = matchSharedIP(in: raw) {
                return bare
            }
        }
        return nil
    }

    // MARK: - describe

    static func describe(octet: Int) throws -> MpdVirt.BackendInfo {
        let target = MpdVirt.vmName(octet: octet)

        // `prlctl status` shape: `VM '<name>' exist <state>`.
        // States we care about: running, stopped, suspended, paused.
        // One prlctl call — `list` enumerates the registry, so this is
        // on the hot path; the full-info `list -i -j` would be ~5×
        // slower and we don't need UUID here.
        let statusLine = (try? prl(["status", target]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if statusLine.isEmpty {
            return MpdVirt.BackendInfo(state: "missing")
        }
        let state: String
        if statusLine.contains(" running") {
            state = "running"
        } else if statusLine.contains(" suspended") {
            state = "suspended"
        } else if statusLine.contains(" stopped") {
            state = "stopped"
        } else if statusLine.contains(" paused") {
            state = "paused"
        } else {
            state = "unknown"
        }
        return MpdVirt.BackendInfo(state: state)
    }

    // MARK: - prlctl info parsing

    /// Run `prlctl list -i <target> -j` and parse the JSON. Returns
    /// nil if prlctl doesn't recognize -j, or if parsing fails. Used
    /// by the IP-waiter and the UUID reader.
    private static func info(target: String) throws -> [String: Any]? {
        let out = try prl(["list", "-i", "-j", target])
        guard let data = out.data(using: .utf8) else { return nil }
        let parsed = try? JSONSerialization.jsonObject(with: data)
        // -j returns a JSON array of one VM dict for `list -i <name>`.
        if let array = parsed as? [[String: Any]], let first = array.first {
            return first
        }
        if let dict = parsed as? [String: Any] {
            return dict
        }
        return nil
    }

    /// Extract the VM's UUID. prlctl shows it as the `ID` field.
    private static func readUUID(target: String) throws -> String {
        if let i = try info(target: target),
           let id = i["ID"] as? String {
            return id
        }
        // Fallback: scrape from `prlctl list -i` plain text.
        let plain = try prl(["list", "-i", target])
        for line in plain.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespaces) == "ID" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        throw MpdVirt.BackendError.other("could not read UUID for \(target)")
    }

    /// Poll `prlctl list -i <target>` until Parallels Tools reports a
    /// guest IP on the Shared network (10.211.55.x). Times out after
    /// `timeoutSeconds`. The clone path needs this because the IP
    /// isn't known until the guest agent in the VM checks in.
    private static func waitForGuestIP(target: String, timeoutSeconds: Int) throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let ip = (try? info(target: target)).flatMap(extractSharedIP) {
                return ip
            }
            Thread.sleep(forTimeInterval: 3)
        }
        throw MpdVirt.BackendError.other("""
            Parallels Tools never reported a guest IP for \(target) within \(timeoutSeconds)s. \
            Verify the template has Parallels Tools installed and the VM has reached the login \
            prompt.
            """)
    }

    /// Walk a prlctl JSON info dict looking for an IPv4 address on the
    /// Parallels Shared network (10.211.55.x). Returns the bare IP
    /// (no CIDR suffix) or nil if absent. The exact path varies by
    /// prlctl version, so this descends loosely.
    static func extractSharedIP(_ info: [String: Any]) -> String? {
        if let hw = info["Hardware"] as? [String: Any] {
            for (_, v) in hw {
                if let adapter = v as? [String: Any],
                   let ip = adapter["ip"] as? String,
                   let match = matchSharedIP(in: ip) {
                    return match
                }
            }
        }
        return walkForSharedIP(info)
    }

    /// Recursively scan for the first Shared-network IPv4 in any
    /// string value. Tolerates CIDR-suffixed values (e.g.
    /// `10.211.55.155/24`) and mixed strings (e.g.
    /// `10.211.55.155 - 2001:db8::1`).
    static func walkForSharedIP(_ value: Any) -> String? {
        if let s = value as? String, let ip = matchSharedIP(in: s) { return ip }
        if let arr = value as? [Any] {
            for item in arr { if let hit = walkForSharedIP(item) { return hit } }
        }
        if let dict = value as? [String: Any] {
            for (_, v) in dict { if let hit = walkForSharedIP(v) { return hit } }
        }
        return nil
    }

    /// Find the first `10.211.55.<num>` occurrence inside an arbitrary
    /// string, ignoring any trailing `/N` CIDR mask or non-IP suffix.
    /// Returns the bare IP (`"10.211.55.155"`), or nil.
    static func matchSharedIP(in s: String) -> String? {
        // Manual scan — avoids NSRegularExpression for one tiny case.
        // We want digits 0..255 in the last octet, but Parallels won't
        // emit out-of-range octets so `[0-9]+` is enough.
        let prefix = "10.211.55."
        var idx = s.startIndex
        while let range = s.range(of: prefix, range: idx..<s.endIndex) {
            // After the prefix, consume the longest run of digits.
            var end = range.upperBound
            while end < s.endIndex, s[end].isASCII, s[end].isNumber {
                end = s.index(after: end)
            }
            if end > range.upperBound {
                return String(s[range.lowerBound..<end])
            }
            idx = range.upperBound
        }
        return nil
    }

    // MARK: - Size parsing

    /// "8G" / "8192M" / "8192" → 8192 (Mb). nil → caller skips the override.
    private static func parseSizeMB(_ s: String?) -> Int? {
        guard let raw = s?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.hasSuffix("g") {
            return Int(lower.dropLast()).map { $0 * 1024 }
        }
        if lower.hasSuffix("m") {
            return Int(lower.dropLast())
        }
        return Int(lower)
    }
}
#endif
