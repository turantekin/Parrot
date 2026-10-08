import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// `.parrotprofile`, declared in project.yml.
    static let parrotProfile = UTType(exportedAs: "com.uygar.parrot.profile", conformingTo: .json)
}

/// A profile as a file, for the share sheet (Mail, Messages, AirDrop).
struct ProfileExport: Transferable {
    let name: String
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .parrotProfile) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(export.fileName)
            try export.data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }

    /// "Sales discovery.parrotprofile", safe on every file system.
    var fileName: String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (safe.isEmpty ? "Profile" : String(safe.prefix(80))) + ".parrotprofile"
    }
}

/// Profile editor → Export…: what the file holds, in plain words, before
/// it's saved or shared. The exact text is one click away.
struct ProfileExportSheet: View {
    let profile: CallProfile
    @Environment(\.dismiss) private var dismiss
    @State private var showText = false
    @State private var saveError: String?

    private var export: ProfileExport { ProfileExport(name: profile.name, data: ProfileFile.encode(profile)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export \u{201C}\(profile.name)\u{201D}")
                .font(Theme.Typography.title())
                .foregroundStyle(Theme.Colors.ink)
            Text("This file holds:")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink2)
            VStack(alignment: .leading, spacing: 0) {
                row("Name, icon, persona and custom rules", first: true)
                row("What to flag: \(count(profile.kinds.count, "card type")) · Mood meters: \(profile.gauges.count)")
                row("Report: " + (profile.reportTemplate.isStandard ? "the classic report"
                                  : "\(count(profile.reportTemplate.sections.count, "section"))"
                                    + (profile.reportTemplate.coachingEnabled ? " and coaching" : "")))
                row("Privacy: on-device only is " + (profile.onDeviceOnly ? "on" : "off"))
            }
            Text("It never holds your meetings, your documents, names from your calls, or any keys.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
                .padding(Theme.Metrics.popoverPad)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.panel, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            // A popover, not a disclosure: a sheet doesn't grow, so opening the
            // text inline pushed Cancel and Save out of it.
            Button("Show the file's text") { showText.toggle() }
                .buttonStyle(.link)
                .popover(isPresented: $showText, arrowEdge: .bottom) {
                    ScrollView {
                        Text(String(decoding: export.data, as: UTF8.self))
                            .font(Theme.Typography.mono(11))
                            .foregroundStyle(Theme.Colors.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Metrics.popoverPad)
                    }
                    .frame(width: 440, height: 320)
                }
            if let saveError {
                Text(saveError).font(Theme.Typography.secondary).foregroundStyle(Theme.Colors.warn)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                ShareLink(item: export, preview: SharePreview(export.fileName)) { Text("Share…") }
                Button("Save…") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Metrics.pad)
        .frame(width: 480)
    }

    private func row(_ text: String, first: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !first { Divider() }
            Text(text)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.ink)
                .padding(.vertical, 7)
        }
    }

    private func count(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.parrotProfile]
        panel.nameFieldStringValue = export.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export.data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            saveError = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Files chosen in Import… or dropped on the profile list, queued for the
/// review screen. Read while the sandbox lets us.
enum ProfileImport {
    @MainActor
    static func queue(_ urls: [URL], in session: AppSession) {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let item = PendingProfile.read(url) { session.profileReviews.append(item) }
        }
    }
}
