import SwiftUI

/// Rename, describe, or change the visibility of a synced remote collection.
/// Making it more visible asks first.
struct EditCollectionSheet: View {
    let plugin: DiscoveredPlugin
    let link: SourceLink
    @EnvironmentObject var sources: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var visibility = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmingExposure = false

    private var info: SourceInfo { plugin.manifest.source! }
    private var original: SourceCollection { link.collection }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit \(info.noun.capitalized)").font(.title3.bold())
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            Text("Description").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $details)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            if let choices = info.visibilities, !choices.isEmpty {
                VisibilityPicker(choices: choices, selection: $visibility)
            }
            if title != original.title {
                Text("Renaming also renames the tag “\(SourceEngine.tag(for: info, collectionTitle: original.title))” on your files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if exposes {
                        confirmingExposure = true
                    } else {
                        save()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || title.trimmingCharacters(in: .whitespaces).isEmpty || !changed)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            title = original.title
            details = original.description ?? ""
            visibility = original.visibility ?? info.mostPrivate?.id ?? ""
        }
        .confirmationDialog(exposurePrompt, isPresented: $confirmingExposure) {
            Button("Make \(info.visibilityLabel(visibility) ?? visibility)") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("More people will be able to see its \(original.count.map { "\($0) " } ?? "")items.")
        }
    }

    private var changed: Bool {
        title != original.title || details != (original.description ?? "") || visibility != (original.visibility ?? "")
    }

    /// More people would see it than before.
    private var exposes: Bool {
        info.widens(from: original.visibility, to: visibility)
    }

    private var exposurePrompt: String {
        "Make “\(title)” \((info.visibilityLabel(visibility) ?? visibility).lowercased())?"
    }

    private func save() {
        saving = true
        Task {
            let result = await sources.updateCollection(
                link,
                title: title != original.title ? title : nil,
                description: details != (original.description ?? "") ? details : nil,
                visibility: visibility != (original.visibility ?? "") ? visibility : nil)
            saving = false
            switch result {
            case .success:
                dismiss()
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }
}

/// Publish a board as a new remote collection: create it, link the board,
/// send the board's files. Hidden files are left out and counted.
struct PublishBoardSheet: View {
    let plugin: DiscoveredPlugin
    let boardID: UUID
    let boardName: String
    let urls: [URL]
    @EnvironmentObject var sources: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var details = ""
    @State private var visibility = ""
    @State private var publishing = false
    @State private var error: String?

    private var info: SourceInfo { plugin.manifest.source! }
    private var gate: (allowed: [URL], dropped: Int) { sources.shareable(urls) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Publish “\(boardName)” to \(info.displayName)").font(.title3.bold())
            Text("Creates a new \(info.noun), sends the board's files to it, and links the two so syncing the board keeps them together.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("\(info.noun.capitalized) title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $details).textFieldStyle(.roundedBorder)
            if let choices = info.visibilities, !choices.isEmpty {
                VisibilityPicker(choices: choices, selection: $visibility)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("\(gate.allowed.count) file\(gate.allowed.count == 1 ? "" : "s") will be sent.").bold()
                if info.isShared(visibility) {
                    Text("Others will be able to see them.").foregroundStyle(.orange)
                }
                if gate.dropped > 0 {
                    Text("\(gate.dropped) hidden or vault file\(gate.dropped == 1 ? "" : "s") left out.")
                        .foregroundStyle(.secondary)
                }
                Text("Notes, labels and your tags stay on this Mac.").foregroundStyle(.secondary)
            }
            .font(.caption)
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Publish") { publish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(publishing || sources.busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear {
            title = boardName
            visibility = info.mostPrivate?.id ?? ""
        }
    }

    private func publish() {
        publishing = true
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let visibilityChoice = info.visibilities?.isEmpty == false ? visibility : nil
        Task {
            let failure = await sources.publishBoard(urls, boardID: boardID, title: trimmed,
                                                     visibility: visibilityChoice,
                                                     description: details.isEmpty ? nil : details,
                                                     plugin: plugin)
            publishing = false
            if let failure {
                error = failure.localizedDescription
            } else {
                dismiss()
            }
        }
    }
}

/// The service's visibility choices, with its own labels and explanations.
struct VisibilityPicker: View {
    let choices: [SourceVisibility]
    @Binding var selection: String

    var body: some View {
        Picker("Visibility", selection: $selection) {
            ForEach(choices) { choice in
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.label)
                    if let help = choice.help {
                        Text(help).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(choice.id)
            }
        }
        .pickerStyle(.radioGroup)
    }
}
