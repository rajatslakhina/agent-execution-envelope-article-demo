import XCTest
@testable import AgentEnvelope

final class EnvelopePathTests: XCTestCase {
    func testNormalisesAbsoluteAndHomePaths() throws {
        XCTAssertEqual(EnvelopePath("/a/b/../c/./d")?.description, "/a/c/d")
        XCTAssertEqual(EnvelopePath("~/x//y/")?.description, "~/x/y")
        XCTAssertEqual(EnvelopePath("~")?.description, "~")
        XCTAssertEqual(EnvelopePath("/")?.description, "/")
    }

    func testRejectsRelativeEmptyAndEscapingPaths() {
        XCTAssertNil(EnvelopePath("a/b"))
        XCTAssertNil(EnvelopePath(""))
        XCTAssertNil(EnvelopePath("/.."))
        XCTAssertNil(EnvelopePath("~/.."))
        XCTAssertNil(EnvelopePath("~other/x"))
    }

    func testComparesByComponentNotByStringPrefix() throws {
        let one = try XCTUnwrap(EnvelopePath("/Volumes/agent-1"))
        let ten = try XCTUnwrap(EnvelopePath("/Volumes/agent-10"))
        let inside = try XCTUnwrap(EnvelopePath("/Volumes/agent-1/tmp"))
        XCTAssertFalse(one.contains(ten))
        XCTAssertFalse(one.overlaps(ten))
        XCTAssertTrue(one.contains(inside))
        XCTAssertTrue(inside.overlaps(one))
        XCTAssertFalse(inside.contains(one))
    }

    func testAppendingCannotEscapeItsParent() throws {
        let base = try XCTUnwrap(EnvelopePath("/Volumes/agent-1"))
        XCTAssertNil(base.appending(".."))
        XCTAssertNil(base.appending("a/b"))
        XCTAssertNil(base.appending(""))
        XCTAssertEqual(base.appending("tmp")?.description, "/Volumes/agent-1/tmp")
    }

    func testEverySamplePathParses() {
        for setup in Sample.Setup.allCases {
            for e in Sample.envelopes(setup) {
                for path in [e.worktree, e.derivedData, e.tempRoot].compactMap({ $0 }) {
                    XCTAssertNotEqual(path, .root, "\(setup) \(e.agent)")
                }
            }
        }
        XCTAssertNotEqual(Sample.repo, .root)
    }
}

final class EnvelopeAuditTests: XCTestCase {
    func testWorktreesOnlyOwnOneFieldOfSix() {
        let report = EnvelopeAudit.run(Sample.envelopes(.worktreesOnly), on: Sample.host)
        for agent in Sample.agents {
            XCTAssertEqual(report.owned[agent], [.worktree], "\(agent)")
        }
        XCTAssertEqual(report.findings.count, 14)
        XCTAssertEqual(report.count(.collision), 1)
        XCTAssertEqual(report.count(.leak), 5)
        XCTAssertEqual(report.count(.capacity), 8)
    }

    func testWorktreeAndSimulatorOwnThreeAndMissTheDiskHalf() {
        let report = EnvelopeAudit.run(Sample.envelopes(.worktreeAndSimulator), on: Sample.host)
        for agent in Sample.agents {
            XCTAssertEqual(report.owned[agent], [.worktree, .derivedData, .simulator], "\(agent)")
        }
        XCTAssertEqual(report.findings.count, 9)
        XCTAssertEqual(report.count(.collision), 0)
    }

    func testFullEnvelopeOwnsAllSixWithNoFindings() {
        let report = EnvelopeAudit.run(Sample.envelopes(.envelope), on: Sample.host)
        XCTAssertTrue(report.findings.isEmpty, "\(report.findings.map(\.detail))")
        for agent in Sample.agents {
            XCTAssertEqual(report.ownedCount(for: agent), 6)
        }
    }

    func testEveryMissingFieldHasAReason() {
        for setup in Sample.Setup.allCases {
            let report = EnvelopeAudit.run(Sample.envelopes(setup), on: Sample.host)
            for agent in Sample.agents {
                for field in Field.allCases where !(report.owned[agent] ?? []).contains(field) {
                    XCTAssertFalse(report.reasons(agent, field).isEmpty, "\(setup) \(agent) \(field)")
                }
            }
        }
    }

    func testBootedSimulatorIsOneCollisionNamingEveryAgent() throws {
        let report = EnvelopeAudit.run(Sample.envelopes(.worktreesOnly), on: Sample.host)
        let shared = try XCTUnwrap(report.findings.first { $0.kind == .sharedSimulator })
        XCTAssertEqual(shared.agents, Sample.agents)
        XCTAssertEqual(shared.severity, .collision)
    }

    func testSameUDIDIsACollision() {
        let envelopes = [
            ExecutionEnvelope(agent: "a", worktree: EnvelopePath("/w/a"), simulator: .dedicated(udid: "X")),
            ExecutionEnvelope(agent: "b", worktree: EnvelopePath("/w/b"), simulator: .dedicated(udid: "X")),
        ]
        let report = EnvelopeAudit.run(envelopes, on: Sample.host)
        let shared = report.findings.filter { $0.kind == .sharedSimulator }
        XCTAssertEqual(shared.count, 1)
        XCTAssertEqual(shared.first?.agents, ["a", "b"])
        XCTAssertFalse(report.owned["a"]?.contains(.simulator) ?? true)
    }

    func testOverlapAcrossDifferentFieldsIsACollision() {
        let envelopes = [
            ExecutionEnvelope(agent: "a", worktree: EnvelopePath("/w/a"), tempRoot: EnvelopePath("/w/b/tmp")),
            ExecutionEnvelope(agent: "b", worktree: EnvelopePath("/w/b"), tempRoot: EnvelopePath("/t/b")),
        ]
        let report = EnvelopeAudit.run(envelopes, on: Sample.host)
        let overlap = report.findings.filter { $0.kind == .overlappingPaths }
        XCTAssertEqual(overlap.count, 1)
        XCTAssertEqual(overlap.first?.agents, ["a", "b"])
        XCTAssertEqual(overlap.first?.affects, [.worktree, .tempRoot])
    }

    func testSiblingFoldersWithSharedPrefixDoNotOverlap() {
        let envelopes = [
            ExecutionEnvelope(agent: "agent-1", worktree: EnvelopePath("/Volumes/agent-1/w"), tempRoot: EnvelopePath("/Volumes/agent-1/tmp")),
            ExecutionEnvelope(agent: "agent-10", worktree: EnvelopePath("/Volumes/agent-10/w"), tempRoot: EnvelopePath("/Volumes/agent-10/tmp")),
        ]
        let report = EnvelopeAudit.run(envelopes, on: Sample.host)
        XCTAssertFalse(report.findings.contains { $0.kind == .overlappingPaths })
    }

    func testQuotaOvercommitIsHostLevelAndLeavesOwnershipAlone() {
        let six = (1...6).map { i in
            ExecutionEnvelope(
                agent: AgentID("agent-\(i)"),
                worktree: EnvelopePath("/Volumes/agent-\(i)/worktree"),
                derivedData: EnvelopePath("/Volumes/agent-\(i)/DerivedData"),
                simulator: .dedicated(udid: "SIM-\(i)"),
                tempRoot: EnvelopePath("/Volumes/agent-\(i)/tmp"),
                scratch: .dedicated(name: "agent-\(i)", quotaBytes: Bytes.gb(100), inTimeMachine: false),
                teardown: [.worktree, .derivedData, .tempRoot, .simulator]
            )
        }
        let host = HostProfile(freeBytes: Bytes.gb(550), floorBytes: Bytes.gb(50), maxBootedSimulators: 8, timeMachineSnapshots: true)
        let report = EnvelopeAudit.run(six, on: host)
        XCTAssertEqual(report.findings.map(\.kind), [.quotaOvercommit])
        XCTAssertEqual(report.hostFindings.count, 1)
        XCTAssertEqual(report.ownedCount(for: "agent-6"), 6)
    }

    func testSimulatorBudget() {
        var five = Sample.envelopes(.envelope)
        five.append(ExecutionEnvelope(agent: "agent-5", worktree: EnvelopePath("/Volumes/agent-5/worktree"), simulator: .dedicated(udid: "SIM-5")))
        let report = EnvelopeAudit.run(five, on: Sample.host)
        XCTAssertTrue(report.findings.contains { $0.kind == .simulatorBudget })
    }

    func testPooledVolumeProtectsMacOSButNotTheAgents() {
        let pooled = ScratchVolume.dedicated(name: "agents", quotaBytes: Bytes.gb(300), inTimeMachine: false)
        let envelopes = ["a", "b"].map { name in
            ExecutionEnvelope(agent: AgentID(name), worktree: EnvelopePath("/Volumes/agents/\(name)/w"),
                              tempRoot: EnvelopePath("/Volumes/agents/\(name)/tmp"), scratch: pooled, teardown: [.worktree, .tempRoot])
        }
        let report = EnvelopeAudit.run(envelopes, on: Sample.host)
        XCTAssertEqual(report.findings.filter { $0.kind == .pooledQuota }.first?.agents, ["a", "b"])
        XCTAssertFalse(report.owned["a"]?.contains(.scratchVolume) ?? true)
    }

    func testPathOffTheScratchVolumeIsFlagged() {
        let e = ExecutionEnvelope(
            agent: "a", worktree: EnvelopePath("/Volumes/a/worktree"), derivedData: EnvelopePath("~/dd/a"),
            simulator: .dedicated(udid: "S"), tempRoot: EnvelopePath("/Volumes/a/tmp"),
            scratch: .dedicated(name: "a", quotaBytes: Bytes.gb(50), inTimeMachine: false), teardown: .everything
        )
        let report = EnvelopeAudit.run([e], on: Sample.host)
        XCTAssertEqual(report.findings.map(\.kind), [.offScratchVolume(.derivedData)])
    }

    func testBackedUpVolumeIsStillSnapshotted() {
        let e = ExecutionEnvelope(
            agent: "a", worktree: EnvelopePath("/Volumes/a/worktree"), derivedData: EnvelopePath("/Volumes/a/dd"),
            simulator: .dedicated(udid: "S"), tempRoot: EnvelopePath("/Volumes/a/tmp"),
            scratch: .dedicated(name: "a", quotaBytes: Bytes.gb(50), inTimeMachine: true), teardown: .everything
        )
        var host = Sample.host
        XCTAssertEqual(EnvelopeAudit.run([e], on: host).findings.map(\.kind), [.snapshotRetention])
        host.timeMachineSnapshots = false
        XCTAssertTrue(EnvelopeAudit.run([e], on: host).findings.isEmpty)
    }

    func testDuplicateAgentIDOwnsNothing() {
        let e = ExecutionEnvelope(agent: "a", worktree: EnvelopePath("/w/a"))
        let report = EnvelopeAudit.run([e, e], on: Sample.host)
        XCTAssertTrue(report.findings.contains { $0.kind == .duplicateAgentID })
        XCTAssertEqual(report.ownedCount(for: "a"), 0)
    }

    func testCapacityPlanIsTheTighterOfDiskAndSimulators() {
        XCTAssertEqual(CapacityPlan.maxParallelAgents(on: Sample.host, quotaPerAgent: Bytes.gb(100)), 4)
        XCTAssertEqual(CapacityPlan.maxParallelAgents(on: Sample.host, quotaPerAgent: Bytes.gb(200)), 2)
        XCTAssertEqual(CapacityPlan.maxParallelAgents(on: Sample.host, quotaPerAgent: 0), 0)
        let full = HostProfile(freeBytes: Bytes.gb(30), floorBytes: Bytes.gb(50), maxBootedSimulators: 4, timeMachineSnapshots: false)
        XCTAssertEqual(full.headroomBytes, 0)
        XCTAssertEqual(CapacityPlan.maxParallelAgents(on: full, quotaPerAgent: Bytes.gb(10)), 0)
    }
}
