// mpd-virt — MpdVirt.WireGuard namespace
// Curve25519 keypair generation + persistence for WireGuard static keys.
// All keys persist under ~/.mpd-virt/conf/wireguard/.
//
// Powered by swift-crypto: on Apple platforms `Crypto` re-exports CryptoKit.

import Foundation
import Crypto

extension MpdVirt.WireGuard {

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
}
