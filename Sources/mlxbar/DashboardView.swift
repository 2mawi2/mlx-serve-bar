import SwiftUI

// Palette ported from the mlx-serve dashboard panel CSS.
let dashBG = Color(red: 0x0b/255, green: 0x0d/255, blue: 0x10/255)
let tileBG = Color(red: 0x0f/255, green: 0x12/255, blue: 0x16/255)
let tileBorder = Color(red: 0x1f/255, green: 0x24/255, blue: 0x2c/255)
let lblColor = Color(red: 0x7d/255, green: 0x87/255, blue: 0x94/255)
let valColor = Color(red: 0xe6/255, green: 0xe9/255, blue: 0xee/255)
let subColor = Color(red: 0x5b/255, green: 0x64/255, blue: 0x70/255)
let greenSpark = Color(red: 0x22/255, green: 0xc5/255, blue: 0x5e/255)
let blueSpark = Color(red: 0x3b/255, green: 0x82/255, blue: 0xf6/255)
let warnFill = Color(red: 0xf5/255, green: 0x9e/255, blue: 0x0b/255)
let critFill = Color(red: 0xef/255, green: 0x44/255, blue: 0x44/255)
let liveText = Color(red: 0x4a/255, green: 0xde/255, blue: 0x80/255)
let liveBgPill = Color(red: 0x0f/255, green: 0x2a/255, blue: 0x17/255)
let muteText = Color(red: 0x7d/255, green: 0x87/255, blue: 0x94/255)
let muteBgPill = Color(red: 0x1a/255, green: 0x1e/255, blue: 0x25/255)

extension MetricsModel {
    var stateLabel: String {
        switch state {
        case .running: return "● live"
        case .loading: return "loading…"
        case .stopping: return "stopping…"
        case .stopped: return "stopped"
        case .unknown: return "connecting…"
        }
    }
    var stateColor: Color {
        switch state {
        case .running: return liveText
        case .loading, .stopping: return warnFill
        case .stopped, .unknown: return muteText
        }
    }
    var statePillBg: Color {
        switch state {
        case .running: return liveBgPill
        case .loading, .stopping: return tileBorder
        case .stopped, .unknown: return muteBgPill
        }
    }
}

func gpuBarColor(_ pct: Int) -> Color {
    if pct >= 90 { return critFill }
    if pct >= 70 { return warnFill }
    return blueSpark
}

struct MetricTile: View {
    let label: String
    let value: String
    var unit: String = ""
    var sub: String = ""
    var barPct: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(0.7)
                .foregroundStyle(lblColor)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundStyle(valColor)
                if !unit.isEmpty {
                    Text(unit).font(.system(size: 10)).foregroundStyle(lblColor)
                }
            }
            .padding(.top, 4)
            if let barPct {
                DashBar(pct: barPct)
            } else if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 8.5))
                    .foregroundStyle(subColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(tileBG))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tileBorder, lineWidth: 1))
    }
}

// Exact port of the dashboard's .mbar/.mfill: #1f242c track, fill width = pct,
// color ≥90 #ef4444, ≥70 #f59e0b, else #3b82f6.
struct DashBar: View {
    let pct: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tileBorder)
                Capsule()
                    .fill(gpuBarColor(pct))
                    .frame(width: geo.size.width * CGFloat(min(max(Double(pct), 0), 100)) / 100)
            }
        }
        .frame(height: 5)
        .padding(.top, 8)
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let maxV = max(values.max() ?? 0.001, 0.001)
            let p: CGFloat = 3
            ZStack {
                if values.count > 1 {
                    Path { path in
                        for (i, v) in values.enumerated() {
                            let x = p + CGFloat(i) / CGFloat(values.count - 1) * (w - 2 * p)
                            let y = h - p - CGFloat(v / maxV) * (h - 2 * p)
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                Path { path in
                    path.move(to: CGPoint(x: p, y: h - 1))
                    path.addLine(to: CGPoint(x: w - p, y: h - 1))
                }
                .stroke(tileBorder, lineWidth: 1)
            }
        }
    }
}

struct SparkTile: View {
    let label: String
    let value: String
    let values: [Double]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(0.7)
                    .foregroundStyle(lblColor)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(valColor)
            }
            Sparkline(values: values, color: color).frame(height: 40)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(tileBG))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tileBorder, lineWidth: 1))
    }
}

struct StatsGrid: View {
    @ObservedObject var model: MetricsModel

    private var cols: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    var body: some View {
        let s = model.snap
        VStack(spacing: 8) {
            LazyVGrid(columns: cols, spacing: 8) {
                MetricTile(label: "Decode", value: Formats.fmt(s.decode, 1), unit: "tok/s",
                           sub: Formats.orDash(s.decodeMs, 0) + " ms avg")
                MetricTile(label: "Prefill", value: Formats.fmt(s.prefill, 0), unit: "tok/s",
                           sub: prefillSub(s))
                MetricTile(label: "Requests", value: Formats.raw(s.running), unit: "running",
                           sub: subWaiting(s))
                MetricTile(label: "Avg TTFT", value: Formats.orDash(s.ttftMs, 0), unit: "ms",
                           sub: Formats.orDash(s.e2eMs, 0) + " ms e2e")
                MetricTile(label: "Cache hit rate", value: Formats.dashInt(s.cachePct), unit: "%",
                           sub: subCache(s))
                MetricTile(label: "GPU", value: Formats.raw(s.gpuPct), unit: "%",
                           barPct: s.gpuPct)
                MetricTile(label: "Memory", value: Formats.raw(s.memMB), unit: "MB",
                           sub: "physical footprint")
                MetricTile(label: "Generated", value: Formats.fmt(s.liveTok, 0), unit: "tok",
                           sub: Formats.fmt(Double(s.reqSuccess), 0) + " requests")
            }
            SparkTile(label: "Decode tok/s · last 60s",
                      value: model.decodeHist.last.map { Formats.fmt($0, 1) } ?? "—",
                      values: model.decodeHist, color: greenSpark)
            SparkTile(label: "Prefill tok/s · last 60s",
                      value: model.prefillHist.last.map { Formats.fmt($0, 0) } ?? "—",
                      values: model.prefillHist, color: blueSpark)
        }
    }

    func prefillSub(_ s: MetricsSnapshot) -> String {
        if s.prefilling {
            return s.livePre > 0 ? "prefilling · \(Formats.fmt(s.livePre, 0)) tok" : "prefilling"
        }
        if s.avgPrefillTps >= 0 {
            return "\(Formats.fmt(s.avgPrefillTps, 0)) tok/s avg · \(Formats.orDash(s.prefillMs, 0)) ms"
        }
        return "— ms avg"
    }

    func subWaiting(_ s: MetricsSnapshot) -> String {
        let rate = s.reqPerSec >= 0 ? Formats.fmt(s.reqPerSec, 2) : "—"
        return "\(s.waiting) waiting · \(rate) req/s"
    }

    func subCache(_ s: MetricsSnapshot) -> String {
        let base = "\(s.cacheHits) / \(s.cacheQueries) queries"
        if s.tokPct >= 0 { return base + " · \(Formats.dashInt(s.tokPct))% tokens reused" }
        return base
    }
}

// Interactive panel shown on click: same stats plus power control / links.
struct DashboardView: View {
    @ObservedObject var model: MetricsModel
    let host: String
    let port: Int
    var onStart: () -> Void
    var onStop: () -> Void
    var onQuit: () -> Void
    var onDashboard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("mlx-serve")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(valColor)
                Text(model.stateLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(model.stateColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(model.statePillBg))
                Spacer()
                Button(action: {
                    if model.state == .running { onStop() } else { onStart() }
                }) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(powerColor)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(tileBG))
                        .overlay(Circle().stroke(tileBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(model.state == .loading || model.state == .stopping)
                .help(model.state == .running ? "Stop server" : "Start server")
            }
            StatsGrid(model: model)
            HStack {
                Text("\(host):\(port)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(subColor)
                Spacer()
                Button("Dashboard", action: onDashboard)
                    .font(.system(size: 10))
                Button("Quit", action: onQuit)
                    .font(.system(size: 10))
            }
            .buttonStyle(.link)
            .tint(muteText)
        }
        .padding(12)
        .frame(width: 320)
    }

    private var powerColor: Color {
        switch model.state {
        case .running: return liveText
        case .loading, .stopping: return warnFill
        case .stopped, .unknown: return muteText
        }
    }
}
