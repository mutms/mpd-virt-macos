// mpd-virt — Backend kind + capability declarations + dispatch.
//
// `MpdVirt.Backend` is a raw-value enum used three ways:
//   1. as the **kind tag** stored in each registry env file
//      (MPD_VM_BACKEND=parallels|utm|general),
//   2. as the **capability source** (which verbs each backend supports),
//   3. as the **dispatcher** that forwards verb calls to per-backend
//      implementations in MpdVirt.Parallels / .UTM / .General.
//
// Unsupported operations throw `BackendError.unsupported`. Not-yet-built
// operations (step 1 scaffold) throw `BackendError.notImplemented`.

import Foundation

extension MpdVirt {

    enum Backend: String, CaseIterable {
        case parallels
        case utm
        case general

        // MARK: - Discovery

        /// All backends compiled into this binary. Parallels and UTM
        /// require `#if os(macOS)` — once Linux/Windows ports exist,
        /// `compiledIn` will drop them on those targets.
        static var compiledIn: [Backend] {
            #if os(macOS)
            return [.parallels, .utm, .general]
            #else
            return [.general]
            #endif
        }

        /// Parse a backend name (case-insensitive), rejecting names that
        /// are not compiled into this binary.
        static func parse(_ raw: String) throws -> Backend {
            guard let kind = Backend(rawValue: raw.lowercased()) else {
                throw BackendError.unknown(name: raw)
            }
            guard compiledIn.contains(kind) else {
                throw BackendError.notCompiledIn(backend: kind.rawValue)
            }
            return kind
        }

        // MARK: - Capabilities

        struct Capabilities {
            /// `mpd-virt create <NNN>` — materialize a fresh VM from
            /// scratch (cloud-init / wizard / blank disk).
            let create: Bool
            /// `mpd-virt clone <NNN> --template=…` — duplicate an
            /// existing template/VM.
            let clone: Bool
            /// `mpd-virt start|stop|delete` operating on the VM itself
            /// (not just bookkeeping). Implied false for `general`.
            let lifecycle: Bool
        }

        var capabilities: Capabilities {
            switch self {
            case .parallels:
                // Initial scope: clone via `prlctl clone`. `create` lands
                // in a follow-up (Parallels has no first-class headless
                // "build from scratch" path; cloning a template is the
                // canonical way).
                return Capabilities(create: false, clone: true, lifecycle: true)
            case .utm:
                // Initial scope: create via UTM's cloud-init seed-ISO
                // flow. `clone` lands in a follow-up.
                return Capabilities(create: true, clone: false, lifecycle: true)
            case .general:
                // No hypervisor to drive. Only `setup` (and the
                // bookkeeping-only paths of `delete`/`list`/`show`/
                // `doctor`) talk to a general-backend VM.
                return Capabilities(create: false, clone: false, lifecycle: false)
            }
        }

        // MARK: - Dispatch

        // Per-verb dispatchers. Each one switches on `self` and forwards
        // to the matching per-backend namespace. Capability checks happen
        // here so the per-backend code can assume it's been called for a
        // verb it actually supports.

        func create(octet: Int, opts: CreateOpts) throws -> Provisioned {
            guard capabilities.create else {
                throw BackendError.unsupported(verb: "create", backend: rawValue)
            }
            switch self {
            case .parallels: return try MpdVirt.Parallels.create(octet: octet, opts: opts)
            case .utm:       return try MpdVirt.UTM.create(octet: octet, opts: opts)
            case .general:   throw BackendError.unsupported(verb: "create", backend: rawValue)
            }
        }

        func clone(octet: Int, template: String, opts: CloneOpts) throws -> Provisioned {
            guard capabilities.clone else {
                throw BackendError.unsupported(verb: "clone", backend: rawValue)
            }
            switch self {
            case .parallels: return try MpdVirt.Parallels.clone(octet: octet, template: template, opts: opts)
            case .utm:       return try MpdVirt.UTM.clone(octet: octet, template: template, opts: opts)
            case .general:   throw BackendError.unsupported(verb: "clone", backend: rawValue)
            }
        }

        func start(octet: Int) throws {
            guard capabilities.lifecycle else {
                throw BackendError.unsupported(verb: "start", backend: rawValue)
            }
            switch self {
            case .parallels: try MpdVirt.Parallels.start(octet: octet)
            case .utm:       try MpdVirt.UTM.start(octet: octet)
            case .general:   throw BackendError.unsupported(verb: "start", backend: rawValue)
            }
        }

        func stop(octet: Int, kill: Bool) throws {
            guard capabilities.lifecycle else {
                throw BackendError.unsupported(verb: "stop", backend: rawValue)
            }
            switch self {
            case .parallels: try MpdVirt.Parallels.stop(octet: octet, kill: kill)
            case .utm:       try MpdVirt.UTM.stop(octet: octet, kill: kill)
            case .general:   throw BackendError.unsupported(verb: "stop", backend: rawValue)
            }
        }

        /// Destroy the VM in the hypervisor. Skipped entirely on
        /// `general` and when `delete --keep-vm` is set (the verb layer
        /// is responsible for honoring `--keep-vm`).
        func delete(octet: Int) throws {
            guard capabilities.lifecycle else {
                throw BackendError.unsupported(verb: "delete", backend: rawValue)
            }
            switch self {
            case .parallels: try MpdVirt.Parallels.delete(octet: octet)
            case .utm:       try MpdVirt.UTM.delete(octet: octet)
            case .general:   throw BackendError.unsupported(verb: "delete", backend: rawValue)
            }
        }

        /// Live VM state — for `show` and `list`. Best-effort: callers
        /// should swallow errors and render `state=unknown` when the
        /// hypervisor isn't reachable.
        func describe(octet: Int) throws -> BackendInfo {
            switch self {
            case .parallels: return try MpdVirt.Parallels.describe(octet: octet)
            case .utm:       return try MpdVirt.UTM.describe(octet: octet)
            case .general:   return try MpdVirt.General.describe(octet: octet)
            }
        }

        /// Print the diag "Registry" block — common header (identifier,
        /// backend, IP, username) plus whatever backend-specific extras
        /// make sense (parallels adds VM name + UUID + live status;
        /// general has nothing to add).
        func printRegistry(entry: Registry.Entry) {
            print("    identifier: \(entry.name)")
            print("    backend:    \(rawValue)")
            print("    IP:         \(entry.ip)")
            print("    username:   \(entry.user)")
            switch self {
            case .parallels: MpdVirt.Parallels.printRegistryExtras(entry: entry)
            case .utm:       MpdVirt.UTM.printRegistryExtras(entry: entry)
            case .general:   break
            }
        }

        /// Pre-flight check before Setup does any work. Backends that
        /// track their own state (Parallels, UTM) refuse if there's a
        /// name or IP collision with an existing hypervisor VM. The
        /// `general` backend has no hypervisor — always returns clean.
        func preflight(octet: Int) throws {
            switch self {
            case .parallels: try MpdVirt.Parallels.preflight(octet: octet)
            case .utm:       try MpdVirt.UTM.preflight(octet: octet)
            case .general:   break
            }
        }

        /// Fires from inside Bootstrap's `onCanonicalIPReady` callback,
        /// right after the registry entry is written. Used by Parallels
        /// to `prlctl set --name mpd-<NNN>` so the Parallels GUI label
        /// matches the new guest hostname deterministically (Parallels
        /// has an auto-sync between guest-hostname and VM-name that
        /// would otherwise race with our bootstrap).
        ///
        /// `hint` is an optional Parallels/UTM identifier (UUID or
        /// current name) for the just-cloned/created VM. Setup passes
        /// it through from create/clone's Provisioned. Backends that
        /// don't have it can fall back to finding the VM by IP.
        func afterCanonicalIPReady(octet: Int, hint: String?) throws {
            switch self {
            case .parallels: try MpdVirt.Parallels.afterCanonicalIPReady(octet: octet, hint: hint)
            case .utm:       try MpdVirt.UTM.afterCanonicalIPReady(octet: octet, hint: hint)
            case .general:   break
            }
        }

        /// Single entry point Setup uses to resolve "what do you know
        /// about VM <NNN>?". Each backend does whatever makes sense:
        ///
        ///   - `parallels`: query `prlctl list -i mpd-<NNN>`. Cross-
        ///     references with `ipHint` when provided. Returns the
        ///     hypervisor-reported IP + UUID.
        ///   - `utm`: same shape (stub for now).
        ///   - `general`: just trusts `ipHint`. No hypervisor to ask;
        ///     reachability is verified later by the SSH probe.
        ///
        /// Returns nil when the backend can't locate the VM (e.g.
        /// general without --ip, or parallels with no matching VM).
        /// Setup turns nil into a helpful "pass --ip" error.
        func locate(octet: Int, ipHint: String?) throws -> (ip: String, uuid: String?)? {
            switch self {
            case .parallels: return try MpdVirt.Parallels.locate(octet: octet, ipHint: ipHint)
            case .utm:       return try MpdVirt.UTM.locate(octet: octet, ipHint: ipHint)
            case .general:
                if let ip = ipHint { return (ip: ip, uuid: nil) }
                return nil
            }
        }
    }

    // MARK: - Inputs / outputs shared by every backend

    struct CreateOpts {
        let username: String
        let vmDisk: String?     // e.g. "80G"; nil → backend default
        let vmRam: String?      // e.g. "8G";  nil → backend default
    }

    struct CloneOpts {
        let username: String
        let vmDisk: String?     // optional override on the cloned VM
        let vmRam: String?
    }

    struct Provisioned {
        let ip: String          // reachable IP for SSH from the Mac
        let uuid: String?       // hypervisor-assigned UUID (nil for general)
    }

    struct BackendInfo {
        /// Power state in the hypervisor: "running", "stopped",
        /// "suspended", "missing", "unknown".
        let state: String
        /// Last known UUID, used for drift detection in `doctor`.
        let uuid: String?
    }

    // MARK: - Errors

    enum BackendError: Error, CustomStringConvertible {
        case unsupported(verb: String, backend: String)
        case notImplemented(verb: String, backend: String)
        case notCompiledIn(backend: String)
        case unknown(name: String)
        case missingExecutable(String)
        case other(String)

        var description: String {
            switch self {
            case .unsupported(let verb, let backend):
                return "backend=\(backend): verb '\(verb)' is not supported by this backend."
            case .notImplemented(let verb, let backend):
                return "backend=\(backend): verb '\(verb)' is not yet implemented."
            case .notCompiledIn(let backend):
                return "backend=\(backend) is not compiled into this binary."
            case .unknown(let name):
                return "unknown backend '\(name)'. Try one of: \(Backend.compiledIn.map(\.rawValue).joined(separator: ", "))."
            case .missingExecutable(let path):
                return "required executable not found on PATH: \(path)"
            case .other(let msg):
                return msg
            }
        }
    }

    // MARK: - Default-backend file

    /// Read `~/.mpd-virt/conf/backend.env`. Returns nil if the file is
    /// absent or its single key is missing. Never throws for "absent";
    /// throws only on filesystem errors.
    static func readDefaultBackend() throws -> Backend? {
        let path = backendConfFile
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        for line in raw.split(whereSeparator: { $0 == "\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "MPD_VIRT_DEFAULT_BACKEND"
            else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return try Backend.parse(value)
        }
        return nil
    }

    /// Write `~/.mpd-virt/conf/backend.env`. Creates `conf/` if missing.
    static func writeDefaultBackend(_ kind: Backend) throws {
        let confURL = URL(fileURLWithPath: confDir)
        try FileManager.default.createDirectory(at: confURL, withIntermediateDirectories: true)
        let body = "MPD_VIRT_DEFAULT_BACKEND=\(kind.rawValue)\n"
        try body.write(toFile: backendConfFile, atomically: true, encoding: .utf8)
    }

    /// Resolve which backend to use for a verb invocation:
    ///   1. `--backend=` flag wins,
    ///   2. else stored default from backend.env,
    ///   3. else throws — the verb layer translates to a helpful message.
    static func resolveBackend(flag: String?) throws -> Backend {
        if let raw = flag {
            return try Backend.parse(raw)
        }
        if let stored = try readDefaultBackend() {
            return stored
        }
        throw BackendError.other("""
            no backend selected: pass --backend=<name> or set a default with \
            `mpd-virt backend set-default <name>`. Compiled-in backends: \
            \(Backend.compiledIn.map(\.rawValue).joined(separator: ", ")).
            """)
    }
}
