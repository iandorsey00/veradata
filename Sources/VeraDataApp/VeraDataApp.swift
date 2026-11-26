import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers
import VeraDataCore

// Select the SwiftUI property wrapper on SDKs that also export a State macro.
typealias ViewState<Value> = State<Value>

@main
struct VeraDataApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("VeraData", id: "vault") {
            MainView(state: state)
                .frame(minWidth: 690, minHeight: 480)
                .tint(.blue)
        }
        .defaultSize(width: 1020, height: 690)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Record") { state.editor = RecordDraft() }
                    .keyboardShortcut("n")
                    .disabled(!state.canEdit)
                Divider()
                Button("Back Up Vault…", action: state.backup).disabled(!state.canEdit)
                Button("Restore Vault…", action: state.chooseRestore).disabled(!state.canEdit)
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
    @Published var problem: String?
    @Published var status: String?
    @Published var restoreCandidate: Vault?
    @Published var importRequest: ImportRequest?
    @Published var phoneExportOpen = false
    @Published var exportRequest: ExportRequest?
    @Published private(set) var canEdit = true
    @Published private(set) var shortcutAvailable = false

    private(set) var index = RetrievalIndex(records: [])
    private var store: VaultFile
    private var hotkey: GlobalShortcut?
    private var searchPanel: NSPanel?
    private var returnApp: NSRunningApplication?
    private var pinnedRecordID: String?
    private var statusReset: Task<Void, Never>?
    weak var mainWindow: NSWindow?

    override init() {
        store = VaultFile(url: VaultFile.defaultURL)
        super.init()
        do {
            if let saved = try store.load() { vault = saved }
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
            updated.profiles[profileIndex].records[position] = record
        } else {
            updated.profiles[profileIndex].records.append(record)
        }
        try persist(updated)
        recordID = record.id
        showStatus(VeraText.text("Your changes have been saved."))
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

    func backup() {
        let panel = NSSavePanel()
        panel.title = VeraText.text("Back Up VeraData")
        panel.prompt = VeraText.text("Save Backup")
        panel.message = VeraText.text("A backup includes every profile and stored value in readable JSON.")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "VeraData-backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeExport(vault.data(), to: url)
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
        let panel = NSOpenPanel()
        panel.title = VeraText.text("Restore VeraData")
        panel.prompt = VeraText.text("Review Backup")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { restoreCandidate = try VaultFile.readBackup(url) }
        catch { problem = error.localizedDescription }
    }

    func restore(_ candidate: Vault) {
        restoreCandidate = nil
        if commit(candidate) {
            selectProfile(vault.profiles[0].id)
            registerShortcut()
            showStatus(VeraText.text("Vault restored."))
        }
    }

    func openExport(recordID: Record.ID? = nil) {
        exportRequest = ExportRequest(profile: profile, recordID: recordID, presets: ExportPresetStore(vaultURL: store.url))
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

    func exportToPhone(_ selection: [Profile.ID: Set<Record.ID>]) {
        do {
            let data = try MobileTransfer(vault: vault, selection: selection).data()
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

    private func persist(_ updated: Vault) throws {
        guard canEdit else { throw DataIssue("Recover the local vault before saving changes.") }
        try store.save(updated)
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
        let registered = hotkey?.register(vault.shortcut) == true
        shortcutAvailable = registered && vault.shortcut != .off
    }

    func openSearch(scopedTo id: String? = nil) {
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
