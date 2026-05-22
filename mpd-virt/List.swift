// mpd-virt — MpdVirt.List namespace
//
// Stub for `mpd-virt list`. Enumerates every tracked VM (one per
// ~/.mpd-virt/<octet>/env file) alongside its current Parallels state.
// Default subcommand for `mpd-virt` with no args.

import ArgumentParser
import Foundation

extension MpdVirt.List {
    static func run() throws {
        FileHandle.standardError.write(Data("""
            mpd-virt list — not yet implemented.

            Planned columns:

              OCTET   NAME                  STATE      IP                UUID
              155     mpd-machine-155       running    10.211.55.155     <uuid>
              156     mpd-machine-156       stopped    10.211.55.156     <uuid>
              …

            Data sources:
              - tracked VMs:   \(MpdVirt.rootDir)/<octet>/env
              - live state:    prlctl list -a -o uuid,status,name --no-header

            """.utf8))
        throw ExitCode(2)
    }
}
