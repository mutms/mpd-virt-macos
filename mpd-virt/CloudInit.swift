// mpd-virt — Cloud-init image cache + NoCloud seed ISO generation.
//
// Shared by backends that materialize a Debian VM from a cloud image
// (Parallels create; UTM create later). The flow is:
//
//   1. ensureBaseRawImage() — download Debian generic-cloud .tar.xz into
//      ~/.mpd-virt/conf/cloud-images/ on first use, extract once, leave
//      the raw disk in place. Subsequent VMs reuse the cached file.
//
//   2. makeCidataISO(...) — write meta-data + user-data for a single VM
//      into a temp dir, then `hdiutil makehybrid` it into an ISO with
//      the volume label `cidata` that cloud-init's NoCloud datasource
//      picks up at first boot.
//
// We deliberately do NOT emit a `network-config` file — the VM comes up
// on DHCP from Parallels Shared, gets some IP in 10.211.55.x, and
// bootstrap step `30-networking.sh <NNN>` later pins the canonical
// static IP. Same path as the clone-from-template flow; no second code
// path to maintain.
//
// The URL pin matches mpd/setup/linux/lib/common.sh (and the historical
// mpd/setup/macos-utm one). When Debian publishes a new daily, bump both
// in lockstep. Users who want a different image can drop their own .raw
// at the canonical cache path.

import Foundation

extension MpdVirt.CloudInit {

    // MARK: - Image source

    /// Debian Trixie generic-cloud, arm64. Same pin as
    /// mpd/setup/linux/lib/common.sh (just the arm64 archive instead of
    /// amd64) — bump them together when refreshing.
    static let cloudBase = "https://cloud.debian.org/images/cloud/trixie/20260501-2465"
    static let cloudArchive = "debian-13-genericcloud-arm64-20260501-2465.tar.xz"

    /// Canonical local name we resolve `.tar.xz` extraction to. Stable
    /// across Debian dailies so users can drop their own raw image here
    /// and the create flow picks it up untouched.
    static let canonicalRawName = "debian-13-genericcloud-arm64.raw"

    /// Where the cached cloud image lives:
    /// `~/.mpd-virt/conf/cloud-images/`.
    static var imageCacheDir: String { "\(MpdVirt.confDir)/cloud-images" }

    /// Absolute path to the canonical cached raw disk.
    static var canonicalRawPath: String { "\(imageCacheDir)/\(canonicalRawName)" }

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

    // MARK: - Public: cached raw image

    /// Ensure a Debian generic-cloud raw disk is on the host at
    /// `canonicalRawPath`. Returns the path. Idempotent: a second call
    /// with the same cache state is instant.
    ///
    /// Flow when the cache is cold:
    ///   curl <cloudBase>/<cloudArchive> → <imageCacheDir>/<archive>
    ///   tar -xJf <archive>              → <imageCacheDir>/disk.raw (or similar)
    ///   mv <whatever-came-out>          → <canonicalRawPath>
    ///
    /// Users who pre-stage a different raw image at `canonicalRawPath`
    /// short-circuit the download entirely (just exists-check passes).
    @discardableResult
    static func ensureBaseRawImage() throws -> String {
        try ensureCacheDir()

        if FileManager.default.fileExists(atPath: canonicalRawPath) {
            return canonicalRawPath
        }

        let archivePath = "\(imageCacheDir)/\(cloudArchive)"
        let url = "\(cloudBase)/\(cloudArchive)"

        if !FileManager.default.fileExists(atPath: archivePath) {
            FileHandle.standardError.write(Data("  ▶ downloading \(cloudArchive) (~200 MB) …\n".utf8))
            let r = try MpdVirt.Host.Ssh.runProcess(argv: [
                "/usr/bin/curl", "-L", "--fail", "--progress-bar",
                "-o", archivePath,
                url
            ])
            if !r.ok {
                try? FileManager.default.removeItem(atPath: archivePath)
                throw Failure.downloadFailed(url: url, exitCode: r.exitCode)
            }
        } else {
            FileHandle.standardError.write(Data("  ▶ using cached archive: \(cloudArchive)\n".utf8))
        }

        // Clear stale .raw artifacts so the freshly-extracted file is
        // unambiguous (Debian's archive layout varies by release).
        try clearStaleRaws()

        FileHandle.standardError.write(Data("  ▶ extracting \(cloudArchive) …\n".utf8))
        let extracted = try MpdVirt.Host.Ssh.runProcess(argv: [
            "/usr/bin/tar", "-xJf", archivePath, "-C", imageCacheDir
        ])
        if !extracted.ok {
            throw Failure.extractFailed(archive: cloudArchive, exitCode: extracted.exitCode)
        }

        // Find whatever raw came out and rename to canonical.
        guard let rawFile = try locateExtractedRaw() else {
            throw Failure.rawNotFoundInArchive(archive: cloudArchive)
        }
        if rawFile != canonicalRawPath {
            do {
                try FileManager.default.moveItem(atPath: rawFile, toPath: canonicalRawPath)
            } catch {
                throw Failure.ioFailed("could not rename \(rawFile) → \(canonicalRawPath): \(error)")
            }
        }

        FileHandle.standardError.write(Data("  ✓ raw image ready: \(canonicalRawPath)\n".utf8))
        return canonicalRawPath
    }

    /// Copy the cached raw to `destPath` and sparse-extend it to
    /// `targetGiB`. Refuses to shrink (`dd seek=` only grows). Throws
    /// when the target is smaller than the source. The copy is a plain
    /// byte-for-byte cp; the extend is `dd if=/dev/zero count=0 seek=<bytes>`
    /// — the trailing seek creates a sparse file, so we don't physically
    /// allocate the extra space on disk.
    static func materializePerVMDisk(destPath: String, targetGiB: Int) throws {
        try ensureBaseRawImage()

        let parent = (destPath as NSString).deletingLastPathComponent
        if !parent.isEmpty {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: parent), withIntermediateDirectories: true
            )
        }

        // Refuse to clobber. Caller is responsible for cleaning up
        // failed-creates before retry.
        if FileManager.default.fileExists(atPath: destPath) {
            throw Failure.ioFailed("destination disk already exists: \(destPath)")
        }

        FileHandle.standardError.write(Data("  ▶ copying base disk → \(destPath) …\n".utf8))
        let cp = try MpdVirt.Host.Ssh.runProcess(argv: ["/bin/cp", canonicalRawPath, destPath])
        if !cp.ok {
            throw Failure.ioFailed("cp \(canonicalRawPath) → \(destPath) failed (exit \(cp.exitCode)).")
        }

        // Check source size against target before extending.
        let attrs = try FileManager.default.attributesOfItem(atPath: destPath)
        let currentBytes = (attrs[.size] as? Int) ?? 0
        let targetBytes = targetGiB * 1024 * 1024 * 1024
        if targetBytes < currentBytes {
            try? FileManager.default.removeItem(atPath: destPath)
            throw Failure.ioFailed("""
                requested disk size \(targetGiB) GB is smaller than the cloud image \
                (\(currentBytes / (1024*1024*1024)) GB). Pick a larger --vm-disk.
                """)
        }

        if targetBytes > currentBytes {
            FileHandle.standardError.write(Data("  ▶ growing disk to \(targetGiB) GB (sparse) …\n".utf8))
            // `dd if=/dev/zero of=<f> bs=1 count=0 seek=<bytes>` extends
            // the file by seeking — no data written, the OS materializes
            // a sparse hole.
            let dd = try MpdVirt.Host.Ssh.runProcess(argv: [
                "/bin/dd", "if=/dev/zero", "of=\(destPath)",
                "bs=1", "count=0", "seek=\(targetBytes)"
            ])
            if !dd.ok {
                throw Failure.ioFailed("dd resize failed (exit \(dd.exitCode)).")
            }
        }
    }

    // MARK: - Public: cidata ISO

    /// Generate a NoCloud cidata seed ISO at `outputPath`. The VM picks
    /// it up at first boot, creates the dev user with `sshPubKey`, grows
    /// the rootfs to fill the disk we just extended, and starts sshd.
    ///
    /// We intentionally **do not** emit `network-config`: the VM boots
    /// on DHCP from Parallels Shared and `30-networking.sh` later pins
    /// the canonical static IP. Matches the clone-from-template flow so
    /// there's one networking code path.
    ///
    /// `localHostname` is the temporary hostname cloud-init sets. The
    /// bootstrap renames it to `mpd-<NNN>` when step 30 runs.
    static func makeCidataISO(
        outputPath: String,
        username: String,
        sshPubKey: String,
        localHostname: String
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

    /// Delete leftover .raw / disk.* files in the cache dir before a
    /// fresh extract, so `locateExtractedRaw` finds exactly one match.
    /// Spares the canonical raw itself — that's the cache we want to
    /// keep.
    private static func clearStaleRaws() throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: imageCacheDir)
        for name in entries {
            if name == canonicalRawName { continue }
            if name.hasSuffix(".raw") || name.hasPrefix("disk.") {
                try? fm.removeItem(atPath: "\(imageCacheDir)/\(name)")
            }
        }
    }

    /// Find the .raw the most recent tar -xJf produced. Debian's
    /// archive currently extracts a `disk.raw` but we tolerate any
    /// `*.raw` for forward-compat.
    private static func locateExtractedRaw() throws -> String? {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: imageCacheDir)
        for name in entries {
            if name == canonicalRawName { continue }
            if name.hasSuffix(".raw") || name.hasPrefix("disk.") {
                return "\(imageCacheDir)/\(name)"
            }
        }
        return nil
    }
}
