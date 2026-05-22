// mpd-virt — MpdVirt.Stop namespace
//
// Stub for `mpd-virt stop <octet>`. Suspends (or hard-stops with --kill)
// the named VM via prlctl.

import ArgumentParser
import Foundation

extension MpdVirt.Stop {
    static func run(octet: Int, kill: Bool) throws {
        let vmName = MpdVirt.vmName(octet: octet)
        let action = kill ? "prlctl stop '\(vmName)' --kill" : "prlctl suspend '\(vmName)'"
        FileHandle.standardError.write(Data("""
            mpd-virt stop \(octet) — not yet implemented.

            Planned: \(action). Idempotent (no-op if already stopped).

            """.utf8))
        throw ExitCode(2)
    }
}
