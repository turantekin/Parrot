import SwiftUI

/// Parrot's face in Ask Parrot: the app icon in a circle with a small ✦
/// badge, so an answer reads as the app's AI.
struct ParrotAvatar: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: Theme.Metrics.avatar, height: Theme.Metrics.avatar)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "sparkles")
                    .font(.system(size: Theme.Metrics.avatarBadge * 0.6, weight: .bold))
                    .foregroundStyle(Theme.Colors.canvas)
                    .frame(width: Theme.Metrics.avatarBadge, height: Theme.Metrics.avatarBadge)
                    .background(Theme.Colors.accent, in: Circle())
                    .overlay(Circle().stroke(Theme.Colors.canvas, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            .accessibilityLabel("Parrot")
    }
}
