import Foundation

/// What each QA run leaves behind, and how often agents run it.
public struct LeakProfile: Hashable, Sendable {
    /// Bytes a run leaves behind, such as a fixture unpacked into a temp
    /// directory that nothing deletes.
    public var bytesPerRun: Int64
    public var runsPerAgentPerHour: Int

    public init(bytesPerRun: Int64, runsPerAgentPerHour: Int) {
        self.bytesPerRun = bytesPerRun
        self.runsPerAgentPerHour = runsPerAgentPerHour
    }
}

/// How the harness contains what runs leave behind.
public struct DiskPolicy: Hashable, Sendable {
    /// Each agent writes to its own volume with this cap. `nil`: everything
    /// lands on the Data volume with no cap.
    public var perAgentQuotaBytes: Int64?
    /// The harness deletes the agent's leftovers after this many runs (one
    /// task), whatever the agent's scripts did. `nil`: nothing is deleted.
    public var teardownEveryRuns: Int?

    public init(perAgentQuotaBytes: Int64? = nil, teardownEveryRuns: Int? = nil) {
        self.perAgentQuotaBytes = perAgentQuotaBytes
        self.teardownEveryRuns = teardownEveryRuns
    }

    /// No quota, no teardown: today's default.
    public static let none = DiskPolicy()
}

/// Free space on the Mac at the end of one simulated hour.
public struct RunwayPoint: Hashable, Sendable, Identifiable {
    public let hour: Int
    public let hostFreeBytes: Int64
    /// Agents stuck because their next run can't get space and nothing will free it.
    public let agentsOutOfSpace: Int
    public var id: Int { hour }
}

/// Free space right after one run, or right after a teardown.
public struct RunwaySample: Hashable, Sendable {
    /// The run, counted across all agents from 1. 0 is the starting state.
    public let run: Int
    /// `run` divided by runs per hour across all agents.
    public let hour: Double
    public let freeBytes: Int64
}

public struct RunwayResult: Hashable, Sendable {
    /// Hour 0 (before any run) to the last simulated hour.
    public let points: [RunwayPoint]
    /// Every run, plus a second sample at the same moment whenever a teardown
    /// frees space. This is what shows the dips inside each hour.
    public let trace: [RunwaySample]
    /// The run, counted across all agents from 1, after which free space first
    /// fell below the floor. 0 if it started below. `nil` if it never did.
    public let floorBreachRun: Int?
    /// `floorBreachRun` divided by runs per hour across all agents.
    public let floorBreachHour: Double?
    /// The first run that failed for lack of space, inside a quota or on a full disk.
    public let firstFailedRun: Int?
    public let firstFailedHour: Double?
    /// The lowest free space at any point, including just before a teardown.
    public let minimumFreeBytes: Int64
    public let completedRuns: Int
    public let failedRuns: Int
}

/// Projects free disk space while parallel agents run a leaky QA workflow.
///
/// Runs are interleaved across agents (agent 1, 2, 3, 4, 1, 2, ...). A run
/// that doesn't fit writes until its volume (or the disk) is full and then
/// fails, the way an unpack does when it hits a quota. The model counts only
/// what runs leave behind. It ignores Time Machine snapshot retention, which
/// is why the envelope puts scratch data on a volume that isn't snapshotted.
///
/// Inputs are clamped rather than trusted: agents and runs per hour to
/// 0...1,000, and a simulation stops after `maxRuns` (100,000) runs, so no input can
/// overflow or run away.
public enum DiskRunway {
    public static let maxAgents = 1_000
    public static let maxRunsPerAgentPerHour = 1_000
    public static let maxRuns = 100_000

    /// The first run after which `freeBytes - n * bytesPerRun` is below
    /// `floorBytes`. 0 if free space already starts below the floor; `nil` if
    /// runs leave nothing behind.
    public static func floorBreachRun(freeBytes: Int64, floorBytes: Int64, bytesPerRun: Int64) -> Int? {
        guard freeBytes >= floorBytes else { return 0 }
        guard bytesPerRun > 0 else { return nil }
        let (headroom, overflow) = freeBytes.subtractingReportingOverflow(floorBytes)
        let runs = overflow ? Int.max : Int(clamping: headroom / bytesPerRun)
        return runs == .max ? .max : runs + 1
    }

    public static func simulate(
        host: HostProfile,
        agents: Int,
        leak: LeakProfile,
        policy: DiskPolicy,
        hours: Int
    ) -> RunwayResult {
        let agentCount = min(max(0, agents), maxAgents)
        let perHour = agentCount * min(max(0, leak.runsPerAgentPerHour), maxRunsPerAgentPerHour)
        let hourLimit = perHour > 0 ? (maxRuns + perHour - 1) / perHour : maxRuns
        let simulatedHours = min(max(0, hours), hourLimit)
        let bytes = max(0, leak.bytesPerRun)
        let quota = policy.perAgentQuotaBytes.map { max(0, $0) }
        let teardownEvery = policy.teardownEveryRuns.map { max(1, $0) }

        var held = Array(repeating: Int64(0), count: agentCount)
        var runsInTask = Array(repeating: 0, count: agentCount)
        var stuck = Array(repeating: false, count: agentCount)
        var free = max(0, host.freeBytes)
        var minimumFree = free
        var points = [RunwayPoint(hour: 0, hostFreeBytes: free, agentsOutOfSpace: 0)]
        var trace = [RunwaySample(run: 0, hour: 0, freeBytes: free)]
        var breach: Int? = free < host.floorBytes ? 0 : nil
        var firstFailed: Int?
        var run = 0, completed = 0, failed = 0

        func hoursFor(_ run: Int) -> Double { perHour > 0 ? Double(run) / Double(perHour) : 0 }
        func record() { trace.append(RunwaySample(run: run, hour: hoursFor(run), freeBytes: free)) }
        func release(_ i: Int) {
            free += held[i]
            held[i] = 0
            runsInTask[i] = 0
        }

        if perHour > 0, simulatedHours > 0 {
            for hour in 1...simulatedHours {
                for slot in 0..<perHour {
                    guard run < maxRuns else { break }
                    run += 1
                    let i = slot % agentCount
                    if stuck[i] {
                        failed += 1
                        record()
                        continue
                    }
                    let quotaRoom = quota.map { max(0, $0 - held[i]) } ?? .max
                    let room = min(quotaRoom, free)
                    let written = min(bytes, room)
                    held[i] += written
                    free -= written
                    minimumFree = min(minimumFree, free)
                    if breach == nil, free < host.floorBytes { breach = run }
                    record()
                    guard written == bytes else {
                        // Out of space part-way through: the run fails and its
                        // partial output stays until something deletes it.
                        failed += 1
                        if firstFailed == nil { firstFailed = run }
                        if teardownEvery != nil {
                            release(i)
                            record()
                        } else {
                            stuck[i] = true
                        }
                        continue
                    }
                    completed += 1
                    runsInTask[i] += 1
                    if let n = teardownEvery, runsInTask[i] >= n {
                        release(i)
                        record()
                    }
                }
                points.append(RunwayPoint(hour: hour, hostFreeBytes: free, agentsOutOfSpace: stuck.filter { $0 }.count))
            }
        } else if simulatedHours > 0 {
            for hour in 1...simulatedHours {
                points.append(RunwayPoint(hour: hour, hostFreeBytes: free, agentsOutOfSpace: 0))
            }
        }

        return RunwayResult(
            points: points,
            trace: trace,
            floorBreachRun: breach,
            floorBreachHour: breach.map(hoursFor),
            firstFailedRun: firstFailed,
            firstFailedHour: firstFailed.map(hoursFor),
            minimumFreeBytes: minimumFree,
            completedRuns: completed,
            failedRuns: failed
        )
    }
}
