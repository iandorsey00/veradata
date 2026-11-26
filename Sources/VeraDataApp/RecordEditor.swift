import SwiftUI
import VeraDataCore

struct RecordDraft: Identifiable, Equatable {
    let id: String
    var kind: RecordKind
    var label: String
    let isNew: Bool
    var known: [String: KnownDraft]
    var custom: [CustomDraft]
    var shortcuts: [String: String]

    init(record: Record? = nil) {
        id = record?.id ?? UUID().uuidString.lowercased()
        kind = record?.kind ?? .contact
        label = record?.label ?? ""
        isNew = record == nil
        let fields = record?.fields ?? [:]
        known = Dictionary(uniqueKeysWithValues: kind.fields.map {
            ($0.key, KnownDraft(value: fields[$0.key]))
        })
        let knownKeys = Set(kind.fields.map(\.key))
        custom = fields.keys.sorted().filter { !knownKeys.contains($0) }.map { key in
            CustomDraft(key: key, value: fields[key]!, shortcuts: Self.shortcuts(for: key, in: record))
        }
        shortcuts = Dictionary(uniqueKeysWithValues: kind.fields.map {
            ($0.key, Self.shortcuts(for: $0.key, in: record))
        })
    }

    private static func shortcuts(for key: String, in record: Record?) -> String {
        (record?.aliases ?? [:]).filter { $0.value == key }.keys.sorted().joined(separator: " ")
    }

    func makeRecord() throws -> Record {
        var fields: [String: JSONValue] = [:]
        var aliases: [String: String] = [:]
        func addAliases(_ text: String, for key: String) throws {
            for alias in text.split(whereSeparator: \.isWhitespace).map(String.init) {
                guard aliases[alias] == nil else { throw DataIssue("Use each shortcut only once in this record.") }
                aliases[alias] = key
            }
        }
        for field in kind.fields {
            if let value = known[field.key]?.value(for: field.style) {
                fields[field.key] = value
                try addAliases(shortcuts[field.key, default: ""], for: field.key)
            }
        }
        for item in custom {
            let key = item.key
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw DataIssue("Give each custom field a name.")
            }
            guard fields[key] == nil, !kind.fields.contains(where: { $0.key == key }) else {
                throw DataIssue("Use a different name for each custom field.")
            }
            do {
                fields[key] = item.mode == .text ? .string(item.text) : try JSONValue.parse(Data(item.text.utf8))
            } catch let error as DataIssue {
                throw DataIssue("Custom field “\(key)”: \(error.message)")
            }
            try addAliases(item.shortcuts, for: key)
        }
        let record = Record(id: id, kind: kind, label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                            fields: fields, aliases: aliases)
        try record.validate()
        return record
    }
}

enum FieldPresence: String, CaseIterable, Identifiable {
    case absent = "Omitted"
    case value = "Value"
    case unknown = "Unknown"
    var id: String { rawValue }
}

struct KnownDraft: Equatable {
    var presence: FieldPresence
    var text: String
    private let original: JSONValue?
    private let initialText: String

    init(value: JSONValue? = nil) {
        original = value
        presence = value == nil ? .absent : (value == .null ? .unknown : .value)
        initialText = value?.string ?? value?.array?.compactMap(\.string).joined(separator: "\n") ?? ""
        text = initialText
    }

    func value(for style: FieldDefinition.Style) -> JSONValue? {
        switch presence {
        case .absent: return nil
        case .unknown: return .null
        case .value:
            if style == .list {
                if text == initialText, let original, original.array != nil { return original }
                return .array(text.isEmpty ? [] : text.components(separatedBy: .newlines).map(JSONValue.string))
            }
            return .string(text)
        }
    }
}

struct CustomDraft: Identifiable, Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case text = "Text"
        case json = "JSON"
        var id: String { rawValue }
    }

    let id = UUID()
    var key = ""
    var mode: Mode = .text
    var text = ""
    var shortcuts = ""

    init() {}

    init(key: String, value: JSONValue, shortcuts: String) {
        self.key = key
        self.shortcuts = shortcuts
        if let string = value.string { text = string }
        else {
            mode = .json
            text = (try? value.rendered()) ?? ""
        }
    }
}

struct RecordEditor: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused: Bool
    @ViewState private var draft: RecordDraft
    @ViewState private var issue: String?
    @ViewState private var discardChanges: Bool = false
    let initial: RecordDraft
    let save: (Record) throws -> Void

    init(initial: RecordDraft, save: @escaping (Record) throws -> Void) {
        self.initial = initial
        self.save = save
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(VeraText.text(draft.isNew ? "New Record" : "Edit Record")).font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 24).padding(.vertical, 18)

            if let issue {
                Label(issue, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.primary)
                    .padding(.horizontal, 24).padding(.bottom, 12)
                    .accessibilityIdentifier("recordValidationError")
            }
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if draft.isNew {
                        Picker("Record type", selection: $draft.kind) {
                            ForEach(RecordKind.allCases) { kind in Text(kind.localizedTitle).tag(kind) }
                        }.frame(maxWidth: 300, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Record name").font(.subheadline.weight(.medium))
                        TextField("Name shown in search and the sidebar", text: $draft.label)
                            .labelsHidden().accessibilityLabel("Record name").focused($nameFocused)
                    }
                    ForEach(draft.kind.fields, id: \.key) { field in
                        KnownFieldEditor(field: field, draft: Binding(
                            get: { draft.known[field.key] ?? KnownDraft() },
                            set: { draft.known[field.key] = $0 }
                        ))
                    }
                    if draft.kind == .address, AddressCoordinates.fieldKeys.contains(where: { key in
                        !draft.custom.contains(where: { $0.key == key })
                    }) {
                        Button {
                            for key in AddressCoordinates.fieldKeys where !draft.custom.contains(where: { $0.key == key }) {
                                draft.custom.append(CustomDraft(key: key, value: .string(""), shortcuts: ""))
                            }
                        } label: {
                            Label("Add Coordinates", systemImage: "location")
                        }
                        .help("Enter decimal latitude and longitude for this address")
                    }
                    ForEach($draft.custom) { $item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("Field name", text: $item.key)
                                Picker("Value type", selection: $item.mode) {
                                    ForEach(CustomDraft.Mode.allCases) { mode in Text(VeraText.text(mode.rawValue)).tag(mode) }
                                }.labelsHidden().accessibilityLabel("Value type").fixedSize()
                                Button {
                                    draft.custom.removeAll { $0.id == item.id }
                                } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel("Remove custom field")
                            }
                            if draft.kind == .address, item.mode == .text,
                               AddressCoordinates.fieldKeys.contains(item.key) {
                                TextField("Decimal degrees", text: $item.text)
                                    .accessibilityLabel(VeraText.text(item.key == "latitude" ? "Latitude" : "Longitude"))
                            } else {
                                TextEditor(text: $item.text)
                                    .font(item.mode == .json ? .system(.body, design: .monospaced) : .body)
                                    .frame(minHeight: 45, idealHeight: 62)
                                    .padding(3)
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                                    .accessibilityLabel(item.key.isEmpty ? "Custom field value" : "\(item.key) value")
                            }
                        }
                    }
                    Button {
                        draft.custom.append(CustomDraft())
                    } label: {
                        Label("Add Custom Field", systemImage: "plus")
                    }
                    shortcuts
                }
                .padding(24)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: saveDraft).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 560, height: 570)
        .defaultFocus($nameFocused, true)
        .confirmationDialog("Discard your edits?", isPresented: $discardChanges, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .interactiveDismissDisabled()
    }

    private var shortcuts: some View {
        DisclosureGroup("Search Shortcuts") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enter shortcuts such as ;ph for fields already present in this record.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(draft.kind.fields.filter { draft.known[$0.key]?.presence != nil && draft.known[$0.key]?.presence != .absent },
                        id: \.key) { field in
                    TextField(field.localizedLabel, text: Binding(
                        get: { draft.shortcuts[field.key, default: ""] },
                        set: { draft.shortcuts[field.key] = $0 }
                    ))
                }
                ForEach($draft.custom) { $item in
                    TextField(item.key.isEmpty ? "Custom field" : item.key, text: $item.shortcuts)
                }
            }
            .padding(.top, 9)
        }
    }

    private func cancel() {
        if draft == initial { dismiss() }
        else { discardChanges = true }
    }

    private func saveDraft() {
        do {
            let record = try draft.makeRecord()
            try save(record)
            dismiss()
        } catch { issue = error.localizedDescription }
    }
}

private struct KnownFieldEditor: View {
    let field: FieldDefinition
    @Binding var draft: KnownDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.localizedLabel).font(.subheadline.weight(.medium))
                Spacer()
                Picker("\(field.localizedLabel) state", selection: $draft.presence) {
                    ForEach(FieldPresence.allCases) { state in Text(VeraText.text(state.rawValue)).tag(state) }
                }.labelsHidden().accessibilityLabel("\(field.localizedLabel) state").fixedSize()
            }
            if draft.presence != .unknown {
                switch field.style {
                case .choice(let choices):
                    Picker(field.localizedLabel, selection: Binding(
                        get: { draft.text }, set: { draft.text = $0; draft.presence = .value }
                    )) {
                        Text(VeraText.text(draft.presence == .absent ? "Choose…" : "Empty text")).tag("")
                        ForEach(choices, id: \.self) { option in Text(VeraText.text(option)).tag(option) }
                    }.labelsHidden().accessibilityLabel(field.localizedLabel)
                case .multiline, .list:
                    TextEditor(text: entry)
                        .font(.body).frame(minHeight: 46, idealHeight: 64).padding(3)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                        .accessibilityLabel(field.localizedLabel)
                    if field.style == .list {
                        Text("One item per line.").font(.caption).foregroundStyle(.secondary)
                    }
                case .text, .phone, .date:
                    TextField(field.style == .date ? VeraText.text("YYYY, YYYY-MM, or YYYY-MM-DD") : "", text: entry)
                        .labelsHidden().accessibilityLabel(field.localizedLabel)
                }
            }
        }
    }

    private var entry: Binding<String> {
        Binding(get: { draft.text }, set: { draft.text = $0; draft.presence = .value })
    }
}
