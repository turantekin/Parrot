import SwiftUI

/// Compact sentiment chips shown under the live copilot header — one horizontal
/// row (~24pt), one chip per gauge defined by the active call profile, plus the
/// model's one-word room read. Exact value and low/high anchors live in the
/// tooltip; the row exists for trend-at-a-glance, not reading.
/// Empty gauges list → invisible (EmptyView).
struct SentimentStripView: View {
    let gauges: [SentimentGauge]
    let values: [String: Int]
    let read: String?

    var body: some View {
        if gauges.isEmpty { EmptyView() } else {
            HStack(spacing: 12) {
                if let read, !read.isEmpty {
                    Text(read.capitalized)
                        .font(Theme.Typography.sans(12, .semibold))
                        .foregroundStyle(Theme.Colors.ink2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.Colors.chip, in: Capsule())
                        .help("The copilot's one-word read of the room")
                }

                ForEach(gauges) { gauge in
                    chip(for: gauge)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func chip(for gauge: SentimentGauge) -> some View {
        let v = values[gauge.key]
        // Clamp the meter fill: model-returned values aren't fully trusted, so
        // an out-of-range value can't overflow the track.
        let fill = CGFloat(min(max(v ?? 0, 0), 100)) / 100
        return HStack(spacing: 5) {
            Circle()
                .fill(Color(hex: gauge.colorHex))
                .frame(width: 6, height: 6)
            Text(gauge.label)
                .font(Theme.Typography.sans(12, .medium))
                .foregroundStyle(Theme.Colors.ink2)
                .lineLimit(1)
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.line)
                Capsule().fill(Color(hex: gauge.colorHex))
                    .frame(width: 36 * fill)
                    .animation(.easeOut(duration: 0.4), value: v)
            }
            .frame(width: 36, height: 4)
        }
        .help("\(gauge.label): \(v.map { "\($0)" } ?? "—") · 0 = \(gauge.lowLabel), 100 = \(gauge.highLabel)")
    }
}
