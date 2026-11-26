import SwiftUI
import VeraDataCore

struct RevisionHistoryView: View {
    let store: VaultStateStore
    let restore: (String, String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @ViewState private var revisions: [VaultRevision] = []
    @ViewState private var selected: String?
    @ViewState private var preview: StateDifference?
    @ViewState private var token = ""
    @ViewState private var problem: String?
    @ViewState private var confirming = false

    private var revision: VaultRevision? { revisions.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Revision History").font(.title2.weight(.semibold))
            Text("Each revision can restore the vault and presets as they were before an edit. Deleted values may remain in history.")
                .foregroundStyle(.secondary)
            HStack(spacing: 16) {
                List(revisions, selection: $selected) { item in
                    VStack(alignment: .leading) {
                        Text(VeraText.text(item.summary))
                        Text(item.date, format: .dateTime).foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
                .frame(width: 225)
                Group {
                    if let preview {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Changes if restored").font(.headline)
                                if preview.entries.isEmpty { Text("No visible changes") }
                                ForEach(Array(preview.entries.enumerated()), id: \.offset) { _, entry in
                                    VStack(alignment: .leading) {
                                        Text(VeraText.text(entry.action.capitalized) + " " + entry.target)
                                        Text(entry.fields.joined(separator: ", ")).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        Text(revisions.isEmpty ? VeraText.text("No revisions yet.") : VeraText.text("Select a revision to review it."))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
            HStack {
                Button("Refresh", action: refresh)
                Spacer()
                Button("Done") { dismiss() }
                Button("Restore Revision…") { confirming = true }
                    .disabled(revision?.recoverable != true || preview == nil)
            }
        }
        .padding(24)
        .frame(width: 720, height: 450)
        .task { refresh() }
        .onChange(of: selected) { _, _ in review() }
        .confirmationDialog("Restore this revision?", isPresented: $confirming, titleVisibility: .visible, presenting: revision) { revision in
            Button("Restore Vault and Presets", role: .destructive) { restoreSelected(revision.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("VeraData saves a new recovery revision before replacing the current vault and presets.")
        }
    }

    private func refresh() {
        do {
            revisions = try store.history()
            if revisions.contains(where: { $0.id == selected }) { review() }
            else { selected = revisions.first?.id; preview = nil; problem = nil }
        } catch { problem = error.localizedDescription }
    }

    private func review() {
        preview = nil
        guard let selected else { return }
        do {
            let snapshot = try store.snapshot()
            let prior = try store.revision(selected)
            preview = StateDifference(before: snapshot, after: prior.state)
            token = snapshot.token
            problem = prior.revision.recoverable ? nil : VeraText.text("This revision has no readable vault to restore.")
        } catch { problem = error.localizedDescription }
    }

    private func restoreSelected(_ id: String) {
        do { try restore(id, token); dismiss() }
        catch {
            let message = error.localizedDescription
            refresh()
            problem = message
        }
    }
}
