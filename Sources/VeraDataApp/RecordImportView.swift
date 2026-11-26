import SwiftUI
import VeraDataCore

struct ImportRequest: Identifiable {
    let id = UUID()
    let fileName: String
    let data: RecordImport
}

struct RecordImportView: View {
    let request: ImportRequest
    let profiles: [Profile]
    let save: (RecordImportReview, [Record.ID: RecordImportReview.Decision], String?) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var sourceID: Profile.ID
    @ViewState private var target: Destination
    @ViewState private var newName: String
    @ViewState private var review: RecordImportReview
    @ViewState private var decisions: [Record.ID: RecordImportReview.Decision]
    @ViewState private var recordID: Record.ID?
    @ViewState private var problem: String?

    private enum Destination: Hashable {
        case existing(Profile.ID)
        case new
    }
    private enum Action: Hashable {
        case skip
        case add
        case update(Record.ID)
    }

    init(request: ImportRequest, profiles: [Profile], activeID: Profile.ID,
         save: @escaping (RecordImportReview, [Record.ID: RecordImportReview.Decision], String?) throws -> Void) {
        self.request = request
        self.profiles = profiles
        self.save = save
        let source = request.data.profiles[0]
        let matched = profiles.first { $0.id == source.id }
        let existing = matched ?? (request.data.profiles.count == 1 ? profiles.first { $0.id == activeID } : nil)
        let initial = RecordImportReview(source: source, destination: existing ?? Profile(name: source.name))
        _sourceID = State(initialValue: source.id)
        _target = State(initialValue: existing.map { .existing($0.id) } ?? .new)
        _newName = State(initialValue: source.name)
        _review = State(initialValue: initial)
        _recordID = State(initialValue: source.records.first?.id)
        _decisions = State(initialValue: Self.defaultDecisions(initial))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review Record Import").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(request.fileName).foregroundStyle(.secondary).lineLimit(1)

            HStack(alignment: .top, spacing: 14) {
                if request.data.profiles.count > 1 {
                    Picker("Source Profile", selection: Binding(get: { sourceID }, set: changeSource)) {
                        ForEach(request.data.profiles) { Text($0.name).tag($0.id) }
                    }
                }
                Picker("Import Into", selection: Binding(get: { target }, set: changeTarget)) {
                    ForEach(profiles) { Text($0.name).tag(Destination.existing($0.id)) }
                    Text("New Profile…").tag(Destination.new)
                }
                if target == .new {
                    TextField("New profile name", text: $newName)
                }
            }
            Text("Possible matches start as Skip. Review any field you want to update.")
                .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                List(review.source.records, selection: $recordID) { record in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(record.label).lineLimit(1)
                        Text(actionTitle(decisions[record.id, default: .skip]))
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(record.id)
                }
                .listStyle(.sidebar).frame(width: 228)
                Divider()
                if let record = review.source.records.first(where: { $0.id == recordID }) {
                    recordReview(record).id(record.id)
                }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
            HStack {
                Text(VeraText.format("%lld to add · %lld to update", addCount, updateCount)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply Import", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(addCount + updateCount == 0 || (target == .new && newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(24).frame(width: 790, height: 580)
    }

    private var addCount: Int { decisions.values.filter { $0 == .add }.count }
    private var updateCount: Int { decisions.values.filter { if case .update = $0 { return true }; return false }.count }

    private static func defaultDecisions(_ review: RecordImportReview) -> [Record.ID: RecordImportReview.Decision] {
        Dictionary(uniqueKeysWithValues: review.source.records.map { ($0.id, review.initialDecision(for: $0)) })
    }

    private func changeSource(_ id: Profile.ID) {
        guard let source = request.data.profiles.first(where: { $0.id == id }) else { return }
        sourceID = id
        newName = source.name
        target = profiles.first(where: { $0.id == id }).map { .existing($0.id) } ?? .new
        resetReview(source: source)
    }

    private func changeTarget(_ newTarget: Destination) {
        target = newTarget
        resetReview(source: review.source)
    }

    private func resetReview(source: Profile) {
        let destination: Profile
        switch target {
        case .existing(let id):
            guard let existing = profiles.first(where: { $0.id == id }) else { return }
            destination = existing
        case .new: destination = Profile(name: source.name)
        }
        let newReview = RecordImportReview(source: source, destination: destination)
        review = newReview
        decisions = Self.defaultDecisions(newReview)
        if !source.records.contains(where: { $0.id == recordID }) { recordID = source.records.first?.id }
        problem = nil
    }

    private func actionTitle(_ decision: RecordImportReview.Decision) -> String {
        switch decision {
        case .skip: return VeraText.text("Skip")
        case .add: return VeraText.text("Add Record")
        case .update: return VeraText.text("Update Fields")
        }
    }

    private func recordReview(_ record: Record) -> some View {
        let decision = decisions[record.id, default: .skip]
        let possible = review.possibleMatches(for: record)
        let candidates = review.destination.records.filter { $0.kind == record.kind }
        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(record.label).font(.headline)
                Picker("Action", selection: Binding(
                    get: {
                        switch decision {
                        case .skip: return Action.skip
                        case .add: return Action.add
                        case .update(let id, _): return Action.update(id)
                        }
                    },
                    set: { action in
                        problem = nil
                        switch action {
                        case .skip: decisions[record.id] = .skip
                        case .add: decisions[record.id] = .add
                        case .update(let id):
                            guard let existing = candidates.first(where: { $0.id == id }) else { return }
                            let fresh = record.fields.filter { key, value in existing.fields[key] == nil && value != .null }
                            decisions[record.id] = .update(id, fields: Set(fresh.keys))
                        }
                    }
                )) {
                    Text("Skip").tag(Action.skip)
                    Text("Add Record").tag(Action.add)
                    if !possible.isEmpty {
                        Section("Possible Matches") {
                            ForEach(possible, id: \.self) { id in
                                if let match = candidates.first(where: { $0.id == id }) {
                                    Text(matchLabel(match)).tag(Action.update(id))
                                }
                            }
                        }
                    }
                    let others = candidates.filter { !possible.contains($0.id) }
                    if !others.isEmpty {
                        Section("Other Records of This Type") {
                            ForEach(others) { Text(matchLabel($0)).tag(Action.update($0.id)) }
                        }
                    }
                }
                if case .update(let targetID, let keys) = decision,
                   let existing = candidates.first(where: { $0.id == targetID }) {
                    Text("Only checked fields change. Unchecked values and fields missing from the import stay as they are.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(record.orderedKeys, id: \.self) { key in
                        Toggle(isOn: Binding(get: { keys.contains(key) }, set: { selected in
                            var updated = keys
                            if selected { updated.insert(key) } else { updated.remove(key) }
                            decisions[record.id] = .update(targetID, fields: updated)
                            problem = nil
                        })) {
                            field(record.fieldDefinition(key).localizedLabel, incoming: record.fields[key],
                                  existing: existing.fields[key], comparing: true)
                        }
                        .disabled(existing.fields[key] == record.fields[key])
                    }
                } else {
                    ForEach(record.orderedKeys, id: \.self) { key in
                        field(record.fieldDefinition(key).localizedLabel, incoming: record.fields[key])
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func matchLabel(_ record: Record) -> String {
        let title = record.subtitle.isEmpty ? record.label : "\(record.label) · \(record.subtitle)"
        return VeraText.format("Update %@", title)
    }

    private func field(_ label: String, incoming: JSONValue?, existing: JSONValue? = nil,
                       comparing: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.body.weight(.medium))
            if comparing {
                Text("Existing").font(.caption).foregroundStyle(.secondary)
                Text(description(existing))
                Text("Incoming").font(.caption).foregroundStyle(.secondary)
            }
            Text(description(incoming))
        }
        .padding(.bottom, 6)
    }

    private func description(_ value: JSONValue?) -> String {
        guard let value else { return VeraText.text("Omitted") }
        if value == .null { return VeraText.text("Unknown") }
        if let text = value.string { return text.isEmpty ? VeraText.text("Empty text") : text }
        return (try? value.rendered()) ?? ""
    }

    private func apply() {
        do {
            let name = target == .new ? newName.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            try save(review, decisions, name)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}
