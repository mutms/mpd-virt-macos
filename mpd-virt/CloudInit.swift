// mpd-virt — Cloud-init image cache + NoCloud seed ISO generation.
//
// Shared by backends that materialize a Debian VM from a cloud image
// (UTM today; other cloud-init flows in the future). Two helpers:
//
//   1. ensureBaseArchive() — download the Debian generic-cloud .tar.xz
//      into ~/.mpd-virt/conf/cloud-images/ on first use. Subsequent
//      creates reuse the cached archive. The raw disk inside is NOT
//      cached — extraction is cheap (a few seconds on Apple Silicon)
//      and a stray multi-GB raw on disk is more annoying than re-running
//      `tar -xJf` per create.
//
//   2. extractRawTo(destPath:) — extract the raw disk image from the
//      cached archive directly to a caller-specified per-VM path.
//
//   3. makeCidataISO(...) — write meta-data + user-data for a single VM
//      into a temp dir, then `hdiutil makehybrid` it into an ISO with
//      the volume label `cidata` that cloud-init's NoCloud datasource
//      picks up at first boot.
//
// `makeCidataISO` takes an optional `networkConfig` string. Callers
// that want a static IP from boot one (UTM, mirroring the historical
// macos-utm flow) pass a cloud-init v2 ethernets block; callers that
// prefer DHCP-then-bootstrap-step-30 pass nil.
//
// The URL pin matches mpd/setup/linux/lib/common.sh (and the historical
// mpd/setup/macos-utm one). When Debian publishes a new daily, bump both
// in lockstep.

import Foundation

extension MpdVirt.CloudInit {

    // MARK: - Image source

    /// Debian Trixie generic-cloud, arm64. Same pin as
    /// mpd/setup/linux/lib/common.sh (just the arm64 archive instead of
    /// amd64) — bump them together when refreshing.
    static let cloudBase = "https://cloud.debian.org/images/cloud/trixie/20260501-2465"
    static let cloudArchive = "debian-13-genericcloud-arm64-20260501-2465.tar.xz"

    /// Where the cached cloud archive lives:
    /// `~/.mpd-virt/conf/cloud-images/`. Only the .tar.xz is cached —
    /// the multi-GB raw disk inside is re-extracted to a per-VM path
    /// on every create.
    static var imageCacheDir: String { "\(MpdVirt.confDir)/cloud-images" }

    /// Absolute path to the cached archive.
    static var cachedArchivePath: String { "\(imageCacheDir)/\(cloudArchive)" }

    // MARK: - Errors

    enum Failure: Error, CustomStringConvertible {
        case downloadFailed(url: String, exitCode: Int32)
        case extractFailed(archive: String, exitCode: Int32)
        case rawNotFoundInArchive(archive: String)
        case hdiutilFailed(exitCode: Int32, stderr: String)
        case ioFailed(String)

        var description: String {
            switch self {
            case .downloadFailed(let url, let code):
                return "curl failed to download \(url) (exit \(code))."
            case .extractFailed(let arc, let code):
                return "tar failed to extract \(arc) (exit \(code))."
            case .rawNotFoundInArchive(let arc):
                return "no .raw disk image found inside \(arc)."
            case .hdiutilFailed(let code, let err):
                return "hdiutil makehybrid failed (exit \(code)): \(err)"
            case .ioFailed(let msg):
                return msg
            }
        }
    }

    // MARK: - Public: archive cache + raw extraction

    /// Ensure the Debian generic-cloud archive is cached on the host.
    /// Returns its path. Idempotent: instant if already downloaded.
    @discardableResult
    static func ensureBaseArchive() throws -> String {
        try ensureCacheDir()

        if FileManager.default.fileExists(atPath: cachedArchivePath) {
            return cachedArchivePath
        }

        let url = "\(cloudBase)/\(cloudArchive)"
        FileHandle.standardError.write(Data("  ▶ downloading \(cloudArchive) (~200 MB) …\n".utf8))
        let r = try MpdVirt.Host.Ssh.runProcess(argv: [
            "/usr/bin/curl", "-L", "--fail", "--progress-bar",
            "-o", cachedArchivePath,
            url
        ])
        if !r.ok {
            try? FileManager.default.removeItem(atPath: cachedArchivePath)
            throw Failure.downloadFailed(url: url, exitCode: r.exitCode)
        }
        return cachedArchivePath
    }

    /// Extract the raw disk image inside the cached archive to
    /// `destPath`. The cached archive is downloaded on first use.
    /// Refuses to clobber an existing file at `destPath`.
    static func extractRawTo(destPath: String) throws {
        let archivePath = try ensureBaseArchive()

        if FileManager.default.fileExists(atPath: destPath) {
            throw Failure.ioFailed("destination raw already exists: \(destPath)")
        }

        // tar extracts whatever filename is inside the archive (Debian
        // currently ships `disk.raw`, but tolerate variation). Stage to a
        // temp dir so we can find the .raw and move it to destPath, then
        // wipe the temp dir.
        let parent = (destPath as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: parent), withIntermediateDirectories: true
            )
        }

        let tempDir = NSTemporaryDirectory() + "mpd-virt-rawx-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: tempDir), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        FileHandle.standardError.write(Data("  ▶ extracting \(cloudArchive) → \(destPath) …\n".utf8))
        let extracted = try MpdVirt.Host.Ssh.runProcess(argv: [
            "/usr/bin/tar", "-xJf", archivePath, "-C", tempDir
        ])
        if !extracted.ok {
            throw Failure.extractFailed(archive: cloudArchive, exitCode: extracted.exitCode)
        }

        // Find whatever raw came out of the archive.
        let entries = try FileManager.default.contentsOfDirectory(atPath: tempDir)
        guard let raw = entries.first(where: { $0.hasSuffix(".raw") || $0.hasPrefix("disk.") })
        else {
            throw Failure.rawNotFoundInArchive(archive: cloudArchive)
        }

        try FileManager.default.moveItem(atPath: "\(tempDir)/\(raw)", toPath: destPath)
    }

    // MARK: - Public: cidata ISO

    /// Generate a NoCloud cidata seed ISO at `outputPath`. The VM picks
    /// it up at first boot, creates the dev user with `sshPubKey`, grows
    /// the rootfs to fill the disk we just extended, and starts sshd.
    ///
    /// `localHostname` is the temporary hostname cloud-init sets. The
    /// bootstrap renames it to `mpd-<NNN>` when step 30 runs.
    ///
    /// `networkConfig`, if provided, becomes the cidata's
    /// `network-config` file (cloud-init v2 ethernets/etc.). UTM uses
    /// this to pin the canonical static IP from boot one — bypasses the
    /// DHCP→step-30 dance the clone flow needs. Pass nil to omit the
    /// file entirely (cloud-init falls back to DHCP).
    static func makeCidataISO(
        outputPath: String,
        username: String,
        sshPubKey: String,
        localHostname: String,
        networkConfig: String? = nil
    ) throws {
        let workDir = NSTemporaryDirectory() + "mpd-virt-cidata-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: workDir) }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: workDir),
            withIntermediateDirectories: true
        )

        let meta = """
        instance-id: \(localHostname)
        local-hostname: \(localHostname)
        """
        try meta.write(
            toFile: "\(workDir)/meta-data",
            atomically: true, encoding: .utf8
        )

        // `users:` overrides cloud-init's defaults (which would create a
        // `debian` user). We want only the dev user.
        // `lock_passwd: true` means no shadow password — SSH key auth
        // is the only way in, which matches the bootstrap's invariants.
        // `sudo: ALL=(ALL) NOPASSWD:ALL` makes bootstrap step 10 a
        // no-op verification rather than an actual config change.
        let userData = """
        #cloud-config
        hostname: \(localHostname)
        manage_etc_hosts: true

        users:
          - name: \(username)
            sudo: ALL=(ALL) NOPASSWD:ALL
            shell: /bin/bash
            lock_passwd: true
            ssh_authorized_keys:
              - \(sshPubKey)

        ssh_pwauth: false

        growpart:
          mode: auto
          devices: ['/']

        resize_rootfs: true

        runcmd:
          - systemctl enable --now ssh
        """
        try userData.write(
            toFile: "\(workDir)/user-data",
            atomically: true, encoding: .utf8
        )

        if let networkConfig = networkConfig {
            try networkConfig.write(
                toFile: "\(workDir)/network-config",
                atomically: true, encoding: .utf8
            )
        }

        // hdiutil makehybrid with volume label "cidata" — the NoCloud
        // datasource looks for exactly that label.
        let parent = (outputPath as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: parent), withIntermediateDirectories: true
            )
        }
        try? FileManager.default.removeItem(atPath: outputPath)

        let r = try MpdVirt.Host.Ssh.runProcess(argv: [
            "/usr/bin/hdiutil", "makehybrid",
            "-o", outputPath,
            "-iso", "-joliet",
            "-default-volume-name", "cidata",
            workDir
        ])
        if !r.ok {
            throw Failure.hdiutilFailed(
                exitCode: r.exitCode,
                stderr: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    // MARK: - Internals

    private static func ensureCacheDir() throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: imageCacheDir),
            withIntermediateDirectories: true
        )
    }
}
