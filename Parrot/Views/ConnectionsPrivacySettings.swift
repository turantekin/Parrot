import AppKit
import SwiftUI

// MARK: - Settings → Connections

/// Where meetings can go after a call: a Markdown folder, a follow-up email,
/// a webhook, and AI apps on this Mac (MCP). All off until switched on.
struct ConnectionsSettingsPage: View {
    @AppStorage(ExportFolder.autoKey) private var autoExport = false
    @AppStorage(FollowUpEmail.autoKey) private var autoFollowUp = false
    @AppStorage(Webhook.urlKey) private var webhookURL = ""
    @AppStorage(Webhook.enabledKey) private var webhookEnabled = false
    @AppStorage(Webhook.includeTranscriptKey) private var webhookTranscript = false
    @AppStorage(Webhook.lastResultKey) private var webhookLast = ""
    @AppStorage(MCPServer.enabledKey) private var mcpEnabled = false

    @State private var folderPath = ExportFolder.resolve()?.path
    @State private var secretDraft = ""
    @State private var secretSaved = (APIKeyStore.load(account: Webhook.secretAccount) ?? "").isEmpty == false
    @State private var testing = false
    @State private var testResult: String?
    @State private var copiedConfig = false

    var body: some View {
        SettingsPage {
            SettingsCard(title: "Save to a Folder",
                         blurb: "Each meeting as a Markdown note: summary, next steps as tasks, marked moments and the transcript. Point it at an Obsidian vault or any folder.") {
                SettingsLabeledRow(title: folderPath == nil ? "No folder chosen" : "Folder",
                                   detail: folderPath, first: true) {
                    HStack(spacing: 6) {
                        if folderPath != nil {
                            Button("Remove") {
                                ExportFolder.clear()
                                folderPath = nil
                                autoExport = false
                            }
                        }
                        Button(folderPath == nil ? "Choose Folder…" : "Change…") { chooseFolder() }
                    }
                }
                SettingsToggleRow(title: "Save every finished meeting there automatically",
                                  detail: "Re-saving a meeting (from its Share menu) updates the same note.",
                                  isOn: $autoExport)
                    .disabled(folderPath == nil)
            }

            SettingsCard(title: "Follow-up Email",
                         blurb: "A short email with what was agreed and who does what, written from the transcript, only with promises someone actually made. Open it in Mail from the meeting.") {
                SettingsToggleRow(title: "Draft one after every call",
                                  detail: "Uses your post-call reports AI. Or draft one any time from a meeting's Share menu.",
                                  first: true, isOn: $autoFollowUp)
            }

            SettingsCard(title: "Webhook",
                         blurb: "After each call Parrot posts the meeting as JSON to this address. Paste a Zapier, Make or n8n webhook to reach Slack, Notion or your CRM. On-device-only meetings are never sent.") {
                SettingsBlockRow(title: "Address (https)", first: true) {
                    TextField("https://hooks.zapier.com/…", text: $webhookURL)
                        .textFieldStyle(.roundedBorder)
                    if !webhookURL.isEmpty, Webhook.validate(webhookURL) == nil {
                        Hint("Use an https:// address (plain http only for localhost).")
                    }
                }
                SettingsToggleRow(title: "Send after every call", isOn: $webhookEnabled)
                    .disabled(Webhook.validate(webhookURL) == nil)
                SettingsToggleRow(title: "Include the full transcript",
                                  detail: "Off: title, people, summary, next steps, marked moments and notes only.",
                                  isOn: $webhookTranscript)
                SettingsLabeledRow(title: "Signing secret (optional)",
                                   detail: secretSaved
                                       ? "Saved in your Keychain. Requests carry X-Parrot-Signature: sha256=HMAC of the body."
                                       : "Lets the receiver check a request really came from your Parrot.") {
                    HStack(spacing: 6) {
                        SecureField("secret", text: $secretDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        Button(secretSaved && secretDraft.isEmpty ? "Clear" : "Save") {
                            _ = APIKeyStore.save(secretDraft, account: Webhook.secretAccount)
                            secretSaved = !secretDraft.isEmpty
                            secretDraft = ""
                        }
                    }
                }
                SettingsLabeledRow(title: "Test it", detail: testResult ?? (webhookLast.isEmpty ? nil : "Last: \(webhookLast)")) {
                    Button(testing ? "Sending…" : "Send Test") {
                        testing = true
                        Task {
                            do {
                                try await Webhook.sendTest()
                                testResult = "Test delivered."
                            } catch {
                                testResult = "Didn't arrive: \(error.localizedDescription)"
                            }
                            testing = false
                        }
                    }
                    .disabled(testing || Webhook.validate(webhookURL) == nil)
                }
            }

            SettingsCard(title: "AI Apps on This Mac (MCP)",
                         blurb: "Let Claude Desktop, ChatGPT or another MCP app read and search your meetings, read-only. The app you connect usually sends what it reads to its own cloud, so on-device-only meetings are never shown to it.") {
                SettingsToggleRow(title: "Allow AI apps to read my meetings", first: true, isOn: $mcpEnabled)
                SettingsLabeledRow(title: "Connect Claude Desktop",
                                   detail: "Copies the setup to paste into Claude Desktop → Settings → Developer → Edit Config, then restart Claude.") {
                    Button(copiedConfig ? "Copied" : "Copy Setup") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            MCPServer.claudeDesktopConfig(executable: Bundle.main.executablePath ?? "/Applications/Parrot.app/Contents/MacOS/Parrot"),
                            forType: .string)
                        copiedConfig = true
                    }
                    .disabled(!mcpEnabled)
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ExportFolder.set(url)
            folderPath = url.path
        } catch {
            NSLog("Parrot: couldn't remember the export folder, \(error.localizedDescription)")
        }
    }
}

// MARK: - Settings → Privacy

/// On-device only, hiding details from cloud AI, recording consent and
/// automatic clean-up.
struct PrivacySettingsPage: View {
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage(CloudGate.globalKey) private var onDeviceOnly = false
    @AppStorage(Redactor.enabledKey) private var redact = false
    @AppStorage(Redactor.namesKey) private var redactNames = false
    @AppStorage(Consent.noticeKey) private var notice = ""
    @AppStorage(Consent.remindKey) private var remindConsent = true
    @AppStorage(Retention.audioDaysKey) private var audioDays = 0
    @AppStorage(Retention.meetingDaysKey) private var meetingDays = 0
    @State private var cleanupResult: String?

    var body: some View {
        SettingsPage {
            SettingsCard(title: "On-device Only",
                         blurb: "One switch for nothing leaves this Mac: Whisper transcribes, Ollama runs the copilot and reports, and there's no polish pass, no TypeSafe answers, no webhook. Meetings recorded this way stay out of cloud Ask and AI apps later too. To do this for some calls only, turn it on for a profile instead (Settings → Profiles).") {
                SettingsToggleRow(title: "On-device only, for every call",
                                  detail: "Set up Ollama under Copilot first, or the copilot and reports have nothing to run on.",
                                  first: true, isOn: $onDeviceOnly)
            }

            SettingsCard(title: "Hide Personal Details from Cloud AI",
                         blurb: "Before anything goes to Claude or a custom server, Parrot swaps emails, phone numbers, card numbers and IBANs for placeholders like [EMAIL_1], then puts the real values back in what comes back. Local Ollama gets the text as is.") {
                SettingsToggleRow(title: "Hide emails, phone, card and bank numbers", first: true, isOn: $redact)
                SettingsToggleRow(title: "Hide people's names too",
                                  detail: "Uses Apple's on-device name detection. It can miss names or catch a product name, and the AI's answers get vaguer.",
                                  isOn: $redactNames)
                    .disabled(!redact)
            }

            SettingsCard(title: "Recording Consent",
                         blurb: "Many places require telling everyone a call is recorded. The Consent button on the call screen copies this notice to paste in the call chat (or notes that everyone agreed out loud) and keeps the record with the meeting.") {
                SettingsBlockRow(title: "Notice", first: true) {
                    TextField(Consent.defaultNotice, text: $notice, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }
                SettingsToggleRow(title: "Remind me at the start of every call",
                                  detail: "The Consent button stays orange until you've used it.",
                                  isOn: $remindConsent)
            }

            SettingsCard(title: "Automatic Clean-up",
                         blurb: "Delete old recordings on a schedule. Checked when Parrot opens and every hour.") {
                SettingsLabeledRow(title: "Delete call audio",
                                   detail: "Transcript, report and notes stay.", first: true) {
                    Picker("", selection: $audioDays) {
                        ForEach(Retention.audioChoices, id: \.self) { Text(Retention.label(days: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                SettingsLabeledRow(title: "Delete whole meetings", detail: "Everything, audio included. Can't be undone.") {
                    Picker("", selection: $meetingDays) {
                        ForEach(Retention.meetingChoices, id: \.self) { Text(Retention.label(days: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                }
                SettingsLabeledRow(title: "Clean up now", detail: cleanupResult) {
                    Button("Clean Up") {
                        let (audio, meetings) = recordingManager.applyRetention()
                        cleanupResult = "Removed audio from \(audio) meeting\(audio == 1 ? "" : "s"), deleted \(meetings)."
                    }
                    .disabled(audioDays == 0 && meetingDays == 0)
                }
            }
        }
    }
}
