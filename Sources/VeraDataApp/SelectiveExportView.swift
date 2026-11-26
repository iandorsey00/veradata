import AppKit
import SwiftUI
import VeraDataCore

struct ExportRequest: Identifiable {
    let id = UUID()
    let profile: Profile
    let recordID: Record.ID?
    let presets: ExportPresetStore
}

struct SelectiveExportView: View {
    let request: ExportRequest
    let save: (Data, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var format: ExportFormat
    @ViewState private var chosen: [ExportFormat: [ExportRecordSelection]] = [:]
    @ViewState private var recordID: Record.ID?
    @ViewState private var preview: Data?
    @ViewState private var problem: String?
    @ViewState private var savedNames: [String] = []
    @ViewState private var presetName = ""
    @ViewState private var namedSelection: (name: String, format: ExportFormat, records: [ExportRecordSelection])?
    @ViewState private var editingPreset = false
    @ViewState private var confirmReplacement = false
    @ViewState private var presetStatus: String?

    init(request: ExportRequest, save: @escaping (Data, String) -> Void) {
        self.request = request
        self.save = save
        let record = request.profile.records.first { $0.id == request.recordID }
        _format = State(initialValue: record?.fields.values.contains(where: \.isScalar) == true ? .flatRecord : .structured)
        _recordID = State(initialValue: request.recordID ?? request.profile.records.first(where: { !$0.fields.isEmpty })?.id)
    }

    private var formats: [ExportFormat] {
        request.recordID == nil && chosen[.flatRecord]?.isEmpty != false
            ? [.structured, .veraFlowResume] : [.flatRecord, .structured, .veraFlowResume]
    }

    private var selection: [ExportRecordSelection] { chosen[format, default: []] }

    private var suggestedFilename: String {
        if let namedSelection, namedSelection.format == format, namedSelection.records == selection {
            return namedSelection.name + ".json"
        }
        return format.filename
    }

    private var available: [Record] {
        let flatRecordID = chosen[.flatRecord]?.first?.id ?? request.recordID
        return request.profile.records.filter { record in
            (format != .flatRecord || record.id == flatRecordID)
                && record.orderedKeys.contains { format.includes($0, in: record) }
        }
    }

    private var focused: Record? { available.first { $0.id == recordID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(preview == nil ? VeraText.text("Export Data") : VeraText.text("Review Export"))
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            if let preview {
                Text("This is the complete JSON file. Its contents are readable by anyone who has the file.")
                    .foregroundStyle(.secondary)
                ExportJSONPreview(data: preview)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                if editingPreset { presetEditor }
                if let problem { Text(problem).foregroundStyle(.red) }
                if let presetStatus { Text(presetStatus).foregroundStyle(.secondary) }
                HStack {
                    Button("Back") {
                        self.preview = nil
                        editingPreset = false
                        problem = nil
                        presetStatus = nil
                    }
                    Button("Save Preset…") { editingPreset.toggle(); problem = nil }
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Save JSON…") {
                        let filename = suggestedFilename
                        dismiss()
                        Task { @MainActor in save(preview, filename) }
                    }.keyboardShortcut(.defaultAction)
                }
            } else {
                HStack {
                    Text(request.profile.name).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !savedNames.isEmpty {
                        Menu("Load Preset") {
                            ForEach(savedNames, id: \.self) { name in
                                Button(name) { loadPreset(name) }
                            }
                        }.fixedSize()
                    }
                    Picker("Format", selection: $format) {
                        ForEach(formats) { format in Text(format.title).tag(format) }
                    }.fixedSize()
                }
                HStack {
                    Text(instruction).foregroundStyle(.secondary)
                    Spacer()
                    if format == .veraFlowResume {
                        Menu("Select Résumé Fields") {
                            Button("Standard") { selectResumeFields(.standard) }
                            Button("Recommended") { selectResumeFields(.recommended) }
                            Button("Select All") { selectResumeFields(.all) }
                        }
                        .disabled(available.isEmpty)
                        .fixedSize()
                    }
                }
                HStack(spacing: 0) {
                    recordList.frame(width: 242)
                    Divider()
                    if let focused { fieldList(for: focused).id(focused.id) }
                    else {
                        Text("No fields are available for this export format.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    }
                }
                if let problem { Text(problem).foregroundStyle(.red) }
                HStack {
                    Text(selection.count == 1 ? VeraText.text("1 record selected") : VeraText.format("%lld records selected", selection.count)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Review…", action: review)
                        .disabled(selection.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 780, height: 575)
        .task { refreshPresets() }
        .confirmationDialog("Replace this export preset?", isPresented: $confirmReplacement, titleVisibility: .visible) {
            Button("Replace Preset", role: .destructive) { savePreset(replace: true) }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: format) { _, _ in
            problem = nil
            if focused == nil { recordID = available.first?.id }
        }
    }

    private var presetEditor: some View {
        HStack {
            TextField("Preset name", text: $presetName)
                .help("Use English letters, digits, hyphens or underscores.")
            Button("Save Preset") {
                if let name = try? ExportPreset.normalizedName(presetName), savedNames.contains(name) {
                    confirmReplacement = true
                } else {
                    savePreset()
                }
            }.disabled(presetName.isEmpty)
        }
    }

    private func refreshPresets() {
        do { savedNames = try request.presets.names(for: request.profile.id) }
        catch { problem = error.localizedDescription }
    }

    private func loadPreset(_ name: String) {
        do {
            let loaded = try request.presets.load(name).selection(in: request.profile)
            chosen[loaded.format] = loaded.records
            format = loaded.format
            recordID = loaded.records.first?.id
            presetName = name
            namedSelection = (name, loaded.format, loaded.records)
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    private func savePreset(replace: Bool = false) {
        do {
            let preset = try ExportPreset(name: presetName, profile: request.profile, selection: selection, format: format)
            try request.presets.save(preset, replace: replace)
            problem = nil
            presetName = preset.name
            namedSelection = (preset.name, format, selection)
            presetStatus = VeraText.format("Saved preset “%@”.", preset.name)
            editingPreset = false
            refreshPresets()
        } catch { problem = error.localizedDescription }
    }

    private var instruction: String {
        switch format {
        case .structured: return VeraText.text("Choose fields and list items. Selected records appear in export order.")
        case .veraFlowResume: return VeraText.text("Choose a selection, then review the fields and sections before exporting.")
        case .flatRecord: return VeraText.text("Choose individual values from this record.")
        }
    }

    private func selectResumeFields(_ scope: ResumeSelectionScope) {
        let contacts = available.filter { $0.kind == .contact }
        let selectedContact = selection.first { item in contacts.contains { $0.id == item.id } }?.id
        let contactID = selectedContact ?? (contacts.count == 1 ? contacts.first?.id : nil)
        let suggested = SelectiveExport.resumeSelection(in: request.profile, contactID: contactID, scope: scope)
        let byID = Dictionary(uniqueKeysWithValues: suggested.map { ($0.id, $0) })
        let customIDs = Set(available.filter { $0.kind == .custom }.map(\.id))
        let previouslySelectedIDs = Set(selection.map(\.id))
        chosen[format] = selection.compactMap { existing in
            guard var item = byID[existing.id] else {
                return scope == .recommended && customIDs.contains(existing.id) ? existing : nil
            }
            if scope == .recommended {
                item.fields.merge(existing.fields) { _, kept in kept }
            }
            if scope != .standard, let section = existing.resumeSection { item.resumeSection = section }
            return item
        } + suggested.filter { !previouslySelectedIDs.contains($0.id) }

        if contacts.count > 1 && contactID == nil {
            problem = VeraText.text("Select fields from one contact to add it to the résumé.")
        } else if scope == .all, selection.contains(where: { customIDs.contains($0.id) && $0.resumeSection == nil }) {
            problem = VeraText.text("Assign a section to each selected custom record or exclude it before exporting.")
        } else {
            problem = nil
        }
    }

    private var recordList: some View {
        VStack(spacing: 6) {
            List(selection: $recordID) {
                if !selection.isEmpty {
                    Section("Selected · export order") {
                        ForEach(selection) { item in
                            if let record = available.first(where: { $0.id == item.id }) { recordRow(record) }
                        }
                    }
                }
                let remaining = available.filter { record in !selection.contains(where: { $0.id == record.id }) }
                if !remaining.isEmpty {
                    Section("Available Records") {
                        ForEach(remaining) { record in recordRow(record) }
                    }
                }
            }
            .listStyle(.sidebar)
            if format != .flatRecord {
                HStack {
                    moveButton(-1, title: VeraText.text("Move record earlier"), icon: "arrow.up")
                    moveButton(1, title: VeraText.text("Move record later"), icon: "arrow.down")
                    Spacer()
                }.padding(.horizontal, 8).padding(.bottom, 4)
            }
        }
    }

    private func recordRow(_ record: Record) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.label).lineLimit(1)
            if !record.subtitle.isEmpty {
                Text(record.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .tag(record.id)
    }

    private func moveButton(_ offset: Int, title: String, icon: String) -> some View {
        let position = selection.firstIndex { $0.id == recordID }
        let canMove = position.map { selection.indices.contains($0 + offset) } ?? false
        return Button {
            guard let position, canMove else { return }
            let item = chosen[format, default: []].remove(at: position)
            chosen[format, default: []].insert(item, at: position + offset)
        } label: { Label(title, systemImage: icon).labelStyle(.iconOnly) }
        .disabled(!canMove).help(title)
    }

    private func fieldList(for record: Record) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(record.label).font(.headline)
                    Spacer()
                    Button("Select All Fields") {
                        setFields(SelectiveExport.allFields(in: record, format: format), for: record)
                    }
                    Button("Exclude Record") {
                        setFields([:], for: record)
                    }
                    .disabled(!selection.contains { $0.id == record.id })
                }
                if format == .veraFlowResume, record.kind == .custom,
                   let item = selection.first(where: { $0.id == record.id }) {
                    Picker("Résumé section", selection: Binding(
                        get: { item.resumeSection },
                        set: { section in
                            guard let index = selection.firstIndex(where: { $0.id == record.id }) else { return }
                            chosen[format, default: []][index].resumeSection = section
                            problem = nil
                        }
                    )) {
                        Text("Choose a section").tag(nil as ResumeSection?)
                        ForEach(ResumeSection.allCases) { section in
                            Text(section.title).tag(Optional(section))
                        }
                    }
                }
                ForEach(record.orderedKeys.filter { format.includes($0, in: record) }, id: \.self) { key in
                    if let value = record.fields[key] {
                        fieldRow(key, value: value, in: record)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    @ViewBuilder
    private func fieldRow(_ key: String, value: JSONValue, in record: Record) -> some View {
        let label = record.fieldDefinition(key).localizedLabel
        let current = selection.first { $0.id == record.id }?.fields[key]
        if let items = value.array, !items.isEmpty {
            let indices = selectedIndices(current, count: items.count)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("Select all items", isOn: Binding(get: { indices.count == items.count }, set: {
                        update(key, in: record, to: $0 ? .whole : nil)
                    }))
                    ForEach(items.indices, id: \.self) { index in
                        Toggle(isOn: Binding(get: { indices.contains(index) }, set: { checked in
                            var updated = indices
                            if checked { updated.insert(index) } else { updated.remove(index) }
                            let choice: ExportFieldSelection? = updated.isEmpty ? nil : .items(updated)
                            update(key, in: record, to: choice)
                        })) {
                            Text(valueText(items[index])).lineLimit(4)
                        }
                    }
                }.padding(.top, 8).padding(.leading, 8)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                    Text(VeraText.format("%lld of %lld items selected", indices.count, items.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Toggle(isOn: Binding(get: { current != nil }, set: {
                update(key, in: record, to: $0 ? .whole : nil)
            })) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                    Text(valueText(value)).lineLimit(3).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectedIndices(_ selected: ExportFieldSelection?, count: Int) -> Set<Int> {
        switch selected {
        case .whole: return Set(0..<count)
        case .items(let indices): return indices
        case nil: return []
        }
    }

    private func update(_ key: String, in record: Record, to choice: ExportFieldSelection?) {
        var fields = selection.first { $0.id == record.id }?.fields ?? [:]
        fields[key] = choice
        setFields(fields, for: record)
    }

    private func setFields(_ fields: [String: ExportFieldSelection], for record: Record) {
        var updated = selection
        if let index = updated.firstIndex(where: { $0.id == record.id }) {
            if fields.isEmpty { updated.remove(at: index) }
            else { updated[index].fields = fields }
        } else if !fields.isEmpty {
            updated.append(ExportRecordSelection(id: record.id, fields: fields))
        }
        chosen[format] = updated
        problem = nil
    }

    private func valueText(_ value: JSONValue) -> String {
        if value == .null { return VeraText.text("Unknown") }
        if let text = value.scalarText { return text.isEmpty ? VeraText.text("Empty text") : text }
        if let object = value.object { return VeraText.format("Object with %lld fields", object.count) }
        return VeraText.format("List with %lld items", value.array?.count ?? 0)
    }

    private func review() {
        do {
            preview = try SelectiveExport.data(from: request.profile, selection: selection, format: format)
            problem = nil
        } catch { problem = error.localizedDescription }
    }
}


private struct ExportJSONPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            text.textContainerInset = NSSize(width: 10, height: 10)
            text.setAccessibilityLabel(VeraText.text("Exported JSON"))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let json = String(decoding: data, as: UTF8.self)
        if text.string != json { text.string = json }
    }
}
