// mpd-virt — Registry: the set of `~/.mpd-virt/<NNN>/env` files.
//
// The registry is the **source of truth** for which VMs mpd-virt knows
// about. Every verb that operates on a specific NNN either reads from
// or writes to the corresponding env file under
// `~/.mpd-virt/<NNN>/env`. Setup uses absence-of-file vs presence to
// decide "fix-known mode" vs "first-time adoption".
//
// File format: shell-style `KEY=VALUE` lines, one per key. Tolerant of
// leading/trailing whitespace and `#` comments. No quoting subtleties —
// all values are simple identifiers, IPs, sizes, or UUIDs.

import Foundation

extension MpdVirt.Registry {

    /// In-memory representation of one `<NNN>/env` file. Optional
    /// fields are nil when the backend doesn't supply them (UUID is
    /// nil for `general`; disk/ram are nil if the VM wasn't created
    /// or cloned through mpd-virt).
    struct Entry {
        let octet: Int
        let name: String           // canonical "mpd-<NNN>"
        let backend: MpdVirt.Backend
        let ip: String
        let user: String
        let uuid: String?
        let disk: String?
        let ram: String?
    }

    // MARK: - List

    /// Enumerate known octets by scanning `~/.mpd-virt/` for directories
    /// named NNN (3-digit) that contain an `env` file. Returned sorted
    /// ascending. Missing root dir → empty list.
    static func knownOctets() throws -> [Int] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: MpdVirt.rootDir) else { return [] }
        let children = try fm.contentsOfDirectory(atPath: MpdVirt.rootDir)
        var octets: [Int] = []
        for child in children {
            // 3-digit directory name, env file inside.
            guard child.count == 3, let octet = Int(child),
                  (100...254).contains(octet) || octet == 0
            else { continue }
            let envPath = "\(MpdVirt.rootDir)/\(child)/env"
            if fm.fileExists(atPath: envPath) {
                octets.append(octet)
            }
        }
        return octets.sorted()
    }

    /// Load all known entries. Skips (and logs to stderr) any env file
    /// that fails to parse, rather than aborting the whole listing.
    static func loadAll() throws -> [Entry] {
        try knownOctets().compactMap { octet in
            do {
                return try load(octet: octet)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: skipping \(MpdVirt.vmId(octet: octet)) — \(error)\n".utf8
                ))
                return nil
            }
        }
    }

    // MARK: - Read

    /// Load `<NNN>/env`. Throws if the file is missing or malformed.
    static func load(octet: Int) throws -> Entry {
        let path = MpdVirt.vmEnvFile(octet: octet)
        guard FileManager.default.fileExists(atPath: path) else {
            throw RegistryError.notKnown(octet: octet)
        }
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        var kv: [String: String] = [:]
        for line in raw.split(whereSeparator: { $0 == "\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            kv[key] = value
        }

        func required(_ key: String) throws -> String {
            guard let v = kv[key], !v.isEmpty else {
                throw RegistryError.malformed(octet: octet, missingKey: key)
            }
            return v
        }

        let backendRaw = try required("MPD_VM_BACKEND")
        let backend = try MpdVirt.Backend.parse(backendRaw)

        return Entry(
            octet: octet,
            name: try required("MPD_VM_NAME"),
            backend: backend,
            ip: try required("MPD_VM_IP"),
            user: try required("MPD_VM_USER"),
            uuid: kv["MPD_VM_UUID"],
            disk: kv["MPD_VM_DISK"],
            ram: kv["MPD_VM_RAM"]
        )
    }

    /// Returns true iff `<NNN>/env` exists (no parsing).
    static func exists(octet: Int) -> Bool {
        FileManager.default.fileExists(atPath: MpdVirt.vmEnvFile(octet: octet))
    }

    // MARK: - Write

    /// Persist (or overwrite) the env file for an octet. Creates the
    /// `<NNN>/` directory as needed. Atomic via Foundation's write-to-temp
    /// behavior.
    static func save(_ entry: Entry) throws {
        let dir = MpdVirt.vmDir(octet: entry.octet)
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        var body = """
            # mpd-virt registry entry for \(entry.name).
            # Source of truth for `mpd-virt setup`. Edit at your own risk.
            MPD_VM_OCTET=\(MpdVirt.vmId(octet: entry.octet))
            MPD_VM_NAME=\(entry.name)
            MPD_VM_BACKEND=\(entry.backend.rawValue)
            MPD_VM_IP=\(entry.ip)
            MPD_VM_USER=\(entry.user)
            """
        if let uuid = entry.uuid { body += "\nMPD_VM_UUID=\(uuid)" }
        if let disk = entry.disk { body += "\nMPD_VM_DISK=\(disk)" }
        if let ram  = entry.ram  { body += "\nMPD_VM_RAM=\(ram)" }
        body += "\n"
        try body.write(
            toFile: MpdVirt.vmEnvFile(octet: entry.octet),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Remove `<NNN>/` entirely. Does **not** touch
    /// `~/.mpd-virt/conf/wireguard/<NNN>/` — that survives delete so
    /// re-setup at the same octet reuses the same WG keypair.
    static func remove(octet: Int) throws {
        let dir = MpdVirt.vmDir(octet: octet)
        guard FileManager.default.fileExists(atPath: dir) else { return }
        try FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Errors

    enum RegistryError: Error, CustomStringConvertible {
        case notKnown(octet: Int)
        case malformed(octet: Int, missingKey: String)

        var description: String {
            switch self {
            case .notKnown(let octet):
                return "no registry entry for \(MpdVirt.vmId(octet: octet)) — \(MpdVirt.vmEnvFile(octet: octet)) does not exist."
            case .malformed(let octet, let key):
                return "registry entry for \(MpdVirt.vmId(octet: octet)) is missing required key '\(key)'."
            }
        }
    }
}
