import SwiftUI
import VeraDataCore

struct PhoneExportView: View {
    let vault: Vault
    let export: ([Profile.ID: Set<Record.ID>]) -> Void
    @Environment(\.dismiss) private var dismiss
    @ViewState private var selection: [Profile.ID: Set<Record.ID>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export for iPhone").font(.title2.weight(.semibold))
            Text("Choose the records to copy to your iPhone. Every field in each checked record is included in the readable JSON file.")
                .foregroundStyle(.secondary)
            List {
                ForEach(vault.profiles.filter { !$0.records.isEmpty }) { profile in
                    Section {
                        Toggle("Select All Records", isOn: Binding(
                            get: { selection[profile.id]?.count == profile.records.count },
                            set: { selection[profile.id] = $0 ? Set(profile.records.map(\.id)) : nil }
                        ))
                        ForEach(profile.records) { record in
                            Toggle(isOn: Binding(
                                get: { selection[profile.id]?.contains(record.id) == true },
                                set: { selected in
                                    if selected { selection[profile.id, default: []].insert(record.id) }
                                    else { selection[profile.id]?.remove(record.id) }
                                }
                            )) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(record.label)
                                    Text(record.subtitle.isEmpty ? record.kind.localizedTitle : record.subtitle)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text(profile.name) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    dismiss()
                    let selected = selection
                    Task { @MainActor in export(selected) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!selection.values.contains(where: { !$0.isEmpty }))
            }
        }
        .padding(24).frame(width: 530, height: 495)
    }

}
