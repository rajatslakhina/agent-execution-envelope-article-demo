import XCTest
@testable import AgentEnvelope

final class DiskRunwayTests: XCTestCase {
    func testFloorBreachRunIsPlainArithmetic() {
        XCTAssertEqual(DiskRunway.floorBreachRun(freeBytes: Bytes.gb(550), floorBytes: Bytes.gb(50), bytesPerRun: Bytes.gb(5.7)), 88)
        XCTAssertEqual(DiskRunway.floorBreachRun(freeBytes: Bytes.gb(1_100), floorBytes: Bytes.gb(50), bytesPerRun: Bytes.gb(5.7)), 185)
        XCTAssertEqual(DiskRunway.floorBreachRun(freeBytes: Bytes.gb(40), floorBytes: Bytes.gb(50), bytesPerRun: Bytes.gb(5.7)), 0)
        XCTAssertNil(DiskRunway.floorBreachRun(freeBytes: Bytes.gb(550), floorBytes: Bytes.gb(50), bytesPerRun: 0))
    }

    private func result(_ id: String) throws -> RunwayResult {
        let c = try XCTUnwrap(Sample.runwayCases.first { $0.id == id })
        return Sample.runway(c)
    }

    func testNoEnvelopeCrossesTheFloorInFiveAndAHalfHours() throws {
        let r = try result("none")
        XCTAssertEqual(r.floorBreachRun, 88)
        XCTAssertEqual(r.floorBreachHour, 5.5)
        XCTAssertEqual(r.firstFailedRun, 97, "nine runs after the floor, the disk itself is full")
        XCTAssertEqual(r.minimumFreeBytes, 0)
        XCTAssertEqual(r.points.last?.agentsOutOfSpace, 4)
    }

    func testDoublingFreeSpaceRoughlyDoublesTheRunway() throws {
        let r = try result("bigger-disk")
        XCTAssertEqual(r.floorBreachRun, 185)
        XCTAssertEqual(r.floorBreachHour, 11.5625)
    }

    func testQuotaStopsEachLeakerAndProtectsTheFloor() throws {
        let r = try result("quota")
        XCTAssertNil(r.floorBreachRun)
        XCTAssertEqual(r.firstFailedRun, 69, "agent-1's 18th run hits its 100 GB quota part-way")
        XCTAssertEqual(r.firstFailedHour, 4.3125)
        XCTAssertEqual(r.minimumFreeBytes, Bytes.gb(150), "four full 100 GB volumes")
        XCTAssertEqual(r.points.last?.agentsOutOfSpace, 4)
    }

    func testQuotaPlusTeardownIsSteady() throws {
        let r = try result("envelope")
        XCTAssertNil(r.floorBreachRun)
        XCTAssertNil(r.firstFailedRun)
        XCTAssertEqual(r.failedRuns, 0)
        XCTAssertEqual(r.completedRuns, 12 * 16)
        // Interleaved runs: agent-1 finishes its task while the others hold three runs each.
        XCTAssertEqual(r.minimumFreeBytes, Bytes.gb(550) - 13 * Bytes.gb(5.7))
        XCTAssertEqual(Bytes.format(r.minimumFreeBytes), "475.9 GB")
        XCTAssertEqual(r.points.last?.hostFreeBytes, Bytes.gb(550))
    }

    func testTraceShowsTheDipsTheHourlyPointsHide() throws {
        let r = try result("envelope")
        XCTAssertTrue(r.points.allSatisfy { $0.hostFreeBytes == Bytes.gb(550) }, "every hour ends with all tasks torn down")
        XCTAssertEqual(r.trace.map(\.freeBytes).min(), r.minimumFreeBytes)
        XCTAssertEqual(r.trace.first?.run, 0)
        XCTAssertEqual(r.trace.last?.hour, 12)
        // One sample per run, plus one per teardown: 4 agents x 1 task per hour x 12 hours.
        XCTAssertEqual(r.trace.count, 1 + 192 + 4 * 12)
    }

    func testTeardownFreesAnAgentThatHitsItsQuota() {
        let tiny = DiskPolicy(perAgentQuotaBytes: Bytes.gb(5), teardownEveryRuns: 2)
        let r = DiskRunway.simulate(host: Sample.host, agents: 2, leak: Sample.leak, policy: tiny, hours: 1)
        XCTAssertEqual(r.completedRuns, 0)
        XCTAssertEqual(r.failedRuns, 8)
        XCTAssertEqual(r.points.last?.agentsOutOfSpace, 0, "each failed task is torn down, so nobody stays stuck")
        XCTAssertEqual(r.points.last?.hostFreeBytes, Bytes.gb(550))

        let noTeardown = DiskPolicy(perAgentQuotaBytes: Bytes.gb(5))
        let stuck = DiskRunway.simulate(host: Sample.host, agents: 2, leak: Sample.leak, policy: noTeardown, hours: 1)
        XCTAssertEqual(stuck.points.last?.agentsOutOfSpace, 2)
        XCTAssertEqual(stuck.points.last?.hostFreeBytes, Bytes.gb(540), "each volume is left full at its 5 GB quota")
    }

    func testNoAgentsMeansAFlatLine() {
        let r = DiskRunway.simulate(host: Sample.host, agents: 0, leak: Sample.leak, policy: .none, hours: 3)
        XCTAssertEqual(r.points.map(\.hostFreeBytes), Array(repeating: Bytes.gb(550), count: 4))
        XCTAssertNil(r.floorBreachRun)
        XCTAssertEqual(r.completedRuns, 0)
    }

    /// Writes every runway case's trace as JSON when RUNWAY_TRACE_OUT is set,
    /// so the article's chart (docs/make_runway_chart.py) is drawn from this
    /// model and not a copy of it. A no-op in normal test runs.
    func testExportRunwayTraceWhenAsked() throws {
        guard let out = ProcessInfo.processInfo.environment["RUNWAY_TRACE_OUT"], !out.isEmpty else { return }
        struct Series: Encodable {
            let id: String, title: String
            let floorBreachHour: Double?, firstFailedHour: Double?, minimumFreeGB: Double
            let hours: [Double], freeGB: [Double]
        }
        let series = Sample.runwayCases.map { c -> Series in
            let r = Sample.runway(c)
            return Series(id: c.id, title: c.title, floorBreachHour: r.floorBreachHour, firstFailedHour: r.firstFailedHour,
                          minimumFreeGB: Double(r.minimumFreeBytes) / 1e9,
                          hours: r.trace.map(\.hour), freeGB: r.trace.map { Double($0.freeBytes) / 1e9 })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(series).write(to: URL(fileURLWithPath: out))
    }
}

final class ProvenanceGateTests: XCTestCase {
    private func verdicts(_ replay: Sample.Replay) -> [AgentID: Verdict] {
        let r = Sample.replay(replay)
        return ProvenanceGate.verdicts(receipts: r.receipts, checks: r.checks)
    }

    func testGreenBuildsWithoutALaunchCheckDoNotCount() {
        let v = verdicts(.greenBuildsOnly)
        XCTAssertEqual(v["agent-1"], .notChecked)
        XCTAssertEqual(v["agent-2"], .notChecked)
        XCTAssertFalse(v.values.contains { $0.counts })
    }

    func testSharedSimulatorFailsBothAgents() {
        let v = verdicts(.sharedSimulator)
        XCTAssertEqual(v["agent-1"], .foreignBuild(installedBy: "agent-2"))
        XCTAssertEqual(v["agent-2"], .sharedSimulator(with: ["agent-1"]), "its build is installed, on top of agent-1's app data")
        XCTAssertFalse(v.values.contains { $0.counts })
    }

    func testIdenticalStampsProveNothing() {
        let v = verdicts(.defaultStamps)
        XCTAssertEqual(v["agent-1"], .ambiguousStamp(sharedWith: ["agent-2"]))
        XCTAssertEqual(v["agent-2"], .ambiguousStamp(sharedWith: ["agent-1"]))
    }

    func testEnvelopeVerifiesBoth() {
        let v = verdicts(.envelope)
        XCTAssertEqual(v["agent-1"], .verified)
        XCTAssertEqual(v["agent-2"], .verified)
    }

    func testCheckOnAnotherSimulatorIsRejected() {
        let receipt = BuildReceipt(agent: "a", bundleID: "x", stamp: "7", simulatorUDID: "S1")
        let check = LaunchCheck(agent: "a", simulatorUDID: "S2", bundleID: "x", installedStamp: "7")
        XCTAssertEqual(ProvenanceGate.verdicts(receipts: [receipt], checks: [check])["a"],
                       .wrongSimulator(expected: "S1", actual: "S2"))
    }

    func testLastReceiptAndLastCheckWin() {
        let receipts = [BuildReceipt(agent: "a", bundleID: "x", stamp: "100", simulatorUDID: "S"),
                        BuildReceipt(agent: "a", bundleID: "x", stamp: "111", simulatorUDID: "S")]
        let checks = [LaunchCheck(agent: "a", simulatorUDID: "S", bundleID: "x", installedStamp: "100"),
                      LaunchCheck(agent: "a", simulatorUDID: "S", bundleID: "x", installedStamp: "111")]
        XCTAssertEqual(ProvenanceGate.verdicts(receipts: receipts, checks: checks)["a"], .verified)
    }

    func testUnknownInstalledBuildHasNoOwner() {
        let receipt = BuildReceipt(agent: "a", bundleID: "x", stamp: "7", simulatorUDID: "S")
        let check = LaunchCheck(agent: "a", simulatorUDID: "S", bundleID: "x", installedStamp: "999")
        XCTAssertEqual(ProvenanceGate.verdicts(receipts: [receipt], checks: [check])["a"], .foreignBuild(installedBy: nil))
    }
}

final class EnvelopeContractTests: XCTestCase {
    private func envelope(_ index: Int, _ setup: Sample.Setup = .envelope) throws -> ExecutionEnvelope {
        let all = Sample.envelopes(setup)
        return try XCTUnwrap(all.indices.contains(index) ? all[index] : nil)
    }

    func testAgentsSectionNamesEveryField() throws {
        let text = try EnvelopeContract.agentsSection(for: envelope(1), options: Sample.contractOptions)
        XCTAssertTrue(text.contains("## Execution envelope: agent-2"))
        XCTAssertTrue(text.contains("`/Volumes/agent-2/worktree`"))
        XCTAssertTrue(text.contains("-derivedDataPath '/Volumes/agent-2/DerivedData'"))
        XCTAssertTrue(text.contains("id=22222222-2222-4222-8222-222222222222"))
        XCTAssertTrue(text.contains("`/Volumes/agent-2/tmp`"))
        XCTAssertTrue(text.contains("Your disk budget is 100 GB."))
        XCTAssertTrue(text.contains("confirm CFBundleVersion is `2002`"))
        XCTAssertTrue(text.contains("deletes your worktree, DerivedData, temp root, simulator and scratch volume, whatever state they are in."))
    }

    func testUnboundEnvelopeCannotBeWrittenUp() throws {
        XCTAssertThrowsError(try EnvelopeContract.agentsSection(for: envelope(0, .worktreesOnly), options: Sample.contractOptions)) { error in
            XCTAssertEqual(error as? ContractError,
                           ContractError(reason: .unbound([.derivedData, .simulator, .tempRoot, .scratchVolume])))
        }
        var bad = try envelope(0)
        bad.simulator = .dedicated(udid: "booted")
        XCTAssertThrowsError(try EnvelopeContract.agentsSection(for: bad, options: Sample.contractOptions)) { error in
            XCTAssertEqual(error as? ContractError, ContractError(reason: .unbound([.simulator])))
        }
    }

    func testTeardownDeletesTheWholeVolume() throws {
        let commands = try EnvelopeContract.teardownCommands(for: envelope(1), repo: Sample.repo)
        XCTAssertEqual(commands, [
            "xcrun simctl delete '22222222-2222-4222-8222-222222222222'",
            "git -C \"$HOME\"'/src/App' worktree remove --force '/Volumes/agent-2/worktree'",
            "diskutil apfs deleteVolume '/Volumes/agent-2'",
        ])
    }

    func testTeardownDeletesFoldersWhenTheVolumeStays() throws {
        var e = try envelope(1)
        e.teardown.remove(.scratchVolume)
        XCTAssertEqual(try EnvelopeContract.teardownCommands(for: e, repo: Sample.repo), [
            "xcrun simctl delete '22222222-2222-4222-8222-222222222222'",
            "git -C \"$HOME\"'/src/App' worktree remove --force '/Volumes/agent-2/worktree'",
            "rm -rf '/Volumes/agent-2/DerivedData'",
            "rm -rf '/Volumes/agent-2/tmp'",
        ])
        let inWorktree = try EnvelopeContract.teardownCommands(for: envelope(0, .worktreeAndSimulator), repo: Sample.repo)
        XCTAssertFalse(inWorktree.contains { $0.hasPrefix("rm -rf") }, "DerivedData lives inside the worktree")
    }

    func testRefusesToDeleteAnythingOutsideAnAllowedRoot() throws {
        let dangerous = [
            "/tmp",
            "/Users/me/Library/Developer/Xcode/DerivedData",
            "~/Library/Developer/CoreSimulator/Devices",
            "~/Library/Developer/Xcode/DerivedData/ModuleCache.noindex",
            "/Volumes/Macintosh HD/Users",
            "/Volumes/Macintosh HD/Applications",
            "/Users/me/Documents/Taxes",
            "~/agents",
        ]
        for raw in dangerous {
            let e = ExecutionEnvelope(agent: "a", tempRoot: EnvelopePath(raw), teardown: [.tempRoot])
            XCTAssertThrowsError(try EnvelopeContract.teardownCommands(for: e, repo: Sample.repo, agentsRoot: EnvelopePath("~/agents")), raw)
        }
        let systemVolume = ExecutionEnvelope(agent: "a", tempRoot: EnvelopePath("/Volumes/Macintosh HD/tmp"),
                                             scratch: .dedicated(name: "Macintosh HD", quotaBytes: 1, inTimeMachine: false), teardown: [.tempRoot, .scratchVolume])
        XCTAssertThrowsError(try EnvelopeContract.teardownCommands(for: systemVolume, repo: Sample.repo))
    }

    func testAllowsDeletesInsideTheAgentsRoot() throws {
        let e = ExecutionEnvelope(agent: "a", tempRoot: EnvelopePath("~/agents/a/tmp"), teardown: [.tempRoot])
        XCTAssertEqual(try EnvelopeContract.teardownCommands(for: e, repo: Sample.repo, agentsRoot: EnvelopePath("~/agents")),
                       ["rm -rf \"$HOME\"'/agents/a/tmp'"])
        XCTAssertThrowsError(try EnvelopeContract.teardownCommands(for: e, repo: Sample.repo), "no agents root, no rm -rf")
        for root in ["~", "~/Library", "/Users/me", "/tmp/agents", "/Volumes/Macintosh HD/agents"] {
            XCTAssertFalse(EnvelopeContract.isSaneAgentsRoot(try XCTUnwrap(EnvelopePath(root))), root)
        }
        for root in ["~/agents", "~/Developer/agents", "/Users/me/agents", "/Volumes/agents"] {
            XCTAssertTrue(EnvelopeContract.isSaneAgentsRoot(try XCTUnwrap(EnvelopePath(root))), root)
        }
    }

    func testRefusesToDeleteASimulatorThatIsNotAUUID() {
        let e = ExecutionEnvelope(agent: "a", simulator: .dedicated(udid: "all"), teardown: [.simulator])
        XCTAssertThrowsError(try EnvelopeContract.teardownCommands(for: e, repo: Sample.repo)) { error in
            XCTAssertEqual(error as? ContractError, ContractError(reason: .invalidSimulatorUDID("all")))
        }
    }

    func testShellQuoting() throws {
        XCTAssertEqual(EnvelopeContract.shellQuote(try XCTUnwrap(EnvelopePath("/Volumes/agent 1/it's"))), "'/Volumes/agent 1/it'\\''s'")
        XCTAssertEqual(EnvelopeContract.shellQuote(try XCTUnwrap(EnvelopePath("~/src/My App"))), "\"$HOME\"'/src/My App'")
        XCTAssertEqual(EnvelopeContract.shellQuote(EnvelopePath.home), "\"$HOME\"")
    }
}
