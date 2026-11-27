import SwiftUI
import VeraDataCore

struct PhoneExportView: View {
    let vault: Vault
    let export: ([Profile.ID: Set<Record.ID>], Set<MobileTransfer.EvidencePick>) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selection: [Profile.ID: Set<Record.ID>] = [:]
    @ViewState private var evidence: Set<MobileTransfer.EvidencePick> = []

    private var availableEvidence: Set<MobileTransfer.EvidencePick> {
        Set(vault.profiles.flatMap { profile in
            profile.records.filter { selection[profile.id]?.contains($0.id) == true }.flatMap { record in
                documents(for: record).map { pick($0, record: record, profile: profile) }
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export for iPhone").font(.title2.weight(.semibold))
            Text("Every field in each checked record is included. Evidence is optional and includes the original documents.")
                .foregroundStyle(.secondary)
            if !availableEvidence.isEmpty {
                Toggle("Select All Evidence for Checked Records", isOn: Binding(
                    get: { availableEvidence.isSubset(of: evidence) },
                    set: { enabled in
                        if enabled { evidence.formUnion(availableEvidence) }
                        else { evidence.subtract(availableEvidence) }
                    }
                ))
            }
            List {
                ForEach(vault.profiles.filter { !$0.records.isEmpty }) { profile in
                    Section {
                        Toggle("Select All Records", isOn: Binding(
                            get: { selection[profile.id]?.count == profile.records.count },
                            set: { enabled in
                                selection[profile.id] = enabled ? Set(profile.records.map(\.id)) : nil
                                evidence.formIntersection(availableEvidence)
                            }
                        ))
                        ForEach(profile.records) { record in
                            recordSelection(record, profile: profile)
                        }
                    } header: { Text(profile.name) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    let selected = selection
                    let attachments = evidence.intersection(availableEvidence)
                    dismiss()
                    Task { @MainActor in export(selected, attachments) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!selection.values.contains(where: { !$0.isEmpty }))
            }
        }
        .padding(24).frame(width: 570, height: 525)
    }

    @ViewBuilder
    private func recordSelection(_ record: Record, profile: Profile) -> some View {
        Toggle(isOn: Binding(
            get: { selection[profile.id]?.contains(record.id) == true },
            set: { selected in
                if selected { selection[profile.id, default: []].insert(record.id) }
                else {
                    selection[profile.id]?.remove(record.id)
                    evidence.formIntersection(availableEvidence)
                }
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.label)
                Text(record.subtitle.isEmpty ? record.kind.localizedTitle : record.subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if selection[profile.id]?.contains(record.id) == true {
            ForEach(documents(for: record), id: \.digest) { document in
                let choice = pick(document, record: record, profile: profile)
                Toggle(isOn: Binding(
                    get: { evidence.contains(choice) },
                    set: { enabled in
                        if enabled { evidence.insert(choice) } else { evidence.remove(choice) }
                    }
                )) {
                    Label { Text(document.name) } icon: { Image(systemName: "doc") }
                }
                .padding(.leading, 22)
            }
        }
    }

    private func documents(for record: Record) -> [EvidenceDocument] {
        var seen: Set<String> = []
        return record.evidence.map(\.document).filter { seen.insert($0.digest).inserted }
    }

    private func pick(_ document: EvidenceDocument, record: Record, profile: Profile) -> MobileTransfer.EvidencePick {
        .init(profileID: profile.id, recordID: record.id, digest: document.digest)
    }
}
