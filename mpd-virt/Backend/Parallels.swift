// mpd-virt — Parallels backend (macOS only).
//
// Wraps `prlctl` (Parallels Desktop Pro CLI) for VM lifecycle. Initial
// scope: `clone` from a `mpd-template-<suffix>` template + start /
// stop / delete / describe. `create` (fresh VM from scratch) is a
// follow-up — Parallels doesn't have a natural headless build-from-
// scratch path; cloning a template is the canonical way to materialize
// a VM here.
//
// `prlctl` must be on PATH; it ships with Parallels Desktop Pro. If
// missing, every operation throws BackendError.missingExecutable with
// a pointer at why.

#if os(macOS)
import Foundation

extension MpdVirt.Parallels {

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

    // MARK: - create (not implemented yet)

    static func create(octet: Int, opts: MpdVirt.CreateOpts) throws -> MpdVirt.Provisioned {
        throw MpdVirt.BackendError.notImplemented(verb: "create", backend: "parallels")
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
        let canonicalIP = "10.211.55.\(octet)"

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
    static func afterCanonicalIPReady(octet: Int, hint: String?) throws {
        try requirePrlctl()
        let targetName = MpdVirt.vmName(octet: octet)
        let canonicalIP = "10.211.55.\(octet)"

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

        // Idempotency: skip if already named correctly.
        if let info = try? info(target: identifier),
           let currentName = info["name"] as? String,
           currentName == targetName {
            return
        }
        try prl(["set", identifier, "--name", targetName])
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

    /// Setup's single discovery entry point for Parallels. Looks up
    /// the VM named `mpd-<NNN>`; cross-checks `ipHint` when present.
    ///
    /// Returns nil if Parallels isn't installed or no matching VM
    /// exists (Setup converts that into a "pass --ip" error).
    static func locate(octet: Int, ipHint: String?) throws -> (ip: String, uuid: String?)? {
        // Parallels not installed → can't locate. Returning nil lets
        // setup fall through to its helpful error.
        guard FileManager.default.fileExists(atPath: prlctlPath) else { return nil }

        let targetName = MpdVirt.vmName(octet: octet)
        guard let info = try? info(target: targetName),
              let uuid = info["ID"] as? String
        else { return nil }

        guard let reportedIP = walkForSharedIP(info) else {
            throw MpdVirt.BackendError.other("""
                Parallels has a VM named '\(targetName)' but Parallels Tools \
                aren't reporting an IP yet. Start the VM (or wait for it to \
                finish booting) and re-run.
                """)
        }

        // Cross-check with --ip when both are available. Mismatch is
        // a soft warning; we go with --ip since the caller was explicit.
        if let hint = ipHint, hint != reportedIP {
            FileHandle.standardError.write(Data("""
                  ⚠ Parallels reports '\(targetName)' at \(reportedIP) but --ip=\(hint) was passed.
                    Using --ip; mpd-virt will rename + re-IP through the bootstrap pipeline.

                """.utf8))
            return (ip: hint, uuid: uuid)
        }
        return (ip: reportedIP, uuid: uuid)
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

    /// Parse `prlctl list -a -j` into a flat list of (name, uuid, ip).
    /// Used by preflight + afterCanonicalIPReady. Returns an empty
    /// list when prlctl output isn't parseable so callers don't get
    /// stuck on a bad parse — they'll just miss the conflict check,
    /// which is acceptable for now (a real collision later still
    /// surfaces a useful prlctl error).
    static func listAllVMs() throws -> [VMInfo] {
        let out = try prl(["list", "-a", "-j"])
        guard let data = out.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return array.compactMap { dict in
            guard let name = dict["name"] as? String,
                  let uuid = dict["uuid"] as? String
            else { return nil }
            let ip = walkForSharedIP(dict)
            return VMInfo(name: name, uuid: uuid, ip: ip)
        }
    }

    // MARK: - describe

    static func describe(octet: Int) throws -> MpdVirt.BackendInfo {
        let target = MpdVirt.vmName(octet: octet)

        // `prlctl status` shape: `VM '<name>' exist <state>`.
        // States we care about: running, stopped, suspended, paused.
        let statusLine = (try? prl(["status", target]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state: String
        if statusLine.isEmpty {
            return MpdVirt.BackendInfo(state: "missing", uuid: nil)
        } else if statusLine.contains(" running") {
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

        let uuid = (try? readUUID(target: target))
        return MpdVirt.BackendInfo(state: state, uuid: uuid)
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
