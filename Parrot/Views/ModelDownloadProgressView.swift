import SwiftUI

struct ModelDownloadProgressView: View {
    let progress: Double

    private var boundedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Downloading model…")
                Spacer()
                Text(boundedProgress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
            }
            .font(Theme.Typography.secondary)
            .foregroundStyle(Theme.Colors.ink2)

            ProgressView(value: boundedProgress)
                .accessibilityLabel("Downloading model")
                .accessibilityValue(
                    boundedProgress.formatted(.percent.precision(.fractionLength(0)))
                )
        }
        .frame(maxWidth: 280)
    }
}
