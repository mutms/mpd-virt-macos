// mpd-virt — MpdVirt.Net namespace.
//
// The in-VM container network, as seen from the Mac. Every mpd VM runs
// its podman containers on the same subnet today and reaching them from
// the Mac means one static route plus one scoped resolver file — no
// tunnel involved.
//
// Note the flat, VM-independent addressing: because every VM serves the
// identical subnet, only one of them can be routable from the Mac at a
// time. Making these per-octet is the subject of
// docs/proposals/per-vm-addressing-and-wireguard-removal.md.

import Foundation

extension MpdVirt.Net {

    /// `10.163.0.0/24` — the in-VM container subnet, routed via the VM.
    static let containerSubnet = "10.163.0.0/24"
    /// `10.163.0.3` — in-VM dnsmasq, authoritative for *.mpd.test.
    static let containerDNS = "10.163.0.3"
}
