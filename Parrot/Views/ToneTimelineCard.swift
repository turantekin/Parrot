import SwiftUI

/// "How the call went": talk bars per minute, the main gauge over time and
/// numbered moments (nudges, turning points, marks) you can play.
struct ToneTimelineCard: View, Equatable {
    let model: ToneTimeline.Model
    var play: ((TimeInterval) -> Void)?

    /// Playback redraws the report ten times a second; the card only needs to
    /// when its data changes.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && (lhs.play == nil) == (rhs.play == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("How the call went")
                    .font(Theme.Typography.cardTitle)
                    .foregroundStyle(Theme.Colors.ink)
                Spacer()
                Text(Receipts.stamp(model.duration))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink3)
            }
            HStack(spacing: 10) {
                tile("You talked", model.talkPercentMe.map { "\($0)%" } ?? "–")
                tile("Key moments", "\(model.moments.count)")
                if let gauge = model.gauge, let end = model.endLevel {
                    tile("\(gauge.label) at the end", end)
                }
            }
            legend
            chart.frame(height: 150)
            if !model.moments.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.moments) { row($0) }
                }
            }
        }
        .padding(14)
        .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius).strokeBorder(Theme.Colors.line))
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink2)
            Text(value)
                .font(Theme.Typography.sans(17, .semibold))
                .foregroundStyle(Theme.Colors.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.chip.opacity(0.5), in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(Theme.Colors.meLane, "You")
            swatch(Theme.Colors.themLane, "Them")
            if let gauge = model.gauge { swatch(Theme.Colors.moodLine, gauge.label) }
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.Colors.ink2)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    private static func color(_ kind: ToneTimeline.Moment.Kind) -> Color {
        switch kind {
        case .nudge: Theme.Colors.warn
        case .turn: Theme.Colors.accent
        case .mark: Theme.Colors.ink2
        }
    }

    private var chart: some View {
        Canvas { ctx, size in
            let left: CGFloat = 38, right: CGFloat = 8
            let width = max(1, size.width - left - right)
            let duration = max(model.duration, 1)
            func x(_ t: TimeInterval) -> CGFloat { left + CGFloat(min(max(t, 0), duration) / duration) * width }
            let barH: CGFloat = 28, moodTop: CGFloat = 40, moodH: CGFloat = 68, markY: CGFloat = 124

            // Talk: one bar per minute, you on top, them below.
            ctx.draw(Text("Talk").font(Theme.Typography.caption).foregroundColor(Theme.Colors.ink3),
                     at: CGPoint(x: 0, y: barH / 2), anchor: .leading)
            let slot = width / CGFloat(max(model.minutes.count, 1))
            for (i, m) in model.minutes.enumerated() where m.me + m.them > 0 {
                let meH = barH * CGFloat(m.me / (m.me + m.them))
                let bx = left + CGFloat(i) * slot + 1, bw = max(1, slot - 2)
                ctx.fill(Path(roundedRect: CGRect(x: bx, y: 0, width: bw, height: meH), cornerRadius: 1.5),
                         with: .color(Theme.Colors.meLane))
                ctx.fill(Path(roundedRect: CGRect(x: bx, y: meH, width: bw, height: barH - meH), cornerRadius: 1.5),
                         with: .color(Theme.Colors.themLane))
            }

            // Mood: the profile's main gauge, high at the top.
            if let gauge = model.gauge, model.mood.count >= 2 {
                ctx.draw(Text(gauge.highLabel).font(Theme.Typography.caption).foregroundColor(Theme.Colors.ink3),
                         at: CGPoint(x: 0, y: moodTop), anchor: .leading)
                ctx.draw(Text(gauge.lowLabel).font(Theme.Typography.caption).foregroundColor(Theme.Colors.ink3),
                         at: CGPoint(x: 0, y: moodTop + moodH), anchor: .leading)
                var mid = Path()
                mid.move(to: CGPoint(x: left, y: moodTop + moodH / 2))
                mid.addLine(to: CGPoint(x: left + width, y: moodTop + moodH / 2))
                ctx.stroke(mid, with: .color(Theme.Colors.line), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                var line = Path()
                for (i, p) in model.mood.enumerated() {
                    let point = CGPoint(x: x(p.time), y: moodTop + moodH * (1 - CGFloat(p.value) / 100))
                    if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
                }
                ctx.stroke(line, with: .color(Theme.Colors.moodLine), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            }

            // Moments: numbered markers, the same numbers as the list below.
            // Two at the same moment sit side by side, not on top of each other.
            var lastMarker = -CGFloat.infinity
            for m in model.moments {
                let at = x(m.time)
                let cx = max(at, lastMarker + 20)
                lastMarker = cx
                var tick = Path()
                tick.move(to: CGPoint(x: at, y: barH))
                tick.addLine(to: CGPoint(x: at, y: markY - 14))
                tick.addLine(to: CGPoint(x: cx, y: markY - 9))
                ctx.stroke(tick, with: .color(Theme.Colors.line), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                let tint = Self.color(m.kind)
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 9, y: markY - 9, width: 18, height: 18)),
                         with: .color(tint.opacity(0.18)))
                ctx.draw(Text("\(m.number)").font(Theme.Typography.caption).foregroundColor(tint),
                         at: CGPoint(x: cx, y: markY))
            }

            // Time axis.
            let step: TimeInterval = duration > 1800 ? 600 : duration > 600 ? 300 : 60
            var t: TimeInterval = 0
            while t <= duration {
                ctx.draw(Text(Receipts.stamp(t)).font(Theme.Typography.caption).foregroundColor(Theme.Colors.ink3),
                         at: CGPoint(x: x(t), y: size.height - 6))
                t += step
            }
        }
    }

    private func row(_ m: ToneTimeline.Moment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(m.number)")
                .font(Theme.Typography.caption)
                .foregroundStyle(Self.color(m.kind))
                .frame(width: 20, height: 20)
                .background(Self.color(m.kind).opacity(0.18), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.title)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.ink)
                    Text(Receipts.stamp(m.time))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink3)
                }
                Text(m.detail)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let play {
                Button { play(m.time) } label: {
                    Label("Play", systemImage: "play.fill")
                        .font(Theme.Typography.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.Colors.chip, in: RoundedRectangle(cornerRadius: Theme.Metrics.chipRadius))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.ink2)
                .help("Play from here")
            }
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }
}
