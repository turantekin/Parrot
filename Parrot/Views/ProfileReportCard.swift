import SwiftUI

/// Profile editor → Report: what the report after each call covers for this
/// call type (sections, coaching), plus the one-time offer of a built-in's
/// new report to people who had tuned that built-in before Profiles 2.0.
/// Editing never marks the profile `isUserModified`: report and Copilot
/// changes are tracked apart (see CallProfile.reportChoice).
struct ProfileReportCard: View {
    @Bindable var profile: CallProfile
    @State private var showPreview = false
    /// A change that would throw away the user's own report, waiting for a yes.
    @State private var pendingReplace: (() -> Void)?

    private var template: ReportTemplate { profile.reportTemplate }
    /// The built-in's own report when it differs from the classic one.
    private var builtInReport: ReportTemplate? {
        profile.presetReportTemplate.flatMap { $0.isStandard ? nil : $0 }
    }

    var body: some View {
        SettingsCard(title: "Report", blurb: "What the report after each call covers. Your custom rules above still apply.") {
            if profile.reportOfferPending, let offer = builtInReport, profile.reportChoice != .preset {
                SettingsRow(first: true) { offerBox(offer) }
            }
            SettingsRow(first: !profile.reportOfferPending) { choiceRow }
            SettingsRow {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(template.sections.enumerated()), id: \.element.key) { i, section in
                        if i > 0 { Divider().padding(.vertical, 8) }
                        sectionRow(i, section)
                    }
                    HStack(spacing: 8) {
                        Button("+ Add section") { addSection() }
                            .disabled(template.sections.count >= ReportTemplate.maxSections)
                        Text("Up to \(ReportTemplate.maxSections). Fewer sections work better with local AI.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.ink3)
                    }
                    .padding(.top, 10)
                }
            }
            SettingsToggleRow(title: "Coaching report", detail: "What went well, what to improve. Turn it off to save one AI call per meeting.",
                              isOn: coachingBinding(\.enabled, default: true))
            if template.coachingEnabled {
                SettingsRow {
                    VStack(alignment: .leading, spacing: 6) {
                        coachField("Coach", text: coachingText(\.role), prompt: ReportTemplate.standardCoachRole)
                        coachField("Focus", text: coachingText(\.focus), prompt: "e.g. How objections were handled")
                    }
                }
            }
            SettingsRow { resetRow }
        }
        .confirmationDialog("Replace your own report?", isPresented: Binding(
            get: { pendingReplace != nil }, set: { if !$0 { pendingReplace = nil } })) {
            Button("Replace", role: .destructive) {
                profile.saveVersion(label: "Before changing the report")
                pendingReplace?()
                pendingReplace = nil
            }
        } message: {
            Text("The sections and coaching you set for this profile will be replaced.")
        }
    }

    // MARK: Rows

    private func offerBox(_ offer: ReportTemplate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("A \(profile.name) report is available.")
                .font(Theme.Typography.cardTitle)
                .foregroundStyle(Theme.Colors.ink)
            Text(offer.titles.joined(separator: ", ") + ". Your Copilot settings stay as they are.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Preview") { showPreview.toggle() }
                    .popover(isPresented: $showPreview, arrowEdge: .bottom) { ReportPreview(template: offer) }
                // Not the Return key: this sits on a page of text fields.
                Button("Use it") { profile.useBuiltInReport(true) }
                    .buttonStyle(.borderedProminent)
                Button("Keep classic") { profile.useBuiltInReport(false) }
            }
            .controlSize(.small)
        }
        .padding(Theme.Metrics.popoverPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.spotlight, in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.spotlightLine))
    }

    private var choiceLabel: String {
        switch profile.reportChoice {
        case .classic: return "Classic report"
        case .preset: return builtInReport == nil ? "Classic report" : "\(profile.name) report"
        case .custom: return "Your own report"
        }
    }

    private var choiceRow: some View {
        HStack(spacing: 8) {
            Text("Report")
                .foregroundStyle(Theme.Colors.ink2)
            Menu(choiceLabel) {
                if builtInReport != nil {
                    Button("\(profile.name) report") { replacing { profile.useBuiltInReport(true) } }
                }
                Button("Classic report") { replacing { useClassic() } }
                Divider()
                startFromItems
            }
            .fixedSize()
            Spacer()
            if !profile.isBuiltIn {
                Menu("Start from a built-in…") { startFromItems }
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private var startFromItems: some View {
        Section("Start from another profile's report") {
            ForEach(ProfilePresets.reportStarters.filter { $0.name != profile.name }, id: \.name) { starter in
                Button(starter.name) { replacing { profile.setCustomReport(starter.template) } }
            }
        }
    }

    private func sectionRow(_ i: Int, _ section: ReportTemplate.Section) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 2) {
                Button { move(i, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(i == 0)
                    .help("Move up")
                Button { move(i, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(i == template.sections.count - 1)
                    .help("Move down")
            }
            .buttonStyle(.borderless)
            .font(Theme.Typography.caption)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("", text: sectionText(i, \.title), prompt: Text("Section title"))
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Typography.cardTitle)
                    Picker("", selection: sectionType(i)) {
                        Text("Paragraph").tag("prose")
                        Text("Bullet list").tag("bullets")
                        Text("Scorecard").tag("scorecard")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                TextField("", text: sectionGuide(i), prompt: Text("What goes here"), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                if section.type == "scorecard" {
                    criteriaEditor(i, section)
                } else {
                    Toggle("Promises and next steps go here", isOn: sectionPromises(i))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                if section.commitments == true {
                    Hint("Parrot checks each one against the transcript and uses them for Reminders, open items and \"what did I promise?\".")
                }
            }

            Button { remove(i) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Colors.ink3)
                .disabled(template.sections.count == 1)
                .help("Remove this section")
        }
    }

    /// One row per criterion: its name and what it means. 1 to 8.
    private func criteriaEditor(_ i: Int, _ section: ReportTemplate.Section) -> some View {
        let criteria = section.criteria ?? []
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(criteria.enumerated()), id: \.element.key) { j, _ in
                HStack(spacing: 8) {
                    TextField("", text: criterionText(i, j, \.label), prompt: Text("Criterion"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                    TextField("", text: criterionGuide(i, j), prompt: Text("What it means"))
                        .textFieldStyle(.roundedBorder)
                    Button { update { $0.sections[i].criteria?.remove(at: j) } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.Colors.ink3)
                        .disabled(criteria.count == 1)
                        .help("Remove this criterion")
                }
            }
            HStack(spacing: 8) {
                Button("+ Add criterion") {
                    update { $0.sections[i].criteria = ($0.sections[i].criteria ?? []) + [Self.newCriterion()] }
                }
                .disabled(criteria.count >= ReportTemplate.maxCriteria)
                Hint("Up to \(ReportTemplate.maxCriteria). Each gets a score from 1 to 5 with the moment that shows it. Never age, looks, accent or other personal traits.")
            }
        }
        .padding(.leading, 12)
    }

    private static func newCriterion() -> ReportTemplate.Criterion {
        .init(key: "c" + UUID().uuidString.prefix(6).lowercased(), label: "", guide: "")
    }

    private func coachField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(Theme.Colors.ink2)
                .frame(width: 48, alignment: .leading)
            TextField("", text: text, prompt: Text(prompt), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
        }
    }

    private var resetRow: some View {
        HStack(spacing: 8) {
            if let own = builtInReport {
                Button("Reset to the \(profile.name) report") { replacing { profile.useBuiltInReport(true) } }
                    .disabled(template == own)
            } else {
                Button("Reset to the classic report") { replacing { useClassic() } }
                    .disabled(template.isStandard)
            }
            Hint(profile.isBuiltIn
                 ? "Editing anything makes it your own report. Built-in improvements then stop reaching it."
                 : "Editing anything makes it your own report.")
        }
    }

    // MARK: Changes

    private func update(_ change: (inout ReportTemplate) -> Void) { profile.editReport(change) }

    private func useClassic() {
        if builtInReport != nil { profile.useBuiltInReport(false) } else { profile.setCustomReport(.standard) }
    }

    /// Asks first when the change would throw away the user's own report.
    private func replacing(_ action: @escaping () -> Void) {
        if profile.reportChoice == .custom { pendingReplace = action } else { action() }
    }

    private func addSection() {
        update { $0.sections.append(.init(key: "s" + UUID().uuidString.prefix(6).lowercased(),
                                          title: "", type: "bullets", guide: "")) }
    }

    private func remove(_ i: Int) {
        update { if $0.sections.indices.contains(i), $0.sections.count > 1 { $0.sections.remove(at: i) } }
    }

    private func move(_ i: Int, by step: Int) {
        update { t in
            let j = i + step
            guard t.sections.indices.contains(i), t.sections.indices.contains(j) else { return }
            t.sections.swapAt(i, j)
        }
    }

    // MARK: Bindings

    private func sectionText(_ i: Int, _ path: WritableKeyPath<ReportTemplate.Section, String>) -> Binding<String> {
        Binding(get: { template.sections.indices.contains(i) ? template.sections[i][keyPath: path] : "" },
                set: { v in update { if $0.sections.indices.contains(i) { $0.sections[i][keyPath: path] = v } } })
    }

    private func sectionGuide(_ i: Int) -> Binding<String> {
        Binding(get: { template.sections.indices.contains(i) ? template.sections[i].guide ?? "" : "" },
                set: { v in update { if $0.sections.indices.contains(i) { $0.sections[i].guide = v } } })
    }

    /// A scorecard needs at least one criterion; other types carry none.
    private func sectionType(_ i: Int) -> Binding<String> {
        Binding(get: { template.sections.indices.contains(i) ? template.sections[i].type : "bullets" },
                set: { v in update {
                    guard $0.sections.indices.contains(i) else { return }
                    $0.sections[i].type = v
                    if v == "scorecard" {
                        if ($0.sections[i].criteria ?? []).isEmpty { $0.sections[i].criteria = [Self.newCriterion()] }
                    } else {
                        $0.sections[i].criteria = nil
                    }
                } })
    }

    private func criterion(_ i: Int, _ j: Int) -> ReportTemplate.Criterion? {
        template.sections[i].criteria.flatMap { $0.indices.contains(j) ? $0[j] : nil }
    }

    private func criterionText(_ i: Int, _ j: Int, _ path: WritableKeyPath<ReportTemplate.Criterion, String>) -> Binding<String> {
        Binding(get: { template.sections.indices.contains(i) ? criterion(i, j)?[keyPath: path] ?? "" : "" },
                set: { v in update { if $0.sections.indices.contains(i), $0.sections[i].criteria?.indices.contains(j) == true {
                    $0.sections[i].criteria?[j][keyPath: path] = v } } })
    }

    private func criterionGuide(_ i: Int, _ j: Int) -> Binding<String> {
        Binding(get: { template.sections.indices.contains(i) ? criterion(i, j)?.guide ?? "" : "" },
                set: { v in update { if $0.sections.indices.contains(i), $0.sections[i].criteria?.indices.contains(j) == true {
                    $0.sections[i].criteria?[j].guide = v } } })
    }

    private func sectionPromises(_ i: Int) -> Binding<Bool> {
        Binding(get: { template.sections.indices.contains(i) && template.sections[i].commitments == true },
                set: { v in update { if $0.sections.indices.contains(i) { $0.sections[i].commitments = v ? true : nil } } })
    }

    private func coachingBinding(_ path: WritableKeyPath<ReportTemplate.Coaching, Bool>, default value: Bool) -> Binding<Bool> {
        Binding(get: { template.coaching?[keyPath: path] ?? value },
                set: { v in update { t in
                    var c = t.coaching ?? .init(enabled: true, role: nil, focus: nil)
                    c[keyPath: path] = v
                    t.coaching = c
                } })
    }

    private func coachingText(_ path: WritableKeyPath<ReportTemplate.Coaching, String?>) -> Binding<String> {
        Binding(get: { template.coaching?[keyPath: path] ?? "" },
                set: { v in update { t in
                    var c = t.coaching ?? .init(enabled: true, role: nil, focus: nil)
                    c[keyPath: path] = v
                    t.coaching = c
                } })
    }
}

/// A read-only list of a report's sections, for "Preview".
struct ReportPreview: View {
    let template: ReportTemplate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(template.sections, id: \.key) { s in
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title)
                        .font(Theme.Typography.cardTitle)
                        .foregroundStyle(Theme.Colors.ink)
                    if let guide = s.guide, !guide.isEmpty {
                        Text(guide)
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(template.coachingEnabled ? "Plus a coaching report (\(template.coachRole))." : "No coaching report.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink3)
        }
        .padding(Theme.Metrics.popoverPad)
        .frame(width: 320, alignment: .leading)
    }
}
