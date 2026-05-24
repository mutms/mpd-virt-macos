// mpd-virt — `update <NNN>` verb.
//
// Refresh a running mpd VM to current main. The actual update logic
// lives in mpd at `/opt/mpd/bootstrap/70-update.sh` — this verb is
// pure orchestration: ssh in, run the script, follow with a
// non-interactive diag pass.
//
// Why a separate verb (not folded into setup): setup is "adopt + run
// the initial bootstrap" — runs once per VM. Update is the recurring
// "pull the latest source, rebuild, re-run mpd --setup" loop. Keeping
// them distinct means setup re-runs stay fast (just idempotent host
// state checks), and update is the explicit knob for the slow git/
// build cycle.
//
// Why the logic lives in mpd's bootstrap dir: mpd-virt doesn't need
// a release when the update flow evolves (new container image rebuilds,
// new schema migrations, additional apt packages). The contract is:
// "run /opt/mpd/bootstrap/70-update.sh on the VM; you'll be current."

import Foundation

extension MpdVirt.Update {
    static func run(octet: Int) throws {
        try validateOctet(octet)
        let entry = try MpdVirt.Registry.load(octet: octet)

        let canonicalIP = "10.211.55.\(entry.octet)"
        let target = MpdVirt.Host.Ssh.Target(user: entry.user, host: canonicalIP)

        FileHandle.standardError.write(Data(
            "  • updating \(entry.name) at \(canonicalIP)\n".utf8
        ))

        // Live-stream output — apt / git / make can take a while and
        // the dev should see progress.
        let code = try MpdVirt.Host.Ssh.stream(
            target,
            "bash /opt/mpd/bootstrap/70-update.sh"
        )
        guard code == 0 else {
            throw MpdVirt.BackendError.other(
                "update failed (exit \(code)). SSH in and re-run /opt/mpd/bootstrap/70-update.sh by hand to see the full output."
            )
        }

        FileHandle.standardError.write(Data("\n✓ update \(entry.name) complete.\n".utf8))

        // Verify the update didn't break anything diag-visible.
        try MpdVirt.Diag.run(octet: octet, nonInteractive: true)
    }
}
