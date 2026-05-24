// mpd-virt — General backend.
//
// "General" is the no-hypervisor backend: the VM already exists somewhere
// reachable by IP (a hand-built sandbox VM, an existing template snapshot,
// a colleague's machine on the LAN). `setup` is the only verb that talks
// to such a VM; create/clone/start/stop hard-error via the dispatcher's
// capability check (see Backend.swift).
//
// This file exists primarily so the `MpdVirt.Backend` dispatcher has a
// concrete target for `describe()` — even for general-backend VMs we
// want `list`/`show` to print *something*.

import Foundation

extension MpdVirt.General {

    /// General backend has no hypervisor and thus no native subnet —
    /// the VM lives wherever the user pointed `--ip`. Default assumes
    /// Parallels-like so the common "adopt my sandbox VM" path Just
    /// Works with no flag; pass a different `--ip` for any other LAN.
    static let canonicalSubnet = "10.211.55"

    /// General-backend VMs have no hypervisor to ask about state.
    /// The honest signal we CAN produce is reachability: ICMP-ping
    /// the registry-recorded IP and report "running" / "unreachable".
    ///
    /// Tolerates a missing/malformed registry entry by returning
    /// "unknown" so callers like `list` don't blow up while
    /// enumerating.
    static func describe(octet: Int) throws -> MpdVirt.BackendInfo {
        guard let entry = try? MpdVirt.Registry.load(octet: octet) else {
            return MpdVirt.BackendInfo(state: "unknown")
        }
        // 2-second ping timeout — matches diag's probe cap.
        let r = MpdVirt.Host.Ssh.runWithTimeout(
            argv: ["/sbin/ping", "-c", "1", "-W", "1000", "-t", "2", entry.ip],
            timeoutSeconds: 2.0
        )
        let state = (r.exitCode == 0 && !r.timedOut) ? "running" : "unreachable"
        return MpdVirt.BackendInfo(state: state)
    }
}
