// mpd-virt — `list` verb.
//
// Reads the registry, prints one row per known VM with live backend
// state. State is best-effort: any error from `backend.describe()`
// renders as `state=?` so a stopped Parallels app or unreachable VM
// doesn't break the whole listing.

import Foundation

extension MpdVirt.List {
    static func run(json: Bool) throws {
        let entries = try MpdVirt.Registry.loadAll()
        if entries.isEmpty {
            FileHandle.standardError.write(Data(
                "no VMs registered. Add one with `mpd-virt create|clone|setup`.\n".utf8
            ))
            return
        }

        if json {
            try printJSON(entries: entries)
        } else {
            printTable(entries: entries)
        }
    }

    private static func printTable(entries: [MpdVirt.Registry.Entry]) {
        // Render: NNN  NAME       BACKEND    IP               USER     STATE
        print(row("NNN", "NAME", "BACKEND", "IP", "USER", "STATE"))
        for e in entries {
            let state: String
            do { state = try e.backend.describe(octet: e.octet).state }
            catch { state = "?" }
            print(row(
                MpdVirt.vmId(octet: e.octet),
                e.name,
                e.backend.rawValue,
                e.ip,
                e.user,
                state
            ))
        }
    }

    private static func row(_ nnn: String, _ name: String, _ backend: String,
                            _ ip: String, _ user: String, _ state: String) -> String {
        "\(pad(nnn, 4)) \(pad(name, 10)) \(pad(backend, 10)) \(pad(ip, 16)) \(pad(user, 10)) \(state)"
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.padding(toLength: n, withPad: " ", startingAt: 0)
    }

    private static func printJSON(entries: [MpdVirt.Registry.Entry]) throws {
        // Plain dictionary→JSON to avoid having to declare Codable on
        // Registry.Entry (it carries a `MpdVirt.Backend` which isn't
        // Codable yet). Switch to Codable once the verb body grows.
        var rows: [[String: Any]] = []
        for e in entries {
            let state: String
            do { state = try e.backend.describe(octet: e.octet).state }
            catch { state = "unknown" }
            var row: [String: Any] = [
                "octet": e.octet,
                "name": e.name,
                "backend": e.backend.rawValue,
                "ip": e.ip,
                "user": e.user,
                "state": state,
            ]
            if let uuid = e.uuid { row["uuid"] = uuid }
            if let disk = e.disk { row["disk"] = disk }
            if let ram  = e.ram  { row["ram"] = ram }
            rows.append(row)
        }
        let data = try JSONSerialization.data(
            withJSONObject: rows,
            options: [.prettyPrinted, .sortedKeys]
        )
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
