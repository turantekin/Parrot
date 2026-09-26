import SwiftUI

/// Onboarding's key field. Check key makes one small request, and only a
/// key that works is saved to the Keychain. A key saved earlier is checked
/// on appear, so a returning user doesn't have to press anything.
struct KeyCheckField: View {
    let service: ProviderKeyCheck.Service
    let label: String
    let placeholder: String
    let hint: String
    var optional = false
    @Binding var result: ProviderKeyCheck.Outcome?

    @State private var key = ""
    @State private var checkedKey = ""
    @State private var checking = false
    @State private var empty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(label)
                    .font(Theme.Typography.cardTitle)
                if optional {
                    Text("(optional)")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink3)
                }
            }
            HStack {
                SecureField(placeholder, text: $key, prompt: Text(placeholder))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: key) {
                        if key != checkedKey { result = nil }
                        empty = false
                    }
                Button(checking ? "Checking…" : "Check key") { Task { await check() } }
                    .disabled(checking)
            }
            status
                .font(Theme.Typography.secondary)
        }
        .task {
            let stored = if let account = service.keychainAccount {
                await APIKeyStore.loadInBackground(account: account)
            } else {
                await APIKeyStore.loadInBackground()
            }
            if let stored, !stored.isEmpty, key.isEmpty {
                key = stored
                await check()
            }
        }
    }

    @ViewBuilder private var status: some View {
        if empty {
            Text("Paste a key first")
                .foregroundStyle(Theme.Colors.stop)
        } else if let message = ProviderKeyCheck.message(result, service) {
            Label(message, systemImage: result == .works ? "checkmark.circle.fill" : "exclamationmark.triangle")
                .foregroundStyle(result == .works ? Theme.Colors.good : Theme.Colors.stop)
        } else {
            Text(hint)
                .foregroundStyle(Theme.Colors.ink2)
        }
    }

    private func check() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            empty = true
            return
        }
        checking = true
        checkedKey = key
        let outcome = await ProviderKeyCheck.check(service, key: trimmed)
        // The field changed while this ran: the result belongs to the old key.
        guard key == checkedKey else { checking = false; return }
        checking = false
        result = outcome
        if outcome == .works {
            _ = service.keychainAccount.map { APIKeyStore.save(trimmed, account: $0) } ?? APIKeyStore.save(trimmed)
        }
    }
}
