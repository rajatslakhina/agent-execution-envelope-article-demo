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

enum Tab: String, Hashable {
    case audit, runway, verify, contract
}

struct RootView: View {
    @State private var tab = Tab(rawValue: LaunchOptions.string("tab") ?? "") ?? .audit

    var body: some View {
        TabView(selection: $tab) {
            AuditView()
                .tabItem { Label("Audit", systemImage: "square.grid.3x3") }
                .tag(Tab.audit)
            RunwayView()
                .tabItem { Label("Runway", systemImage: "internaldrive") }
                .tag(Tab.runway)
            VerifyView()
                .tabItem { Label("Verify", systemImage: "checkmark.seal") }
                .tag(Tab.verify)
            ContractView()
                .tabItem { Label("Contract", systemImage: "doc.text") }
                .tag(Tab.contract)
        }
    }
}

// MARK: - Audit

struct AuditView: View {
    @State private var setup = Sample.Setup(rawValue: LaunchOptions.string("setup") ?? "") ?? .worktreesOnly

    private var report: AuditReport { EnvelopeAudit.run(Sample.envelopes(setup), on: Sample.host) }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Setup", selection: $setup) {
                        ForEach(Sample.Setup.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    summary
                }
                Section("Who owns each field") {
                    ForEach(Field.allCases, id: \.self) { field in
                        OwnershipRow(field: field, report: report)
                    }
                }
                if !report.findings.isEmpty {
                    ForEach(Finding.Severity.allCases, id: \.self) { severity in
                        let items = report.findings.filter { $0.severity == severity }
                        if !items.isEmpty {
                            Section("\(severity.title) (\(items.count))") {
                                ForEach(items) { FindingRow(finding: $0) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Envelope audit")
        }
    }

    private var summary: some View {
        let owned = Sample.agents.map { report.ownedCount(for: $0) }
        let lowest = owned.min() ?? 0
        let n = report.findings.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("Each agent owns \(lowest) of \(Field.allCases.count) fields")
                .font(.title3.weight(.semibold))
            Text(n == 0
                 ? "No findings. Four agents can share this Mac."
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

struct RunwaySeriesPoint: Identifiable {
    let series: String
    let hour: Int
    let freeGB: Double
    var id: String { "\(series)-\(hour)" }
}

struct RunwayRow: Identifiable {
    let policy: Sample.RunwayCase
    let result: RunwayResult
    var id: String { policy.id }
}

struct RunwayView: View {
    private let hours = 12
    private let rows: [RunwayRow] = Sample.runwayCases.map { RunwayRow(policy: $0, result: Sample.runway($0)) }

    private var points: [RunwaySeriesPoint] {
        rows.flatMap { row in
            row.result.points.map {
                RunwaySeriesPoint(series: row.policy.title, hour: $0.hour, freeGB: Double($0.hostFreeBytes) / 1_000_000_000)
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("4 agents · QA every 15 minutes · each run leaves a 5.7 GB fixture behind")
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
                                Text("50 GB floor").font(.caption2).foregroundStyle(.red)
                            }
                    }
                    .chartForegroundStyleScale([
                        "No envelope, 550 GB free": Color.red,
                        "No envelope, 1.1 TB free": Color.orange,
                        "100 GB quota, no teardown": Color.purple,
                        "Quota + teardown each task": Color.green,
                    ])
                    .chartXScale(domain: 0...hours)
                    .chartYScale(domain: 0...1_200)
                    .chartXAxisLabel("Hours")
                    .chartYAxisLabel("Free GB on the Mac")
                    .chartLegend(.hidden)
                    .frame(height: 260)
                    .accessibilityLabel("Free disk space over twelve hours for four policies")
                }
                Section("What happens") {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.policy.title).font(.subheadline.weight(.semibold)).foregroundStyle(color(row.id))
                            Text(outcome(row.result)).font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Disk runway")
        }
    }

    private func color(_ id: String) -> Color {
        switch id {
        case "none": return .red
        case "bigger-disk": return .orange
        case "quota": return .purple
        default: return .green
        }
    }

    private func outcome(_ r: RunwayResult) -> String {
        if let h = r.floorBreachHour {
            return "Below the floor after \(hoursText(h)) (run \(r.floorBreachRun ?? 0)). macOS, Xcode and every agent are squeezed together."
        }
        if let h = r.firstFailedHour {
            return "Each agent stops at its own cap from \(hoursText(h)). The Mac never drops below \(Bytes.format(r.minimumFreeBytes)) free."
        }
        return "Steady. Free space never drops below \(Bytes.format(r.minimumFreeBytes))."
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
                    Text("Only Verified lets an agent report success. A green build says the code compiled, not whose app is installed.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Verify the build")
        }
    }

    private var caption: String {
        switch replay {
        case .greenBuildsOnly: return "Both builds succeed and both agents report green. Nobody launches the app and reads what is installed."
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
