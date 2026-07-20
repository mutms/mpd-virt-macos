// mpd-virt — MpdVirt.Net namespace.
//
// The in-VM container network, as seen from the Mac. Reaching a VM's
// containers means one static route plus one scoped resolver file — no
// tunnel involved.
//
// ── Per-VM addressing ──────────────────────────────────────────────────
// Every fact here is a function of the VM's octet, because every fact in
// the VM is too. VM 222 serves `10.163.222.0/24` with dnsmasq on
// `10.163.222.3` and owns the DNS zone `222.mpd.test`; VM 150 serves
// `10.163.150.0/24` / `10.163.150.3` / `150.mpd.test`.
//
// That is what lets several VMs be reachable at once. The Mac holds one
// route and one `/etc/resolver/<id>.mpd.test` file per VM, and they do
// not collide: the routes are to disjoint /24s, and macOS resolver(5)
// picks by longest suffix match, so each zone file governs only its own
// VM.
//
// The in-VM half of this lives in `Mpd.Net` (mpd repo, `mpd/Net.swift`).
// The two must agree; they are separate repos, so a change here is a
// change there.
//
// Mirrors the layout mpd uses inside the VM: the host part of an address
// never moves (dnsmasq always `.3`, portal always `.4`), only the third
// octet varies, and it always equals the VM ID.

import Foundation

extension MpdVirt.Net {

    // MARK: - Fixed facts

    /// The DNS root mpd owns, shared by every VM. It is what the CA is
    /// name-constrained to (`permitted;DNS:mpd.test`), which is why one
    /// CA covers every VM's zone without change. Per-VM names hang below
    /// it — see `zone(octet:)`.
    static let rootDomain = "mpd.test"

    /// First two octets of the container address space. `10.163.0.0/16`
    /// is reserved by mpd in aggregate; each VM takes one /24 inside it.
    static let subnetPrefix = "10.163"

    /// Host octets with a fixed meaning inside every VM's /24.
    enum Host {
        static let dnsmasq = 3
        static let portal = 4
    }

    // MARK: - Per-VM facts

    /// This VM's DNS zone: `150.mpd.test`. Also the zone apex, which
    /// resolves to the portal — so `https://150.mpd.test/` is the
    /// browser entry point for VM 150.
    static func zone(octet: Int) -> String {
        "\(MpdVirt.vmId(octet: octet)).\(rootDomain)"
    }

    /// This VM's container subnet in CIDR form: `10.163.150.0/24`.
    /// The destination of the Mac's static route.
    static func containerSubnet(octet: Int) -> String {
        "\(subnetPrefix).\(octet).0/24"
    }

    /// Compose a container address from its host octet:
    /// `ip(octet: 150, host: Host.portal)` → `10.163.150.4`.
    static func ip(octet: Int, host: Int) -> String {
        "\(subnetPrefix).\(octet).\(host)"
    }

    /// This VM's dnsmasq — authoritative for its zone, and the
    /// nameserver the scoped resolver file points at.
    static func containerDNS(octet: Int) -> String {
        ip(octet: octet, host: Host.dnsmasq)
    }

    /// This VM's portal container.
    static func containerPortal(octet: Int) -> String {
        ip(octet: octet, host: Host.portal)
    }

    /// The scoped resolver file for this VM: `/etc/resolver/150.mpd.test`.
    ///
    /// The filename *is* the match domain. macOS resolver(5) selects by
    /// longest suffix, so per-VM files never conflict with each other —
    /// that property is what makes concurrent VMs work, and it is why the
    /// file is named for the zone rather than for the root domain.
    static func resolverFile(octet: Int) -> String {
        "/etc/resolver/\(zone(octet: octet))"
    }

    /// A runtime's name in this VM's zone: `php.runtime.150.mpd.test`.
    static func runtimeHost(_ runtime: String, octet: Int) -> String {
        "\(runtime).runtime.\(zone(octet: octet))"
    }

    /// `vm.service.<zone>` — the diagnostic record mpd's dnsmasq serves,
    /// answering with the VM's own LAN IP rather than a container
    /// address. Used by `diag` to confirm the route lands where intended.
    static func vmServiceRecord(octet: Int) -> String {
        "vm.service.\(zone(octet: octet))"
    }

    // MARK: - Legacy

    /// The pre-per-VM-addressing resolver file, from when every VM shared
    /// one flat `mpd.test` zone. Nothing writes it any more; `uninstall`
    /// still offers to remove it so an upgraded Mac doesn't keep sending
    /// bare `*.mpd.test` lookups to an address that no longer answers.
    static let legacyResolverFile = "/etc/resolver/\(rootDomain)"

    /// The subnet every VM used to share. Only referenced when cleaning
    /// up a stale route left over from that era.
    static let legacySubnet = "\(subnetPrefix).0.0/24"
}
