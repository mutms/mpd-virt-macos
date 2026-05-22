// mpd-virt — MpdVirt.Doctor namespace
//
// Stub for `mpd-virt doctor`. Host-side verification + idempotent
// repair: re-asserts the parts that aren't per-VM (CA trust, SSH
// config block, WG tunnels imported, etc.). Per-VM state is the
// concern of `mpd-virt show <octet>` instead.

import ArgumentParser
import Foundation

extension MpdVirt.Doctor {
    static func run() throws {
        FileHandle.standardError.write(Data("""
            mpd-virt doctor — not yet implemented.

            Planned checks (idempotent — re-asserts anything missing):

              1. ~/.mpd-virt/conf/caroot/rootCA.pem present and trusted in
                 the macOS System Keychain.
              2. For each tracked VM under \(MpdVirt.rootDir)/<octet>/:
                   - its WireGuard tunnel is imported in WireGuard.app;
                   - ~/.ssh/config has the Host block for the VM and the
                     per-runtime ProxyJump aliases (php / node / util).
                   - the Parallels VM '\(MpdVirt.vmName(octet: 0).replacingOccurrences(of: "0", with: "<octet>"))'
                     still exists (warn if missing).
              3. No claim about which VM is "current" — that's WireGuard.app's
                 toggle, not mpd-virt's bookkeeping. Multiple VMs running
                 simultaneously is fine.

            """.utf8))
        throw ExitCode(2)
    }
}
