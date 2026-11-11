import Foundation

/// A constructed scenario: four agents on one Mac with Time Machine on. The
/// 5.7 GB fixture and the 500-600 GB free-space buffer come from Fatbobman's
/// Swift Weekly #160. The run cadence, the 50 GB floor, the quotas and the
/// UDIDs are made up for the demo.
public enum Sample {
    public static let agents: [AgentID] = ["agent-1", "agent-2", "agent-3", "agent-4"]

    /// 550 GB free (the middle of Fatbobman's 500-600 GB), 50 GB kept for macOS.
    public static let host = HostProfile(
        freeBytes: Bytes.gb(550),
        floorBytes: Bytes.gb(50),
        maxBootedSimulators: 4,
        timeMachineSnapshots: true
    )

    public static let repo = path("~/src/App")
    public static let bootedUDID = "B007ED00-0000-4000-8000-000000000000"

    /// A fake but well-formed UDID per agent: agent-1 gets 11111111-..., and so on.
    public static func udid(for index: Int) -> String {
        let d = String((index + 1) % 10)
        let block = { (n: Int) in String(repeating: d, count: n) }
        return "\(block(8))-\(block(4))-4\(block(3))-8\(block(3))-\(block(12))"
    }

    public enum Setup: String, CaseIterable, Sendable, Identifiable {
        /// One worktree per agent and nothing else: the common setup today.
        case worktreesOnly
        /// Worktree, DerivedData inside it, and a simulator per agent that is
        /// deleted at teardown: the build side is handled, the disk side isn't.
        case worktreeAndSimulator
        /// All six fields: its own APFS volume with a quota, outside Time
        /// Machine, deleted with everything else when the task ends.
        case envelope

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .worktreesOnly: return "Worktrees only"
            case .worktreeAndSimulator: return "+ Simulator"
            case .envelope: return "Envelope"
            }
        }
    }

    public static func envelopes(_ setup: Setup) -> [ExecutionEnvelope] {
        agents.enumerated().map { index, agent in
            switch setup {
            case .worktreesOnly:
                return ExecutionEnvelope(
                    agent: agent,
                    worktree: path("~/src/App-\(agent)"),
                    teardown: [.worktree]
                )
            case .worktreeAndSimulator:
                let worktree = path("~/src/App-\(agent)")
                return ExecutionEnvelope(
                    agent: agent,
                    worktree: worktree,
                    derivedData: worktree.appending(".build")?.appending("dd"),
                    simulator: .dedicated(udid: udid(for: index)),
                    teardown: [.worktree, .simulator]
                )
            case .envelope:
                let volume = ScratchVolume.dedicated(name: agent.rawValue, quotaBytes: Bytes.gb(100), inTimeMachine: false)
                let mount = path("/Volumes/\(agent)")
                return ExecutionEnvelope(
                    agent: agent,
                    worktree: mount.appending("worktree"),
                    derivedData: mount.appending("DerivedData"),
                    simulator: .dedicated(udid: udid(for: index)),
                    tempRoot: mount.appending("tmp"),
                    scratch: volume,
                    teardown: .everything
                )
            }
        }
    }

    // MARK: Disk runway

    /// Each QA run unpacks a 5.7 GB fixture that nothing deletes; each agent
    /// runs QA every 15 minutes.
    public static let leak = LeakProfile(bytesPerRun: Bytes.gb(5.7), runsPerAgentPerHour: 4)

    public struct RunwayCase: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let host: HostProfile
        public let policy: DiskPolicy
    }

    public static let runwayCases: [RunwayCase] = [
        RunwayCase(id: "none", title: "No envelope, 550 GB free", host: host, policy: .none),
        RunwayCase(id: "bigger-disk", title: "No envelope, 1.1 TB free",
                   host: HostProfile(freeBytes: Bytes.gb(1_100), floorBytes: Bytes.gb(50),
                                     maxBootedSimulators: 4, timeMachineSnapshots: true),
                   policy: .none),
        RunwayCase(id: "quota", title: "100 GB quota, no teardown", host: host,
                   policy: DiskPolicy(perAgentQuotaBytes: Bytes.gb(100))),
        RunwayCase(id: "envelope", title: "Quota + teardown each task", host: host,
                   policy: DiskPolicy(perAgentQuotaBytes: Bytes.gb(100), teardownEveryRuns: 4)),
    ]

    public static func runway(_ c: RunwayCase, hours: Int = 12) -> RunwayResult {
        DiskRunway.simulate(host: c.host, agents: agents.count, leak: leak, policy: c.policy, hours: hours)
    }

    // MARK: Verification replays (two agents, after Amarildo Lucas's experiment)

    public static let bundleID = "com.example.WeatherApp"

    public enum Replay: String, CaseIterable, Sendable, Identifiable {
        /// Both agents report green and nobody reads back what is installed.
        case greenBuildsOnly
        /// Stamped 111 and 222, one booted simulator, both read the installed build.
        case sharedSimulator
        /// Same, but neither build was stamped: both are version 1.
        case defaultStamps
        /// Each agent on its own simulator with its own stamp.
        case envelope

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .greenBuildsOnly: return "No check"
            case .sharedSimulator: return "Shared sim"
            case .defaultStamps: return "Version 1"
            case .envelope: return "Envelope"
            }
        }
    }

    public static func replay(_ r: Replay) -> (receipts: [BuildReceipt], checks: [LaunchCheck]) {
        let a: AgentID = "agent-1", b: AgentID = "agent-2"
        switch r {
        case .greenBuildsOnly:
            return ([BuildReceipt(agent: a, bundleID: bundleID, stamp: "111", simulatorUDID: bootedUDID),
                     BuildReceipt(agent: b, bundleID: bundleID, stamp: "222", simulatorUDID: bootedUDID)], [])
        case .sharedSimulator:
            return ([BuildReceipt(agent: a, bundleID: bundleID, stamp: "111", simulatorUDID: bootedUDID),
                     BuildReceipt(agent: b, bundleID: bundleID, stamp: "222", simulatorUDID: bootedUDID)],
                    [LaunchCheck(agent: a, simulatorUDID: bootedUDID, bundleID: bundleID, installedStamp: "222"),
                     LaunchCheck(agent: b, simulatorUDID: bootedUDID, bundleID: bundleID, installedStamp: "222")])
        case .defaultStamps:
            return ([BuildReceipt(agent: a, bundleID: bundleID, stamp: "1", simulatorUDID: bootedUDID),
                     BuildReceipt(agent: b, bundleID: bundleID, stamp: "1", simulatorUDID: bootedUDID)],
                    [LaunchCheck(agent: a, simulatorUDID: bootedUDID, bundleID: bundleID, installedStamp: "1"),
                     LaunchCheck(agent: b, simulatorUDID: bootedUDID, bundleID: bundleID, installedStamp: "1")])
        case .envelope:
            let simA = udid(for: 0), simB = udid(for: 1)
            return ([BuildReceipt(agent: a, bundleID: bundleID, stamp: "111", simulatorUDID: simA),
                     BuildReceipt(agent: b, bundleID: bundleID, stamp: "222", simulatorUDID: simB)],
                    [LaunchCheck(agent: a, simulatorUDID: simA, bundleID: bundleID, installedStamp: "111"),
                     LaunchCheck(agent: b, simulatorUDID: simB, bundleID: bundleID, installedStamp: "222")])
        }
    }

    public static let contractOptions = ContractOptions(
        project: "WeatherApp.xcodeproj", scheme: "WeatherApp", bundleID: bundleID, buildStamp: "2002"
    )

    // MARK: -

    /// Sample paths are literals, so a parse failure is a typo in this file.
    /// It falls back to "/" rather than trapping; a test checks every sample path.
    static func path(_ raw: String) -> EnvelopePath {
        EnvelopePath(raw) ?? .root
    }
}
