import Foundation

/// Identifies one coding agent session.
public struct AgentID: Hashable, Sendable, Comparable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }
    public static func < (lhs: AgentID, rhs: AgentID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The six fields of an execution envelope. Each one is something parallel
/// agents on one Mac share unless the harness gives every agent its own.
public enum Field: String, CaseIterable, Sendable, Comparable {
    case worktree
    case derivedData
    case simulator
    case tempRoot
    case scratchVolume
    case teardown

    public var title: String {
        switch self {
        case .worktree: return "Worktree"
        case .derivedData: return "DerivedData"
        case .simulator: return "Simulator"
        case .tempRoot: return "Temp root"
        case .scratchVolume: return "Scratch volume"
        case .teardown: return "Teardown"
        }
    }

    public static func < (lhs: Field, rhs: Field) -> Bool {
        guard let l = allCases.firstIndex(of: lhs), let r = allCases.firstIndex(of: rhs) else { return false }
        return l < r
    }
}

/// Which simulator an agent installs on.
public enum SimulatorBinding: Hashable, Sendable {
    /// The task names no simulator, so the agent uses whichever one is already booted.
    case whateverIsBooted
    /// A simulator created for this agent and named by UDID wherever the agent
    /// builds, installs or launches.
    case dedicated(udid: String)

    public var udid: String? {
        if case .dedicated(let udid) = self { return udid }
        return nil
    }

    /// A dedicated binding whose UDID is a real UUID. Anything else (say,
    /// `"all"` or `"booted"`) would make `xcrun simctl` act on simulators
    /// that aren't this agent's.
    public var hasValidUDID: Bool { normalizedUDID != nil }

    /// The UDID in canonical upper-case form, or `nil` if it isn't a UUID.
    /// `simctl` accepts either case, so comparisons go through this.
    public var normalizedUDID: String? {
        udid.flatMap(UDID.normalized)
    }
}

enum UDID {
    /// Canonical upper-case form of a UUID string, or `nil` if it isn't one.
    static func normalized(_ raw: String) -> String? {
        UUID(uuidString: raw)?.uuidString
    }

    /// The canonical form when there is one, otherwise the string as given,
    /// so two spellings of the same simulator compare equal.
    static func key(_ raw: String) -> String {
        normalized(raw) ?? raw
    }
}

/// Where an agent's high-churn data (DerivedData, temp files, unpacked fixtures) lands.
public enum ScratchVolume: Hashable, Sendable {
    /// The Mac's Data volume: free space shared with everything else, no cap,
    /// and included in Time Machine's hourly local snapshots when automatic
    /// backups are on. APFS snapshots are whole-volume, so a folder exclusion
    /// keeps data out of backups but not out of local snapshots.
    case system
    /// A separate APFS volume. `quotaBytes` is the most it can grow to (APFS
    /// only lets you set a quota when the volume is created). `inTimeMachine`
    /// says whether Time Machine backs it up, and so snapshots it hourly.
    case dedicated(name: String, quotaBytes: Int64, inTimeMachine: Bool)

    /// Mount point of a dedicated volume. `nil` for the Data volume, and for
    /// a name that can't be a single path component (empty, `.`, `..` or one
    /// containing `/`).
    ///
    /// This assumes the name is free. If a stale volume already has it, macOS
    /// mounts the new one as `/Volumes/<name> 1`, so a harness should check
    /// the mount point (or keep the UUID `addVolume` prints) before handing
    /// the envelope to an agent.
    public var mountPoint: EnvelopePath? {
        guard case .dedicated(let name, _, _) = self else { return nil }
        return EnvelopePath("/Volumes")?.appending(name)
    }

    public var quotaBytes: Int64? {
        guard case .dedicated(_, let quota, _) = self else { return nil }
        return quota
    }
}

/// What the harness deletes when the agent's task ends, whatever the agent did.
///
/// The teardown field is owned when nothing the agent writes outlives the
/// task: no field falls back to a shared default (the user's `$TMPDIR`,
/// Xcode's default DerivedData), and the harness deletes the rest.
public struct Teardown: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `git worktree remove`
    public static let worktree = Teardown(rawValue: 1 << 0)
    /// Delete the agent's DerivedData folder.
    public static let derivedData = Teardown(rawValue: 1 << 1)
    /// Delete the agent's temp root.
    public static let tempRoot = Teardown(rawValue: 1 << 2)
    /// `xcrun simctl delete` the agent's simulator.
    public static let simulator = Teardown(rawValue: 1 << 3)
    /// Delete the agent's dedicated APFS volume.
    public static let scratchVolume = Teardown(rawValue: 1 << 4)

    public static let everything: Teardown = [.worktree, .derivedData, .tempRoot, .simulator, .scratchVolume]
}

/// Everything one agent may write to on a shared Mac.
///
/// A `nil` path means "not set", and an agent fills an unset field with
/// whatever is already there: the shared checkout, Xcode's default DerivedData,
/// the user's `$TMPDIR`, the booted simulator.
public struct ExecutionEnvelope: Hashable, Sendable, Identifiable {
    public var agent: AgentID
    /// `nil`: the agent works in the shared checkout.
    public var worktree: EnvelopePath?
    /// `nil`: Xcode's default, `~/Library/Developer/Xcode/DerivedData/<Project>-<hash>`.
    /// The hash comes from the project's path, so each worktree gets its own
    /// folder, but that folder is outside the worktree and outlives it.
    public var derivedData: EnvelopePath?
    public var simulator: SimulatorBinding
    /// `nil`: the user's shared `$TMPDIR`.
    public var tempRoot: EnvelopePath?
    public var scratch: ScratchVolume
    public var teardown: Teardown

    public var id: AgentID { agent }

    public init(
        agent: AgentID,
        worktree: EnvelopePath? = nil,
        derivedData: EnvelopePath? = nil,
        simulator: SimulatorBinding = .whateverIsBooted,
        tempRoot: EnvelopePath? = nil,
        scratch: ScratchVolume = .system,
        teardown: Teardown = []
    ) {
        self.agent = agent
        self.worktree = worktree
        self.derivedData = derivedData
        self.simulator = simulator
        self.tempRoot = tempRoot
        self.scratch = scratch
        self.teardown = teardown
    }

    /// True when `path` is inside this agent's worktree, so removing the
    /// worktree removes it too.
    func isInsideWorktree(_ path: EnvelopePath) -> Bool {
        guard let worktree else { return false }
        return worktree.contains(path)
    }

    /// True when the harness deletes `path` at teardown: it is explicitly torn
    /// down, it sits inside a worktree that is torn down, or it sits on a
    /// dedicated volume that is deleted.
    func tearsDown(_ path: EnvelopePath, as own: Teardown) -> Bool {
        if teardown.contains(own) { return true }
        if teardown.contains(.worktree), isInsideWorktree(path) { return true }
        if teardown.contains(.scratchVolume), let mount = scratch.mountPoint, mount.contains(path) { return true }
        return false
    }
}

/// The Mac the agents share.
public struct HostProfile: Hashable, Sendable {
    /// Free space on the Data volume, in bytes.
    public var freeBytes: Int64
    /// Space that must stay free for macOS itself (swap, updates, other apps).
    public var floorBytes: Int64
    /// How many simulators this Mac can keep booted at once without thrashing.
    public var maxBootedSimulators: Int
    /// "Back Up Automatically" is on, so Time Machine takes hourly local
    /// snapshots of every APFS volume it backs up.
    public var timeMachineSnapshots: Bool

    public init(freeBytes: Int64, floorBytes: Int64, maxBootedSimulators: Int, timeMachineSnapshots: Bool) {
        self.freeBytes = freeBytes
        self.floorBytes = floorBytes
        self.maxBootedSimulators = maxBootedSimulators
        self.timeMachineSnapshots = timeMachineSnapshots
    }

    /// Bytes the agents can use before macOS is squeezed. Never negative,
    /// and saturates instead of overflowing on extreme inputs.
    public var headroomBytes: Int64 {
        let (difference, overflow) = freeBytes.subtractingReportingOverflow(floorBytes)
        if overflow { return floorBytes < 0 ? .max : 0 }
        return max(0, difference)
    }
}

/// Decimal units, the way disk sizes are sold.
public enum Bytes {
    /// Gigabytes to bytes, rounded to the nearest byte. NaN becomes 0 and
    /// anything outside `Int64`'s range is clamped, so this never traps.
    public static func gb(_ value: Double) -> Int64 {
        let bytes = (value * 1_000_000_000).rounded()
        guard !bytes.isNaN else { return 0 }
        let twoToThe63 = 9_223_372_036_854_775_808.0 // the first Double past Int64.max
        if bytes >= twoToThe63 { return .max }
        if bytes < -twoToThe63 { return .min }
        return Int64(exactly: bytes) ?? 0
    }

    /// "550 GB", "475.9 GB". Whole numbers drop the decimal; everything else
    /// keeps one, so a minimum like 475.9 GB is never rounded up to 476.
    public static func format(_ bytes: Int64) -> String {
        let tenths = (Double(bytes) / 100_000_000).rounded(.down) / 10
        if tenths == tenths.rounded() { return String(format: "%.0f GB", tenths) }
        return String(format: "%.1f GB", tenths)
    }
}
