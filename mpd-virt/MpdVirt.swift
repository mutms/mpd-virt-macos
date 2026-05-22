// mpd-virt — Namespace root.
//
// macOS host-side orchestrator for mpd. Drives Parallels Desktop Pro to
// create + manage mpd VMs. Replaces the bash setup/macos/ tree
// that used to live in the main mpd repo.
//
// Verb implementations live in matching files via extension:
//   MpdVirt.Create    → Create.swift
//   MpdVirt.Delete    → Delete.swift
//   MpdVirt.Start     → Start.swift
//   MpdVirt.Stop      → Stop.swift
//   MpdVirt.List      → List.swift
//   MpdVirt.Show      → Show.swift
//   MpdVirt.Doctor    → Doctor.swift
//   MpdVirt.WireGuard → WireGuard.swift
//
// Multi-VM model: any number of mpd VMs can coexist and run
// simultaneously. WireGuard.app's active tunnel determines which VM the
// Mac's `*.mpd.test` traffic is currently routed to — there's no "current
// VM" tracked on disk by mpd-virt.

import Foundation

enum MpdVirt {
    enum Create {}
    enum Delete {}
    enum Start {}
    enum Stop {}
    enum List {}
    enum Show {}
    enum Doctor {}
    enum WireGuard {}

    // MARK: - Persistent paths on the macOS host

    /// User's home directory.
    static var homeDir: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Top-level dir mpd-virt owns on the host: `~/.mpd-virt/`.
    /// Holds `conf/` (identity, survives `delete`) and per-VM bookkeeping.
    static var rootDir: String { "\(homeDir)/.mpd-virt" }

    /// Persistent identity dir: `~/.mpd-virt/conf/`.
    /// CA, WG keys, service certs. Survives every `mpd-virt delete <octet>`.
    static var confDir: String { "\(rootDir)/conf" }

    /// CA root keypair: `~/.mpd-virt/conf/caroot/`.
    static var caRootDir: String { "\(confDir)/caroot" }

    /// WireGuard keys + configs: `~/.mpd-virt/conf/wireguard/`.
    /// Includes the shared `mac.{private,public}` and per-VM
    /// `machine/<octet>/` subdirs.
    static var wireGuardDir: String { "\(confDir)/wireguard" }

    /// Service certificate dir: `~/.mpd-virt/conf/service/`.
    static var serviceCertDir: String { "\(confDir)/service" }

    /// 3-digit string form of an octet (`"159"`, `"100"`, …). Same shape
    /// used for VM names, host directories, SSH aliases, WG tunnel names.
    static func vmId(octet: Int) -> String { String(format: "%03d", octet) }

    /// Per-VM bookkeeping dir: `~/.mpd-virt/<NNN>/`.
    /// Removed by `mpd-virt delete <octet>`.
    static func vmDir(octet: Int) -> String { "\(rootDir)/\(vmId(octet: octet))" }

    /// Convention: VM name in Parallels is `mpd-<NNN>` (3-digit padded).
    static func vmName(octet: Int) -> String { "mpd-\(vmId(octet: octet))" }

    /// Per-VM WG keys + configs: `~/.mpd-virt/conf/wireguard/<NNN>/`.
    static func wgVmDir(octet: Int) -> String {
        "\(wireGuardDir)/\(vmId(octet: octet))"
    }

    /// Valid octet range for managed VMs. mpd-virt clamps to this so we
    /// never collide with Parallels Shared's DHCP pool (1–99) or the
    /// reserved broadcast/special addresses (>254).
    static let managedOctetRange: ClosedRange<Int> = 100...254
}
