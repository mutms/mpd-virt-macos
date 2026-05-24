// mpd-virt — Thin wrapper over the system ssh/scp binaries.
//
// Lives in MpdVirt.Host.Ssh. Every host→VM interaction routes through
// this file so the Process()-juggling stays in one place and so the rest
// of mpd-virt is unit-testable in principle (mock these calls).
//
// Defaults baked in:
//   - StrictHostKeyChecking=accept-new  — VM identity changes when it
//     gets reprovisioned at the same IP; accept-new beats prompting +
//     beats blanket "no" because it still detects man-in-the-middle on
//     subsequent connections.
//   - UserKnownHostsFile=/dev/null      — same reason; the host fingerprint
//     is treated as ephemeral. (We trust the Parallels Shared network's
//     security boundary — anything stronger means daily prompts.)
//   - ConnectTimeout=10                 — fail fast on unreachable VM.
//   - BatchMode=yes by default          — opt out with target.batchMode=false
//     for first-time runs where the user might need to type a password.

import Foundation

extension MpdVirt.Host.Ssh {

    // MARK: - Connection target

    struct Target {
        let user: String
        let host: String
        /// Optional explicit identity file (e.g. ~/.ssh/id_ed25519).
        /// nil → let ssh pick from agent + default identities.
        var identityFile: String?
        /// Connect-timeout in seconds. Default 10.
        var connectTimeout: Int = 10
        /// When true, refuses to prompt for a password / passphrase.
        var batchMode: Bool = true

        var sshTarget: String { "\(user)@\(host)" }
    }

    // MARK: - Errors

    struct CommandFailed: Error, CustomStringConvertible {
        let argv: [String]
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var description: String {
            """
            command failed (exit \(exitCode)): \(argv.joined(separator: " "))
            stderr: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            """
        }
    }

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var ok: Bool { exitCode == 0 }
    }

    // MARK: - Shared option list

    /// Common ssh/scp `-o` overrides applied to every invocation.
    /// Caller-supplied options always come AFTER these so they win.
    static func baseOptions(_ target: Target) -> [String] {
        var opts: [String] = [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=\(target.connectTimeout)",
            "-o", "LogLevel=ERROR",
        ]
        if target.batchMode {
            opts += ["-o", "BatchMode=yes"]
        }
        if let id = target.identityFile {
            opts += ["-i", id]
        }
        return opts
    }

    // MARK: - ssh exec

    /// Run a single remote command. Returns the captured result;
    /// callers check `.ok` or call `.throwIfFailed()` (see below).
    @discardableResult
    static func exec(_ target: Target, _ remoteCommand: String,
                     stdinData: Data? = nil) throws -> Result {
        var argv = ["/usr/bin/ssh"]
        argv += baseOptions(target)
        argv += [target.sshTarget, remoteCommand]
        return try runProcess(argv: argv, stdinData: stdinData)
    }

    /// Run a remote command, throwing on non-zero exit. Convenience
    /// wrapper for the common "we expect this to succeed" path.
    @discardableResult
    static func run(_ target: Target, _ remoteCommand: String,
                    stdinData: Data? = nil) throws -> String {
        let r = try exec(target, remoteCommand, stdinData: stdinData)
        try r.throwIfFailed(argv: ["ssh", target.sshTarget, remoteCommand])
        return r.stdout
    }

    // MARK: - Reachability

    /// Cheapest possible "is the VM there + key works" probe. True
    /// iff `ssh user@host true` exits 0 within the connect timeout.
    static func reachable(_ target: Target) -> Bool {
        guard let r = try? exec(target, "true") else { return false }
        return r.ok
    }

    /// Wait until `reachable(target)` returns true or the deadline
    /// passes. Returns true if reached, false on timeout. Useful when
    /// the VM is rebooting or pinning a new IP.
    static func waitUntilReachable(_ target: Target,
                                   timeoutSeconds: Int = 180,
                                   pollSeconds: Int = 3) -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if reachable(target) { return true }
            Thread.sleep(forTimeInterval: TimeInterval(pollSeconds))
        }
        return false
    }

    // MARK: - Key auth bootstrap

    /// Standard locations OpenSSH probes for default identity keys.
    /// Order matches OpenSSH's own preference (ed25519 first as the
    /// modern default).
    static let defaultKeyCandidates: [String] = [
        "id_ed25519",
        "id_ecdsa",
        "id_rsa",
    ]

    /// Resolve an absolute path to the first existing default-name
    /// private key under ~/.ssh/. Returns nil if none of the candidates
    /// are present.
    static func defaultIdentityFile() -> String? {
        let sshDir = "\(MpdVirt.homeDir)/.ssh"
        for name in defaultKeyCandidates {
            let path = "\(sshDir)/\(name)"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// True if `ssh-add -l` reports at least one loaded identity in
    /// the agent (so SSH can authenticate even without a key file on
    /// disk). Defensive: errors → false.
    static func sshAgentHasIdentity() -> Bool {
        guard let r = try? runProcess(argv: ["/usr/bin/ssh-add", "-l"]) else {
            return false
        }
        if !r.ok { return false }
        // ssh-add -l prints "The agent has no identities." when empty.
        return !r.stdout.contains("no identities")
    }

    /// Ensure key-based SSH auth works against `target`:
    ///   1. Verify the Mac has a usable identity (key file or agent).
    ///      Missing → error with an `ssh-keygen` hint.
    ///   2. Probe `target` with BatchMode. Already works → return.
    ///   3. Probe failed → run `ssh-copy-id` with full stdio
    ///      inheritance so the user's terminal handles the host-key
    ///      confirmation + password prompt directly (sshd writes the
    ///      "password:" line via /dev/tty in noecho mode; the child
    ///      Process inherits the controlling terminal so this works
    ///      cleanly). Re-probe after — and only if THAT fails do we
    ///      fall back to "go run it yourself" with the exact command.
    static func ensureKeyAuth(_ target: Target) throws {
        let identityFile = defaultIdentityFile()
        let agentReady = sshAgentHasIdentity()

        if identityFile == nil && !agentReady {
            throw MpdVirt.BackendError.other("""
                no SSH identity on this Mac. Create one before running setup:
                  ssh-keygen -t ed25519
                (you'll be prompted for a passphrase — choose one, don't leave it empty).

                If you set a passphrase, load the key once with
                  ssh-add --apple-use-keychain ~/.ssh/id_ed25519
                — this caches the passphrase in your login keychain so future
                ssh / mpd-virt invocations don't re-prompt.

                Then re-run `mpd-virt setup`.
                """)
        }

        if reachable(target) { return }

        // Run ssh-copy-id with inherited stdio. The child opens
        // /dev/tty for the password prompt; macOS's terminal handles
        // noecho on its own. We don't pass --batch / --no-prompt — we
        // WANT the host-key and password prompts to surface here.
        FileHandle.standardError.write(Data("""

              ▸ SSH key isn't authorized on \(target.sshTarget) yet.
                Running ssh-copy-id — you'll be asked for the VM's password once.

            """.utf8))

        var argv = ["/usr/bin/ssh-copy-id"]
        if let key = identityFile {
            argv += ["-i", "\(key).pub"]
        }
        argv += ["-o", "StrictHostKeyChecking=accept-new"]
        argv += [target.sshTarget]

        MpdVirt.Debug.log("run interactive: \(argvForLog(argv))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        // Explicit stdio inheritance — the child gets our terminal.
        process.standardInput  = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError  = FileHandle.standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // ssh-copy-id failed (wrong password, ssh service down,
            // etc.). Fall back to "go run it yourself" with the exact
            // command — the dev can debug from there.
            let keyHint = identityFile.map { " -i \($0).pub" } ?? ""
            throw MpdVirt.BackendError.other("""
                ssh-copy-id failed (exit \(process.terminationStatus)). Run it manually:

                    ssh-copy-id\(keyHint) \(target.sshTarget)

                Then re-run `mpd-virt setup` — it'll continue from here.
                """)
        }

        // Re-verify with BatchMode — catches the case where
        // ssh-copy-id "succeeds" but the key landed with wrong owner
        // / mode on the VM (sshd rejects group-readable
        // authorized_keys / world-readable home).
        guard reachable(target) else {
            throw MpdVirt.BackendError.other("""
                ssh-copy-id reported success but BatchMode SSH still fails.
                Check on the VM that the dev user owns ~/.ssh (700) and
                ~/.ssh/authorized_keys (600), and that sshd allows pubkey auth.
                """)
        }
    }

    // MARK: - Streaming / interactive exec

    /// Run a remote command with **full stdio inheritance** — the
    /// child ssh gets the user's terminal as stdin/stdout/stderr.
    /// Used by long-running bootstrap steps (apt-get, swift build,
    /// git clone) so the user sees progress live, AND by steps that
    /// can prompt for input (e.g. `su -c` in 10-passwordless-sudo.sh
    /// when the VM doesn't have passwordless sudo yet).
    ///
    /// Differences from `exec()`:
    ///   - BatchMode is OFF (would suppress the rare ssh-level prompt
    ///     we might still want — e.g. a host-key change).
    ///   - When `requestTTY=true` we pass `-tt` (force PTY) so the
    ///     remote command's `isatty(stdin)` check passes even if
    ///     mpd-virt's own stdin isn't a TTY.
    ///   - Stdin / stdout / stderr are explicitly bound to the
    ///     parent's standard streams. Foundation does default to
    ///     inherit, but being explicit avoids edge cases where the
    ///     parent has reassigned them (test harnesses, etc.).
    @discardableResult
    static func stream(_ target: Target,
                       _ remoteCommand: String,
                       requestTTY: Bool = false) throws -> Int32 {
        // Plain ssh, stdio inherited. No -tt: when Swift's Process
        // spawns via posix_spawn the child isn't the foreground
        // process group for the controlling terminal, and `ssh -tt`
        // blocks trying to manipulate terminal attributes. Without
        // -tt ssh just transmits stdin/stdout/stderr as pipes — fine
        // for our bootstrap scripts.
        //
        // Trade-off: remote stdout is block-buffered when the remote
        // bash sees a non-TTY (it's not a regression from before since
        // we never had a real PTY here). For scripts that take seconds
        // (10-passwordless-sudo) this is invisible; for long ones
        // (40-install-software's apt-get) output appears in chunks.
        // If we ever need streaming under a non-TTY remote, the fix
        // is `stdbuf -o0 -e0 bash …` on the remote side or wrapping
        // the remote command in `script -q -c '…' /dev/null`.
        //
        // requestTTY is currently ignored — kept on the signature for
        // future use (callers still annotate intent).
        _ = requestTTY

        var argv = ["/usr/bin/ssh"]
        argv += [
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=\(target.connectTimeout)",
            "-o", "LogLevel=ERROR",
        ]
        if let id = target.identityFile {
            argv += ["-i", id]
        }
        argv += [target.sshTarget, remoteCommand]

        MpdVirt.Debug.log("stream: \(argvForLog(argv))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardInput  = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError  = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        MpdVirt.Debug.log("stream exit \(process.terminationStatus)")
        return process.terminationStatus
    }

    // MARK: - scp put / get

    /// Upload a local file to a remote path. Creates the remote
    /// directory tree first (single `mkdir -p`) before scp'ing.
    static func put(_ target: Target,
                    localPath: String,
                    remotePath: String,
                    mode: Int? = nil) throws {
        let remoteDir = (remotePath as NSString).deletingLastPathComponent
        if !remoteDir.isEmpty, remoteDir != "/" {
            try run(target, "mkdir -p \(shellQuote(remoteDir))")
        }
        var argv = ["/usr/bin/scp"]
        argv += baseOptions(target)
        argv += [localPath, "\(target.sshTarget):\(remotePath)"]
        let r = try runProcess(argv: argv)
        try r.throwIfFailed(argv: ["scp", localPath, "\(target.sshTarget):\(remotePath)"])
        if let m = mode {
            try run(target, "chmod \(String(m, radix: 8)) \(shellQuote(remotePath))")
        }
    }

    /// Download a remote file to a local path.
    static func get(_ target: Target,
                    remotePath: String,
                    localPath: String) throws {
        var argv = ["/usr/bin/scp"]
        argv += baseOptions(target)
        argv += ["\(target.sshTarget):\(remotePath)", localPath]
        let r = try runProcess(argv: argv)
        try r.throwIfFailed(argv: ["scp", "\(target.sshTarget):\(remotePath)", localPath])
    }

    // MARK: - Process runner

    /// Run a Process, capturing stdout/stderr. Stays at the bottom
    /// of this file so the public surface above reads top-down.
    static func runProcess(argv: [String], stdinData: Data? = nil) throws -> Result {
        MpdVirt.Debug.log("run: \(argvForLog(argv))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let data = stdinData {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            try stdinPipe.fileHandleForWriting.close()
        }

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let result = Result(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
        MpdVirt.Debug.log("exit \(result.exitCode): \(argv[0])")
        if MpdVirt.Debug.enabled, !result.stdout.isEmpty {
            MpdVirt.Debug.log("stdout:\n\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if MpdVirt.Debug.enabled, !result.stderr.isEmpty {
            MpdVirt.Debug.log("stderr:\n\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result
    }

    /// Run a Process with a wall-clock timeout. Returns the captured
    /// result plus a `timedOut` flag. On timeout the child is
    /// SIGTERM'd (and SIGKILL'd 100ms later if still alive). Used by
    /// diag probes that can otherwise hang for the resolver's full
    /// timeout when routing is incomplete.
    static func runWithTimeout(argv: [String], timeoutSeconds: Double) -> (
        exitCode: Int32, stdout: String, stderr: String, timedOut: Bool
    ) {
        MpdVirt.Debug.log("run (timeout=\(timeoutSeconds)s): \(argvForLog(argv))")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return (exitCode: -1, stdout: "", stderr: "\(error)", timedOut: false)
        }

        // Poll for completion with a deadline. 50ms tick is plenty
        // fine-grained for a 2s-ish bound.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    /// Format an argv array for the debug log. Each arg quoted if it
    /// has any character that'd surprise a copy-paste into a shell.
    private static func argvForLog(_ argv: [String]) -> String {
        argv.map { arg in
            if arg.range(of: "[^A-Za-z0-9_./:=@%+,-]", options: .regularExpression) == nil {
                return arg
            }
            return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    // MARK: - Helpers

    /// Quote a shell argument with single quotes. Sufficient for
    /// the paths we generate (no embedded single quotes). For user
    /// input we'd reach for a stricter sanitizer.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension MpdVirt.Host.Ssh.Result {
    /// Throws CommandFailed if this result is non-zero. argv is supplied
    /// by the caller so the error message reflects the high-level command
    /// (e.g. ["ssh", "user@host", "true"]) rather than the literal argv we
    /// passed Process.
    func throwIfFailed(argv: [String]) throws {
        if exitCode != 0 {
            throw MpdVirt.Host.Ssh.CommandFailed(
                argv: argv, exitCode: exitCode, stdout: stdout, stderr: stderr
            )
        }
    }
}
