// mpd-virt — MpdVirt.Create namespace
//
// Stub for `mpd-virt create <octet>`. Real implementation lands in
// follow-up commits — see README "What `mpd-virt create` does" for the
// planned step sequence (mirrors the old setup/macos/lib/setup.sh).

import ArgumentParser
import Foundation

extension MpdVirt.Create {
    static func run(octet: Int) throws {
        let vmName = MpdVirt.vmName(octet: octet)
        FileHandle.standardError.write(Data("""
            mpd-virt create \(octet) — not yet implemented.

            Planned flow (for VM '\(vmName)'):

              1. Check Parallels Desktop Pro + prlctl + template + host tooling.
              2. SSH key (~/.ssh/id_ed25519.pub) — generate if missing.
              3. Generate or reuse host-side identity under
                 \(MpdVirt.confDir)/:
                   - caroot/{rootCA.pem, rootCA-key.pem}    (first call only)
                   - wireguard/mac.{private,public}         (first call only)
                   - wireguard/\(octet)/{private,public,server.conf,client.conf}
                     (first call per octet; reused on re-create at same octet)
              4. Trust CA in macOS System Keychain (idempotent).
              5. Refuse if Parallels already has a VM named '\(vmName)'.
              6. Clone 'mpd-template' as '\(vmName)'.
              7. Boot the VM and wait for SSH.
              8. Push CA + WG server.conf into the VM as
                 ~/.mpd/conf/{caroot/rootCA.pem, wireguard/mpd0.conf}.
              9. Write ~/.mpd/conf/platform.env in the VM (MPD_PLATFORM=managed, …).
             10. Kick `mpd --setup` over SSH inside the VM.
             11. Write ~/.mpd-virt/\(octet)/env with VM metadata
                 (UUID, IP, user) for diagnostics.
             12. Import wireguard/\(octet)/client.conf into
                 WireGuard.app as '\(vmName)'.
             13. Write ~/.ssh/config entries for \(vmName) + the per-runtime
                 ProxyJump aliases (php / node / util).

            """.utf8))
        throw ExitCode(2)
    }
}
