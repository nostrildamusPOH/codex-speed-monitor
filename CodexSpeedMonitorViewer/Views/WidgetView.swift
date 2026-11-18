import SwiftUI
import AppKit

struct WidgetView: View {
    @ObservedObject var store: TelemetryStore
    var initialSpeedSelection: SpeedSelection? = nil
    @AppStorage("telemetryTimeScope") private var timeScope = "today"
    private let timer = Timer.publish(every:15,tolerance:2,on:.main,in:.common).autoconnect()

    var body: some View {
        // The window hugs its content (up to a cap set by FittingScroll), so a
        // short overview doesn't leave an empty black area under the list.
        VStack(spacing:0) {
            TimelineView(.periodic(from:.now,by:15)) {context in
                CompactSpeedContent(report:store.speedReport,now:context.date,initialSelection:initialSpeedSelection,refresh:{store.refresh(scope:timeScope,force:true)})
            }
            Rectangle().fill(SpeedTheme.divider).frame(height:1)
            WidgetFooter(snapshot:store.snapshot,scope:timeScope,updated:store.speedReport.snapshotAt ?? store.speedReport.checkedAt) {store.refresh(scope:timeScope,force:true)}

        }
        .frame(width:400)
        .background(SpeedTheme.surface)
        .foregroundStyle(SpeedTheme.primary)
        .preferredColorScheme(.dark)
        .onAppear { store.setScope(timeScope) }
        .onChange(of: timeScope) { store.setScope(timeScope) }
        .onReceive(timer) { _ in store.refresh(scope: timeScope) }
    }
}

struct WidgetTopBar: View {
    let snapshot: Snapshot
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Token Speed")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                Text("Trusted Codex responses")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
            }
            Spacer()
            StatusBadge(live: snapshot.live)
        }
    }
}

struct StatusBadge: View {
    let live: Bool
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(live ? fastTone : mutedTone)
                .frame(width: 7, height: 7)
                .shadow(color: (live ? fastTone : mutedTone).opacity(0.42), radius: 4)
            Text(live ? "Collector current" : "Collector stale")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(live ? 0.84 : 0.50))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .background(.white.opacity(0.065), in: Capsule())
    }
}

struct WidgetTabControl: View {
    @Binding var tab: String
    private let options = [("model", "Model"), ("effective", "End-to-end")]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { option in
                Button(action: { tab = option.0 }) {
                    Text(option.1)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(tab == option.0 ? .white.opacity(0.94) : .white.opacity(0.38))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(tab == option.0 ? .white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct ScopeControl: View {
    @Binding var scope: String
    private let options = [("today", "Today"), ("7d", "7 days"), ("14d", "14 days")]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { option in
                Button(action: { scope = option.0 }) {
                    Text(option.1)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(scope == option.0 ? .white.opacity(0.95) : .white.opacity(0.38))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(scope == option.0 ? .white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct WidgetHero: View {
    let snapshot: Snapshot
    let scope: String
    let metricLabel: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(scopeTitle(scope).uppercased())
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(String(format: "%.1f", snapshot.todayTPS))
                            .font(.system(size: 54, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.96))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                        Text("t/s")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.44))
                    }
                }
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(scopeSubtitle(scope))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                    Text(metricLabel)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.28))
                }
                .padding(.top, 5)
            }
            HStack(spacing: 10) {
                HeroMetric(title: "responses", value: "\(snapshot.todayTurns)")
                HeroMetric(title: "tokens", value: compact(snapshot.todayTokens))
            }
        }
        .padding(17)
        .background(
            LinearGradient(colors: [.white.opacity(0.075), .white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.08)))
    }
}

struct HeroMetric: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.30))
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModeComparison: View {
    let title: String
    let modes: [ModeRow]
    var fastRows: [ModeRow] { modes.filter { $0.name.lowercased() == "fast" } }
    var standardRows: [ModeRow] { modes.filter { $0.name.lowercased() == "standard" || $0.name.lowercased() == "default" } }
    var fastTPS: Double { weightedAverage(rows: fastRows) }
    var standardTPS: Double { weightedAverage(rows: standardRows) }
    var maxTPS: Double { max(fastTPS, standardTPS, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Text(speedMultiple(fast: fastTPS, standard: standardTPS))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.36))
                    .lineLimit(1)
            }
            VStack(spacing: 11) {
                ModeSpeedRow(title: "Fast", rows: fastRows, accent: fastTone, maxTPS: maxTPS)
                ModeSpeedRow(title: "Standard", rows: standardRows, accent: standardTone, maxTPS: maxTPS)
            }
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.06)))
    }
}

struct ModeSpeedRow: View {
    let title: String
    let rows: [ModeRow]
    let accent: Color
    let maxTPS: Double
    var turns: Int { rows.reduce(0) { $0 + $1.turns } }
    var tokens: Int64 { rows.reduce(0) { $0 + $1.tokens } }
    var tps: Double { weightedAverage(rows: rows) }
    var widthRatio: Double { turns == 0 ? 0 : min(max(tps / maxTPS, 0), 1) }

    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(accent.opacity(0.95))
                    .frame(width: 76, alignment: .leading)
                if turns == 0 {
                    Text("No data")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                } else {
                    Text(String(format: "%.1f", tps))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .monospacedDigit()
                    Text("t/s")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.40))
                    Spacer(minLength: 8)
                    Text("\(turns) · \(compact(tokens))")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                }
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.075))
                    Capsule()
                        .fill(LinearGradient(colors: [accent.opacity(0.96), accent.opacity(0.44)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(turns == 0 ? 0 : 10, proxy.size.width * CGFloat(widthRatio)))
                }
            }
            .frame(height: 6)
        }
    }
}

struct TrendPanel: View {
    let points: [MiniDay]
    let scope: String
    var title: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title ?? (scope == "today" ? "Live trend" : "Daily trend"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer()
                Text(scopeTitle(scope))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
            }
            HStack(spacing: 14) {
                Legend(label: "Fast", tone: fastTone, dash: false)
                Legend(label: "Standard", tone: standardTone, dash: true)
                Spacer()
            }
            Sparkline(days: points, scope: scope)
                .frame(height: 112)
        }
        .padding(16)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.06)))
    }
}

struct Sparkline: View {
    let days: [MiniDay]
    let scope: String
    var grouped: [(String, [MiniDay])] {
        Dictionary(grouping: days, by: { $0.lane })
            .map { ($0.key, $0.value.sorted { $0.date < $1.date }) }
            .sorted { laneRank($0.0) < laneRank($1.0) }
    }

    var body: some View {
        Canvas { context, size in
            guard !days.isEmpty else {
                context.draw(Text("Waiting for speed data").font(.caption).foregroundStyle(.white.opacity(0.35)), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let allDates = days.map(\.date).sorted()
            let rawMinDate = allDates.first ?? Date()
            let rawMaxDate = allDates.last ?? rawMinDate
            let span = rawMaxDate.timeIntervalSince(rawMinDate)
            let minWindow = scope == "today" ? 3600.0 : 86400.0
            let pad = scope == "today" ? 300.0 : 43200.0
            let minDate = scope == "today" && span < minWindow ? rawMaxDate.addingTimeInterval(-minWindow) : rawMinDate.addingTimeInterval(-pad)
            let maxDate = scope == "today" && span < minWindow ? rawMaxDate.addingTimeInterval(pad) : rawMaxDate.addingTimeInterval(pad)
            let maxY = niceCeiling(max(days.map(\.tps).max() ?? 1, 1) * 1.08)
            let plot = CGRect(x: 6, y: 8, width: size.width - 12, height: size.height - 30)
            var grid = Path()
            for i in 0...2 {
                let y = plot.maxY - plot.height * CGFloat(i) / 2
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(0.075)), lineWidth: 1)
            func x(_ date: Date) -> CGFloat {
                let xSpan = max(maxDate.timeIntervalSince(minDate), minWindow)
                return plot.minX + plot.width * CGFloat(date.timeIntervalSince(minDate) / xSpan)
            }
            func y(_ value: Double) -> CGFloat { plot.maxY - plot.height * CGFloat(value / maxY) }
            for (lane, rows) in grouped {
                if rows.count >= 2 {
                    var path = Path()
                    for (idx, day) in rows.enumerated() {
                        let point = CGPoint(x: x(day.date), y: y(day.tps))
                        if idx == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    let isFast = lane.lowercased() == "fast"
                    context.stroke(path, with: .color(tone(for: lane)), style: StrokeStyle(lineWidth: isFast ? 3.2 : 2.1, lineCap: .round, lineJoin: .round, dash: isFast ? [] : [4, 4]))
                }
                let dots = rows.count <= 4 ? rows : Array(rows.suffix(2))
                for row in dots {
                    let point = CGPoint(x: x(row.date), y: y(row.tps))
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(tone(for: lane)))
                }
            }
            context.draw(Text(String(format: "%.0f t/s", maxY)).font(.caption2).foregroundStyle(.white.opacity(0.30)), at: CGPoint(x: plot.maxX, y: plot.minY), anchor: .trailing)
            let leftLabel = scope == "today" ? shortTime(minDate) : shortAxis(minDate)
            let rightLabel = scope == "today" ? shortTime(maxDate) : shortAxis(maxDate)
            context.draw(Text(leftLabel).font(.caption2).foregroundStyle(.white.opacity(0.32)), at: CGPoint(x: plot.minX, y: size.height - 8), anchor: .leading)
            context.draw(Text(rightLabel).font(.caption2).foregroundStyle(.white.opacity(0.32)), at: CGPoint(x: plot.maxX, y: size.height - 8), anchor: .trailing)
        }
    }
}

struct Legend: View {
    let label: String
    let tone: Color
    let dash: Bool
    var body: some View {
        HStack(spacing: 6) {
            Canvas { context, size in
                var p = Path()
                p.move(to: CGPoint(x: 0, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(p, with: .color(tone), style: StrokeStyle(lineWidth: dash ? 1.8 : 2.6, lineCap: .round, dash: dash ? [3, 3] : []))
            }
            .frame(width: 20, height: 7)
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.46))
        }
    }
}

struct WidgetFooter: View {
    @Environment(\.openWindow) private var openWindow
    let snapshot: Snapshot
    let scope: String
    var updated: Date? = nil
    let refresh: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text("Generating t/s (est.)").font(.system(size: 11)).foregroundStyle(SpeedTheme.tertiary)
                SpeedInfoButton()
            }
            Spacer(minLength: 4)
            // Turns yellow when the numbers are more than 5 minutes old.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let age: TimeInterval = updated.map { context.date.timeIntervalSince($0) } ?? 0
                let stale = age > 300
                let label: String = updated.map { "Updated " + shortTime($0) } ?? "Waiting for data"
                Text(stale ? "\(Int(age / 60))m old" : updated.map {shortTime($0)} ?? "Waiting")
                    .help(stale ? label + " · \(Int(age / 60)) min ago" : label)
                    .accessibilityLabel(stale ? label + " · \(Int(age / 60)) min ago" : label)
                    .font(.system(size: 11))
                    .foregroundStyle(stale ? SpeedTheme.slowerYellow : SpeedTheme.tertiary)
            }
            Button(action: {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "report")
            }) {
                Text("Open report ›")
            }
            .buttonStyle(ChipButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// Explicit appearance keeps the close control legible even with a light system
// appearance hosting the dark menu-bar panel. Closing here quits the viewer.
struct MonitorCloseButton: NSViewRepresentable {
    static func makeButton() -> NSButton {
        let button = NSButton(title: "", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        button.bezelStyle = .texturedRounded
        button.isBordered = true
        button.imagePosition = .imageOnly
        button.appearance = NSAppearance(named: .darkAqua)
        button.contentTintColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        button.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Quit Codex Speed Monitor")
        button.toolTip = "Quit Codex Speed Monitor"
        button.setAccessibilityLabel("Quit Codex Speed Monitor")
        return button
    }
    func makeNSView(context: Context) -> NSButton { Self.makeButton() }
    func updateNSView(_ button: NSButton, context: Context) {}
}

struct MonitorRefreshLink: View {
    let refresh: () -> Void
    @State private var hovering = false
    var body: some View {
        Button("Refresh", action: refresh)
            .font(.system(size: 11))
            .foregroundStyle(hovering ? SpeedTheme.primary : SpeedTheme.secondary)
            .buttonStyle(.plain)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .pointingHand()
            .onHover { hovering = $0 }
            .help("Refresh measurements")
            .accessibilityLabel("Refresh measurements")
            .fixedSize()
    }
}

// Kept separate so WidgetFooter's memberwise initializer stays usable from
// other files (it has no private stored state of its own).
struct FooterIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 12)
        }
        .buttonStyle(OutlineButtonStyle(compact: true))
        .accessibilityLabel(label)
        .help(label)
    }
}

func weightedAverage(rows: [ModeRow]) -> Double {
    let totalTurns = rows.reduce(0) { $0 + $1.turns }
    guard totalTurns > 0 else { return 0 }
    return rows.reduce(0.0) { $0 + ($1.tps * Double($1.turns)) } / Double(totalTurns)
}

func shortAxis(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "MM-dd"
    return f.string(from: date)
}

func shortTime(_ date: Date) -> String {clockTime(date)}

func chartLane(_ mode: String) -> String {
    let lower = mode.lowercased()
    if lower == "ultrafast" { return "Ultrafast" }
    if lower == "fast" || lower == "priority" { return "Fast" }
    if lower == "standard" || lower == "default" { return "Standard" }
    return "Other"
}

func laneRank(_ lane: String) -> Int {
    let lower = lane.lowercased()
    if lower == "fast" { return 0 }
    if lower.contains("standard") { return 1 }
    return 2
}

func niceCeiling(_ value: Double) -> Double {
    guard value.isFinite, value > 0 else { return 1 }
    let steps = [1.0, 2.0, 5.0, 10.0]
    let magnitude = pow(10, floor(log10(value)))
    for step in steps {
        let candidate = step * magnitude
        if candidate >= value { return candidate }
    }
    return 10 * magnitude
}

func parseTurnDate(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    return whole.date(from: value)
}
