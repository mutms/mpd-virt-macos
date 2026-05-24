// mpd-virt — Local root CA for *.mpd.test.
//
// One CA per Mac, generated on first `mpd-virt setup`, persisted under
// ~/.mpd-virt/conf/caroot/. **Name-constrained** to the `mpd.test` DNS
// tree so even if the trust store entry is ever abused it can only sign
// certs for *.mpd.test — never google.com, never anything outside the
// dev tree. This is the property that lets us put the CA in the macOS
// System Keychain without it being a real security risk.
//
// Implementation shells out to `/usr/bin/openssl` (LibreSSL on macOS).
// Reasons:
//   - Apple ships it. Zero install footprint.
//   - X.509 name-constraints + custom extensions are a one-liner in
//     openssl-conf. Reimplementing ASN.1 encoding in pure Swift is
//     possible but a lot of code for no real benefit.
//   - The cert never gets validated by openssl — it just needs to be
//     a well-formed X.509 the Security framework + the in-VM trust
//     stores accept. LibreSSL produces that.
//
// File layout under `caRootDir`:
//   rootCA.pem      — public cert. Pushed to VMs, trusted in System Keychain.
//   rootCA-key.pem  — private key. NEVER leaves the Mac.

import Foundation

extension MpdVirt.CA {

    /// Friendly subject name. Used as the cert's CN and as the lookup
    /// key for `security delete-certificate -c "..."` in uninstall.
    static let commonName = "mpd Root CA"

    /// Subject DN. OpenSSL formats it lazily from these components.
    private static let subject = "/CN=\(commonName)/OU=mpd-virt/O=mpd local development"

    /// Validity. 365 days — capped because macOS's trust evaluator
    /// rejects user-installed roots with long validity windows (Apple
    /// has progressively tightened cert-lifetime policy; even when the
    /// root itself isn't formally capped, longer windows trip warnings
    /// or outright rejection in Safari / `security verify-cert`). The
    /// practical implication is **annual rotation**: re-run
    /// `mpd-virt setup` (or, once implemented, `mpd-virt refresh-trust`)
    /// every ~11 months to regenerate + redistribute the CA.
    ///
    /// `mpd-virt doctor` will eventually warn when the on-disk CA is
    /// within 30 days of expiry so the rotation isn't a surprise.
    private static let validityDays = 365

    /// Path to the persisted public cert (PEM).
    static var certPath: String { "\(MpdVirt.caRootDir)/rootCA.pem" }

    /// Path to the persisted private key (PEM). Mode 0600.
    static var keyPath: String { "\(MpdVirt.caRootDir)/rootCA-key.pem" }

    /// Are both files present?
    static var exists: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: certPath) && fm.fileExists(atPath: keyPath)
    }

    /// Return the on-disk CA, generating + persisting one if absent.
    /// Idempotent: repeat calls return the same files.
    static func loadOrGenerate() throws {
        if exists { return }
        try generate()
    }

    /// Force-generate a new CA. Overwrites any existing files. Used by
    /// `setup` only via loadOrGenerate; exposed mainly for future
    /// `refresh-trust`.
    static func generate() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: MpdVirt.caRootDir, withIntermediateDirectories: true
        )

        // openssl-conf with NameConstraints. `permitted;DNS:mpd.test`
        // covers both `mpd.test` itself and all `*.mpd.test` subdomains.
        let confBody = """
            [ req ]
            distinguished_name = req_dn
            x509_extensions    = v3_ca
            prompt             = no

            [ req_dn ]
            CN = \(commonName)
            OU = mpd-virt
            O  = mpd local development

            [ v3_ca ]
            subjectKeyIdentifier   = hash
            authorityKeyIdentifier = keyid:always
            basicConstraints       = critical, CA:TRUE
            keyUsage               = critical, keyCertSign, cRLSign
            nameConstraints        = critical, permitted;DNS:mpd.test
            """

        // Write the openssl conf to a temp file so we don't leave it
        // lying around alongside the CA material.
        let confURL = try writeTempFile(named: "mpd-virt-ca.cnf", body: confBody)
        defer { try? fm.removeItem(at: confURL) }

        // openssl req invocation. -newkey rsa:4096 generates the
        // keypair in the same call as the self-sign, eliminating an
        // intermediate keyfile-on-disk step.
        let argv: [String] = [
            "/usr/bin/openssl", "req",
            "-x509",
            "-newkey", "rsa:4096",
            "-sha256",
            "-days", String(validityDays),
            "-nodes",                       // unencrypted private key
            "-keyout", keyPath,
            "-out",    certPath,
            "-subj",   subject,
            "-extensions", "v3_ca",
            "-config", confURL.path,
        ]

        let r = try MpdVirt.Host.Ssh.runProcess(argv: argv)
        guard r.ok else {
            // Clean up partial files so a retry starts clean.
            try? fm.removeItem(atPath: certPath)
            try? fm.removeItem(atPath: keyPath)
            throw MpdVirt.BackendError.other("""
                CA generation failed (openssl exit \(r.exitCode)):
                \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                """)
        }

        // Tighten permissions on the private key.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certPath)
    }

    // MARK: - Expiry

    /// Days remaining until the on-disk CA expires. Negative if already
    /// expired. Throws if the cert is missing or unreadable by openssl.
    /// Used by `doctor` to warn at the 30-day threshold (the macOS
    /// 1-year-cap discussion in CA.swift's validityDays comment).
    static func daysUntilExpiry() throws -> Int {
        guard FileManager.default.fileExists(atPath: certPath) else {
            throw MpdVirt.BackendError.other("CA missing: \(certPath)")
        }
        let r = try MpdVirt.Host.Ssh.runProcess(argv: [
            "/usr/bin/openssl", "x509", "-in", certPath, "-noout", "-enddate",
        ])
        guard r.ok else {
            throw MpdVirt.BackendError.other("openssl could not read \(certPath): \(r.stderr)")
        }
        // Output shape: `notAfter=May 24 09:21:03 2027 GMT`
        let line = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let eq = line.firstIndex(of: "=") else {
            throw MpdVirt.BackendError.other("unexpected openssl output: \(line)")
        }
        let dateString = String(line[line.index(after: eq)...])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        // openssl's default format: `MMM d HH:mm:ss yyyy zzz`
        formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
        guard let notAfter = formatter.date(from: dateString) else {
            throw MpdVirt.BackendError.other("could not parse cert expiry '\(dateString)'")
        }
        let interval = notAfter.timeIntervalSinceNow
        return Int(interval / 86_400)
    }

    // MARK: - Helpers

    private static func writeTempFile(named: String, body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("\(named).\(UUID().uuidString)")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
