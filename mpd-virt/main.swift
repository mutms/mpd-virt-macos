// mpd-virt — CLI entry point.
//
// CRUD-shaped verb surface, one per VM. Multiple VMs can be tracked +
// running simultaneously; WireGuard.app's active tunnel decides which
// one the Mac's `*.mpd.test` traffic flows to.

import ArgumentParser
import Foundation

struct MpdVirtCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mpd-virt",
        abstract: "macOS host-side orchestrator for mpd (Parallels Desktop Pro backend).",
        version: "0.1.0-dev",
        subcommands: [
            CreateCmd.self,
            DeleteCmd.self,
            StartCmd.self,
            StopCmd.self,
            ListCmd.self,
            ShowCmd.self,
            DoctorCmd.self,
        ],
        defaultSubcommand: ListCmd.self
    )
}

struct CreateCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Clone the Parallels template into a new mpd-<NNN> VM and provision it."
    )

    @Argument(help: "Last IP octet on the Parallels Shared network (e.g. 155). Becomes the VM name suffix.")
    var octet: Int

    func run() throws { try MpdVirt.Create.run(octet: octet) }
}

struct DeleteCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete an mpd-<NNN> VM. Removes ~/.mpd-virt/<octet>/ and drops SSH config block; preserves ~/.mpd-virt/conf/."
    )

    @Argument(help: "Octet identifying the VM (e.g. 155).")
    var octet: Int

    @Flag(name: .customLong("yes"), help: "Skip confirmation prompt (for scripted use).")
    var assumeYes: Bool = false

    func run() throws { try MpdVirt.Delete.run(octet: octet, assumeYes: assumeYes) }
}

struct StartCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start an mpd-<NNN> VM (prlctl start)."
    )

    @Argument(help: "Octet identifying the VM.")
    var octet: Int

    func run() throws { try MpdVirt.Start.run(octet: octet) }
}

struct StopCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Suspend an mpd-<NNN> VM. With --kill, hard-stop."
    )

    @Argument(help: "Octet identifying the VM.")
    var octet: Int

    @Flag(name: .customLong("kill"), help: "Hard stop instead of suspend.")
    var kill: Bool = false

    func run() throws { try MpdVirt.Stop.run(octet: octet, kill: kill) }
}

struct ListCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every tracked mpd VM with its current Parallels state."
    )

    func run() throws { try MpdVirt.List.run() }
}

struct ShowCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show one VM's details (state, IP, UUID, …)."
    )

    @Argument(help: "Octet identifying the VM.")
    var octet: Int

    func run() throws { try MpdVirt.Show.run(octet: octet) }
}

struct DoctorCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Re-assert host-side setup: CA in System Keychain, SSH config block, WG tunnels imported."
    )

    func run() throws { try MpdVirt.Doctor.run() }
}

MpdVirtCLI.main()
