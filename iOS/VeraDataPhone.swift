import Combine
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VeraDataCore

@main
struct VeraDataPhone: App {
    var body: some Scene {
        WindowGroup { PhoneLibrary() }
    }
}

@MainActor
private final class PhoneStore: ObservableObject {
    @Published private(set) var transfer: MobileTransfer?
    private var indexes: [String: RetrievalIndex] = [:]
    @Published var problem: String?
    var hasSavedTransfer: Bool { FileManager.default.fileExists(atPath: Self.vault.path) }

    private static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "VeraData", directoryHint: .isDirectory)
    }
    private static var vault: URL { folder.appending(path: "transfer.json") }

    init() {
        do { apply(try MobileTransfer.read(Self.vault)) }
        catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {}
        catch { problem = error.localizedDescription }
    }

    func preview(_ url: URL) throws -> MobileTransfer {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<MobileTransfer, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result { try MobileTransfer.read(coordinated) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw DataIssue("Could not read the transfer file.") }
        return try result.get()
    }

    func replace(with snapshot: MobileTransfer) throws {
        var folder = Self.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var options = URLResourceValues()
        options.isExcludedFromBackup = true
        try folder.setResourceValues(options)
        try snapshot.data().write(to: Self.vault, options: [.atomic, .completeFileProtection])
        apply(snapshot)
    }

    func clear() throws {
        do { try FileManager.default.removeItem(at: Self.vault) }
        catch let error as CocoaError where [.fileNoSuchFile, .fileReadNoSuchFile].contains(error.code) {}
        indexes = [:]
        transfer = nil
    }

    func index(for profile: Profile) -> RetrievalIndex {
        indexes[profile.id] ?? RetrievalIndex(records: profile.records)
    }

    private func apply(_ snapshot: MobileTransfer) {
        indexes = Dictionary(uniqueKeysWithValues: snapshot.profiles.map { ($0.id, RetrievalIndex(records: $0.records)) })
        transfer = snapshot
    }
}

private struct PhoneLibrary: View {
    @StateObject private var store = PhoneStore()
    @State private var importOpen = false
    @State private var pending: MobileTransfer?
    @State private var removeOpen = false
    @State private var profileID: String?
    @State private var query = ""
    @State private var copied = false

    private var profile: Profile? {
        store.transfer?.profiles.first { $0.id == profileID } ?? store.transfer?.profiles.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if let profile {
                    ProfileRecords(profile: profile, query: query, index: store.index(for: profile), copy: copy)
                        .searchable(text: $query, prompt: Text(VeraText.text("Search records or fields")))
                } else {
                    ContentUnavailableView {
                        Label(VeraText.text("No records on this iPhone"), systemImage: "tray")
                    } description: {
                        Text(VeraText.text("On your Mac, choose File › Export for iPhone. Then import that file here."))
                    } actions: {
                        Button(VeraText.text("Import Transfer")) { importOpen = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("VeraData")
            .toolbar {
                if let profile, let profiles = store.transfer?.profiles {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            ForEach(profiles) { item in
                                Button {
                                    profileID = item.id
                                    query = ""
                                } label: {
                                    if item.id == profile.id { Label(item.name, systemImage: "checkmark") }
                                    else { Text(item.name) }
                                }
                            }
                        } label: {
                            Label(profile.name, systemImage: "person.crop.circle")
                                .lineLimit(1)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            importOpen = true
                        } label: {
                            Label(VeraText.text("Import Transfer"), systemImage: "square.and.arrow.down")
                        }
                        if store.hasSavedTransfer {
                            Button(role: .destructive) {
                                removeOpen = true
                            } label: {
                                Label(VeraText.text("Remove Downloaded Records"), systemImage: "trash")
                            }
                        }
                    } label: {
                        Label(VeraText.text("Options"), systemImage: "ellipsis.circle")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if copied {
                    Text(VeraText.text("Copied"))
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 15).padding(.vertical, 7)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 6)
                }
            }
        }
        .onChange(of: copied) { _, value in
            if value { Task { try? await Task.sleep(for: .seconds(1.5)); copied = false } }
        }
        .fileImporter(isPresented: $importOpen, allowedContentTypes: [.json]) { result in
            attempt {
                let transfer = try store.preview(result.get())
                if store.transfer == nil { try install(transfer) }
                else { pending = transfer }
            }
        }
        .confirmationDialog(VeraText.text("Replace downloaded records?"), isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { transfer in
            Button(VeraText.text("Replace Records"), role: .destructive) { attempt { try install(transfer) } }
        } message: { transfer in
            Text(VeraText.format("This transfer contains %lld profiles and %lld records.", transfer.profiles.count, transfer.recordCount))
        }
        .confirmationDialog(VeraText.text("Remove downloaded records?"), isPresented: $removeOpen, titleVisibility: .visible) {
            Button(VeraText.text("Remove Downloaded Records"), role: .destructive) {
                attempt { try store.clear(); query = ""; profileID = nil }
            }
        } message: {
            Text(VeraText.text("This removes the copies inside VeraData on this iPhone."))
        }
        .alert(VeraText.text("VeraData"), isPresented: Binding(
            get: { store.problem != nil }, set: { if !$0 { store.problem = nil } }
        )) {
            Button(VeraText.text("OK"), role: .cancel) {}
        } message: {
            Text(store.problem ?? "")
        }
    }

    private func attempt(_ operation: () throws -> Void) {
        do { try operation() }
        catch { store.problem = error.localizedDescription }
    }

    private func install(_ value: MobileTransfer) throws {
        try store.replace(with: value)
        profileID = value.profiles.first?.id
        query = ""
        pending = nil
    }

    private func copy(_ value: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)]
        )
        copied = true
    }
}

private struct ProfileRecords: View {
    let profile: Profile
    let query: String
    let index: RetrievalIndex
    let copy: (String) -> Void

    var body: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            List {
                ForEach(RecordKind.allCases) { kind in
                    let records = profile.records.filter { $0.kind == kind }
                    if !records.isEmpty {
                        Section(VeraText.text(kind.section)) {
                            ForEach(records) { record in recordLink(record) }
                        }
                    }
                }
            }
        } else {
            let results = index.search(query)
            List(results) { result in
                if let record = result.record, result.field == nil {
                    recordLink(record)
                } else {
                    CopyRow(title: result.title, detail: result.subtitle, preview: result.field?.display,
                            formats: result.representations, preferred: result.preferredFormat) { format in
                        let fresh = result.currentValue?.representations(at: .now).first { $0.id == format.id }
                        copy((fresh ?? format).text)
                    }
                }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(VeraText.text("No matches"), systemImage: "magnifyingglass")
                }
            }
        }
    }

    private func recordLink(_ record: VeraDataCore.Record) -> some View {
        NavigationLink {
            List(record.values) { field in
                CopyRow(title: field.localizedLabel, detail: "", preview: field.display, formats: field.representations) {
                    copy($0.text)
                }
            }
            .navigationTitle(record.label)
            .navigationBarTitleDisplayMode(.inline)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(record.label)
                if !record.subtitle.isEmpty {
                    Text(record.subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct CopyRow: View {
    let title: String
    let detail: String
    let preview: String?
    let formats: [Representation]
    var preferred: Representation? = nil
    let copy: (Representation) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
                if let preview = preferred?.text ?? preview { Text(preview).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            if let format = preferred ?? formats.first {
                Button {
                    copy(format)
                } label: {
                    Label(VeraText.text("Copy"), systemImage: "doc.on.doc").labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.borderless)
            }
            if formats.count > 1 {
                Menu {
                    ForEach(formats) { format in
                        Button(format.localizedLabel) { copy(format) }
                    }
                } label: {
                    Label(VeraText.text("Format"), systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.borderless)
            }
        }
    }
}
