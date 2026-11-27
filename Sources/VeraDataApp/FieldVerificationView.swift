import AppKit
import SwiftUI
import VeraDataCore

struct VerificationTarget: Identifiable {
    let key: String
    let title: String
    let value: JSONValue
    var id: String { key }
}

struct SavedVerificationRequest: Identifiable {
    let profileID: Profile.ID
    let record: Record
    let target: VerificationTarget
    var id: String { target.id }
}

struct FieldVerificationBadge: View {
    let verification: FieldVerification?
    let value: JSONValue?

    var body: some View {
        if let verification {
            Text(VeraText.text(verification.matches(value) ? "Verified" : "Needs verification"))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct FieldVerificationView: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var original = ""
    @ViewState private var comparedOriginal: String?
    @ViewState private var match: FieldVerification?
    @ViewState private var issue: String?
    let target: VerificationTarget
    let selectedText: () throws -> String
    let save: (FieldVerification) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Verify Field").font(.title2.weight(.semibold))
            Text(target.title).font(.headline)
            Text("Field value").font(.subheadline)
            ScrollView {
                Text(FieldVerification.comparisonText(target.value) ?? "")
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 72)
            HStack {
                Text("Original value").font(.subheadline)
                Spacer()
                Button("Paste Original") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        original = text
                        issue = nil
                    } else {
                        issue = VeraText.text("The clipboard does not contain text.")
                    }
                }
                Button("Compare Selection") {
                    do {
                        original = try selectedText()
                        compare()
                    } catch { issue = error.localizedDescription }
                }
            }
            TextEditor(text: $original)
                .frame(height: 96).padding(3)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                .accessibilityLabel("Original value")
            Text("Comparison ignores differences in whitespace. Case and punctuation must match.")
                .font(.caption).foregroundStyle(.secondary)
            if let issue {
                Label(issue, systemImage: "exclamationmark.circle")
            } else if comparedOriginal == original {
                if match == nil {
                    Label("Values differ. Review the field and original value.", systemImage: "exclamationmark.circle")
                } else {
                    Label("Values match.", systemImage: "checkmark.circle")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if let match, comparedOriginal == original, issue == nil {
                    Button("Mark Verified") {
                        do { try save(match); dismiss() }
                        catch { issue = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Compare", action: compare).keyboardShortcut(.defaultAction)
                        .disabled(FieldVerification.comparisonText(.string(original)) == nil)
                }
            }
        }
        .padding(24).frame(width: 520)
    }

    private func compare() {
        comparedOriginal = original
        issue = nil
        match = nil
        do { match = try FieldVerification(value: target.value, original: original) }
        catch { issue = error.localizedDescription }
    }
}
