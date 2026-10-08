import SwiftUI

/// Home, once per version after an update: the release's headline, a few
/// highlights, and the changelog entry for the rest. Fresh installs never
/// see it (WhatsNew.seenAfterLaunch).
struct WhatsNewCard: View {
    let news: WhatsNew
    let onClose: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CopilotHeroCard(title: news.headline, subtitle: "Here's what changed since you last looked.",
                            bordered: false) { EmptyView() }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(news.highlights, id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.accent)
                            .accessibilityHidden(true)
                        Text(line)
                            .font(Theme.Typography.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: Theme.Metrics.controlGap) {
                Button("Read the full story") {
                    openURL(news.changelogURL)
                    onClose()
                }
                .buttonStyle(.borderedProminent)
                Button("Got it", action: onClose)
            }
        }
        .padding(Theme.Metrics.pad)
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius).stroke(Theme.Colors.spotlightLine, lineWidth: 1.5))
    }
}
