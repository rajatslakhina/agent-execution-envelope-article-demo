import Foundation

public struct ContractError: Error, Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// Fields the agent would fill with shared defaults: the instructions
        /// can't be written until the harness binds them.
        case unbound([Field])
        /// A teardown would `rm -rf` a path that isn't strictly inside this
        /// agent's own scratch volume or the agents root.
        case unsafeDelete(String)
        /// A teardown would hand `xcrun simctl delete` something that isn't a UUID.
        case invalidSimulatorUDID(String)
    }
    public let reason: Reason
}

/// What the agent's instructions need to know about the project.
public struct ContractOptions: Hashable, Sendable {
    public var project: String
    public var scheme: String
    public var bundleID: String
    /// The harness's per-build stamp, passed as `CURRENT_PROJECT_VERSION`.
    public var buildStamp: String

    public init(project: String, scheme: String, bundleID: String, buildStamp: String) {
        self.project = project
        self.scheme = scheme
        self.bundleID = bundleID
        self.buildStamp = buildStamp
    }
}

/// Renders the envelope into the two places it has to live: the agent's
/// instructions (an AGENTS.md section) and the harness's teardown. Both come
/// from the same value the audit checks, so the instructions can't name a
/// path or simulator the audit hasn't seen.
public enum EnvelopeContract {
    /// Fields the agent's instructions must name. Teardown isn't one of them:
    /// the harness runs it, not the agent.
    public static func unboundFields(_ e: ExecutionEnvelope) -> [Field] {
        var missing: [Field] = []
        if e.worktree == nil { missing.append(.worktree) }
        if e.derivedData == nil { missing.append(.derivedData) }
        if !e.simulator.hasValidUDID { missing.append(.simulator) }
        if e.tempRoot == nil { missing.append(.tempRoot) }
        if (e.scratch.quotaBytes ?? 0) <= 0 || e.scratch.mountPoint == nil { missing.append(.scratchVolume) }
        return missing
    }

    /// The AGENTS.md section for one agent. Throws while any field the agent
    /// needs is unbound, because an agent fills an unbound field with whatever
    /// is already there.
    public static func agentsSection(for e: ExecutionEnvelope, options o: ContractOptions) throws -> String {
        let missing = unboundFields(e)
        guard missing.isEmpty,
              let worktree = e.worktree, let dd = e.derivedData, let udid = e.simulator.normalizedUDID,
              let tmp = e.tempRoot, let quota = e.scratch.quotaBytes else {
            throw ContractError(reason: .unbound(missing))
        }
        let build = "xcodebuild -project \(shellQuote(o.project)) -scheme \(shellQuote(o.scheme)) "
            + "-destination \(shellQuote("platform=iOS Simulator,id=\(udid)")) "
            + "-derivedDataPath \(shellQuote(dd)) CURRENT_PROJECT_VERSION=\(shellQuote(o.buildStamp))"
        let check = "xcrun simctl appinfo \(shellQuote(udid)) \(shellQuote(o.bundleID))"
        return """
        ## Execution envelope: \(e.agent)

        Other agents share this Mac. Stay inside your envelope.

        - Work only in `\(worktree)`. Don't read or write any other checkout.
        - Build and test only with this destination and DerivedData path:
          `\(build)`
        - Your simulator's UDID is `\(udid)`. Boot, install and launch there and nowhere else.
        - Put temporary files only under `$TMPDIR`, which is `\(tmp)`. Delete what you create.
        - Your disk budget is \(Bytes.format(quota)). If a write fails for lack of space, stop and report it. Don't delete anything outside your envelope to make room.
        - A green build is not verification. After launching the app, run `\(check)` and confirm CFBundleVersion is `\(o.buildStamp)` before you report success.

        \(teardownSentence(for: e))
        """
    }

    /// Shell commands the harness runs when the task ends, in order.
    ///
    /// `rm -rf` is only ever emitted for a path strictly inside this agent's
    /// own dedicated volume, or strictly inside `agentsRoot` (say,
    /// `~/agents`) when you keep envelopes in folders, and never for a path
    /// that overlaps `repo`. Anything else, however it's spelled, is refused
    /// rather than guessed at. The volume is deleted by its mount point; see
    /// `ScratchVolume.mountPoint` for the name-collision caveat.
    public static func teardownCommands(for e: ExecutionEnvelope, repo: EnvelopePath, agentsRoot: EnvelopePath? = nil) throws -> [String] {
        var commands: [String] = []
        if e.teardown.contains(.simulator), let udid = e.simulator.udid {
            guard let canonical = e.simulator.normalizedUDID else { throw ContractError(reason: .invalidSimulatorUDID(udid)) }
            // A booted simulator can't be deleted, and it usually is still booted here.
            commands.append("xcrun simctl shutdown \(shellQuote(canonical)) 2>/dev/null || true")
            commands.append("xcrun simctl delete \(shellQuote(canonical))")
        }
        if e.teardown.contains(.worktree), let worktree = e.worktree {
            commands.append("git -C \(shellQuote(repo)) worktree remove --force \(shellQuote(worktree))")
        }
        let ownMount = e.scratch.mountPoint.flatMap { isDeletableVolume($0) ? $0 : nil }
        let volumeGoes = e.teardown.contains(.scratchVolume) && ownMount != nil
        for (flag, path) in [(Teardown.derivedData, e.derivedData), (Teardown.tempRoot, e.tempRoot)] {
            guard e.teardown.contains(flag), let path else { continue }
            if e.teardown.contains(.worktree), e.isInsideWorktree(path) { continue }
            if volumeGoes, let mount = ownMount, mount.contains(path) { continue }
            guard !mayOverlap(path, repo), isSafeToDelete(path, ownMount: ownMount, agentsRoot: agentsRoot) else {
                throw ContractError(reason: .unsafeDelete(path.description))
            }
            commands.append("rm -rf \(shellQuote(path))")
        }
        if e.teardown.contains(.scratchVolume), let mount = e.scratch.mountPoint {
            guard let own = ownMount else { throw ContractError(reason: .unsafeDelete(mount.description)) }
            commands.append("diskutil apfs deleteVolume \(shellQuote(own))")
        }
        return commands
    }

    // MARK: - Helpers

    private static func teardownSentence(for e: ExecutionEnvelope) -> String {
        var parts: [String] = []
        if let w = e.worktree, e.tearsDown(w, as: .worktree) { parts.append("worktree") }
        if let d = e.derivedData, e.tearsDown(d, as: .derivedData) { parts.append("DerivedData") }
        if let t = e.tempRoot, e.tearsDown(t, as: .tempRoot) { parts.append("temp root") }
        if e.teardown.contains(.simulator), e.simulator.udid != nil { parts.append("simulator") }
        if e.teardown.contains(.scratchVolume), e.scratch.mountPoint != nil { parts.append("scratch volume") }
        guard !parts.isEmpty else {
            return "Nothing in your envelope is deleted automatically, so clean up everything you create."
        }
        if parts.count == 1, let only = parts.first {
            return "When the task ends, the harness deletes your \(only), whatever state it is in."
        }
        let joined = parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
        return "When the task ends, the harness deletes your \(joined), whatever state they are in."
    }

    /// Volumes that belong to macOS, never to an agent.
    private static let systemVolumeNames: Set<String> = [
        "macintosh hd", "macintosh hd - data", "data", "preboot", "recovery", "vm", "update", "xarts", "hardware", "isc",
    ]

    /// A `/Volumes/<name>` mount an agent may own: not one of macOS's own volumes.
    static func isDeletableVolume(_ mount: EnvelopePath) -> Bool {
        let c = lowercased(mount)
        guard c.count == 2, c.first == "volumes", let name = c.last else { return false }
        return !systemVolumeNames.contains(name)
    }

    /// Top-level folders an agents root may never be inside (lower-cased:
    /// the default APFS volume is case-insensitive, so `/library` is `/Library`).
    private static let systemTopLevel: Set<String> = [
        "system", "library", "applications", "private", "usr", "bin", "sbin", "etc", "var", "tmp", "opt", "cores", "dev", "volumes", "users",
    ]

    /// Folders in a home directory that hold the user's own things.
    private static let personalFolders: Set<String> = [
        "library", "documents", "desktop", "downloads", "movies", "music", "pictures", "public", "applications",
    ]

    /// An allow list: strictly inside this agent's own volume, or strictly
    /// inside a sane agents root. `~` and `/Users/<you>` are different roots
    /// here, so a path spelled the other way is refused, not guessed at.
    static func isSafeToDelete(_ path: EnvelopePath, ownMount: EnvelopePath?, agentsRoot: EnvelopePath?) -> Bool {
        if let mount = ownMount, isDeletableVolume(mount), mount.contains(path), !path.isSame(as: mount) { return true }
        guard let root = agentsRoot, isSaneAgentsRoot(root), root.contains(path), !path.isSame(as: root) else { return false }
        return true
    }

    /// Whether two paths could be the same place or nest, ignoring letter
    /// case. A `~` path and a `/Users/...` path can't be compared without
    /// knowing the home directory, so they count as overlapping.
    static func mayOverlap(_ a: EnvelopePath, _ b: EnvelopePath) -> Bool {
        let x = lowercased(a), y = lowercased(b)
        if (x.first == "~" && y.first == "users") || (x.first == "users" && y.first == "~") { return true }
        return x.starts(with: y) || y.starts(with: x)
    }

    /// Somewhere a lead would deliberately keep agent folders: a folder under
    /// a home directory that isn't hidden, the Library or a personal folder,
    /// or a folder on a non-system volume (never the volume itself). Never
    /// `/`, `~`, `/Users/<you>` or a system folder. Compared case-insensitively.
    static func isSaneAgentsRoot(_ root: EnvelopePath) -> Bool {
        let c = lowercased(root)
        guard c.count >= 2, let first = c.first else { return false }
        switch first {
        case "~":
            return isOrdinaryFolder(c[1])
        case "users":
            guard c.count >= 3 else { return false }
            return isOrdinaryFolder(c[2])
        case "volumes":
            guard c.count >= 3 else { return false }
            return !systemVolumeNames.contains(c[1]) && !c[2].hasPrefix(".")
        default:
            return !systemTopLevel.contains(first) && !first.hasPrefix(".")
        }
    }

    private static func isOrdinaryFolder(_ name: String) -> Bool {
        !name.hasPrefix(".") && !personalFolders.contains(name)
    }

    private static func lowercased(_ path: EnvelopePath) -> [String] {
        path.components.map { $0.lowercased() }
    }

    /// Single-quotes for the shell. A leading `~` becomes `"$HOME"` so it still expands.
    static func shellQuote(_ path: EnvelopePath) -> String {
        if path.components.first == "~" {
            let rest = path.components.dropFirst().joined(separator: "/")
            return rest.isEmpty ? "\"$HOME\"" : "\"$HOME\"" + shellQuote("/" + rest)
        }
        return shellQuote(path.description)
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
