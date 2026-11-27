import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import VeraDataCore

struct EvidenceView: View {
    let record: Record
    let files: EvidenceFileStore
    let save: ([EvidenceMark], VaultAttachment?) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var source: EvidencePreview?
    @ViewState private var editing: EvidenceMark?
    @ViewState private var selected: Set<String> = []
    @ViewState private var page = 0
    @ViewState private var region: EvidenceRegion?
    @ViewState private var problem: String?
    @ViewState private var choosingFile = false
    @ViewState private var zoom = 1.0

    init(record: Record, files: EvidenceFileStore, save: @escaping ([EvidenceMark], VaultAttachment?) throws -> Void) {
        self.record = record
        self.files = files
        self.save = save
    }

    private var keys: [String] { record.orderedKeys.filter { EvidenceMark.canCheck(EvidenceMark.reviewValue(in: record, key: $0)) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Evidence").font(.title2.bold())
                    Text(record.label).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Attach PDF or Image…") { choosingFile = true }
            }
            if !record.evidence.isEmpty {
                Menu("Saved Evidence") {
                    ForEach(record.evidence) { mark in
                        Button { open(mark) } label: {
                            Text("\(mark.document.name) · \(fieldNames(mark))")
                        }
                    }
                }
            }
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            if let source {
                HStack(alignment: .top, spacing: 16) {
                    documentView(source)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    fieldPicker.frame(width: 235)
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Attach a document and mark the area that supports your fields.")
                    ForEach(record.evidence) { mark in
                        HStack {
                            Button { open(mark) } label: { Text(mark.document.name) }
                            Text(fieldNames(mark)).foregroundStyle(.secondary).lineLimit(2)
                            Spacer()
                        }
                    }
                    Spacer()
                }
            }
            Divider()
            HStack {
                if let editing {
                    Button("Remove Mark", role: .destructive) {
                        perform { try save(record.evidence.filter { $0.id != editing.id }, nil) }
                    }
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if source != nil {
                    Button("Mark as Checked", action: confirm)
                        .buttonStyle(.borderedProminent)
                        .disabled(selected.isEmpty || region == nil)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 900, minHeight: 510, idealHeight: 650)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.pdf, .image]) { result in
            perform {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let bytes = try EvidenceFileStore.readInput(url)
                let kind: EvidenceDocument.Kind = url.pathExtension.lowercased() == "pdf" ? .pdf : .image
                let document = EvidenceFileStore.document(for: bytes, name: url.lastPathComponent, kind: kind)
                source = try EvidencePreview(document: document, bytes: bytes, page: 0)
                editing = nil
                selected = []
                region = nil
                page = 0
                zoom = 1
            }
        }
    }

    private func documentView(_ source: EvidencePreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(source.document.name).font(.headline).lineLimit(1)
                Spacer()
                if editing != nil {
                    Button("Mark Another Area") {
                        editing = nil
                        selected = []
                        region = nil
                    }
                }
            }
            if let editing {
                Text(VeraText.format("Last checked %@", editing.checkedAt.formatted(date: .abbreviated, time: .omitted)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if source.pageCount > 1 {
                    Button { changePage(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Previous page").disabled(page == 0)
                    Text(VeraText.format("Page %lld of %lld", page + 1, source.pageCount)).monospacedDigit()
                    Button { changePage(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("Next page").disabled(page + 1 >= source.pageCount)
                }
                Spacer()
                Button { zoom /= 1.4 } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("Zoom out").disabled(zoom <= 1)
                Button { zoom *= 1.4 } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Zoom in").disabled(zoom >= 3.8)
            }
            GeometryReader { space in
                let width = max(1, min(space.size.width - 14, (space.size.height - 14) * source.aspect)) * zoom
                ScrollView([.horizontal, .vertical]) {
                    EvidenceCanvas(image: source.image, region: $region)
                        .frame(width: width, height: width / source.aspect)
                        .padding(7)
                        .frame(minWidth: space.size.width, minHeight: space.size.height)
                }
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Text("Drag to draw a box around the evidence.").foregroundStyle(.secondary)
                Spacer()
                Menu("Mark Area") {
                    Button("Whole Page") { region = EvidenceRegion(x: 0, y: 0, width: 1, height: 1) }
                    Button("Clear Mark") { region = nil }.disabled(region == nil)
                }
            }.font(.callout)
        }
    }

    private var fieldPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fields supported by this area").font(.headline)
            if record.kind == .address {
                Button("Select Address Fields") {
                    selected.formUnion(keys.filter { ["line1", "line2", "city", "region", "postalCode"].contains($0) })
                }
                Text("Uncheck anything the document doesn’t show.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(keys, id: \.self) { key in
                        Toggle(isOn: Binding(get: { selected.contains(key) }, set: { included in
                            if included { selected.insert(key) } else { selected.remove(key) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.fieldDefinition(key).localizedLabel).fontWeight(.medium)
                                if let value = EvidenceMark.reviewValue(in: record, key: key) {
                                    Text(value.scalarText ?? ((try? value.rendered()) ?? ""))
                                        .foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                if let editing, editing.fields[key] != nil, !editing.matches(key, in: record) {
                                    Text("Needs review").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func fieldNames(_ mark: EvidenceMark) -> String {
        mark.fields.keys.sorted().map { record.fieldDefinition($0).localizedLabel }.joined(separator: ", ")
    }

    private func open(_ mark: EvidenceMark) {
        editing = mark
        source = nil
        perform {
            source = try EvidencePreview(document: mark.document, bytes: files.read(mark.document), page: mark.page)
            page = mark.page
            region = mark.region
            selected = Set(mark.fields.keys).intersection(keys)
            zoom = 1
        }
    }

    private func changePage(_ step: Int) {
        guard let source else { return }
        perform {
            let next = page + step
            self.source = try EvidencePreview(document: source.document, bytes: source.bytes, page: next)
            page = next
            region = editing?.page == next ? editing?.region : nil
        }
    }

    private func confirm() {
        guard let source, let region else { return }
        perform {
            let mark = try EvidenceMark(id: editing?.id ?? UUID(), document: source.document, page: page,
                                        region: region, record: record, keys: selected)
            var marks = record.evidence
            if let index = marks.firstIndex(where: { $0.id == mark.id }) { marks[index] = mark }
            else { marks.append(mark) }
            try save(marks, VaultAttachment(document: source.document, bytes: source.bytes))
        }
    }

    private func perform(_ work: () throws -> Void) {
        problem = nil
        do { try work() }
        catch { problem = error.localizedDescription }
    }
}

private struct EvidencePreview {
    let document: EvidenceDocument
    let bytes: Data
    let image: NSImage
    let pageCount: Int
    var aspect: CGFloat { image.size.width / image.size.height }

    init(document: EvidenceDocument, bytes: Data, page index: Int) throws {
        self.document = document
        self.bytes = bytes
        switch document.kind {
        case .pdf:
            guard let pdf = PDFDocument(data: bytes), !pdf.isLocked, let page = pdf.page(at: index) else {
                throw DataIssue("Choose a readable, unlocked PDF.")
            }
            pageCount = pdf.pageCount
            let bounds = page.bounds(for: .cropBox)
            let scale = 2000 / max(bounds.width, bounds.height)
            guard scale.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw DataIssue("The PDF page could not be displayed.")
            }
            image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
        case .image:
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2200,
            ]
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw DataIssue("Choose a readable image.")
            }
            pageCount = 1
            image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
        }
    }
}

private struct EvidenceCanvas: View {
    let image: NSImage
    @Binding var region: EvidenceRegion?
    @ViewState private var draft: EvidenceRegion? = nil

    var body: some View {
        GeometryReader { geometry in
            Image(nsImage: image).resizable()
                .overlay(alignment: .topLeading) {
                    if let box = draft ?? region {
                        Rectangle().strokeBorder(.red, lineWidth: 2)
                            .frame(width: box.width * geometry.size.width, height: box.height * geometry.size.height)
                            .offset(x: box.x * geometry.size.width, y: box.y * geometry.size.height)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { draft = box($0, size: geometry.size) }
                    .onEnded { value in
                        if let box = box(value, size: geometry.size) { region = box }
                        draft = nil
                    })
                .accessibilityLabel("Evidence document page")
        }
    }

    private func box(_ drag: DragGesture.Value, size: CGSize) -> EvidenceRegion? {
        func clamp(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }
        let x1 = clamp(drag.startLocation.x / size.width)
        let y1 = clamp(drag.startLocation.y / size.height)
        let x2 = clamp(drag.location.x / size.width)
        let y2 = clamp(drag.location.y / size.height)
        guard x1 != x2, y1 != y2 else { return nil }
        return EvidenceRegion(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
    }
}
