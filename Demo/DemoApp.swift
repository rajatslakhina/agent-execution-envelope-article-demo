import AgentEnvelope
import Charts
import SwiftUI

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Launch arguments pick the starting screen, so the screenshot script can
/// open each tab without tapping: `-tab runway`, `-setup envelope`, `-replay sharedSimulator`.
enum LaunchOptions {
    static func string(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }
}

enum DemoTab: String, Hashable {
    case audit, runway, verify, contract
}

struct RootView: View {
    @State private var tab = DemoTab(rawValue: LaunchOptions.string("tab") ?? "") ?? .audit

    var body: some View {
        TabView(selection: $tab) {
            AuditView()
                .tabItem { Label("Audit", systemImage: "square.grid.3x3") }
                .tag(DemoTab.audit)
            RunwayView()
                .tabItem { Label("Runway", systemImage: "internaldrive") }
                .tag(DemoTab.runway)
            VerifyView()
                .tabItem { Label("Verify", systemImage: "checkmark.seal") }
                .tag(DemoTab.verify)
            ContractView()
                .tabItem { Label("Contract", systemImage: "doc.text") }
                .tag(DemoTab.contract)
        }
    }
}

// MARK: - Audit

struct AuditView: View {
    @State private var setup = Sample.Setup(rawValue: LaunchOptions.string("setup") ?? "") ?? .worktreesOnly

    var body: some View {
        let report = EnvelopeAudit.run(Sample.envelopes(setup), on: Sample.host)
        return NavigationStack {
            List {
                Section {
                    Picker("Setup", selection: $setup) {
                        ForEach(Sample.Setup.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    AuditSummary(report: report)
                }
                Section("Who owns each field") {
                    ForEach(Field.allCases, id: \.self) { field in
                        OwnershipRow(field: field, report: report)
                    }
                }
                ForEach(Finding.Severity.allCases, id: \.self) { severity in
                    let items = report.findings.filter { $0.severity == severity }
                    if !items.isEmpty {
                        Section("\(severity.title) (\(items.count))") {
                            ForEach(items) { FindingRow(finding: $0) }
                        }
                    }
                }
            }
            .navigationTitle("Envelope audit")
        }
    }
}

struct AuditSummary: View {
    let report: AuditReport

    var body: some View {
        let lowest = Sample.agents.map { report.ownedCount(for: $0) }.min() ?? 0
        let n = report.findings.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("Each agent owns \(lowest) of \(Field.allCases.count) fields")
                .font(.title3.weight(.semibold))
            Text(n == 0
                 ? "No findings. These \(Sample.agents.count) agents can share this Mac."
                 : "\(n) findings: \(report.count(.collision)) collision · \(report.count(.leak)) leak · \(report.count(.capacity)) capacity")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct OwnershipRow: View {
    let field: Field
    let report: AuditReport

    var body: some View {
        HStack {
            Text(field.title)
            Spacer()
            ForEach(Sample.agents, id: \.self) { agent in
                let owned = report.owned[agent]?.contains(field) ?? false
                Image(systemName: owned ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(owned ? Color.green : Color.red)
                    .accessibilityLabel("\(agent.rawValue) \(owned ? "owns" : "doesn't own") \(field.title)")
            }
        }
        .font(.body)
    }
}

struct FindingRow: View {
    let finding: Finding

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(finding.agents.map(\.rawValue).joined(separator: ", "))
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(finding.detail)
                .font(.footnote)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch finding.severity {
        case .collision: return .red
        case .leak: return .orange
        case .capacity: return .purple
        }
    }
}

// MARK: - Runway

struct RunwayRow: Identifiable {
    let policy: Sample.RunwayCase
    let result: RunwayResult
    let color: Color
    var id: String { policy.id }
}

struct TracePoint: Identifiable {
    let series: String
    let index: Int
    let hour: Double
    let freeGB: Double
    var id: String { "\(series)-\(index)" }
}

struct RunwayView: View {
    private static let hours = 12
    private static let palette: [Color] = [.red, .orange, .purple, .green, .blue, .teal]

    private let rows: [RunwayRow] = Sample.runwayCases.enumerated().map { index, c in
        RunwayRow(policy: c, result: Sample.runway(c, hours: RunwayView.hours),
                  color: RunwayView.palette.indices.contains(index) ? RunwayView.palette[index] : .gray)
    }

    private var points: [TracePoint] {
        rows.flatMap { row in
            row.result.trace.enumerated().map { i, s in
                TracePoint(series: row.policy.title, index: i, hour: s.hour, freeGB: Double(s.freeBytes) / 1_000_000_000)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(Sample.agents.count) agents · QA every \(60 / max(1, Sample.leak.runsPerAgentPerHour)) minutes · each run leaves \(Bytes.format(Sample.leak.bytesPerRun)) behind")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Chart {
                        ForEach(points) { p in
                            LineMark(x: .value("Hour", p.hour), y: .value("Free GB", p.freeGB))
                                .foregroundStyle(by: .value("Policy", p.series))
                                .interpolationMethod(.linear)
                        }
                        RuleMark(y: .value("Floor", Double(Sample.host.floorBytes) / 1_000_000_000))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.red)
                            .annotation(position: .top, alignment: .leading) {
                                Text("\(Bytes.format(Sample.host.floorBytes)) floor").font(.caption2).foregroundStyle(.red)
                            }
                    }
                    .chartForegroundStyleScale(domain: rows.map(\.policy.title), range: rows.map(\.color))
                    .chartXScale(domain: 0...Double(Self.hours))
                    .chartYScale(domain: 0...1_200)
                    .chartXAxisLabel("Hours")
                    .chartYAxisLabel("Free GB on the Mac")
                    .chartLegend(.hidden)
                    .frame(height: 260)
                    .accessibilityLabel("Free disk space over \(Self.hours) hours for \(rows.count) policies")
                }
                Section("What happens") {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.policy.title).font(.subheadline.weight(.semibold)).foregroundStyle(row.color)
                            Text(outcome(row.result)).font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Disk runway")
        }
    }

    private func outcome(_ r: RunwayResult) -> String {
        if let h = r.floorBreachHour {
            return "Below the floor after \(hoursText(h)) (run \(r.floorBreachRun ?? 0)). macOS, Xcode and every agent are squeezed together."
        }
        if let h = r.firstFailedHour {
            return "Each agent stops at its own cap from \(hoursText(h)). The Mac bottoms out at \(Bytes.format(r.minimumFreeBytes)) free."
        }
        return "Steady. Free space bottoms out at \(Bytes.format(r.minimumFreeBytes)), just before each teardown."
    }

    private func hoursText(_ h: Double) -> String { String(format: "%.1f h", h) }
}

// MARK: - Verify

struct VerifyView: View {
    @State private var replay = Sample.Replay(rawValue: LaunchOptions.string("replay") ?? "") ?? .sharedSimulator

    var body: some View {
        let data = Sample.replay(replay)
        let verdicts = ProvenanceGate.verdicts(receipts: data.receipts, checks: data.checks)
        return NavigationStack {
            List {
                Section {
                    Picker("Replay", selection: $replay) {
                        ForEach(Sample.Replay.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(data.receipts, id: \.agent) { receipt in
                    let check = data.checks.last { $0.agent == receipt.agent }
                    let verdict = verdicts[receipt.agent] ?? .notChecked
                    Section(receipt.agent.rawValue) {
                        LabeledContent("Built", value: "build \(receipt.stamp)")
                        LabeledContent("Installed on", value: shortUDID(receipt.simulatorUDID))
                        LabeledContent("Read back", value: check.map { "build \($0.installedStamp) on \(shortUDID($0.simulatorUDID))" } ?? "nothing")
                        HStack {
                            Image(systemName: verdict.counts ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            Text(verdict.title).fontWeight(.semibold)
                        }
                        .foregroundStyle(verdict.counts ? Color.green : Color.red)
                    }
                }
                Section {
                    Text("Only Verified lets an agent report success: its own stamp, read back from a simulator nobody else installed to.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Verify the build")
        }
    }

    private var caption: String {
        switch replay {
        case .greenBuildsOnly: return "Two green builds, and neither agent launches the app to check which build is installed."
        case .sharedSimulator: return "Stamped 111 and 222, both installed on the one booted simulator, then each agent reads the installed build."
        case .defaultStamps: return "Same, but nobody stamped the builds: every worktree builds version 1, so the read-back proves nothing."
        case .envelope: return "Each agent builds with its own stamp and installs on its own simulator."
        }
    }

    private func shortUDID(_ udid: String) -> String {
        udid == Sample.bootedUDID ? "the booted simulator" : String(udid.prefix(8)) + "…"
    }
}

// MARK: - Contract

struct ContractView: View {
    private var envelope: ExecutionEnvelope? {
        Sample.envelopes(.envelope).first { $0.agent == "agent-2" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Generated from the same envelope the audit checks, so the instructions and the harness can't drift apart.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    block(title: "AGENTS.md", text: section)
                    block(title: "Harness teardown", text: teardown)
                }
                .padding()
            }
            .navigationTitle("Contract")
        }
    }

    private var section: String {
        guard let envelope else { return "No envelope for agent-2." }
        do {
            return try EnvelopeContract.agentsSection(for: envelope, options: Sample.contractOptions)
        } catch {
            return "Can't write instructions: \(error)"
        }
    }

    private var teardown: String {
        guard let envelope else { return "" }
        do {
            return try EnvelopeContract.teardownCommands(for: envelope, repo: Sample.repo).joined(separator: "\n")
        } catch {
            return "Refused: \(error)"
        }
    }

    private func block(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
