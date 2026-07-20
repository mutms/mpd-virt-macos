// mpd-virt — ~/.ssh/config managed block per VM.
//
// One block per VM, written between explicit markers so we can find +
// strip it cleanly. Markers include the VM name so a single ssh/config
// can hold blocks for several VMs without aliasing:
//
//   # >>> mpd-<NNN> (managed by mpd-virt) >>>
//   Host mpd-<NNN>
//       …
//   Host mpd-<NNN>-php
//       …
//   # <<< mpd-<NNN> <<<
//
// Block lifecycle:
//   - `setup`     — writes / overwrites the block (idempotent).
//   - `doctor`    — re-asserts (same operation as setup).
//   - `delete`    — strips by marker.
//
// Runtime list is fixed: php / node / util. If mpd ever gains a new
// runtime, the user re-runs setup or doctor; the block is regenerated
// from this static template.

import Foundation

extension MpdVirt.Host.SSHConfig {

    /// Default config path. Exposed for tests / hooks; production code
    /// just uses the default.
    static var path: String { "\(MpdVirt.homeDir)/.ssh/config" }

    /// Render the managed block. Self-contained; everything between the
    /// markers is exactly what gets written or stripped.
    static func render(octet: Int, ip: String, user: String) -> String {
        let name = MpdVirt.vmName(octet: octet)
        let runtimes = ["php", "node", "util"]
        var lines: [String] = []
        lines.append(beginMarker(octet: octet))
        lines.append("Host \(name)")
        lines.append("    HostName \(ip)")
        lines.append("    User \(user)")
        lines.append("    StrictHostKeyChecking no")
        lines.append("    UserKnownHostsFile /dev/null")
        for runtime in runtimes {
            lines.append("")
            lines.append("Host \(name)-\(runtime)")
            // Per-VM zone, so two VMs' blocks name different hosts even
            // though both have a `php` runtime. The alias (`mpd-150-php`)
            // is deliberately NOT itself a resolvable name — it stays a
            // pure ssh_config alias, and the resolvable name appears only
            // as HostName, reached through the ProxyJump.
            lines.append("    HostName \(MpdVirt.Net.runtimeHost(runtime, octet: octet))")
            lines.append("    User \(user)")
            lines.append("    ProxyJump \(name)")
            lines.append("    StrictHostKeyChecking no")
            lines.append("    UserKnownHostsFile /dev/null")
        }
        lines.append(endMarker(octet: octet))
        return lines.joined(separator: "\n")
    }

    /// Write (or overwrite) the block for one VM. Creates ~/.ssh and
    /// ~/.ssh/config if missing.
    static func write(octet: Int, ip: String, user: String) throws {
        try ensureConfigFile()
        let current = try String(contentsOfFile: path, encoding: .utf8)
        let withoutOld = stripBlock(current, octet: octet)
        let block = render(octet: octet, ip: ip, user: user)
        var rebuilt = withoutOld
        if !rebuilt.isEmpty, !rebuilt.hasSuffix("\n") { rebuilt += "\n" }
        if !rebuilt.isEmpty { rebuilt += "\n" }
        rebuilt += block + "\n"
        try rebuilt.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path
        )
    }

    /// Remove the block for one VM. No-op if no block is present.
    static func strip(octet: Int) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let current = try String(contentsOfFile: path, encoding: .utf8)
        let stripped = stripBlock(current, octet: octet)
        if stripped == current { return }
        try stripped.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: path
        )
    }

    /// Return true iff a block for this octet exists in the file.
    static func contains(octet: Int) throws -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let current = try String(contentsOfFile: path, encoding: .utf8)
        return current.contains(beginMarker(octet: octet))
    }

    // MARK: - Markers + stripping

    private static func beginMarker(octet: Int) -> String {
        "# >>> \(MpdVirt.vmName(octet: octet)) (managed by mpd-virt) >>>"
    }

    private static func endMarker(octet: Int) -> String {
        "# <<< \(MpdVirt.vmName(octet: octet)) <<<"
    }

    /// Remove the marked block (and a single surrounding blank line if
    /// present) from a config file's contents.
    private static func stripBlock(_ contents: String, octet: Int) -> String {
        let begin = beginMarker(octet: octet)
        let end = endMarker(octet: octet)
        let lines = contents.components(separatedBy: "\n")
        var out: [String] = []
        var inside = false
        for line in lines {
            if !inside, line.contains(begin) { inside = true; continue }
            if inside {
                if line.contains(end) { inside = false; continue }
                continue
            }
            out.append(line)
        }
        // Collapse consecutive blank lines down to one to keep the file
        // tidy across repeated write/strip cycles.
        var collapsed: [String] = []
        for line in out {
            if line.isEmpty, collapsed.last == "" { continue }
            collapsed.append(line)
        }
        // Drop trailing blank lines.
        while collapsed.last == "" { collapsed.removeLast() }
        return collapsed.joined(separator: "\n")
    }

    // MARK: - Setup

    private static func ensureConfigFile() throws {
        let sshDir = "\(MpdVirt.homeDir)/.ssh"
        try FileManager.default.createDirectory(
            atPath: sshDir, withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: sshDir
        )
        if !FileManager.default.fileExists(atPath: path) {
            try "".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
