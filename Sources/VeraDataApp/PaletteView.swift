import AppKit
import Combine
import SwiftUI
import VeraDataCore

struct PaletteView: View {
    @ObservedObject var state: AppState
    @ViewState var scope: String?
    @ViewState private var query: String = ""
    @ViewState private var selectedID: String?
    @ViewState private var formatID: String?
    @ViewState private var focusRequest: Int = 0
    @ViewState private var now: Date = .now
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(state: AppState, initialScope: String?) {
        self.state = state
        _scope = State(initialValue: initialScope)
    }

    private var results: [SearchResult] { state.index.search(query, recordID: scope, now: now) }

    private var scopedRecord: VeraDataCore.Record? { state.profile.records.first { $0.id == scope } }

    var body: some View {
        let results = results
        let selected = results.first { $0.id == selectedID } ?? results.first
        let format = selected.flatMap(activeFormat)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass").font(.system(size: 18)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                PaletteInput(
                    text: $query, placeholder: VeraText.text(scope == nil ? "Search records or fields" : "Search fields in this record"),
                    move: { move($0, in: results) }, accept: { activate(selected) },
                    cancel: { state.closeSearch() }, focusRequest: focusRequest
                )
                .frame(height: 28)
                if !query.isEmpty {
                    Button {
                        query = ""
                        selectedID = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless).accessibilityLabel("Clear search").help("Clear search")
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 10)

            HStack(spacing: 10) {
                if let record = scopedRecord {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.label).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if !record.subtitle.isEmpty, record.subtitle != record.kind.localizedTitle {
                            Text(record.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Spacer()
                    scopeNavigation(from: record.id)
                    Button("Search All") { setScope(nil) }
                } else {
                    Text(state.profile.name).font(.subheadline.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text("↑ ↓ Navigate").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 9)
            Divider()

            if results.isEmpty {
                VStack(spacing: 6) {
                    Text(VeraText.text(query.isEmpty ? "No saved values here" : "No matches")).font(.headline)
                    Text(VeraText.text(query.isEmpty ? "Try “today” or “timestamp”, or add a record to this profile."
                         : "Try a different field name or search across this profile."))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(results) { result in
                                row(result, selected: result.id == selected?.id).id(result.id)
                            }
                        }.padding(.horizontal, 12).padding(.vertical, 7)
                    }
                    .onChange(of: selected?.id) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            footer(selected, format: format)
        }
        .frame(minWidth: 590, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: query) { _, _ in selectedID = nil; formatID = nil; now = .now }
        .onReceive(clock) { date in
            if results.contains(where: { $0.currentValue != nil }) { now = date }
        }
        .onExitCommand { state.closeSearch() }
    }

    private func row(_ result: SearchResult, selected: Bool) -> some View {
        Button {
            selectedID = result.id
            formatID = nil
        } label: {
            HStack(spacing: 12) {
                Image(systemName: result.currentValue != nil ? "clock" : (result.field == nil ? "square.text.square" : "text.alignleft"))
                    .frame(width: 21).foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title).font(.body.weight(selected ? .semibold : .regular)).lineLimit(1)
                    if !result.subtitle.isEmpty {
                        Text(result.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 10)
                if let preview = (selected ? activeFormat(result) : result.preferredFormat)?.text ?? result.field?.display {
                    Text(preview)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: 240, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background {
                if selected { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.16)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func footer(_ result: SearchResult?, format: Representation?) -> some View {
        HStack(spacing: 9) {
            if let result, result.field != nil || result.currentValue != nil {
                let formats = result.representations
                if formats.count > 1 {
                    Picker("Format", selection: Binding(
                        get: { format?.id ?? "" }, set: { formatID = $0 }
                    )) {
                        ForEach(formats) { option in Text(option.localizedLabel).tag(option.id) }
                    }.fixedSize()
                }
                Spacer()
                if format != nil {
                    Button("Copy") { activate(result) }.buttonStyle(.borderedProminent).help("Copy (Return)")
                } else {
                    Text("No value to copy").font(.callout).foregroundStyle(.secondary)
                }
            } else if let record = result?.record {
                Button("View Record") { state.openRecordFromSearch(record.id) }
                Menu("Copy Record") {
                    Button("As Text") {
                        if state.copy(record.copyableSummary, label: "record") { state.closeSearch() }
                    }
                }
                Spacer()
                Button("Search This Record") { setScope(record.id) }.buttonStyle(.borderedProminent)
            } else {
                Spacer()
                Button("Close") { state.closeSearch() }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
    }

    private func move(_ direction: Int, in results: [SearchResult]) {
        guard let first = results.first else { return }
        let active = results.firstIndex { $0.id == (selectedID ?? first.id) } ?? 0
        selectedID = results[max(0, min(results.count - 1, active + direction))].id
        formatID = nil
    }

    private func setScope(_ id: String?) {
        state.pin(id)
        scope = id
        selectedID = nil
        formatID = nil
        query = ""
        focusRequest += 1
    }

    private func scopeNavigation(from id: String) -> some View {
        HStack(spacing: 5) {
            scopeButton("Previous record", icon: "chevron.left", direction: -1, from: id)
            scopeButton("Next record", icon: "chevron.right", direction: 1, from: id)
        }
    }

    private func scopeButton(_ label: String, icon: String, direction: Int, from id: String) -> some View {
        let target = state.stepTarget(direction, from: id)
        return Button {
            if let target { setScope(target.id) }
        } label: {
            Image(systemName: icon).frame(minWidth: 16)
        }
        .disabled(target == nil).accessibilityLabel(VeraText.text(label)).help(VeraText.text(label))
    }

    private func activeFormat(_ result: SearchResult) -> Representation? {
        let formats = result.representations
        return formats.first { $0.id == formatID } ?? result.preferredFormat ?? formats.first
    }

    private func activate(_ result: SearchResult?) {
        guard let result else { return }
        if let record = result.record, result.field == nil {
            setScope(record.id)
            return
        }
        let selected = activeFormat(result)
        let fresh = result.currentValue?.representations(at: .now).first { $0.id == selected?.id }
        if let format = fresh ?? selected, state.copy(format.text, label: result.title) {
            state.closeSearch()
        }
    }
}

private struct PaletteInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let move: (Int) -> Void
    let accept: () -> Void
    let cancel: () -> Void
    let focusRequest: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = SearchField()
        field.isBordered = false
        field.drawsBackground = false
        field.font = NSFont.systemFont(ofSize: 18)
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.setAccessibilityLabel(VeraText.text("Search"))
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if context.coordinator.input.focusRequest != focusRequest {
            DispatchQueue.main.async { [weak nsView] in
                if let nsView { nsView.window?.makeFirstResponder(nsView) }
            }
        }
        context.coordinator.input = self
        nsView.placeholderString = placeholder
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var input: PaletteInput
        init(_ input: PaletteInput) { self.input = input }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            input.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)): input.move(-1)
            case #selector(NSResponder.moveDown(_:)): input.move(1)
            case #selector(NSResponder.insertNewline(_:)): input.accept()
            case #selector(NSResponder.cancelOperation(_:)): input.cancel()
            default: return false
            }
            return true
        }
    }

    private final class SearchField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }
}
