// mpd-virt — MpdVirt.Show namespace
//
// Stub for `mpd-virt show <octet>`. Detailed view of one VM:
// Parallels state, IP, UUID, stored env, WG tunnel status.

import ArgumentParser
import Foundation

extension MpdVirt.Show {
    static func run(octet: Int) throws {
        let vmName = MpdVirt.vmName(octet: octet)
        FileHandle.standardError.write(Data("""
            mpd-virt show \(octet) — not yet implemented.

            Planned output for '\(vmName)':

              Name:        \(vmName)
              Octet:       \(octet)
              UUID:        <from \(MpdVirt.vmDir(octet: octet))/env, cross-checked with prlctl>
              Parallels:   <running|stopped|suspended|missing>
              IP:          10.211.55.\(octet)
              SSH alias:   ssh \(vmName)
              WG tunnel:   <imported in WireGuard.app|missing>
              Runtimes:    php / node / util (via ProxyJump \(vmName))

            """.utf8))
        throw ExitCode(2)
    }
}
