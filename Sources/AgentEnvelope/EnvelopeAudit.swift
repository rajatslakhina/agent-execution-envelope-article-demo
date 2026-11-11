import Foundation

/// One way parallel agents can interfere with each other or with the Mac.
public struct Finding: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// Two or more agents work in one checkout, or one works in yours.
        case sharedCheckout
        /// A path of one agent overlaps a path of another.
        case overlappingPaths
        /// Agents in the shared checkout also share its default DerivedData folder.
        case sharedDerivedData
        /// Agents install on the same simulator.
        case sharedSimulator
        /// A dedicated simulator binding whose UDID isn't a UUID.
        case invalidSimulatorUDID
        /// Xcode's default DerivedData: one folder per worktree path, outside the worktree.
        case defaultDerivedData
        /// Temp files go to the user's shared `$TMPDIR`.
        case sharedTempRoot
        /// Something this agent was given is not deleted when its task ends.
        case survivesTeardown(Field)
        /// Scratch data has no cap.
        case noQuota
        /// Scratch data is inside Time Machine's local snapshots.
        case snapshotRetention
        /// A dedicated volume name that can't be a mount point.
        case invalidVolumeName
        /// Several agents share one capped volume.
        case pooledQuota
        /// A shared volume is deleted at one agent's teardown, taking the others' work with it.
        case pooledVolumeDeleted
        /// A path that should be on the agent's scratch volume isn't.
        case offScratchVolume(Field)
        /// Volume quotas add up to more than the Mac can spare.
        case quotaOvercommit
        /// More simulators would be booted at once than the Mac can run.
        case simulatorBudget
        /// The same agent ID appears in more than one envelope.
        case duplicateAgentID
    }

    public enum Severity: Int, Sendable, Comparable, CaseIterable {
        /// Another agent can change this agent's result.
        case collision = 0
        /// Something survives the task.
        case leak = 1
        /// A shared resource has no cap.
        case capacity = 2

        public var title: String {
            switch self {
            case .collision: return "Collision"
            case .leak: return "Leak"
            case .capacity: return "Capacity"
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Position in the report, so it stays unique even when agent IDs repeat.
    public let id: Int
    public let kind: Kind
    public let severity: Severity
    /// Sorted. Host-level findings list every agent they concern.
    public let agents: [AgentID]
    /// The envelope fields this finding takes away from each listed agent.
    /// Empty for host-level findings.
    public let affects: [Field]
    public let detail: String

    public var isHostLevel: Bool { affects.isEmpty }
}

/// The result of auditing a set of envelopes on one Mac.
public struct AuditReport: Sendable {
    /// Ordered by severity, then by the first agent, then by detail.
    public let findings: [Finding]
    /// The fields each agent owns: no other agent can write to them, and
    /// nothing the agent leaves in them outlives the task.
    public let owned: [AgentID: Set<Field>]

    public func ownedCount(for agent: AgentID) -> Int { owned[agent]?.count ?? 0 }

    public func count(_ severity: Finding.Severity) -> Int {
        findings.filter { $0.severity == severity }.count
    }

    public var hostFindings: [Finding] { findings.filter(\.isHostLevel) }

    /// Findings that explain why `agent` doesn't own `field`.
    public func reasons(_ agent: AgentID, _ field: Field) -> [Finding] {
        findings.filter { $0.agents.contains(agent) && $0.affects.contains(field) }
    }
}

/// Checks every envelope against the others and against the host.
///
/// A field is owned only when no finding takes it away, so every gap in the
/// ownership grid has at least one finding that explains it.
public enum EnvelopeAudit {
    private struct Draft {
        let kind: Finding.Kind
        let severity: Finding.Severity
        let agents: [AgentID]
        let affects: [Field]
        let detail: String
    }

    public static func run(_ envelopes: [ExecutionEnvelope], on host: HostProfile) -> AuditReport {
        var drafts: [Draft] = []
        func add(_ kind: Finding.Kind, _ severity: Finding.Severity, _ agents: [AgentID], _ affects: [Field], _ detail: String) {
            drafts.append(Draft(kind: kind, severity: severity, agents: agents.sorted(), affects: affects, detail: detail))
        }

        // Duplicate IDs make every other answer ambiguous.
        let idCounts = Dictionary(grouping: envelopes, by: \.agent).filter { $0.value.count > 1 }
        for id in idCounts.keys.sorted() {
            add(.duplicateAgentID, .collision, [id], Field.allCases,
                "\(id) appears in \(idCounts[id]?.count ?? 0) envelopes, so nothing can tell their files, builds or simulators apart.")
        }

        // Worktree
        let inSharedCheckout = envelopes.filter { $0.worktree == nil }.map(\.agent)
        if !inSharedCheckout.isEmpty {
            add(.sharedCheckout, .collision, inSharedCheckout, [.worktree],
                "\(list(inSharedCheckout)) \(inSharedCheckout.count == 1 ? "works" : "work") in the shared checkout, where another session (or you) can change files mid-task.")
        }

        // DerivedData
        let sharedDefaultDD = envelopes.filter { $0.worktree == nil && $0.derivedData == nil }.map(\.agent)
        if sharedDefaultDD.count > 1 {
            add(.sharedDerivedData, .collision, sharedDefaultDD, [.derivedData],
                "\(list(sharedDefaultDD)) build one project path, so Xcode gives them one default DerivedData folder and they overwrite each other's products.")
        }
        for e in envelopes where e.derivedData == nil {
            let detail = e.worktree == nil
                ? "\(e.agent) builds into Xcode's default DerivedData, outside any envelope, so nothing deletes it when the task ends."
                : "\(e.agent) builds into Xcode's default DerivedData. Xcode keys that folder by project path, so each worktree gets its own, but it lives outside the worktree and `git worktree remove` leaves it behind."
            add(.defaultDerivedData, .leak, [e.agent], [.derivedData, .teardown], detail)
        }

        // Simulator
        let onBooted = envelopes.filter { $0.simulator == .whateverIsBooted }.map(\.agent)
        if !onBooted.isEmpty {
            add(.sharedSimulator, .collision, onBooted, [.simulator],
                "\(list(onBooted)) \(onBooted.count == 1 ? "installs" : "install") on whatever simulator is booted. The last install wins, so an agent can launch, and \"verify\", a build it didn't make.")
        }
        for e in envelopes {
            if let udid = e.simulator.udid, !e.simulator.hasValidUDID {
                add(.invalidSimulatorUDID, .collision, [e.agent], [.simulator],
                    "\(e.agent)'s simulator \"\(udid)\" isn't a UUID. `simctl` treats words like \"booted\" or \"all\" as every matching simulator, not this agent's.")
            }
        }
        var byUDID: [String: [AgentID]] = [:]
        for e in envelopes {
            if let udid = e.simulator.udid { byUDID[udid, default: []].append(e.agent) }
        }
        for udid in byUDID.keys.sorted() {
            guard let agents = byUDID[udid], agents.count > 1 else { continue }
            add(.sharedSimulator, .collision, agents, [.simulator],
                "\(list(agents)) are bound to the same simulator (\(udid)), so their installs replace each other.")
        }

        // Temp root
        let sharedTmp = envelopes.filter { $0.tempRoot == nil }.map(\.agent)
        if !sharedTmp.isEmpty {
            add(.sharedTempRoot, .leak, sharedTmp, [.tempRoot, .teardown],
                "\(list(sharedTmp)) \(sharedTmp.count == 1 ? "writes" : "write") temp files into the user's shared $TMPDIR. Nothing records whose files they are, so teardown can't delete them.")
        }

        // Overlapping paths between different agents, across all path fields.
        for (i, a) in envelopes.enumerated() {
            for b in envelopes.dropFirst(i + 1) where a.agent != b.agent {
                var affected: [Field] = []
                for (fa, pa) in paths(of: a) {
                    for (fb, pb) in paths(of: b) where pa.overlaps(pb) {
                        if !affected.contains(fa) { affected.append(fa) }
                        if !affected.contains(fb) { affected.append(fb) }
                    }
                }
                if !affected.isEmpty {
                    add(.overlappingPaths, .collision, [a.agent, b.agent], affected.sorted(),
                        "\(a.agent) and \(b.agent) have overlapping paths (\(affected.sorted().map(\.title).joined(separator: ", "))), so one can overwrite or delete the other's files.")
                }
            }
        }

        // Teardown gaps for things this agent was given.
        for e in envelopes {
            if let w = e.worktree, !e.tearsDown(w, as: .worktree) {
                add(.survivesTeardown(.worktree), .leak, [e.agent], [.worktree, .teardown],
                    "\(e.agent)'s worktree isn't removed when the task ends.")
            }
            if let dd = e.derivedData, !e.tearsDown(dd, as: .derivedData) {
                add(.survivesTeardown(.derivedData), .leak, [e.agent], [.derivedData, .teardown],
                    "\(e.agent)'s DerivedData at \(dd) isn't deleted when the task ends.")
            }
            if let tmp = e.tempRoot, !e.tearsDown(tmp, as: .tempRoot) {
                add(.survivesTeardown(.tempRoot), .leak, [e.agent], [.tempRoot, .teardown],
                    "\(e.agent)'s temp root at \(tmp) isn't deleted when the task ends, so whatever its scripts forget stays.")
            }
            if case .dedicated = e.simulator, !e.teardown.contains(.simulator) {
                add(.survivesTeardown(.simulator), .leak, [e.agent], [.simulator, .teardown],
                    "\(e.agent)'s simulator isn't deleted when the task ends. Reinstalling doesn't clear an app's data, so the next task starts with this one's state.")
            }
            if let mount = e.scratch.mountPoint, !e.teardown.contains(.scratchVolume) {
                add(.survivesTeardown(.scratchVolume), .leak, [e.agent], [.scratchVolume, .teardown],
                    "\(e.agent)'s volume \(mount) isn't deleted when the task ends, so anything it wrote outside its worktree, DerivedData and temp root stays.")
            }
        }

        // Scratch volume
        var volumeUsers: [String: [AgentID]] = [:]
        var volumeQuota: [String: Int64] = [:]
        var volumeDeleters: [String: [AgentID]] = [:]
        for e in envelopes {
            switch e.scratch {
            case .system:
                add(.noQuota, .capacity, [e.agent], [.scratchVolume],
                    "\(e.agent)'s scratch is on the Data volume with no cap: one runaway script can fill the disk for every agent and for macOS.")
                if host.timeMachineSnapshots {
                    add(.snapshotRetention, .capacity, [e.agent], [.scratchVolume],
                        "\(e.agent)'s scratch is inside Time Machine's hourly local snapshots. A snapshot covers the whole volume and can be kept for up to a day, so a deleted file's space only comes back when the snapshot holding it is removed.")
                }
            case .dedicated(let name, let quota, let inTimeMachine):
                guard let mount = e.scratch.mountPoint else {
                    add(.invalidVolumeName, .capacity, [e.agent], [.scratchVolume],
                        "\(e.agent)'s volume name \"\(name)\" can't be a mount point under /Volumes, so nothing can be placed on it.")
                    continue
                }
                volumeUsers[name, default: []].append(e.agent)
                volumeQuota[name] = max(volumeQuota[name] ?? 0, quota)
                if e.teardown.contains(.scratchVolume) { volumeDeleters[name, default: []].append(e.agent) }
                if quota <= 0 {
                    add(.noQuota, .capacity, [e.agent], [.scratchVolume],
                        "\(e.agent)'s volume \(name) has no quota, so it can grow until the container is full.")
                }
                if inTimeMachine && host.timeMachineSnapshots {
                    add(.snapshotRetention, .capacity, [e.agent], [.scratchVolume],
                        "\(e.agent)'s volume \(name) is backed up by Time Machine, so it gets hourly local snapshots that keep deleted data for up to a day.")
                }
                for (field, path) in [(Field.worktree, e.worktree), (Field.derivedData, e.derivedData), (Field.tempRoot, e.tempRoot)] {
                    if let path, !mount.contains(path) {
                        add(.offScratchVolume(field), .capacity, [e.agent], [.scratchVolume],
                            "\(e.agent)'s \(field.title) at \(path) is outside \(mount), so its churn lands on the Data volume anyway.")
                    }
                }
            }
        }
        for name in volumeUsers.keys.sorted() {
            guard let users = volumeUsers[name], Set(users).count > 1 else { continue }
            add(.pooledQuota, .capacity, users, [.scratchVolume],
                "\(list(users)) share the volume \(name). Its quota protects macOS, not these agents from each other.")
            if let deleters = volumeDeleters[name], !deleters.isEmpty {
                add(.pooledVolumeDeleted, .collision, users, [.scratchVolume, .teardown],
                    "\(list(deleters)) \(deleters.count == 1 ? "deletes" : "delete") the shared volume \(name) at teardown, which destroys the other agents' work on it.")
            }
        }

        // Host level
        let totalQuota = volumeQuota.values.filter { $0 > 0 }.reduce(Int64(0)) { $0.addingReportingOverflow($1).overflow ? .max : $0 + $1 }
        if totalQuota > host.headroomBytes {
            let agents = Array(Set(volumeUsers.values.flatMap { $0 }))
            add(.quotaOvercommit, .capacity, agents, [],
                "Volume quotas add up to \(Bytes.format(totalQuota)), but only \(Bytes.format(host.headroomBytes)) is free above the floor. A quota is a cap, not a reservation.")
        }
        let dedicatedSims = Set(envelopes.compactMap(\.simulator.udid))
        let booted = dedicatedSims.count + (onBooted.isEmpty ? 0 : 1)
        if booted > host.maxBootedSimulators {
            add(.simulatorBudget, .capacity, envelopes.map(\.agent), [],
                "\(booted) simulators would be booted at once; this Mac's budget is \(host.maxBootedSimulators). Queue the extra agents or add a machine.")
        }

        drafts.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
            let l = lhs.agents.first?.rawValue ?? "", r = rhs.agents.first?.rawValue ?? ""
            if l != r { return l < r }
            return lhs.detail < rhs.detail
        }
        let findings = drafts.enumerated().map { index, d in
            Finding(id: index, kind: d.kind, severity: d.severity, agents: d.agents, affects: d.affects, detail: d.detail)
        }

        var owned: [AgentID: Set<Field>] = [:]
        for e in envelopes {
            var fields = Set(Field.allCases)
            for f in findings where f.agents.contains(e.agent) {
                fields.subtract(f.affects)
            }
            owned[e.agent] = fields
        }
        return AuditReport(findings: findings, owned: owned)
    }

    /// Every path an envelope writes to, with the field it belongs to.
    private static func paths(of e: ExecutionEnvelope) -> [(Field, EnvelopePath)] {
        var out: [(Field, EnvelopePath)] = []
        if let w = e.worktree { out.append((.worktree, w)) }
        if let d = e.derivedData { out.append((.derivedData, d)) }
        if let t = e.tempRoot { out.append((.tempRoot, t)) }
        return out
    }

    private static func list(_ agents: [AgentID]) -> String {
        let names = agents.sorted().map(\.rawValue)
        guard let last = names.last else { return "No agent" }
        if names.count == 1 { return last }
        if names.count == 2, let first = names.first { return "\(first) and \(last)" }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// How many agents one Mac can run in parallel without breaking its own floor.
public enum CapacityPlan {
    /// The smaller of the simulator budget and the number of per-agent quotas
    /// that fit in the headroom. Returns 0 when `quotaPerAgent` isn't positive:
    /// without a cap there is no number to plan with.
    public static func maxParallelAgents(on host: HostProfile, quotaPerAgent: Int64) -> Int {
        guard quotaPerAgent > 0 else { return 0 }
        let byDisk = host.headroomBytes / quotaPerAgent
        return max(0, min(host.maxBootedSimulators, Int(clamping: byDisk)))
    }
}
