import SwiftUI

/// The settings pages' building blocks: a titled white card of rows on a plain
/// canvas, the look the landing page's rebuilt windows use. Pages migrate to
/// these from grouped Forms one by one.
struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Metrics.sectionGap) { content }
                .frame(maxWidth: 680, alignment: .leading)
                .padding(Theme.Metrics.pad)
                .padding(.bottom, Theme.Metrics.floatingClearance)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Colors.canvas)
    }
}

/// A titled section: heading, optional blurb, then a bordered rounded card.
struct SettingsCard<Content: View>: View {
    let title: String
    var blurb: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.Typography.sans(13, .semibold))
                .foregroundStyle(Theme.Colors.ink)
            if let blurb {
                Text(blurb)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Theme.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.canvas, in: RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius).strokeBorder(Theme.Colors.line))
                .padding(.top, 4)
        }
    }
}

/// One row in a card. Every row but the first draws a hairline above itself.
struct SettingsRow<Content: View>: View {
    var first = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { Divider() }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }
}

/// Title and optional detail on the left, a control on the right.
struct SettingsLabeledRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var first = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        SettingsRow(first: first) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.ink)
                    if let detail {
                        Text(detail)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
        }
    }
}

/// A switch row. Outside a Form macOS would draw a checkbox; this keeps the switch.
struct SettingsToggleRow: View {
    let title: String
    var detail: String? = nil
    var first = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsLabeledRow(title: title, detail: detail, first: first) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A title above full-width content (radio groups, editors), detail below.
struct SettingsBlockRow<Content: View>: View {
    let title: String
    var detail: String? = nil
    var first = false
    @ViewBuilder let content: Content

    var body: some View {
        SettingsRow(first: first) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.ink)
                content
                if let detail {
                    Text(detail)
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Lays children out left to right and wraps to new lines, like text.
/// Chips and tags use it so a long list never squeezes its members.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// A small tag. `on` uses the accent tint, like the app's selected chips.
struct TagChip: View {
    let label: String
    let on: Bool

    var body: some View {
        HStack(spacing: 4) {
            if on {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(label)
        }
        .font(Theme.Typography.caption)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(on ? Theme.Colors.selection : Theme.Colors.chip,
                    in: RoundedRectangle(cornerRadius: Theme.Metrics.chipRadius))
        .foregroundStyle(on ? Theme.Colors.accent : Theme.Colors.ink)
    }
}
