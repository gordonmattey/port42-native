import SwiftUI

public struct UsageSheet: View {
    @EnvironmentObject var appState: AppState
    @Binding var isPresented: Bool

    enum Period: String, CaseIterable {
        case day = "Day"
        case week = "Week"
        case month = "Month"
    }

    enum Grouping: String, CaseIterable {
        case companion = "Companion"
        case port = "Port"
        case model = "Model"
    }

    @State private var period: Period = .day
    @State private var grouping: Grouping = .companion
    @State private var offset: Int = 0  // 0 = current, -1 = previous, etc.

    @State private var aggregates: [DatabaseService.UsageAggregate] = []
    @State private var totalInput: Int = 0
    @State private var totalOutput: Int = 0
    @State private var totalRequests: Int = 0
    @State private var totalCacheRead: Int = 0
    @State private var totalCacheCreation: Int = 0
    @State private var recentCalls: [DatabaseService.UsageRecord] = []

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Token Usage")
                    .font(Port42Theme.monoBold(16))
                    .foregroundStyle(Port42Theme.textPrimary)
                Spacer()
                Button("Done") { isPresented = false }
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.accent)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Period selector + navigation
            HStack(spacing: 12) {
                Picker("", selection: $period) {
                    ForEach(Period.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Spacer()

                Button(action: { offset -= 1 }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Port42Theme.textSecondary)

                Text(periodLabel)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textSecondary)
                    .frame(minWidth: 100)

                Button(action: { offset += 1 }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(offset < 0 ? Port42Theme.textSecondary : Port42Theme.textSecondary.opacity(0.3))
                .disabled(offset >= 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // Key stats
            HStack(spacing: 0) {
                StatBox(label: "Total", value: formatTokens(totalInput + totalOutput))
                Spacer()
                StatBox(label: "Requests", value: "\(totalRequests)")
                Spacer()
                StatBox(label: "Avg/Req", value: totalRequests > 0 ? formatTokens((totalInput + totalOutput) / totalRequests) : "–")
                Spacer()
                if totalCacheRead > 0 || totalCacheCreation > 0 {
                    let hitRate = (totalInput + totalCacheRead) > 0
                        ? Int(Double(totalCacheRead) / Double(totalInput + totalCacheRead) * 100) : 0
                    StatBox(label: "Cache", value: "\(hitRate)%")
                } else {
                    StatBox(label: "Cache", value: "–")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)

            // Breakdown line
            HStack(spacing: 12) {
                Text("\(formatTokens(totalInput)) in")
                    .foregroundStyle(Port42Theme.accent.opacity(0.7))
                Text("\(formatTokens(totalOutput)) out")
                    .foregroundStyle(Port42Theme.accent.opacity(0.4))
                if totalCacheRead > 0 {
                    Text("\(formatTokens(totalCacheRead)) cached")
                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                }
            }
            .font(Port42Theme.mono(10))
            .padding(.horizontal, 20)

            Spacer().frame(height: 8)

            // Grouping toggle
            HStack {
                Picker("Group by", selection: $grouping) {
                    ForEach(Grouping.allCases, id: \.self) { g in
                        Text(g.rawValue).tag(g)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            // Breakdown bars + recent calls
            if aggregates.isEmpty && recentCalls.isEmpty {
                VStack {
                    Spacer()
                    Text("No usage data for this period")
                        .font(Port42Theme.mono(13))
                        .foregroundStyle(Port42Theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(aggregates, id: \.key) { agg in
                            UsageRow(
                                label: agg.key,
                                inputTokens: agg.inputTokens,
                                outputTokens: agg.outputTokens,
                                requests: agg.requests,
                                maxTokens: aggregates.map { $0.inputTokens + $0.outputTokens }.max() ?? 1
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                    // Recent calls
                    if !recentCalls.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Recent Calls")
                                .font(Port42Theme.monoBold(11))
                                .foregroundStyle(Port42Theme.textSecondary)
                                .padding(.bottom, 2)

                            ForEach(Array(recentCalls.enumerated()), id: \.offset) { _, record in
                                HStack(spacing: 8) {
                                    Text(record.source)
                                        .font(Port42Theme.mono(11))
                                        .foregroundStyle(Port42Theme.textPrimary)
                                        .frame(width: 80, alignment: .leading)
                                        .lineLimit(1)
                                    Text(shortModel(record.model))
                                        .font(Port42Theme.mono(10))
                                        .foregroundStyle(Port42Theme.textSecondary)
                                        .frame(width: 60, alignment: .leading)
                                    Spacer()
                                    Text("\(formatTokens(record.inputTokens)) in")
                                        .font(Port42Theme.mono(10))
                                        .foregroundStyle(Port42Theme.accent.opacity(0.7))
                                    Text("\(formatTokens(record.outputTokens)) out")
                                        .font(Port42Theme.mono(10))
                                        .foregroundStyle(Port42Theme.accent.opacity(0.4))
                                    Text(timeAgo(record.timestamp))
                                        .font(Port42Theme.mono(10))
                                        .foregroundStyle(Port42Theme.textSecondary.opacity(0.6))
                                        .frame(width: 40, alignment: .trailing)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                    }
                }
            }
        }
        .frame(width: 520, height: 560)
        .background(Port42Theme.bgPrimary)
        .background(WindowRefAccessor { window in
            window?.level = .floating
        })
        .onChange(of: period) { _ in offset = 0; reload() }
        .onChange(of: offset) { _ in reload() }
        .onChange(of: grouping) { _ in reload() }
        .onAppear { reload() }
    }

    // MARK: - Date math

    private var dateRange: (from: Date, to: Date) {
        let cal = Calendar.current
        let now = Date()
        switch period {
        case .day:
            let start = cal.startOfDay(for: cal.date(byAdding: .day, value: offset, to: now)!)
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            return (start, end)
        case .week:
            let todayStart = cal.startOfDay(for: now)
            let weekday = cal.component(.weekday, from: todayStart)
            let weekStart = cal.date(byAdding: .day, value: -(weekday - cal.firstWeekday), to: todayStart)!
            let shifted = cal.date(byAdding: .weekOfYear, value: offset, to: weekStart)!
            let end = cal.date(byAdding: .weekOfYear, value: 1, to: shifted)!
            return (shifted, end)
        case .month:
            let comps = cal.dateComponents([.year, .month], from: now)
            let monthStart = cal.date(from: comps)!
            let shifted = cal.date(byAdding: .month, value: offset, to: monthStart)!
            let end = cal.date(byAdding: .month, value: 1, to: shifted)!
            return (shifted, end)
        }
    }

    private var periodLabel: String {
        let (from, to) = dateRange
        let f = DateFormatter()
        switch period {
        case .day:
            f.dateFormat = "MMM d, yyyy"
            return f.string(from: from)
        case .week:
            f.dateFormat = "MMM d"
            let f2 = DateFormatter()
            f2.dateFormat = "MMM d"
            let end = Calendar.current.date(byAdding: .day, value: -1, to: to)!
            return "\(f.string(from: from)) – \(f2.string(from: end))"
        case .month:
            f.dateFormat = "MMMM yyyy"
            return f.string(from: from)
        }
    }

    private func reload() {
        let (from, to) = dateRange
        let total = (try? appState.db.usageTotal(from: from, to: to)) ?? (0, 0, 0, 0, 0)
        totalInput = total.0
        totalOutput = total.1
        totalRequests = total.2
        totalCacheRead = total.3
        totalCacheCreation = total.4

        let allBySource = (try? appState.db.usageBySource(from: from, to: to)) ?? []
        switch grouping {
        case .companion:
            aggregates = allBySource.filter { !$0.key.hasPrefix("port:") }
        case .port:
            aggregates = allBySource.filter { $0.key.hasPrefix("port:") }.map {
                DatabaseService.UsageAggregate(
                    key: String($0.key.dropFirst(5)),
                    inputTokens: $0.inputTokens,
                    outputTokens: $0.outputTokens,
                    requests: $0.requests
                )
            }
        case .model:
            aggregates = (try? appState.db.usageByModel(from: from, to: to)) ?? []
        }

        recentCalls = (try? appState.db.recentUsage(from: from, to: to, limit: 5)) ?? []
    }

    private func shortModel(_ model: String) -> String {
        if model.contains("opus") { return "opus" }
        if model.contains("sonnet") { return "sonnet" }
        if model.contains("haiku") { return "haiku" }
        if model.contains("gemini") { return "gemini" }
        return String(model.prefix(8))
    }

    private func timeAgo(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

// MARK: - Subviews

private struct StatBox: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(Port42Theme.monoBold(16))
                .foregroundStyle(Port42Theme.accent)
            Text(label)
                .font(Port42Theme.mono(10))
                .foregroundStyle(Port42Theme.textSecondary)
        }
    }
}

private struct UsageRow: View {
    let label: String
    let inputTokens: Int
    let outputTokens: Int
    let requests: Int
    let maxTokens: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(Port42Theme.mono(12))
                    .foregroundStyle(Port42Theme.textPrimary)
                Spacer()
                Text("\(formatTokens(inputTokens + outputTokens)) tokens · \(requests) calls")
                    .font(Port42Theme.mono(10))
                    .foregroundStyle(Port42Theme.textSecondary)
            }

            // Stacked bar
            GeometryReader { geo in
                let total = inputTokens + outputTokens
                let fraction = maxTokens > 0 ? CGFloat(total) / CGFloat(maxTokens) : 0
                let inputFraction = total > 0 ? CGFloat(inputTokens) / CGFloat(total) : 0
                let barWidth = geo.size.width * fraction

                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Port42Theme.accent.opacity(0.7))
                        .frame(width: max(barWidth * inputFraction, 1))
                    Rectangle()
                        .fill(Port42Theme.accent.opacity(0.3))
                        .frame(width: max(barWidth * (1 - inputFraction), 0))
                }
                .frame(height: 6)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}
