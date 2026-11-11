import XCTest
@testable import AgentEnvelope

/// Well-formed UUIDs for tests that need a simulator of their own.
enum TestUDID {
    static func make(_ n: Int) -> String {
        String(format: "00000000-0000-4000-8000-%012d", n)
    }
}

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
        XCTAssertNil(EnvelopePath("/~/x"), "would read as the home directory")
        XCTAssertNil(EnvelopePath("/a/../~/x"))
        XCTAssertNil(EnvelopePath.root.appending("~"))
    }

    func testContainmentIgnoresLetterCaseLikeAPFS() throws {
        let a = try XCTUnwrap(EnvelopePath("/Volumes/Scratch/tmp"))
        let b = try XCTUnwrap(EnvelopePath("/Volumes/scratch/TMP"))
        XCTAssertTrue(a.overlaps(b))
        XCTAssertTrue(a.isSame(as: b))
        XCTAssertNotEqual(a, b, "== is exact spelling")
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
                if let udid = e.simulator.udid { XCTAssertNotNil(UUID(uuidString: udid), "\(setup) \(e.agent)") }
            }
        }
        XCTAssertNotEqual(Sample.repo, .root)
        XCTAssertNotNil(UUID(uuidString: Sample.bootedUDID))
        for index in [Int.max, Int.min, -1, 0, 9, 10] {
            XCTAssertNotNil(UUID(uuidString: Sample.udid(for: index)), "\(index)")
        }
        XCTAssertEqual(Sample.udid(for: 0), "11111111-1111-4111-8111-111111111111")
    }

    func testBytesNeverTrapsAndNeverRoundsAMinimumUp() {
        XCTAssertEqual(Bytes.gb(.nan), 0)
        XCTAssertEqual(Bytes.gb(.infinity), .max)
        XCTAssertEqual(Bytes.gb(-.infinity), .min)
        XCTAssertEqual(Bytes.gb(1e30), .max)
        XCTAssertEqual(Bytes.format(Bytes.gb(550)), "550 GB")
        XCTAssertEqual(Bytes.format(Bytes.gb(475.9)), "475.9 GB")
        XCTAssertEqual(Bytes.format(Bytes.gb(475.99)), "475.9 GB")
        XCTAssertEqual(Bytes.format(Bytes.gb(5.7)), "5.7 GB")
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

    func testKeepingTheClonedSimulatorsDropsItToTwo() {
        let kept = Sample.envelopes(.worktreeAndSimulator).map { e -> ExecutionEnvelope in
            var e = e
            e.teardown = [.worktree]
            return e
        }
        let report = EnvelopeAudit.run(kept, on: Sample.host)
        XCTAssertEqual(report.owned["agent-1"], [.worktree, .derivedData])
        XCTAssertEqual(report.findings.count, 13)
    }

    func testFullEnvelopeOwnsAllSixWithNoFindings() {
        let report = EnvelopeAudit.run(Sample.envelopes(.envelope), on: Sample.host)
        XCTAssertTrue(report.findings.isEmpty, "\(report.findings.map(\.detail))")
        for agent in Sample.agents {
            XCTAssertEqual(report.ownedCount(for: agent), 6)
        }
    }

    func testAVolumeThatOutlivesTheTaskIsNotOwned() {
        let kept = Sample.envelopes(.envelope).map { e -> ExecutionEnvelope in
            var e = e
            e.teardown.remove(.scratchVolume)
            return e
        }
        let report = EnvelopeAudit.run(kept, on: Sample.host)
        XCTAssertEqual(report.findings.filter { $0.kind == .survivesTeardown(.scratchVolume) }.count, 4)
        XCTAssertEqual(report.owned["agent-1"], [.worktree, .derivedData, .simulator, .tempRoot])
    }

    func testFallingBackToASharedDefaultCostsTeardown() {
        let booted = ExecutionEnvelope(
            agent: "a", worktree: EnvelopePath("/w/a"), derivedData: EnvelopePath("/w/a/.build/dd"),
            tempRoot: EnvelopePath("/w/a/tmp"), scratch: .dedicated(name: "a", quotaBytes: Bytes.gb(10), inTimeMachine: false),
            teardown: [.worktree, .scratchVolume]
        )
        XCTAssertFalse(EnvelopeAudit.run([booted], on: Sample.host).owned["a"]?.contains(.teardown) ?? true, "booted simulator")
        var checkout = booted
        checkout.worktree = nil
        checkout.simulator = .dedicated(udid: TestUDID.make(1))
        checkout.teardown = .everything
        XCTAssertFalse(EnvelopeAudit.run([checkout], on: Sample.host).owned["a"]?.contains(.teardown) ?? true, "shared checkout")
        var dataVolume = booted
        dataVolume.simulator = .dedicated(udid: TestUDID.make(1))
        dataVolume.scratch = .system
        dataVolume.teardown = .everything
        XCTAssertFalse(EnvelopeAudit.run([dataVolume], on: Sample.host).owned["a"]?.contains(.teardown) ?? true, "Data volume")
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
        let udid = TestUDID.make(1)
        let envelopes = [
            ExecutionEnvelope(agent: "a", worktree: EnvelopePath("/w/a"), simulator: .dedicated(udid: udid)),
            ExecutionEnvelope(agent: "b", worktree: EnvelopePath("/w/b"), simulator: .dedicated(udid: udid)),
        ]
        let report = EnvelopeAudit.run(envelopes, on: Sample.host)
        let shared = report.findings.filter { $0.kind == .sharedSimulator }
        XCTAssertEqual(shared.count, 1)
        XCTAssertEqual(shared.first?.agents, ["a", "b"])
        XCTAssertFalse(report.owned["a"]?.contains(.simulator) ?? true)
    }

    func testSameSimulatorInDifferentLetterCaseIsStillShared() {
        let udid = TestUDID.make(7).replacingOccurrences(of: "0000-4000", with: "ABCD-4000")
        let envelopes = [
            ExecutionEnvelope(agent: "a", worktree: EnvelopePath("/w/a"), simulator: .dedicated(udid: udid)),
            ExecutionEnvelope(agent: "b", worktree: EnvelopePath("/w/b"), simulator: .dedicated(udid: udid.lowercased())),
        ]
        let report = EnvelopeAudit.run(envelopes, on: Sample.host)
        XCTAssertEqual(report.findings.filter { $0.kind == .sharedSimulator }.first?.agents, ["a", "b"])
        XCTAssertFalse(report.findings.contains { $0.kind == .simulatorBudget })
    }

    func testNonUUIDSimulatorIsRejected() {
        let e = ExecutionEnvelope(agent: "a", worktree: EnvelopePath("/w/a"), simulator: .dedicated(udid: "all"), teardown: [.worktree, .simulator])
        let report = EnvelopeAudit.run([e], on: Sample.host)
        XCTAssertTrue(report.findings.contains { $0.kind == .invalidSimulatorUDID })
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

    private func fullEnvelope(_ i: Int, quota: Double = 100) -> ExecutionEnvelope {
        ExecutionEnvelope(
            agent: AgentID("agent-\(i)"),
            worktree: EnvelopePath("/Volumes/agent-\(i)/worktree"),
            derivedData: EnvelopePath("/Volumes/agent-\(i)/DerivedData"),
            simulator: .dedicated(udid: TestUDID.make(i)),
            tempRoot: EnvelopePath("/Volumes/agent-\(i)/tmp"),
            scratch: .dedicated(name: "agent-\(i)", quotaBytes: Bytes.gb(quota), inTimeMachine: false),
            teardown: .everything
        )
    }

    func testQuotaOvercommitIsHostLevelAndLeavesOwnershipAlone() {
        let host = HostProfile(freeBytes: Bytes.gb(550), floorBytes: Bytes.gb(50), maxBootedSimulators: 8, timeMachineSnapshots: true)
        let report = EnvelopeAudit.run((1...6).map { fullEnvelope($0) }, on: host)
        XCTAssertEqual(report.findings.map(\.kind), [.quotaOvercommit])
        XCTAssertEqual(report.hostFindings.count, 1)
        XCTAssertEqual(report.ownedCount(for: "agent-6"), 6)
    }

    func testSimulatorBudget() {
        let report = EnvelopeAudit.run((1...5).map { fullEnvelope($0, quota: 50) }, on: Sample.host)
        XCTAssertEqual(report.findings.map(\.kind), [.simulatorBudget])
    }

    func testPooledVolumeProtectsMacOSButNotTheAgents() {
        let pooled = ScratchVolume.dedicated(name: "agents", quotaBytes: Bytes.gb(300), inTimeMachine: false)
        let envelopes = ["a", "b"].map { name in
            ExecutionEnvelope(agent: AgentID(name), worktree: EnvelopePath("/Volumes/agents/\(name)/w"),
                              tempRoot: EnvelopePath("/Volumes/agents/\(name)/tmp"), scratch: pooled, teardown: [.worktree, .tempRoot])
        }
        let report = EnvelopeAudit.run(envelopes, on: Sample.host)
        XCTAssertEqual(report.findings.filter { $0.kind == .pooledQuota }.first?.agents, ["a", "b"])
        XCTAssertFalse(report.findings.contains { $0.kind == .pooledVolumeDeleted })
        XCTAssertFalse(report.owned["a"]?.contains(.scratchVolume) ?? true)
    }

    func testDeletingAPooledVolumeIsACollision() {
        let pooled = ScratchVolume.dedicated(name: "agents", quotaBytes: Bytes.gb(300), inTimeMachine: false)
        let envelopes = ["a", "b"].map { name in
            ExecutionEnvelope(agent: AgentID(name), worktree: EnvelopePath("/Volumes/agents/\(name)/w"),
                              tempRoot: EnvelopePath("/Volumes/agents/\(name)/tmp"), scratch: pooled,
                              teardown: name == "a" ? [.worktree, .tempRoot, .scratchVolume] : [.worktree, .tempRoot])
        }
        let report = EnvelopeAudit.run(envelopes, on: Sample.host)
        let deleted = report.findings.filter { $0.kind == .pooledVolumeDeleted }
        XCTAssertEqual(deleted.count, 1)
        XCTAssertEqual(deleted.first?.severity, .collision)
        XCTAssertEqual(deleted.first?.agents, ["a", "b"])
    }

    func testPathsOffTheScratchVolumeAreFlaggedIncludingTheWorktree() {
        var e = fullEnvelope(1, quota: 50)
        e.derivedData = EnvelopePath("~/dd/a")
        e.worktree = EnvelopePath("~/src/App-agent-1")
        let report = EnvelopeAudit.run([e], on: Sample.host)
        XCTAssertEqual(Set(report.findings.map(\.kind)), [.offScratchVolume(.derivedData), .offScratchVolume(.worktree)])
    }

    func testVolumeNameThatCannotMountIsFlagged() {
        var e = fullEnvelope(1, quota: 50)
        e.scratch = .dedicated(name: "a/b", quotaBytes: Bytes.gb(50), inTimeMachine: false)
        let report = EnvelopeAudit.run([e], on: Sample.host)
        XCTAssertTrue(report.findings.contains { $0.kind == .invalidVolumeName })
        XCTAssertFalse(report.owned["agent-1"]?.contains(.scratchVolume) ?? true)
    }

    func testSystemVolumeNameIsNotAScratchVolume() {
        var e = fullEnvelope(1, quota: 50)
        e.scratch = .dedicated(name: "Data", quotaBytes: Bytes.gb(50), inTimeMachine: false)
        e.worktree = EnvelopePath("/Volumes/Data/worktree")
        e.derivedData = EnvelopePath("/Volumes/Data/dd")
        e.tempRoot = EnvelopePath("/Volumes/Data/tmp")
        let report = EnvelopeAudit.run([e], on: Sample.host)
        XCTAssertTrue(report.findings.contains { $0.kind == .invalidVolumeName })
        XCTAssertFalse(report.owned["agent-1"]?.contains(.scratchVolume) ?? true)
    }

    func testBackedUpVolumeIsStillSnapshotted() {
        var e = fullEnvelope(1, quota: 50)
        e.scratch = .dedicated(name: "agent-1", quotaBytes: Bytes.gb(50), inTimeMachine: true)
        var host = Sample.host
        XCTAssertEqual(EnvelopeAudit.run([e], on: host).findings.map(\.kind), [.snapshotRetention])
        host.timeMachineSnapshots = false
        XCTAssertTrue(EnvelopeAudit.run([e], on: host).findings.isEmpty)
    }

    func testDuplicateAgentIDOwnsNothingAndIdsStayUnique() {
        let e = ExecutionEnvelope(agent: "a", worktree: EnvelopePath("/w/a"))
        let report = EnvelopeAudit.run([e, e], on: Sample.host)
        XCTAssertTrue(report.findings.contains { $0.kind == .duplicateAgentID })
        XCTAssertEqual(report.ownedCount(for: "a"), 0)
        XCTAssertEqual(Set(report.findings.map(\.id)).count, report.findings.count)
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
