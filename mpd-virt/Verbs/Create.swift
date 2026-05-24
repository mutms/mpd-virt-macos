// mpd-virt — `create <NNN>` verb.
//
// Materialize a fresh VM from scratch on a hypervisor backend (no
// template). Initial scope: UTM cloud-init. Parallels gains a `create`
// path later. After the backend returns the new VM's IP, `Setup` runs
// the universal post-provisioning flow.

import Foundation

extension MpdVirt.Create {
    static func run(
        octet: Int,
        backendFlag: String?,
        username: String,
        vmDisk: String?,
        vmRam: String?,
        assumeYes: Bool
    ) throws {
        try validateOctet(octet)
        let backend = try MpdVirt.resolveBackend(flag: backendFlag)
        guard backend.capabilities.create else {
            throw MpdVirt.BackendError.unsupported(verb: "create", backend: backend.rawValue)
        }

        let opts = MpdVirt.CreateOpts(username: username, vmDisk: vmDisk, vmRam: vmRam)
        let provisioned = try backend.create(octet: octet, opts: opts)

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
        // non-interactive so the whole `create --yes` is scriptable.
        try MpdVirt.Diag.run(octet: octet, nonInteractive: assumeYes)
    }
}

func validateOctet(_ octet: Int) throws {
    guard MpdVirt.managedOctetRange.contains(octet) else {
        throw MpdVirt.BackendError.other(
            "octet \(octet) out of range (\(MpdVirt.managedOctetRange.lowerBound)–\(MpdVirt.managedOctetRange.upperBound))."
        )
    }
}
