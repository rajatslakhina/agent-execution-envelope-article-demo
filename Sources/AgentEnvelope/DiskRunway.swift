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
    /// The harness deletes the agent's temp root after this many runs (one
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

public struct RunwayResult: Hashable, Sendable {
    /// Hour 0 (before any run) to the last simulated hour.
    public let points: [RunwayPoint]
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
/// Runs are interleaved across agents (agent 1, 2, 3, 4, 1, 2, ...). The model
/// counts only what runs leave behind. It ignores Time Machine snapshot
/// retention, which is why the envelope puts scratch data on a volume that
/// isn't snapshotted.
public enum DiskRunway {
    /// The first run after which `freeBytes - n * bytesPerRun` is below
    /// `floorBytes`. 0 if free space already starts below the floor; `nil` if
    /// runs leave nothing behind.
    public static func floorBreachRun(freeBytes: Int64, floorBytes: Int64, bytesPerRun: Int64) -> Int? {
        guard freeBytes >= floorBytes else { return 0 }
        guard bytesPerRun > 0 else { return nil }
        return Int(clamping: (freeBytes - floorBytes) / bytesPerRun) + 1
    }

    public static func simulate(
        host: HostProfile,
        agents: Int,
        leak: LeakProfile,
        policy: DiskPolicy,
        hours: Int
    ) -> RunwayResult {
        let agentCount = max(0, agents)
        let perHour = agentCount * max(0, leak.runsPerAgentPerHour)
        let bytes = max(0, leak.bytesPerRun)
        let teardownEvery = policy.teardownEveryRuns.map { max(1, $0) }

        var held = Array(repeating: Int64(0), count: agentCount)
        var runsInTask = Array(repeating: 0, count: agentCount)
        var stuck = Array(repeating: false, count: agentCount)
        var free = host.freeBytes
        var minimumFree = free
        var points = [RunwayPoint(hour: 0, hostFreeBytes: free, agentsOutOfSpace: 0)]
        var breach: Int? = free < host.floorBytes ? 0 : nil
        var firstFailed: Int?
        var run = 0, completed = 0, failed = 0

        func release(_ i: Int) {
            free += held[i]
            held[i] = 0
            runsInTask[i] = 0
        }

        if perHour > 0, hours > 0 {
            for hour in 1...hours {
                for slot in 0..<perHour {
                    run += 1
                    let i = slot % agentCount
                    if stuck[i] {
                        failed += 1
                        continue
                    }
                    let fitsQuota = policy.perAgentQuotaBytes.map { held[i] + bytes <= $0 } ?? true
                    let fitsDisk = free - bytes >= 0
                    guard fitsQuota, fitsDisk else {
                        failed += 1
                        if firstFailed == nil { firstFailed = run }
                        // The task fails. With a teardown, the harness deletes
                        // its leftovers and the agent can start again; without
                        // one, nothing will ever free the space.
                        if teardownEvery != nil { release(i) } else { stuck[i] = true }
                        continue
                    }
                    held[i] += bytes
                    free -= bytes
                    completed += 1
                    minimumFree = min(minimumFree, free)
                    if breach == nil, free < host.floorBytes { breach = run }
                    runsInTask[i] += 1
                    if let n = teardownEvery, runsInTask[i] >= n { release(i) }
                }
                points.append(RunwayPoint(hour: hour, hostFreeBytes: free, agentsOutOfSpace: stuck.filter { $0 }.count))
            }
        } else if hours > 0 {
            for hour in 1...hours {
                points.append(RunwayPoint(hour: hour, hostFreeBytes: free, agentsOutOfSpace: 0))
            }
        }

        func hoursFor(_ run: Int?) -> Double? {
            guard let run, perHour > 0 else { return run == 0 ? 0 : nil }
            return Double(run) / Double(perHour)
        }

        return RunwayResult(
            points: points,
            floorBreachRun: breach,
            floorBreachHour: hoursFor(breach),
            firstFailedRun: firstFailed,
            firstFailedHour: hoursFor(firstFailed),
            minimumFreeBytes: minimumFree,
            completedRuns: completed,
            failedRuns: failed
        )
    }
}
