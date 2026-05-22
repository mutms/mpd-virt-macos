// mpd-virt — MpdVirt.Delete namespace
//
// Stub for `mpd-virt delete <octet>`. Removes a single mpd-machine VM
// and its bookkeeping; preserves the persistent identity under
// ~/.mpd-virt/conf/ so a later re-create at the same octet reuses the
// same WG keys + CA.

import ArgumentParser
import Foundation

extension MpdVirt.Delete {
    static func run(octet: Int, assumeYes: Bool) throws {
        let vmName = MpdVirt.vmName(octet: octet)
        FileHandle.standardError.write(Data("""
            mpd-virt delete \(octet) — not yet implemented.

            Planned flow (for VM '\(vmName)'):

              1. Confirm with the user (\(assumeYes ? "skipped — --yes" : "y/N prompt")).
              2. prlctl stop --kill '\(vmName)' if it's running.
              3. prlctl delete '\(vmName)'.
              4. Remove ~/.ssh/config Host blocks for \(vmName) and its
                 per-runtime ProxyJump aliases.
              5. Prompt the user to delete the '\(vmName)' tunnel in
                 WireGuard.app (App Sandbox keeps us from doing it from CLI).
              6. rm -rf \(MpdVirt.vmDir(octet: octet))/.
              7. NEVER touch \(MpdVirt.confDir)/ — CA + WG identity persist
                 so a re-create at the same octet reuses them.

            """.utf8))
        throw ExitCode(2)
    }
}
