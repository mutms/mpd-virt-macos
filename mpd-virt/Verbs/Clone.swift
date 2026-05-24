// mpd-virt — `clone <NNN> --template=<mpd-template-…>` verb.
//
// Copy an existing template (or VM) into a fresh `mpd-<NNN>` VM. Initial
// scope: Parallels via `prlctl clone`. UTM gains a clone path later.
// After the backend returns the new VM's IP, `Setup` runs the universal
// post-provisioning flow.

import Foundation

extension MpdVirt.Clone {
    static func run(
        octet: Int,
        backendFlag: String?,
        template: String,
        username: String,
        vmDisk: String?,
        vmRam: String?,
        assumeYes: Bool
    ) throws {
        try validateOctet(octet)
        let backend = try MpdVirt.resolveBackend(flag: backendFlag)
        guard backend.capabilities.clone else {
            throw MpdVirt.BackendError.unsupported(verb: "clone", backend: backend.rawValue)
        }

        // Refuse fast if Parallels already has a VM at this name or
        // at the canonical IP — clone would clobber it. Setup is the
        // adoption verb; clone is the "make a new one" verb.
        try backend.preflight(octet: octet)

        let opts = MpdVirt.CloneOpts(username: username, vmDisk: vmDisk, vmRam: vmRam)
        let provisioned = try backend.clone(octet: octet, template: template, opts: opts)

        try MpdVirt.Setup.run(
            octet: octet,
            ip: provisioned.ip,
            backend: backend,
            username: username,
            uuid: provisioned.uuid,
            disk: vmDisk,
            ram: vmRam
        )

        // create/clone are the user-friendly verbs — finish with
        // interactive diag (Setup already ran the non-interactive
        // mandatory checks internally). With --yes, diag also goes
        // non-interactive so the whole `clone --yes` is scriptable.
        try MpdVirt.Diag.run(octet: octet, nonInteractive: assumeYes)
    }
}
