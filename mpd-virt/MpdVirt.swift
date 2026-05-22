// mpd-virt — Namespace root.
//
// macOS host-side orchestrator for mpd. Drives Parallels Desktop Pro to
// create + manage mpd-machine VMs. Replaces the bash setup/macos/ tree
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
// Multi-VM model: any number of mpd-machine VMs can coexist and run
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

    /// Per-VM bookkeeping dir for the given octet:
    /// `~/.mpd-virt/<octet>/`. Removed by `mpd-virt delete <octet>`.
    static func vmDir(octet: Int) -> String { "\(rootDir)/\(octet)" }

    /// Convention: VM name in Parallels is always `mpd-machine-<octet>`.
    static func vmName(octet: Int) -> String { "mpd-machine-\(octet)" }
}
