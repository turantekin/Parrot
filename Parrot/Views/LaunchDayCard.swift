import SwiftUI

/// Home, on Product Hunt launch day only: a line about the launch and a link
/// to it. Either button closes it for good (LaunchDay).
struct LaunchDayCard: View {
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CopilotHeroCard(title: LaunchDay.headline, subtitle: LaunchDay.subtitle,
                            bordered: false) { EmptyView() }
            HStack(spacing: Theme.Metrics.controlGap) {
                Button(LaunchDay.openTitle) {
                    openURL(LaunchDay.url)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                Button("Not now", action: onClose)
            }
        }
        .padding(Theme.Metrics.pad)
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius).stroke(Theme.Colors.spotlightLine, lineWidth: 1.5))
    }
}
