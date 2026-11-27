import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import UniformTypeIdentifiers
import VeraDataCore

// Select the SwiftUI property wrapper on SDKs that also export a State macro.
typealias ViewState<Value> = State<Value>

@main
struct VeraDataApp: App {
    @StateObject private var state = AppState()
    @StateObject private var updates = AppUpdates()

    var body: some Scene {
        Window(VeraText.text("VeraData"), id: "vault") {
            MainView(state: state, updateURL: updates.updateURL)
                .frame(minWidth: 690, minHeight: 480)
                .tint(.blue)
                .task { await updates.monitor() }
                .onOpenURL { state.openVault($0) }
        }
        .defaultSize(width: 1020, height: 690)
        .commands {
            CommandGroup(after: .appInfo) {
                if let url = updates.updateURL {
                    Button("Update App…") { NSWorkspace.shared.open(url) }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Record") { state.editor = RecordDraft() }
                    .keyboardShortcut("n")
                    .disabled(!state.canEdit)
                Divider()
                Button("New Encrypted Vault…") { state.createEncryptedVault() }.disabled(!state.canSwitchVault)
                Button("Open Vault…", action: state.chooseVault).disabled(!state.canSwitchVault)
                Button("Save Vault As…", action: state.saveVaultAs).disabled(!state.canEdit || !state.canSwitchVault)
                if state.isEncrypted, state.canEdit {
                    Button("Lock Vault", action: state.lockVault).disabled(!state.canSwitchVault)
                }
                Divider()
                Button("Back Up Records as JSON…", action: state.backUpRecords).disabled(!state.canEdit || !state.canSwitchVault)
                Button("Restore Records from JSON…", action: state.chooseRestore).disabled(!state.canEdit || state.isEncrypted)
                Button("Revision History…") { state.historyOpen = true }.disabled(!state.canEdit)
                Button("Import Records…", action: state.chooseImport).disabled(!state.canEdit)
                Button("Export Data…") { state.openExport() }.disabled(!state.canExportData)
                Button("Export for iPhone…") { state.phoneExportOpen = true }.disabled(!state.canExportToPhone)
            }
            CommandMenu("Records") {
                Button("Quick Search") { state.openSearch() }.keyboardShortcut("k")
                Button("Search This Record") { state.openSearch(scopedTo: state.record?.id) }
                    .keyboardShortcut("k", modifiers: [.command, .shift]).disabled(state.record == nil)
                Divider()
                Button("Previous Record") { state.stepRecord(-1) }.keyboardShortcut("[")
                    .disabled(!state.canStepRecord(-1))
                Button("Next Record") { state.stepRecord(1) }.keyboardShortcut("]")
                    .disabled(!state.canStepRecord(1))
                Divider()
                Menu("Global Search Shortcut") {
                    ForEach(SearchShortcut.allCases) { shortcut in
                        Button {
                            state.changeShortcut(shortcut)
                        } label: {
                            if state.vault.shortcut == shortcut { Label(VeraText.text(shortcut.title), systemImage: "checkmark") }
                            else { Text(VeraText.text(shortcut.title)) }
                        }
                        .disabled(!state.canEdit)
                    }
                }
            }
        }
    }
}

@MainActor
final class AppState: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var vault = Vault(profiles: [Profile(name: VeraText.text("Personal"))])
    @Published private(set) var profileID = ""
    @Published var recordID: String?
    @Published var editor: RecordDraft?
    @Published var evidenceRecord: Record?
    @Published var verificationRequest: SavedVerificationRequest?
    @Published var problem: String?
    @Published var status: String?
    @Published var restoreCandidate: Vault?
    @Published var importRequest: ImportRequest?
    @Published var phoneExportOpen = false
    @Published var exportRequest: ExportRequest?
    @Published var historyOpen = false
    @Published private(set) var reloadPending = false
    @Published private(set) var canEdit = true
    @Published private(set) var shortcutAvailable = false

    private(set) var index = RetrievalIndex(records: [])
    private var store: VaultFile
    var stateStore: VaultStateStore { store.stateStore }
    var evidenceFiles: EvidenceFileStore { EvidenceFileStore(vaultURL: store.url, archive: store.archive) }
    @Published private(set) var isEncrypted = false
    var vaultFilename: String { store.url.lastPathComponent }
    var showsVaultFilename: Bool { store.url != VaultFile.defaultURL || VaultArchive.isArchiveURL(store.url) }
    var canSwitchVault: Bool {
        editor == nil && evidenceRecord == nil && verificationRequest == nil && importRequest == nil && exportRequest == nil &&
            restoreCandidate == nil && !phoneExportOpen && !historyOpen
    }
    private static let workingVaultPreference = "WorkingVaultPath"
    private static let vaultType = UTType(exportedAs: "com.iandorsey.veradata.vault", conformingTo: .data)
    private static let defaultVaultFilename = "Database.veradata"
    private var hotkey: GlobalShortcut?
    private var searchPanel: NSPanel?
    private var returnApp: NSRunningApplication?
    private var verificationSource = NSWorkspace.shared.frontmostApplication
    private var pinnedRecordID: String?
    private var statusReset: Task<Void, Never>?
    weak var mainWindow: NSWindow?

    override init() {
        let custom = ProcessInfo.processInfo.environment["VERADATA_VAULT_PATH"]
        let saved = UserDefaults.standard.string(forKey: Self.workingVaultPreference)
            ?? UserDefaults.standard.string(forKey: "EncryptedWorkingVaultPath")
        let location = custom == nil ? saved.map { URL(fileURLWithPath: $0) } ?? VaultFile.defaultURL : VaultFile.defaultURL
        store = VaultFile(url: location)
        super.init()
        do {
            if VaultArchive.isArchiveURL(location) {
                isEncrypted = try VaultArchive.requiresPassword(at: location)
                if !isEncrypted {
                    store = try VaultFile(url: location, archive: VaultArchive.open(location))
                }
            }
            canEdit = !isEncrypted
            if canEdit, let saved = try store.load() { vault = saved }
        } catch {
            canEdit = false
            problem = VeraText.format("The local vault could not be opened. Its file was preserved. %@", error.localizedDescription)
        }
        selectProfile(vault.profiles[0].id)
        hotkey = GlobalShortcut { [weak self] in self?.openSearch() }
        registerShortcut()
    }

    var profile: Profile { vault.profiles.first { $0.id == profileID } ?? vault.profiles[0] }
    var record: Record? { profile.records.first { $0.id == recordID } }
    var canExportData: Bool { profile.records.contains { !$0.fields.isEmpty } }
    var canExportToPhone: Bool { vault.profiles.contains { !$0.records.isEmpty } }
    var hasDemo: Bool { vault.profiles.contains { $0.id == "demo" } }

    func selectProfile(_ id: String) {
        guard let profile = vault.profiles.first(where: { $0.id == id }) else { return }
        index = RetrievalIndex(records: profile.records)
        profileID = id
        recordID = profile.records.first?.id
        pinnedRecordID = nil
    }

    func createProfile(_ name: String) -> Bool {
        let profile = Profile(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        var updated = vault
        updated.profiles.append(profile)
        guard commit(updated) else { return false }
        selectProfile(profile.id)
        showStatus(VeraText.text("Your changes have been saved."))
        return true
    }

    func installDemo() {
        if hasDemo { selectProfile("demo"); return }
        do {
            let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main : Bundle.module
            guard let path = bundle.url(forResource: "demo", withExtension: "json") else {
                throw DataIssue("The fictional demo is missing from this build.")
            }
            let demo = try VaultFile.readBackup(path)
            var updated = vault
            updated.profiles.append(contentsOf: demo.profiles)
            if commit(updated) { selectProfile("demo") }
        } catch { problem = error.localizedDescription }
    }

    func saveRecord(_ record: Record) throws {
        guard let profileIndex = vault.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw DataIssue("Select a profile to save this record.")
        }
        var updated = vault
        if let position = profile.records.firstIndex(where: { $0.id == record.id }) {
            var edited = record
            edited.evidence = updated.profiles[profileIndex].records[position].evidence
            updated.profiles[profileIndex].records[position] = edited
        } else {
            updated.profiles[profileIndex].records.append(record)
        }
        try persist(updated)
        recordID = record.id
        showStatus(VeraText.text("Your changes have been saved."))
    }

    func saveEvidence(_ evidence: [EvidenceMark], for record: Record, attachment: VaultAttachment?) throws {
        guard let profileIndex = vault.profiles.firstIndex(where: { $0.id == profileID }),
              let recordIndex = vault.profiles[profileIndex].records.firstIndex(where: { $0.id == record.id }),
              vault.profiles[profileIndex].records[recordIndex] == record else { throw VaultStateConflict.stale }
        var updated = vault
        updated.profiles[profileIndex].records[recordIndex].evidence = evidence
        try persist(updated, attachment: attachment)
        evidenceRecord = nil
        showStatus(VeraText.text("Evidence updated."))
    }

    func verifyField(_ key: String) {
        guard canEdit, canSwitchVault, let record, let value = record.fields[key],
              FieldVerification.comparisonText(value) != nil else { return }
        verificationRequest = SavedVerificationRequest(profileID: profileID, record: record,
            target: VerificationTarget(key: key, title: record.fieldDefinition(key).localizedLabel, value: value))
    }

    func saveVerification(_ verification: FieldVerification, request: SavedVerificationRequest) throws {
        guard let index = vault.profiles.firstIndex(where: { $0.id == request.profileID }),
              let position = vault.profiles[index].records.firstIndex(where: { $0.id == request.record.id }),
              vault.profiles[index].records[position] == request.record else { throw VaultStateConflict.stale }
        var updated = vault
        updated.profiles[index].records[position].verifications[request.target.key] = verification
        try persist(updated)
        showStatus(VeraText.text("Field verified."))
    }

    func trackVerificationSource(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        verificationSource = app
    }

    func selectedOriginalText() throws -> String {
        guard let app = verificationSource, !app.isTerminated,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw DataIssue("Select the original text in another app or paste it here.")
        }
        guard AXIsProcessTrusted() else {
            throw DataIssue("Allow VeraData in System Settings › Privacy & Security › Accessibility to compare selections, or paste the original text.")
        }
        let source = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(),
              AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selection) == .success,
              let text = selection as? String, FieldVerification.comparisonText(.string(text)) != nil else {
            throw DataIssue("The source app did not provide selected text. Select the original text again or paste it here.")
        }
        return text
    }

    func deleteRecord(_ id: String) {
        guard let profileIndex = vault.profiles.firstIndex(where: { $0.id == profileID }) else { return }
        let position = profile.records.firstIndex { $0.id == id } ?? 0
        var updated = vault
        updated.profiles[profileIndex].records.removeAll { $0.id == id }
        if commit(updated) {
            if pinnedRecordID == id { pinnedRecordID = nil }
            let records = profile.records
            recordID = records.isEmpty ? nil : records[min(position, records.count - 1)].id
            showStatus(VeraText.text("Record deleted."))
        }
    }

    func stepTarget(_ direction: Int, from id: String? = nil) -> Record? {
        guard let record = profile.records.first(where: { $0.id == (id ?? recordID) }) else { return nil }
        let peers = profile.records.filter { $0.kind == record.kind }
        guard let position = peers.firstIndex(where: { $0.id == record.id }),
              peers.indices.contains(position + direction) else { return nil }
        return peers[position + direction]
    }

    func canStepRecord(_ direction: Int) -> Bool { stepTarget(direction) != nil }
    func stepRecord(_ direction: Int) {
        if let target = stepTarget(direction) {
            if pinnedRecordID == recordID { pinnedRecordID = target.id }
            recordID = target.id
        }
    }

    func chooseVault() {
        guard canSwitchVault else { return }
        let panel = NSOpenPanel()
        panel.title = VeraText.text("Open Vault")
        panel.allowedContentTypes = [Self.vaultType, .json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVault(url)
    }

    func openVault(_ url: URL) {
        guard url.isFileURL, canSwitchVault else { return }
        do {
            if VaultArchive.isArchiveURL(url) {
                if try VaultArchive.requiresPassword(at: url) { openEncryptedVault(url); return }
                try adopt(VaultFile(url: url, archive: VaultArchive.open(url)))
            } else if url.pathExtension.lowercased() == "json" {
                try adopt(VaultFile(url: url))
            }
        } catch { problem = error.localizedDescription }
    }

    func createEncryptedVault() {
        guard canSwitchVault else { return }
        let panel = NSSavePanel()
        panel.title = VeraText.text("New Encrypted Vault")
        panel.allowedContentTypes = [Self.vaultType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.defaultVaultFilename
        guard panel.runModal() == .OK, let url = panel.url,
              let password = requestVaultPassword(creating: true, filename: url.lastPathComponent) else { return }
        do {
            let archive = try VaultArchive.create(at: url, password: password,
                                                  initialVault: Vault(profiles: [Profile(name: VeraText.text("Personal"))]))
            try adopt(VaultFile(url: url, archive: archive))
            showStatus(VeraText.text("Encrypted vault created."))
        } catch { problem = error.localizedDescription }
    }

    func unlockVault() {
        guard isEncrypted, canSwitchVault else { return }
        openEncryptedVault(store.url)
    }

    private func openEncryptedVault(_ url: URL) {
        guard let password = requestVaultPassword(creating: false, filename: url.lastPathComponent) else { return }
        do { try adopt(VaultFile(url: url, archive: VaultArchive.open(url, password: password))) }
        catch { problem = error.localizedDescription }
    }

    private func adopt(_ file: VaultFile) throws {
        var next = file
        guard let opened = try next.load() else { throw DataIssue("The vault has no records database.") }
        let selectedProfile = opened.profiles.first(where: { $0.id == profileID })?.id ?? opened.profiles[0].id
        let selectedRecord = recordID
        closeSearch(returnToOrigin: false)
        status = nil
        store = next
        isEncrypted = next.archive?.isEncrypted == true
        vault = opened
        selectProfile(selectedProfile)
        if profile.records.contains(where: { $0.id == selectedRecord }) { recordID = selectedRecord }
        canEdit = true
        reloadPending = false
        UserDefaults.standard.set(next.url.path, forKey: Self.workingVaultPreference)
        registerShortcut()
    }

    func lockVault() {
        guard isEncrypted, canSwitchVault else { return }
        closeSearch(returnToOrigin: false)
        status = nil
        store = VaultFile(url: store.url)
        vault = Vault(profiles: [Profile(name: VeraText.text("Personal"))])
        selectProfile(vault.profiles[0].id)
        canEdit = false
        reloadPending = false
        registerShortcut()
    }

    private func requestVaultPassword(creating: Bool, filename: String) -> String? {
        let panel = NSAlert()
        panel.messageText = VeraText.text(creating ? "Set Vault Password" : "Unlock Vault")
        panel.informativeText = creating
            ? VeraText.text("Use at least 12 characters and save the password somewhere safe. VeraData cannot recover it.")
            : filename
        let password = NSSecureTextField()
        password.placeholderString = VeraText.text("Vault password")
        let confirmation = NSSecureTextField()
        confirmation.placeholderString = VeraText.text("Confirm password")
        let inputs = NSStackView(views: creating ? [password, confirmation] : [password])
        inputs.orientation = .vertical
        inputs.alignment = .width
        inputs.spacing = 8
        inputs.frame = CGRect(x: 0, y: 0, width: 270, height: creating ? 58 : 25)
        panel.accessoryView = inputs
        panel.window.initialFirstResponder = password
        panel.addButton(withTitle: VeraText.text(creating ? "Create" : "Unlock"))
        panel.addButton(withTitle: VeraText.text("Cancel"))
        guard panel.runModal() == .alertFirstButtonReturn else { return nil }
        guard !creating || password.stringValue == confirmation.stringValue else {
            problem = VeraText.text("The vault passwords do not match.")
            return nil
        }
        return password.stringValue
    }

    func saveVaultAs() {
        guard canEdit, canSwitchVault else { return }
        let panel = NSSavePanel()
        panel.title = VeraText.text("Save Vault As")
        panel.allowedContentTypes = [Self.vaultType]
        panel.message = VeraText.text("Includes records, evidence, verification, presets, settings, and history. VeraData will use the new vault for future edits. The original stays where it is.")
        panel.nameFieldStringValue = VaultArchive.isArchiveURL(store.url)
            ? VeraText.format("%@ Copy", store.url.deletingPathExtension().lastPathComponent)
            : Self.defaultVaultFilename
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.addItems(withTitles: [VeraText.text("Unencrypted"), VeraText.text("Password-protected")])
        picker.selectItem(at: isEncrypted ? 1 : 0)
        picker.setAccessibilityLabel(VeraText.text("Vault format"))
        let accessory = NSStackView(views: [NSTextField(labelWithString: VeraText.text("Vault format")), picker])
        accessory.spacing = 8
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var password: String?
        if picker.indexOfSelectedItem == 1 {
            guard let entered = requestVaultPassword(creating: true, filename: url.lastPathComponent) else { return }
            password = entered
        }
        do {
            let archive = try VaultArchive.create(at: url, password: password, copying: stateStore, initialVault: vault)
            try adopt(VaultFile(url: url, archive: archive))
            showStatus(VeraText.text("Vault saved. Future edits go to this copy."))
        } catch { problem = error.localizedDescription }
    }

    func backUpRecords() {
        guard canEdit, canSwitchVault else { return }
        let panel = NSSavePanel()
        panel.title = VeraText.text("Back Up Records as JSON")
        panel.prompt = VeraText.text("Save Backup")
        panel.message = VeraText.text("Saves all profiles, records, and the search shortcut in readable JSON. Evidence, verification, presets, and revision history are excluded.")
        panel.allowedContentTypes = [.json]
        let date = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        panel.nameFieldStringValue = "VeraData-Records-\(date).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let latest = try stateStore.snapshot().vault() ?? vault
            try writeExport(latest.recordsBackupData(), to: url)
            showStatus(VeraText.text("Backup saved."))
        } catch { problem = error.localizedDescription }
    }

    func chooseImport() {
        let panel = NSOpenPanel()
        panel.title = VeraText.text("Import Records")
        panel.prompt = VeraText.text("Review Records")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importRequest = ImportRequest(fileName: url.lastPathComponent, data: try RecordImport.read(url))
        } catch { problem = error.localizedDescription }
    }

    func applyImport(
        _ review: RecordImportReview, decisions: [Record.ID: RecordImportReview.Decision], newProfileName: String?
    ) throws {
        var updated = vault
        var imported = try review.applying(decisions)
        if let name = newProfileName {
            guard !updated.profiles.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw DataIssue("That profile name already exists. Choose it as the destination or enter a different name.")
            }
            imported.name = name
            updated.profiles.append(imported)
        } else {
            guard let index = updated.profiles.firstIndex(where: { $0.id == review.destination.id }),
                  updated.profiles[index] == review.destination else {
                throw DataIssue("The destination profile changed. Reopen the import to review the latest records.")
            }
            updated.profiles[index] = imported
        }
        try persist(updated)
        selectProfile(imported.id)
        showStatus(VeraText.text("Import applied."))
    }

    func chooseRestore() {
        guard canEdit, !isEncrypted else { return }
        let panel = NSOpenPanel()
        panel.title = VeraText.text("Restore Records from JSON")
        panel.prompt = VeraText.text("Review Backup")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { restoreCandidate = try VaultFile.readBackup(url) }
        catch { problem = error.localizedDescription }
    }

    func restore(_ candidate: Vault) {
        restoreCandidate = nil
        do {
            try store.restore(candidate)
            try reloadVault()
            showStatus(VeraText.text("Vault restored."))
        } catch { problem = error.localizedDescription }
    }

    func openExport(recordID: Record.ID? = nil) {
        do {
            let snapshot = try stateStore.snapshot()
            guard try snapshot.vault() == vault else { throw VaultStateConflict.stale }
            exportRequest = ExportRequest(profile: profile, recordID: recordID, presets: ExportPresetStore(vaultURL: store.url, archive: store.archive),
                                          token: snapshot.token)
        } catch { problem = error.localizedDescription }
    }

    func restoreRevision(_ id: String, expected: String) throws {
        try stateStore.restore(id, expected: expected)
        try reloadVault()
        showStatus(VeraText.text("Vault and presets restored."))
    }

    func refreshExternalChanges() {
        guard canEdit else { return }
        do {
            guard try store.hasExternalChanges() else { reloadPending = false; return }
            if editor != nil || evidenceRecord != nil || verificationRequest != nil || importRequest != nil || exportRequest != nil || restoreCandidate != nil || phoneExportOpen {
                reloadPending = true
            } else {
                try reloadVault()
            }
        } catch VaultStateConflict.busy {
            // The next refresh can try again once the writer releases its lock.
        } catch {
            // Keep a valid view (and any open draft) when an external file is unreadable.
            reloadPending = canEdit
        }
    }

    private func reloadVault() throws {
        let saved = try store.load() ?? Vault(profiles: [Profile(name: VeraText.text("Personal"))])
        let selected = recordID
        let previousShortcut = vault.shortcut
        vault = saved
        let selectedProfile = saved.profiles.first { $0.id == profileID } ?? saved.profiles[0]
        if selectedProfile.id == profileID {
            index = RetrievalIndex(records: selectedProfile.records)
            recordID = selectedProfile.records.contains { $0.id == selected } ? selected : selectedProfile.records.first?.id
            if !selectedProfile.records.contains(where: { $0.id == pinnedRecordID }) { pinnedRecordID = nil }
        } else {
            selectProfile(selectedProfile.id)
        }
        canEdit = true
        reloadPending = false
        if previousShortcut != vault.shortcut { registerShortcut() }
    }

    func saveSelection(_ data: Data, suggestedFilename: String) {
        let panel = NSSavePanel()
        panel.title = VeraText.text("Export Data")
        panel.prompt = VeraText.text("Export")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedFilename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeExport(data, to: url)
            showStatus(VeraText.text("Selected fields exported."))
        } catch { problem = error.localizedDescription }
    }

    func exportToPhone(_ selection: [Profile.ID: Set<Record.ID>], evidence: Set<MobileTransfer.EvidencePick>) {
        do {
            let data = try MobileTransfer(vault: vault, selection: selection, evidence: evidence,
                                          readEvidence: evidenceFiles.read).data()
            let panel = NSSavePanel()
            panel.title = VeraText.text("Export for iPhone")
            panel.prompt = VeraText.text("Export")
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "VeraData-iPhone.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try writeExport(data, to: url)
            showStatus(VeraText.text("iPhone transfer exported."))
        } catch { problem = error.localizedDescription }
    }

    private func writeExport(_ data: Data, to destination: URL) throws {
        let folder = destination.deletingLastPathComponent()
        let filename = ".veradata-export-\(UUID().uuidString)"
        let temporary = folder.appendingPathComponent(filename)
        guard destination.standardizedFileURL.resolvingSymlinksInPath() != store.url.standardizedFileURL.resolvingSymlinksInPath() else {
            throw DataIssue("Choose a separate location for your export.")
        }
        let files = FileManager.default
        guard files.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw DataIssue("The export could not be written to the selected folder.")
        }
        defer { try? files.removeItem(at: temporary) }
        guard rename(temporary.path, destination.path) == 0 else {
            throw DataIssue("The export could not be saved at the selected location.")
        }
    }

    private func commit(_ updated: Vault) -> Bool {
        do {
            try persist(updated)
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    private func persist(_ updated: Vault, attachment: VaultAttachment? = nil) throws {
        guard canEdit else { throw DataIssue("Recover the local vault before saving changes.") }
        try store.save(updated, attachment: attachment)
        index = RetrievalIndex(records: updated.profiles.first { $0.id == profileID }?.records ?? [])
        vault = updated
    }

    func changeShortcut(_ shortcut: SearchShortcut) {
        let previous = vault.shortcut
        guard shortcut != previous || !shortcutAvailable else { return }
        guard hotkey?.register(shortcut) == true else {
            registerShortcut()
            problem = VeraText.text("That shortcut is unavailable. Choose another shortcut in Records › Global Search Shortcut.")
            return
        }
        var updated = vault
        updated.shortcut = shortcut
        if commit(updated) { showStatus(VeraText.text("Your changes have been saved.")) }
        registerShortcut()
    }

    private func registerShortcut() {
        let shortcut = canEdit ? vault.shortcut : .off
        let registered = hotkey?.register(shortcut) == true
        shortcutAvailable = registered && shortcut != .off
    }

    func openSearch(scopedTo id: String? = nil) {
        guard canEdit else { return }
        if let visible = searchPanel, visible.isVisible {
            visible.makeKeyAndOrderFront(nil)
            return
        }
        if let id { pin(id) }
        let active = NSWorkspace.shared.frontmostApplication
        returnApp = active?.processIdentifier != ProcessInfo.processInfo.processIdentifier ? active : nil
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 472),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = VeraText.text("Quick Search")
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.contentViewController = NSHostingController(rootView:
            PaletteView(state: self, initialScope: pinnedRecordID).tint(.blue)
        )
        searchPanel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func pin(_ id: String?) {
        pinnedRecordID = id
        if let id { recordID = id }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === searchPanel {
            closeSearch()
            return false
        }
        return true
    }

    func closeSearch(returnToOrigin: Bool = true) {
        let panel = searchPanel
        searchPanel = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        DispatchQueue.main.async { panel?.contentViewController = nil }
        if returnToOrigin, let returnApp { returnApp.activate(options: []) }
        else { mainWindow?.makeKeyAndOrderFront(nil) }
        returnApp = nil
    }

    func openRecordFromSearch(_ id: String) {
        recordID = id
        closeSearch(returnToOrigin: false)
    }

    @discardableResult
    func copy(_ text: String, label: String) -> Bool {
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setString(text, forType: .string) else {
            problem = VeraText.text("The value could not be copied.")
            return false
        }
        showStatus(VeraText.format("Copied %@.", VeraText.text(label.lowercased())))
        return true
    }

    private func showStatus(_ message: String) {
        statusReset?.cancel()
        status = message
        statusReset = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            status = nil
        }
    }
}

@MainActor
final class GlobalShortcut {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        installHandler()
    }

    func register(_ shortcut: SearchShortcut) -> Bool {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        guard shortcut != .off else { return true }
        guard handler != nil else { return false }
        let codes = [SearchShortcut.space: kVK_Space, .j: kVK_ANSI_J, .k: kVK_ANSI_K]
        let code = UInt32(codes[shortcut] ?? kVK_Space)
        let id = EventHotKeyID(signature: 0x5644_4154, id: 1)
        return RegisterEventHotKey(code, UInt32(controlKey | optionKey), id, GetApplicationEventTarget(),
                                   0, &reference) == noErr
    }

    private func installHandler() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x5644_4154, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { shortcut.action() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
}
