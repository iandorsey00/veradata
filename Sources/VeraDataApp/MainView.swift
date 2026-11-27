import AppKit
import Combine
import SwiftUI
import VeraDataCore

struct MainView: View {
    @ObservedObject var state: AppState
    let updateURL: URL?
    @ViewState private var newProfile: Bool = false
    @ViewState private var profileName: String = ""
    @ViewState private var proposedDeletion: VeraDataCore.Record?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 258)
            Divider()
            detail
        }
        .background(WindowCapture { state.mainWindow = $0 })
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) {
            state.trackVerificationSource($0)
        }
        .safeAreaInset(edge: .top) {
            if state.reloadPending {
                Text("VeraData changed on disk. Close your open edit or review to reload. Unsaved changes stay in your draft.")
                    .font(.callout).padding(8)
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                state.refreshExternalChanges()
            }
        }
        .sheet(item: $state.editor) { draft in
            RecordEditor(initial: draft, selectedText: state.selectedOriginalText, save: state.saveRecord)
        }
        .sheet(item: $state.verificationRequest) { request in
            FieldVerificationView(target: request.target, selectedText: state.selectedOriginalText) {
                try state.saveVerification($0, request: request)
            }
        }
        .sheet(item: $state.evidenceRecord) { record in
            EvidenceView(record: record, files: state.evidenceFiles) { marks, attachment in
                try state.saveEvidence(marks, for: record, attachment: attachment)
            }
        }
        .sheet(isPresented: $state.phoneExportOpen) {
            PhoneExportView(vault: state.vault, export: state.exportToPhone)
        }
        .sheet(item: $state.importRequest) { request in
            RecordImportView(request: request, profiles: state.vault.profiles, activeID: state.profileID, save: state.applyImport)
        }
        .sheet(item: $state.exportRequest) { request in
            SelectiveExportView(request: request, save: state.saveSelection)
        }
        .sheet(isPresented: $state.historyOpen) {
            RevisionHistoryView(store: state.stateStore, restore: state.restoreRevision)
        }
        .alert("VeraData", isPresented: Binding(
            get: { state.problem != nil }, set: { if !$0 { state.problem = nil } }
        )) {
            Button("OK", role: .cancel) { state.problem = nil }
        } message: {
            Text(state.problem ?? "")
        }
        .alert("New Profile", isPresented: $newProfile) {
            TextField("Profile name", text: $profileName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { _ = state.createProfile(profileName) }
        } message: {
            Text("Give this set of records a name.")
        }
        .confirmationDialog("Delete this record?", isPresented: Binding(
            get: { proposedDeletion != nil }, set: { if !$0 { proposedDeletion = nil } }
        ), titleVisibility: .visible, presenting: proposedDeletion) { record in
            Button("Delete Record", role: .destructive) { state.deleteRecord(record.id) }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text(VeraText.format("“%@” will be removed from this profile.", record.label))
        }
        .confirmationDialog("Replace this vault?", isPresented: Binding(
            get: { state.restoreCandidate != nil }, set: { if !$0 { state.restoreCandidate = nil } }
        ), titleVisibility: .visible, presenting: state.restoreCandidate) { candidate in
            Button("Replace Vault", role: .destructive) { state.restore(candidate) }
            Button("Cancel", role: .cancel) {}
        } message: { candidate in
            Text(VeraText.format("This replaces your current profiles and search shortcut with the backup’s %lld profiles and shortcut. Use Save Vault As… first if you want to keep a complete copy.", candidate.profiles.count))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("VeraData")
                .font(.custom("Helvetica Neue", size: 27, relativeTo: .title).weight(.bold))
                .tracking(-1.1)
                .padding(.horizontal, 20).padding(.top, 21).padding(.bottom, 17)
                .accessibilityAddTraits(.isHeader)
            if let updateURL {
                Button {
                    NSWorkspace.shared.open(updateURL)
                } label: {
                    Label("Update App…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            if state.showsVaultFilename {
                Label(state.vaultFilename, systemImage: state.isEncrypted ? "lock" : "doc")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(state.vaultFilename)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }

            Menu {
                ForEach(state.vault.profiles) { profile in
                    Button {
                        state.selectProfile(profile.id)
                    } label: {
                        if profile.id == state.profileID { Label(profile.name, systemImage: "checkmark") }
                        else { Text(profile.name) }
                    }
                }
                Divider()
                Button("New Profile…") { profileName = ""; newProfile = true }.disabled(!state.canEdit)
                Button("Open Fictional Demo") { state.installDemo() }.disabled(!state.canEdit)
            } label: {
                Label { Text(state.profile.name).lineLimit(1) }
                icon: { Image(systemName: "person.crop.circle") }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityLabel(VeraText.format("Profile, %@", state.profile.name))
            .padding(.horizontal, 16).padding(.bottom, 12)

            Button { state.openSearch() } label: {
                HStack {
                    Label("Quick Search", systemImage: "magnifyingglass")
                    Spacer()
                    Text("⌘ K").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16).padding(.bottom, 14)

            if state.profile.records.isEmpty {
                Spacer()
            } else {
                List(selection: $state.recordID) {
                    ForEach(RecordKind.allCases) { kind in
                        let records = state.profile.records.filter { $0.kind == kind }
                        if !records.isEmpty {
                            Section(VeraText.text(kind.section)) {
                                ForEach(records) { record in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.label).font(.body.weight(.medium)).lineLimit(1)
                                        if !record.subtitle.isEmpty {
                                            Text(record.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                        }
                                    }
                                    .padding(.vertical, 5)
                                    .tag(record.id)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("Records")
            }

            HStack {
                Button { state.editor = RecordDraft() } label: {
                    Label("New Record", systemImage: "plus")
                }
                .disabled(!state.canEdit)
                Spacer()
                Menu {
                    Button("Save Vault As…", action: state.saveVaultAs).disabled(!state.canSwitchVault)
                    Button("Back Up Records as JSON…", action: state.backUpRecords).disabled(!state.canSwitchVault)
                    Button("Restore Records from JSON…", action: state.chooseRestore).disabled(state.isEncrypted)
                    Button("Export for iPhone…") { state.phoneExportOpen = true }.disabled(!state.canExportToPhone)
                } label: {
                    Label("Vault Options", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .disabled(!state.canEdit)
                .frame(width: 28, height: 28)
                .help("Vault options")
            }
            .padding(.horizontal, 17).padding(.vertical, 13)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var detail: some View {
        if let record = state.record {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(record.kind.localizedTitle).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button { state.stepRecord(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(!state.canStepRecord(-1)).help("Previous record (⌘[)")
                            .accessibilityLabel("Previous record")
                        Button { state.stepRecord(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(!state.canStepRecord(1)).help("Next record (⌘])")
                            .accessibilityLabel("Next record")
                    }
                    Text(record.label)
                        .font(.system(size: 34, weight: .semibold))
                        .tracking(-0.9)
                        .padding(.top, 6)
                        .accessibilityAddTraits(.isHeader)
                    if !record.subtitle.isEmpty, record.subtitle != record.kind.localizedTitle {
                        Text(record.subtitle).font(.subheadline).foregroundStyle(.secondary).padding(.top, 7)
                    }
                    HStack(spacing: 10) {
                        Button("Search This Record") { state.openSearch(scopedTo: record.id) }
                            .buttonStyle(.borderedProminent)
                        Button("Edit") { state.editor = RecordDraft(record: record) }
                            .disabled(!state.canEdit)
                        Button("Evidence…") { state.evidenceRecord = record }
                            .disabled(!state.canEdit || (record.evidence.isEmpty && !record.fields.values.contains(where: EvidenceMark.canCheck)))
                        Menu {
                            Button("Copy Record as Text") { state.copy(record.copyableSummary, label: "record") }
                            Button("Export Selected Fields…") { state.openExport(recordID: record.id) }
                                .disabled(record.fields.isEmpty)
                            Divider()
                            Button("Delete Record…", role: .destructive) { proposedDeletion = record }
                                .disabled(!state.canEdit)
                        } label: {
                            Label("Record Options", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                        }
                        .menuIndicator(.hidden).help("Record options")
                    }
                    .padding(.top, 17)
                    status.padding(.top, 9)

                    Divider().padding(.top, 24)
                    if record.values.isEmpty {
                        Text("This record has no fields yet.")
                            .foregroundStyle(.secondary).padding(.vertical, 22)
                    }
                    ForEach(record.values) { field in
                        let key = field.path.count == 1 ? field.path.first : nil
                        FieldRow(field: field, evidenceStatus: evidenceStatus(for: field, in: record),
                                 verification: key.flatMap { record.verifications[$0] },
                                 verify: verificationAction(for: key, in: record), copy: state.copy)
                        Divider()
                    }
                }
                .frame(maxWidth: 800, alignment: .leading)
                .padding(.horizontal, 32).padding(.vertical, 26)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .id(record.id)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            VStack(alignment: .leading, spacing: 15) {
                if !state.canEdit {
                    Text(state.isEncrypted ? VeraText.text("Vault locked") : VeraText.text("Vault unavailable"))
                        .font(.largeTitle.weight(.semibold))
                    if state.isEncrypted {
                        Text(state.vaultFilename).foregroundStyle(.secondary)
                        HStack {
                            Button("Unlock Vault…", action: state.unlockVault).buttonStyle(.borderedProminent)
                            Button("Open Vault…", action: state.chooseVault)
                        }
                    } else {
                        Text("Reopen VeraData after recovering your vault file.")
                            .foregroundStyle(.secondary)
                    }
                } else if state.profile.records.isEmpty {
                    Text("Keep your information close")
                        .font(.system(size: 31, weight: .semibold)).tracking(-0.7)
                    Text("Save a contact, address, or job once. Search and copy the details whenever a form asks for them.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420, alignment: .leading)
                    HStack(spacing: 10) {
                        Button("New Record") { state.editor = RecordDraft() }.buttonStyle(.borderedProminent)
                        Button("Open Fictional Demo") { state.installDemo() }
                    }
                    .padding(.top, 5)
                } else {
                    Text("Choose a record").font(.largeTitle.weight(.semibold))
                    Text("Select a record in the sidebar or open Quick Search.").foregroundStyle(.secondary)
                }
                status
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func verificationAction(for key: String?, in record: VeraDataCore.Record) -> (() -> Void)? {
        guard state.canEdit, state.canSwitchVault, let key,
              FieldVerification.comparisonText(record.fields[key]) != nil else { return nil }
        return { state.verifyField(key) }
    }

    private func evidenceStatus(for field: RecordValue, in record: VeraDataCore.Record) -> String? {
        guard field.path.count == 1, let key = field.path.first else { return nil }
        let marks = record.evidence.filter { $0.fields[key] != nil }
        guard !marks.isEmpty else { return nil }
        return marks.contains { $0.matches(key, in: record) && state.evidenceFiles.contains($0.document) }
            ? "Checked against source" : "Needs review"
    }

    @ViewBuilder
    private var status: some View {
        if let status = state.status {
            Text(status)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color(nsColor: .labelColor))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityIdentifier("operationStatus")
        } else if !state.shortcutAvailable, state.vault.shortcut != .off, state.canEdit {
            Text("Global shortcut unavailable. You can change it in the Records menu.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct FieldRow: View {
    let field: RecordValue
    let evidenceStatus: String?
    let verification: FieldVerification?
    let verify: (() -> Void)?
    let copy: (String, String) -> Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(field.localizedLabel).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    if let evidenceStatus {
                        Text(VeraText.text(evidenceStatus)).font(.caption).foregroundStyle(.secondary)
                    }
                    FieldVerificationBadge(verification: verification, value: field.value)
                }
                if let items = field.bulletItems {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(items.indices, id: \.self) { index in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").accessibilityHidden(true)
                                Text(items[index]).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.leading, 12)
                    .textSelection(.enabled)
                } else {
                    Text(field.display)
                        .font(.body)
                        .foregroundStyle(field.representations.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !field.missingFields.isEmpty {
                    Text(VeraText.format("Skipped empty fields: %@", field.missingFields.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let verify {
                Button(action: verify) {
                    Label("Verify Field…", systemImage: "checkmark.circle").labelStyle(.iconOnly)
                }
                .help(VeraText.format("Verify %@", field.localizedLabel))
                .accessibilityLabel(VeraText.format("Verify %@", field.localizedLabel))
            }
            if let first = field.preferredRepresentation {
                Button { _ = copy(first.text, field.localizedLabel) } label: {
                    Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                }
                .help(VeraText.format("Copy %@", field.localizedLabel)).accessibilityLabel(VeraText.format("Copy %@", field.localizedLabel))
                if field.representations.count > 1 {
                    Menu {
                        ForEach(field.representations) { format in
                            Button(format.localizedLabel) { _ = copy(format.text, field.localizedLabel) }
                        }
                    } label: {
                        Text("Format")
                    }
                    .fixedSize().accessibilityLabel(VeraText.format("Copy %@ in another format", field.localizedLabel))
                }
            }
        }
        .padding(.vertical, 13)
    }
}

private struct WindowCapture: NSViewRepresentable {
    let capture: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReader {
        let view = WindowReader()
        view.capture = capture
        return view
    }

    func updateNSView(_ nsView: WindowReader, context: Context) { nsView.capture = capture }

    final class WindowReader: NSView {
        var capture: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { capture?(window) }
        }
    }
}
