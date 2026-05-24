// mpd-virt — UTM backend (macOS only).
//
// Wraps UTM (utmctl + AppleScript) for VM lifecycle. Initial scope:
// `create` (cloud-init seed ISO + blank disk) + start/stop/delete/describe.
// `clone` (duplicating an existing UTM VM) is a follow-up.

#if os(macOS)
import Foundation

extension MpdVirt.UTM {

    static func create(octet: Int, opts: MpdVirt.CreateOpts) throws -> MpdVirt.Provisioned {
        throw MpdVirt.BackendError.notImplemented(verb: "create", backend: "utm")
    }

    static func clone(octet: Int, template: String, opts: MpdVirt.CloneOpts) throws -> MpdVirt.Provisioned {
        throw MpdVirt.BackendError.notImplemented(verb: "clone", backend: "utm")
    }

    static func start(octet: Int) throws {
        throw MpdVirt.BackendError.notImplemented(verb: "start", backend: "utm")
    }

    static func stop(octet: Int, kill: Bool) throws {
        throw MpdVirt.BackendError.notImplemented(verb: "stop", backend: "utm")
    }

    static func delete(octet: Int) throws {
        throw MpdVirt.BackendError.notImplemented(verb: "delete", backend: "utm")
    }

    static func describe(octet: Int) throws -> MpdVirt.BackendInfo {
        return MpdVirt.BackendInfo(state: "unknown", uuid: nil)
    }

    static func preflight(octet: Int) throws {
        // Stub — UTM-side conflict detection lands when UTM provisioning
        // does. Until then preflight is permissive (won't block setup).
    }

    static func afterCanonicalIPReady(octet: Int, hint: String?, user: String) throws {
        // Stub — UTM identifies VMs by .utm-bundle paths; rename
        // behavior lands when UTM provisioning does.
    }

    static func locate(octet: Int, ipHint: String?) throws -> (ip: String, uuid: String?)? {
        // Stub — UTM provisioning lands later. For now, behave like
        // general: trust --ip if given, otherwise can't help.
        if let ip = ipHint { return (ip: ip, uuid: nil) }
        return nil
    }

    static func printRegistryExtras(entry: MpdVirt.Registry.Entry) {
        // Stub — UTM diag fields land alongside UTM provisioning.
    }
}
#endif
