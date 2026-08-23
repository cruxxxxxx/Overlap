import SwiftUI

/// Manage hidden tags, the reveal passcode, and per-tag default query stances.
/// Reveal is session-only: hidden tags re-lock every launch. This deters
/// over-the-shoulder viewing — it is NOT encryption; the files and their tags
/// remain readable in Finder and Spotlight.
struct PrivacyView: View {
    @EnvironmentObject var store: TagStore
    @Environment(\.dismiss) private var dismiss

    @State private var revealField = ""
    @State private var revealError = false
    @State private var newPass = ""
    @State private var confirmPass = ""
    @State private var passNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hidden Tags & Privacy").font(.headline)

            lockSection
            Divider()
            passcodeSection
            Divider()
            hiddenSection
            Divider()
            defaultsSection

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: Lock / reveal

    @ViewBuilder
    private var lockSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: store.revealed ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(store.revealed ? Color.orange : .secondary)
                Text(store.revealed ? "Hidden tags are revealed"
                                    : "Hidden tags are locked")
                    .font(.subheadline).bold()
            }
            if store.revealed {
                Button("Lock Now") { store.lock() }
            } else if store.hasPasscode {
                HStack {
                    SecureField("Passcode", text: $revealField)
                        .frame(width: 180)
                        .onSubmit(attemptReveal)
                    Button("Reveal", action: attemptReveal)
                }
                if revealError {
                    Text("Incorrect passcode.").font(.caption).foregroundStyle(.red)
                }
            } else {
                Button("Reveal") { store.reveal() }
                Text("No passcode set — anyone can reveal. Set one below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func attemptReveal() {
        if store.reveal(revealField) {
            revealField = ""; revealError = false
        } else {
            revealError = true
        }
    }

    // MARK: Passcode

    @ViewBuilder
    private var passcodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.hasPasscode ? "Change Passcode" : "Set Passcode")
                .font(.subheadline).bold()
            SecureField("New passcode", text: $newPass).frame(width: 220)
            SecureField("Confirm", text: $confirmPass).frame(width: 220)
            HStack {
                Button(store.hasPasscode ? "Update" : "Set") {
                    guard !newPass.isEmpty else { passNote = "Enter a passcode."; return }
                    guard newPass == confirmPass else { passNote = "Passcodes don't match."; return }
                    store.setPasscode(newPass)
                    newPass = ""; confirmPass = ""; passNote = "Passcode saved."
                }
                if store.hasPasscode {
                    Button("Remove Passcode", role: .destructive) {
                        store.removePasscode(); passNote = "Passcode removed."
                    }
                }
            }
            if !passNote.isEmpty {
                Text(passNote).font(.caption).foregroundStyle(.secondary)
            }
            Text("Deters casual viewing only — not encryption. Files stay readable in Finder.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: Hidden tag list

    @ViewBuilder
    private var hiddenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hidden Tags").font(.subheadline).bold()
            if store.hiddenTags.isEmpty {
                Text("None. Right-click a tag in the sidebar → Hide Tag.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.hiddenTags.sorted(), id: \.self) { tag in
                    HStack {
                        Image(systemName: "eye.slash").foregroundStyle(.secondary)
                        Text(tag)
                        Spacer()
                        Button("Unhide") { store.setHidden(tag, false) }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: Default stances

    @ViewBuilder
    private var defaultsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Default Query Stances").font(.subheadline).bold()
            let entries = store.tagDefaults.sorted { $0.key < $1.key }
            if entries.isEmpty {
                Text("None. Right-click a tag → Default in Queries.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(entries, id: \.key) { tag, stance in
                    HStack {
                        Image(systemName: stance == .include ? "plus.circle" : "minus.circle")
                            .foregroundStyle(stance == .include ? .green : .red)
                        Text(tag)
                        Text(stance == .include ? "always include" : "always exclude")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { store.setDefault(tag, .off) }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                }
            }
        }
    }
}
