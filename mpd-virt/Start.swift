// mpd-virt — MpdVirt.Start namespace
//
// Stub for `mpd-virt start <octet>`. Boots the named VM via prlctl;
// no host-state mutation (WG tunnel state is the user's call via
// WireGuard.app).

import ArgumentParser
import Foundation

extension MpdVirt.Start {
    static func run(octet: Int) throws {
        let vmName = MpdVirt.vmName(octet: octet)
        FileHandle.standardError.write(Data("""
            mpd-virt start \(octet) — not yet implemented.

            Planned: prlctl start '\(vmName)'. Idempotent (no-op if already running).

            """.utf8))
        throw ExitCode(2)
    }
}
