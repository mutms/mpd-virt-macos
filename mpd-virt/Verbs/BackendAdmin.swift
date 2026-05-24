// mpd-virt — `backend list` / `backend set-default <name>` admin verbs.
//
// These don't operate on a specific VM and don't need a registry entry.
// `list` enumerates the backends compiled into this binary plus their
// capabilities and the current default. `set-default` writes the default
// to `~/.mpd-virt/conf/backend.env`.

import Foundation

extension MpdVirt.BackendAdmin {

    static func list() throws {
        let current = try MpdVirt.readDefaultBackend()
        print(row("NAME", "CREATE", "CLONE", "LIFECYCLE", "DEFAULT"))
        for kind in MpdVirt.Backend.compiledIn {
            let caps = kind.capabilities
            let marker = (current == kind) ? "*" : ""
            print(row(
                kind.rawValue,
                caps.create ? "yes" : "no",
                caps.clone ? "yes" : "no",
                caps.lifecycle ? "yes" : "no",
                marker
            ))
        }
        if current == nil {
            FileHandle.standardError.write(Data(
                "no default set — pass --backend=<name> on every verb, or run `mpd-virt backend set-default <name>`.\n".utf8
            ))
        }
    }

    static func setDefault(_ name: String) throws {
        let kind = try MpdVirt.Backend.parse(name)
        try MpdVirt.writeDefaultBackend(kind)
        print("default backend → \(kind.rawValue)  (wrote \(MpdVirt.backendConfFile))")
    }

    /// Five-column left-padded row for the capabilities table.
    private static func row(_ a: String, _ b: String, _ c: String, _ d: String, _ e: String) -> String {
        "\(pad(a, 10)) \(pad(b, 7)) \(pad(c, 6)) \(pad(d, 9)) \(e)"
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.padding(toLength: n, withPad: " ", startingAt: 0)
    }
}
