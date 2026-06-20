import SwiftUI

/// Always-on sentiment strip shown at the top of the live copilot panel.
/// Renders one horizontal meter per gauge defined by the active call profile.
/// Empty gauges list → invisible (EmptyView).
struct SentimentStripView: View {
    let gauges: [SentimentGauge]
    let values: [String: Int]
    let read: String?

    var body: some View {
        if gauges.isEmpty { EmptyView() } else {
            VStack(alignment: .leading, spacing: 8) {
                if let read, !read.isEmpty {
                    Text(read.capitalized)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.ink2)
                }
                ForEach(gauges) { gauge in
                    let v = values[gauge.key]
                    // Clamp the meter fill: model-returned values aren't fully
                    // trusted, so an out-of-range value can't overflow the track.
                    let fill = CGFloat(min(max(v ?? 0, 0), 100)) / 100
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(gauge.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.Colors.ink2)
                            Spacer()
                            Text(v.map { "\($0)" } ?? "—")
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(Theme.Colors.ink3)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.Colors.line).frame(height: 5)
                                Capsule().fill(Color(hex: gauge.colorHex))
                                    .frame(width: geo.size.width * fill, height: 5)
                                    .animation(.easeOut(duration: 0.4), value: v)
                            }
                        }.frame(height: 5)
                        HStack {
                            Text(gauge.lowLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.Colors.ink3)
                            Spacer()
                            Text(gauge.highLabel)
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.Colors.ink3)
                        }
                    }
                }
            }
            .padding(12)
            .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
