// mpd-virt — Sudo-recipe printer.
//
// Matches the old `print_sudo_recipe` shape from
// setup/macos-prl/lib/common.sh in the mpd repo (commit 87d83b0):
//
//   1. Print "The following commands need to run as root:" + each
//      command, indented and copy-pasteable, followed by `sudo -k`.
//   2. Print the explanation: (a) run yourself in another terminal,
//      then press Enter, (b) press Enter to let mpd-virt run them
//      with one password prompt.
//   3. Read a single Enter.
//   4. Either way, mpd-virt now re-tries the work via Process:
//      `sudo -v` once (single password prompt, or Touch ID), then each
//      step via `sudo …`. If the user already ran them, the commands
//      are idempotent so it's a no-op; if they didn't, we run them now.
//   5. `sudo -k` to invalidate the cached credential.
//
// `--yes` mode skips the Enter prompt and runs immediately. (Still
// prints the recipe for visibility.)

import Foundation

extension MpdVirt.Host.SudoRecipe {

    struct Step {
        /// Human-friendly title shown above the command. Optional —
        /// used only by `--yes` execution for the per-step header.
        let title: String
        /// argv to execute under sudo. The recipe printer renders
        /// `sudo <argv...>` for the visible recipe.
        let argv: [String]
    }

    enum Mode {
        /// Interactive: print → wait for Enter → run via sudo.
        case interactive
        /// Non-interactive: skip the Enter prompt; still print + run.
        case yes
    }

    /// Print the recipe, optionally wait for Enter, then re-evaluate
    /// what's STILL needed (the dev may have run the commands by hand
    /// in another terminal during the wait) and only sudo whatever's
    /// left. This matches the old bash `print_sudo_recipe` + `detect_
    /// host_needs` pattern.
    ///
    /// `build` is called twice — once before the prompt to render the
    /// recipe, and once after the prompt to determine the actual work
    /// to run. Each call should inspect current host state (file
    /// existence, keychain contents, route table, …) and return the
    /// steps still pending.
    static func run(mode: Mode, build: () -> [Step]) throws {
        let initial = build()
        guard !initial.isEmpty else { return }

        printRecipe(initial)

        if mode == .interactive {
            FileHandle.standardError.write(Data(
                "    Press Enter to continue: ".utf8
            ))
            _ = readLine()
        }

        // Re-evaluate after the optional manual pause. Anything the
        // dev did in their other shell drops out of the list here.
        let remaining = build()
        if remaining.isEmpty {
            FileHandle.standardError.write(Data(
                "    (everything already done — nothing for mpd-virt to sudo)\n".utf8
            ))
            return
        }
        if remaining.count < initial.count {
            FileHandle.standardError.write(Data(
                "    (\(initial.count - remaining.count) step(s) already done; running the \(remaining.count) remaining)\n".utf8
            ))
        }

        // Prime sudo credential (or Touch-ID prompt on Apple Silicon).
        let primed = try MpdVirt.Host.Ssh.runProcess(argv: ["/usr/bin/sudo", "-v"])
        try primed.throwIfFailed(argv: ["sudo", "-v"])

        for step in remaining {
            var argv = ["/usr/bin/sudo"]
            argv += step.argv
            let r = try MpdVirt.Host.Ssh.runProcess(argv: argv)
            if !r.stderr.isEmpty {
                FileHandle.standardError.write(Data(r.stderr.utf8))
            }
            if !r.ok {
                _ = try? MpdVirt.Host.Ssh.runProcess(argv: ["/usr/bin/sudo", "-k"])
                throw MpdVirt.BackendError.other("""
                    sudo \(step.argv.joined(separator: " ")) failed (exit \(r.exitCode)).
                    """)
            }
        }

        _ = try? MpdVirt.Host.Ssh.runProcess(argv: ["/usr/bin/sudo", "-k"])
    }

    // MARK: - Display

    private static func printRecipe(_ steps: [Step]) {
        var lines: [String] = []
        lines.append("")
        lines.append("    The following commands need to run as root:")
        lines.append("")
        for step in steps {
            lines.append("        \(renderLine(step))")
        }
        lines.append("        sudo -k")
        lines.append("")
        lines.append("    (The trailing 'sudo -k' invalidates your cached sudo credential")
        lines.append("    after the recipe completes — same fence the script applies on")
        lines.append("    its own privileged block.)")
        lines.append("")
        lines.append("    You can:")
        lines.append("      (a) Run them yourself in another terminal, then press Enter here.")
        lines.append("      (b) Press Enter to let mpd-virt run them (it will prompt for your")
        lines.append("          password once, or use Touch ID if configured).")
        lines.append("")
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Render one Step as the literal command line a user would paste.
    /// Whitespace-bearing args get single-quoted.
    static func renderLine(_ step: Step) -> String {
        "sudo " + step.argv.map(quote).joined(separator: " ")
    }

    private static func quote(_ s: String) -> String {
        // Quote only if the arg contains characters that need it.
        if s.range(of: "[^A-Za-z0-9_./:=@%+,-]", options: .regularExpression) == nil {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
