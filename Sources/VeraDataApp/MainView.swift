import AppKit
import SwiftUI
import VeraDataCore

struct MainView: View {
    @ObservedObject var state: AppState
    @ViewState private var newProfile: Bool = false
    @ViewState private var profileName: String = ""
    @ViewState private var proposedDeletion: Record?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 258)
            Divider()
            detail
        }
        .background(WindowCapture { state.mainWindow = $0 })
        .sheet(item: $state.editor) { draft in
            RecordEditor(initial: draft, save: state.saveRecord)
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
            Text(VeraText.format("This replaces all local profiles and the search shortcut with the backup’s %lld profiles. Back up your current vault first if you want to keep it.", candidate.profiles.count))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("VeraData")
                .font(.custom("Helvetica Neue", size: 27, relativeTo: .title).weight(.bold))
                .tracking(-1.1)
                .padding(.horizontal, 20).padding(.top, 21).padding(.bottom, 17)
                .accessibilityAddTraits(.isHeader)

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
                    Button("Back Up Vault…", action: state.backup)
                    Button("Restore Vault…", action: state.chooseRestore)
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
                        FieldRow(field: field, copy: state.copy)
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
                    Text("Vault unavailable").font(.largeTitle.weight(.semibold))
                    Text("Reopen VeraData after recovering your vault file.")
                        .foregroundStyle(.secondary)
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
    let copy: (String, String) -> Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(field.localizedLabel).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Text(field.display)
                    .font(.body)
                    .foregroundStyle(field.representations.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let first = field.representations.first {
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
