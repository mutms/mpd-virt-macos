// mpd-virt — System Keychain helpers for the mpd CA.
//
// Trust install (`setup`):
//   `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain <cert>`
// Trust uninstall (`uninstall`):
//   `sudo security delete-certificate -c "mpd Root CA" /Library/Keychains/System.keychain`
// Trust query (`doctor`):
//   `security find-certificate -c "mpd Root CA" /Library/Keychains/System.keychain`
//
// All `sudo` operations route through MpdVirt.Host.SudoRecipe so the
// user sees the number-to-clipboard UX in interactive mode and a single
// Touch-ID / password prompt in `--yes` mode.

import Foundation

extension MpdVirt.Host.Keychain {

    static let systemKeychain = "/Library/Keychains/System.keychain"

    /// True iff a cert with CN "mpd Root CA" is found in the System
    /// Keychain. Read-only; no sudo required.
    static func isTrusted() -> Bool {
        let r = try? MpdVirt.Host.Ssh.runProcess(argv: [
            "/usr/bin/security", "find-certificate",
            "-c", MpdVirt.CA.commonName,
            systemKeychain,
        ])
        return r?.ok == true
    }

    /// Ensure the CA is trusted. Idempotent: if already trusted, no-op.
    /// Otherwise emits a sudo recipe with the `add-trusted-cert` step.
    /// The recipe re-evaluates `isTrusted()` after the manual pause —
    /// if the dev ran the command themselves, the step is skipped.
    static func trust(mode: MpdVirt.Host.SudoRecipe.Mode) throws {
        if isTrusted() { return }
        guard FileManager.default.fileExists(atPath: MpdVirt.CA.certPath) else {
            throw MpdVirt.BackendError.other("""
                CA not generated yet: \(MpdVirt.CA.certPath) does not exist. \
                This usually means `mpd-virt setup` failed before reaching the \
                CA-trust step.
                """)
        }
        try MpdVirt.Host.SudoRecipe.run(mode: mode) {
            isTrusted() ? [] : [MpdVirt.Host.SudoRecipe.Step(
                title: "Trust the mpd CA in the System Keychain",
                argv: [
                    "/usr/bin/security", "add-trusted-cert",
                    "-d",                   // add to admin trust settings
                    "-r", "trustRoot",      // trust as a root
                    "-k", systemKeychain,
                    MpdVirt.CA.certPath,
                ]
            )]
        }
    }

    /// Remove the CA from the System Keychain. Idempotent: if not
    /// present, no-op. Otherwise emits a sudo recipe with the
    /// `delete-certificate` step.
    static func untrust(mode: MpdVirt.Host.SudoRecipe.Mode) throws {
        if !isTrusted() { return }
        try MpdVirt.Host.SudoRecipe.run(mode: mode) {
            isTrusted() ? [MpdVirt.Host.SudoRecipe.Step(
                title: "Remove the mpd CA from the System Keychain",
                argv: [
                    "/usr/bin/security", "delete-certificate",
                    "-c", MpdVirt.CA.commonName,
                    systemKeychain,
                ]
            )] : []
        }
    }
}
