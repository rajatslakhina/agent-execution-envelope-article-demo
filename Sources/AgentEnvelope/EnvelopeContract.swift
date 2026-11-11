import Foundation

public struct ContractError: Error, Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        /// Fields the agent would fill with shared defaults: the instructions
        /// can't be written until the harness binds them.
        case unbound([Field])
        /// A teardown would `rm -rf` or delete something outside an agent's envelope.
        case unsafeDelete(String)
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
/// from the same value the audit checks, so they can't drift apart.
public enum EnvelopeContract {
    /// Fields an agent's instructions must name. Teardown isn't one of them:
    /// the harness runs it, not the agent.
    public static func unboundFields(_ e: ExecutionEnvelope) -> [Field] {
        var missing: [Field] = []
        if e.worktree == nil { missing.append(.worktree) }
        if e.derivedData == nil { missing.append(.derivedData) }
        if e.simulator.udid == nil { missing.append(.simulator) }
        if e.tempRoot == nil { missing.append(.tempRoot) }
        if (e.scratch.quotaBytes ?? 0) <= 0 { missing.append(.scratchVolume) }
        return missing
    }

    /// The AGENTS.md section for one agent. Throws if any field is unbound,
    /// because an agent fills an unbound field with whatever is already there.
    public static func agentsSection(for e: ExecutionEnvelope, options o: ContractOptions) throws -> String {
        let missing = unboundFields(e)
        guard missing.isEmpty,
              let worktree = e.worktree, let dd = e.derivedData, let udid = e.simulator.udid,
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
        - Use only the simulator with UDID `\(udid)`. Don't boot, erase or install on any other simulator.
        - Put temporary files only under `$TMPDIR`, which is `\(tmp)`. Delete what you create.
        - Your disk budget is \(Bytes.format(quota)). If a write fails for lack of space, stop and report it. Don't delete anything outside your envelope to make room.
        - A green build is not verification. After launching the app, run `\(check)` and confirm CFBundleVersion is `\(o.buildStamp)` before you report success.

        \(teardownSentence(for: e))
        """
    }

    /// Shell commands the harness runs when the task ends, in order.
    public static func teardownCommands(for e: ExecutionEnvelope, repo: EnvelopePath) throws -> [String] {
        var commands: [String] = []
        if e.teardown.contains(.simulator), let udid = e.simulator.udid {
            commands.append("xcrun simctl delete \(shellQuote(udid))")
        }
        if e.teardown.contains(.worktree), let worktree = e.worktree {
            commands.append("git -C \(shellQuote(repo)) worktree remove --force \(shellQuote(worktree))")
        }
        let volumeGoes = e.teardown.contains(.scratchVolume) && e.scratch.mountPoint != nil
        for (flag, path) in [(Teardown.derivedData, e.derivedData), (Teardown.tempRoot, e.tempRoot)] {
            guard e.teardown.contains(flag), let path else { continue }
            if e.teardown.contains(.worktree), e.isInsideWorktree(path) { continue }
            if volumeGoes, let mount = e.scratch.mountPoint, mount.contains(path) { continue }
            guard isSafeToDelete(path) else { throw ContractError(reason: .unsafeDelete(path.description)) }
            commands.append("rm -rf \(shellQuote(path))")
        }
        if volumeGoes, case .dedicated(let name, _, _) = e.scratch, let mount = e.scratch.mountPoint {
            guard !systemVolumeNames.contains(name.lowercased()) else {
                throw ContractError(reason: .unsafeDelete(mount.description))
            }
            commands.append("diskutil apfs deleteVolume \(shellQuote(mount))")
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

    /// Paths an `rm -rf` must never touch, or contain.
    private static let protected: [EnvelopePath] = [
        "/", "~", "/Users", "/Volumes", "/tmp", "/private", "/private/tmp", "/private/var", "/var",
        "/System", "/Library", "/Applications", "~/Library", "~/Library/Developer",
        "~/Library/Developer/Xcode", "~/Library/Developer/Xcode/DerivedData",
        "~/Library/Developer/CoreSimulator", "~/Documents", "~/Desktop", "~/Downloads", "~/Developer",
    ].compactMap { EnvelopePath($0) }

    private static let systemVolumeNames: Set<String> = [
        "macintosh hd", "macintosh hd - data", "data", "preboot", "recovery", "vm", "update",
    ]

    /// Deep enough to be one agent's folder, and not an ancestor of anything shared.
    static func isSafeToDelete(_ path: EnvelopePath) -> Bool {
        let onVolume = path.components.first == "Volumes"
        guard path.components.count >= (onVolume ? 3 : 4) else { return false }
        return !protected.contains { path.contains($0) }
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
