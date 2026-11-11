import Foundation

/// What an agent built and where it installed it.
public struct BuildReceipt: Hashable, Sendable {
    public let agent: AgentID
    public let bundleID: String
    /// A stamp unique to this build, such as `CURRENT_PROJECT_VERSION` set by
    /// the harness. Every worktree builds the same version number unless
    /// something changes it per agent.
    public let stamp: String
    public let simulatorUDID: String

    public init(agent: AgentID, bundleID: String, stamp: String, simulatorUDID: String) {
        self.agent = agent
        self.bundleID = bundleID
        self.stamp = stamp
        self.simulatorUDID = simulatorUDID
    }
}

/// What an agent read back from the installed app after launching it.
public struct LaunchCheck: Hashable, Sendable {
    public let agent: AgentID
    public let simulatorUDID: String
    public let bundleID: String
    /// The installed app's build number, e.g. CFBundleVersion from `xcrun simctl appinfo`.
    public let installedStamp: String

    public init(agent: AgentID, simulatorUDID: String, bundleID: String, installedStamp: String) {
        self.agent = agent
        self.simulatorUDID = simulatorUDID
        self.bundleID = bundleID
        self.installedStamp = installedStamp
    }
}

public enum Verdict: Hashable, Sendable {
    /// The app this agent launched is the build it made, on a simulator no
    /// other agent installed to.
    case verified
    /// The build succeeded, but nobody launched the app and read back what was installed.
    case notChecked
    /// The check ran on a different simulator from the one the build went to.
    case wrongSimulator(expected: String, actual: String)
    /// The installed app is another build. `installedBy` is the agent whose
    /// receipt matches it, when exactly one does.
    case foreignBuild(installedBy: AgentID?)
    /// The installed app matches this agent's build, but another agent built
    /// the same bundle with the same stamp on the same simulator, so the check
    /// can't tell whose app it is.
    case ambiguousStamp(sharedWith: [AgentID])
    /// The installed app is this agent's build, but other agents installed on
    /// the same simulator. Reinstalling keeps an app's data, so what the app
    /// read at launch may have been written by their builds.
    case sharedSimulator(with: [AgentID])

    /// Only `.verified` lets an agent report success.
    public var counts: Bool { self == .verified }

    public var title: String {
        switch self {
        case .verified: return "Verified"
        case .notChecked: return "Not checked"
        case .wrongSimulator: return "Wrong simulator"
        case .foreignBuild(let by): return by.map { "Tested \($0)'s build" } ?? "Tested someone else's build"
        case .ambiguousStamp(let others): return "Ambiguous: same stamp as \(others.map(\.rawValue).joined(separator: ", "))"
        case .sharedSimulator(let others): return "Shared simulator with \(others.map(\.rawValue).joined(separator: ", "))"
        }
    }
}

/// "Verify against the artifact you built", as a check the harness runs
/// instead of a sentence the agent may skip.
public enum ProvenanceGate {
    /// One verdict per agent that has a receipt. When an agent has several
    /// receipts or checks, the last one of each counts.
    public static func verdicts(receipts: [BuildReceipt], checks: [LaunchCheck]) -> [AgentID: Verdict] {
        var lastReceipt: [AgentID: BuildReceipt] = [:]
        for r in receipts { lastReceipt[r.agent] = r }
        var lastCheck: [AgentID: LaunchCheck] = [:]
        for c in checks { lastCheck[c.agent] = c }

        var out: [AgentID: Verdict] = [:]
        for (agent, receipt) in lastReceipt {
            guard let check = lastCheck[agent] else {
                out[agent] = .notChecked
                continue
            }
            // simctl accepts a UDID in either case, so compare canonical forms.
            let simulator = UDID.key(receipt.simulatorUDID)
            guard UDID.key(check.simulatorUDID) == simulator else {
                out[agent] = .wrongSimulator(expected: receipt.simulatorUDID, actual: check.simulatorUDID)
                continue
            }
            let others = lastReceipt.values.filter { $0.agent != agent && UDID.key($0.simulatorUDID) == simulator }
            guard check.bundleID == receipt.bundleID, check.installedStamp == receipt.stamp else {
                let owners = others.filter { $0.bundleID == check.bundleID && $0.stamp == check.installedStamp }.map(\.agent)
                out[agent] = .foreignBuild(installedBy: owners.count == 1 ? owners.first : nil)
                continue
            }
            let lookalikes = others.filter { $0.bundleID == receipt.bundleID && $0.stamp == receipt.stamp }.map(\.agent)
            if !lookalikes.isEmpty {
                out[agent] = .ambiguousStamp(sharedWith: lookalikes.sorted())
            } else if !others.isEmpty {
                out[agent] = .sharedSimulator(with: others.map(\.agent).sorted())
            } else {
                out[agent] = .verified
            }
        }
        return out
    }
}
