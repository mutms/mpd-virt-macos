// mpd-virt — MpdVirt.WireGuard namespace.
//
// Two responsibilities:
//   1. Curve25519 keypair generation + persistence (see `Keypair` below).
//      One Mac-side identity reused across every VM; one per-VM identity
//      generated on first setup and preserved across `delete` so re-setup
//      at the same octet doesn't break the existing WG.app tunnel import.
//   2. Rendering the wg-quick conf files (Confs.render(...)) the VM and
//      WireGuard.app consume.
//
// All material persists under ~/.mpd-virt/conf/wireguard/.
//
// Powered by swift-crypto: on Apple platforms `Crypto` re-exports CryptoKit.

import Foundation
import Crypto

extension MpdVirt.WireGuard {

    // MARK: - Tunnel addressing constants

    /// `10.164.0.1` — Mac peer inside the point-to-point tunnel.
    static let macTunnelIP   = "10.164.0.1"
    /// `10.164.0.2` — VM peer inside the point-to-point tunnel.
    static let vmTunnelIP    = "10.164.0.2"
    /// `10.164.0.0/30` — the tunnel subnet itself (4 addresses, 2 usable).
    static let tunnelSubnet  = "10.164.0.0/30"
    /// `10.163.0.0/24` — the in-VM container subnet routed via the tunnel.
    static let containerSubnet = "10.163.0.0/24"
    /// `10.163.0.3` — in-VM dnsmasq, authoritative for *.mpd.test.
    static let containerDNS  = "10.163.0.3"
    /// UDP port the VM-side wg-quick listens on.
    static let listenPort    = 51820

    /// Curve25519 keypair, base64-encoded for direct use in wg-quick conf files.
    /// WireGuard's static-key format is exactly Curve25519 raw bytes, base64'd.
    struct Keypair {
        let privateKey: String  // base64 of 32 raw bytes
        let publicKey: String   // base64 of 32 raw bytes

        /// Generate a fresh keypair.
        static func generate() -> Keypair {
            let priv = Curve25519.KeyAgreement.PrivateKey()
            return Keypair(
                privateKey: priv.rawRepresentation.base64EncodedString(),
                publicKey: priv.publicKey.rawRepresentation.base64EncodedString()
            )
        }

        /// Load a previously persisted keypair from `<dir>/private` + `<dir>/public`.
        /// Returns nil if either file is missing.
        static func load(from dir: URL) throws -> Keypair? {
            let privURL = dir.appendingPathComponent("private")
            let pubURL = dir.appendingPathComponent("public")
            let fm = FileManager.default
            guard fm.fileExists(atPath: privURL.path),
                  fm.fileExists(atPath: pubURL.path)
            else { return nil }
            let priv = try String(contentsOf: privURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pub = try String(contentsOf: pubURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Keypair(privateKey: priv, publicKey: pub)
        }

        /// Persist to `<dir>/private` (mode 0600) + `<dir>/public` (mode 0644).
        /// Creates `<dir>` if missing.
        func save(to dir: URL) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let privURL = dir.appendingPathComponent("private")
            let pubURL = dir.appendingPathComponent("public")
            try privateKey.write(to: privURL, atomically: true, encoding: .utf8)
            try publicKey.write(to: pubURL, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privURL.path)
            try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pubURL.path)
        }

        /// Load existing keypair from `<dir>`, generating + persisting one if absent.
        /// The file on disk is the source of truth — repeat calls return the same keys.
        static func loadOrGenerate(at dir: URL) throws -> Keypair {
            if let existing = try load(from: dir) {
                return existing
            }
            let fresh = generate()
            try fresh.save(to: dir)
            return fresh
        }
    }

    // MARK: - Identity helpers

    /// Mac-side keypair, shared across every VM. Generated on first
    /// `setup`, reused thereafter. Persisted at
    /// `~/.mpd-virt/conf/wireguard/mac.{private,public}`.
    /// (The file names sit directly under `wireguard/` rather than a
    /// subdirectory because there's only one Mac peer per Mac.)
    static func macKeypair() throws -> Keypair {
        let dir = URL(fileURLWithPath: MpdVirt.wireGuardDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Special-case "mac" because it's not under a per-VM dir.
        let privURL = dir.appendingPathComponent("mac.private")
        let pubURL = dir.appendingPathComponent("mac.public")
        let fm = FileManager.default
        if fm.fileExists(atPath: privURL.path), fm.fileExists(atPath: pubURL.path) {
            let priv = try String(contentsOf: privURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pub = try String(contentsOf: pubURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Keypair(privateKey: priv, publicKey: pub)
        }
        let fresh = Keypair.generate()
        try fresh.privateKey.write(to: privURL, atomically: true, encoding: .utf8)
        try fresh.publicKey.write(to: pubURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privURL.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pubURL.path)
        return fresh
    }

    /// VM-side keypair — **shared across every VM on this Mac**.
    /// Persisted at `~/.mpd-virt/conf/wireguard/vm.{private,public}`.
    ///
    /// Rationale: every mpd VM is a development environment owned by
    /// the same developer on the same Mac. VM-to-VM isolation isn't a
    /// real threat boundary (compromise of any one ≈ compromise of the
    /// dev box). Sharing the keypair removes per-VM identity material
    /// without weakening anything that matters, and means the
    /// Mac-side client.conf differs across VMs in only the Endpoint
    /// line. Plus WireGuard.app exposes only one active tunnel at a
    /// time, so there's never ambiguity about which VM is "live".
    static func vmKeypair() throws -> Keypair {
        let dir = URL(fileURLWithPath: MpdVirt.wireGuardDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default
        let privURL = dir.appendingPathComponent("vm.private")
        let pubURL = dir.appendingPathComponent("vm.public")
        if fm.fileExists(atPath: privURL.path), fm.fileExists(atPath: pubURL.path) {
            let priv = try String(contentsOf: privURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pub = try String(contentsOf: pubURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Keypair(privateKey: priv, publicKey: pub)
        }
        let fresh = Keypair.generate()
        try fresh.privateKey.write(to: privURL, atomically: true, encoding: .utf8)
        try fresh.publicKey.write(to: pubURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privURL.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: pubURL.path)
        return fresh
    }

    // MARK: - wg-quick conf rendering

    enum Confs {

        /// VM-side `mpd0.conf` (`/etc/wireguard/mpd0.conf` after
        /// 60-wireguard.sh installs it). Identical for every VM —
        /// same shared identity, same tunnel addressing.
        ///
        /// No `#` comments in the body: `wireguard-apple` (the
        /// implementation behind WG.app on the Mac App Store) doesn't
        /// accept them, and we keep server/client renderings in lock-
        /// step so the same code shape works for both.
        static func server() throws -> String {
            let vmKey = try vmKeypair()
            let macKey = try macKeypair()
            return """
                [Interface]
                PrivateKey = \(vmKey.privateKey)
                Address    = \(vmTunnelIP)/30
                ListenPort = \(listenPort)

                [Peer]
                PublicKey  = \(macKey.publicKey)
                AllowedIPs = \(macTunnelIP)/32
                """
        }

        /// Mac-side `client.conf` imported into WireGuard.app as
        /// `mpd-<NNN>`. Only `Endpoint` differs across VMs. The Mac
        /// routes `10.164.0.0/30` (tunnel) and `10.163.0.0/24`
        /// (container subnet) through the tunnel.
        ///
        /// **No `DNS = ...` line.** wireguard-apple stores anything in
        /// the DNS field as a global tunnel resolver — it doesn't do
        /// split-DNS via `NEDNSSettings.matchDomains`. Setting it would
        /// route *every* DNS query on the Mac through the in-VM
        /// dnsmasq while the tunnel is up, which is (a) wrong (mpd's
        /// dnsmasq is authoritative for `*.mpd.test` only — NXDOMAIN
        /// for everything else) and (b) a trust problem (the VM is
        /// untrusted). Scoped DNS for `*.mpd.test` is handled on the
        /// Mac side via `/etc/resolver/mpd.test`; the tunnel only
        /// provides routing to 10.163.0.0/24.
        ///
        /// Also no `#` comments — `wireguard-apple` rejects them.
        static func client(octet: Int, vmEndpoint: String) throws -> String {
            let macKey = try macKeypair()
            let vmKey = try vmKeypair()
            return """
                [Interface]
                PrivateKey = \(macKey.privateKey)
                Address    = \(macTunnelIP)/30

                [Peer]
                PublicKey           = \(vmKey.publicKey)
                Endpoint            = \(vmEndpoint):\(listenPort)
                AllowedIPs          = \(tunnelSubnet), \(containerSubnet)
                PersistentKeepalive = 25
                """
        }

        /// Persist both conf files. server.conf is shared across all
        /// VMs under `~/.mpd-virt/conf/wireguard/server.conf`;
        /// client.conf is per-VM at `~/.mpd-virt/<NNN>/wireguard.conf`
        /// (differs in Endpoint only). Atomic per file. Returns both
        /// paths so the caller knows what to push to the VM.
        @discardableResult
        static func renderAndSave(octet: Int, vmEndpoint: String) throws
            -> (serverConfPath: String, clientConfPath: String)
        {
            try FileManager.default.createDirectory(
                atPath: MpdVirt.wireGuardDir, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                atPath: MpdVirt.vmDir(octet: octet), withIntermediateDirectories: true
            )
            let serverPath = MpdVirt.wgServerConfFile
            let clientPath = MpdVirt.vmWireGuardConfFile(octet: octet)
            try server()
                .write(toFile: serverPath, atomically: true, encoding: .utf8)
            try client(octet: octet, vmEndpoint: vmEndpoint)
                .write(toFile: clientPath, atomically: true, encoding: .utf8)
            // Both contain a private key — tighten perms.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: serverPath
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: clientPath
            )
            return (serverPath, clientPath)
        }
    }
}
