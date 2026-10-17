import SwiftUI

/// Manage hidden tags, how they're revealed, the encrypted vault, and per-tag
/// default query stances. Reveal is session-only: hidden tags re-lock every
/// launch, on sleep and screen lock. Without a vault, hiding only filters the
/// UI; with one, hidden files sit in an encrypted disk image while locked.
struct PrivacyView: View {
    @EnvironmentObject var store: TagStore
    @Environment(\.dismiss) private var dismiss

    @State private var revealField = ""
    @State private var revealError = false
    @State private var recoveryField = ""
    @State private var newPass = ""
    @State private var confirmPass = ""
    @State private var passNote = ""
    /// Recovery key on screen (just created, or asked for); nil = hidden.
    @State private var shownKey: String?
    @State private var usage: VaultDisk.Usage?
    @State private var confirmingRemoveVault = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Hidden Tags & Privacy").font(.headline)

                    lockSection
                    Divider()
                    vaultSection
                    Divider()
                    passcodeSection
                    Divider()
                    autoLockSection
                    Divider()
                    hiddenSection
                    Divider()
                    defaultsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460, height: 620)
        .task(id: usageRefreshKey) { usage = await store.vaultUsage() }
    }

    private var usageRefreshKey: String {
        "\(store.revealed)-\(store.vaultEnabled)-\(store.vaultStatus == nil)"
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
            if let status = store.vaultStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = store.vaultError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if store.revealed {
                Button("Lock Now") { store.lock() }
            } else if store.vaultKeyMissing {
                recoveryUnlock
            } else {
                revealControls
            }
        }
    }

    @ViewBuilder
    private var revealControls: some View {
        if store.hasPasscode {
            HStack {
                SecureField("Passcode", text: $revealField)
                    .frame(width: 180)
                    .onSubmit(attemptReveal)
                Button("Reveal", action: attemptReveal)
            }
            if revealError {
                Text("Incorrect passcode.").font(.caption).foregroundStyle(.red)
            }
        }
        if store.revealNeedsDeviceAuth {
            Button(DeviceAuth.hasBiometrics ? "Reveal with Touch ID" : "Reveal with Login Password") {
                store.revealWithDeviceAuth()
            }
        }
        if !store.hasPasscode && !store.revealNeedsDeviceAuth {
            Button("Reveal") { store.reveal() }
            Text("No passcode set — anyone can reveal. Set one below.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recoveryUnlock: some View {
        Text("The vault key is missing from the keychain. Enter your recovery key to open it.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            TextField("XXXXX-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", text: $recoveryField)
                .font(.system(.body, design: .monospaced))
                .onSubmit(attemptRecovery)
            Button("Unlock", action: attemptRecovery)
        }
    }

    private func attemptReveal() {
        if store.reveal(revealField) {
            revealField = ""
            revealError = false
        } else {
            revealError = true
        }
    }

    private func attemptRecovery() {
        store.revealWithRecoveryKey(recoveryField)
        recoveryField = ""
    }

    // MARK: Vault

    @ViewBuilder
    private var vaultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Encrypted Vault").font(.subheadline).bold()
            if let key = shownKey {
                recoveryKeyBox(key)
            }
            if !store.vaultEnabled {
                Text("Move hidden files into an AES-256 encrypted disk image that opens only while revealed. Locked, they can't be read in Finder, Spotlight or Terminal.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Create Vault") {
                    store.createVault { key in shownKey = key }
                }
                .disabled(!store.canEditPrivacy || store.vaultStatus != nil)
                if !store.canEditPrivacy {
                    Text("Reveal first.").font(.caption).foregroundStyle(.secondary)
                }
            } else if store.revealed {
                vaultManagement
            } else {
                Text("Hidden files are encrypted and the vault is closed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var vaultManagement: some View {
        if let usage {
            Text("\(bytes(usage.inUse)) in use · \(bytes(usage.onDisk)) on disk")
                .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button("Reclaim Space") {
                store.reclaimVaultSpace {}
            }
            .disabled((usage?.reclaimable ?? 0) < 64 * 1_048_576 || store.vaultStatus != nil)
            Button("Show Recovery Key") { shownKey = store.recoveryKey() }
            Button("Remove Vault…", role: .destructive) { confirmingRemoveVault = true }
                .disabled(store.vaultStatus != nil)
        }
        if confirmingRemoveVault {
            VStack(alignment: .leading, spacing: 6) {
                Text("Move every hidden file back to its original folder and delete the vault? Hidden tags stay hidden, but the files will be readable in Finder again.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { confirmingRemoveVault = false }
                    Button("Remove Vault", role: .destructive) {
                        confirmingRemoveVault = false
                        shownKey = nil
                        store.removeVault()
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
        }
        Text("The vault grows as files move in. Space freed inside it is reused by later hides; Reclaim Space rebuilds the vault to return it to the disk.")
            .font(.caption2).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func recoveryKeyBox(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recovery Key").font(.caption).bold()
            Text(key)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text("Keep it in a password manager. If the keychain entry is lost, it's the only way to open the vault.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(key, forType: .string)
                }
                Button("Hide") { shownKey = nil }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    // MARK: Passcode

    @ViewBuilder
    private var passcodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.hasPasscode ? "Change Passcode" : "Set Passcode")
                .font(.subheadline).bold()
            if store.canEditPrivacy {
                passcodeEditor
            } else {
                Text("Reveal to change privacy settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if DeviceAuth.isAvailable {
                Toggle(DeviceAuth.hasBiometrics ? "Allow Touch ID to reveal" : "Allow login password to reveal",
                       isOn: $store.useDeviceAuth)
                    .disabled(!store.canEditPrivacy)
            }
            Text(store.vaultEnabled
                 ? "With no passcode, revealing asks for Touch ID or your login password."
                 : "Without a vault this deters casual viewing only — files stay readable in Finder.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var passcodeEditor: some View {
        SecureField("New passcode", text: $newPass).frame(width: 220)
        SecureField("Confirm", text: $confirmPass).frame(width: 220)
        HStack {
            Button(store.hasPasscode ? "Update" : "Set") {
                guard !newPass.isEmpty else {
                    passNote = "Enter a passcode."
                    return
                }
                guard newPass == confirmPass else {
                    passNote = "Passcodes don't match."
                    return
                }
                store.setPasscode(newPass)
                newPass = ""
                confirmPass = ""
                passNote = "Passcode saved."
            }
            if store.hasPasscode {
                Button("Remove Passcode", role: .destructive) {
                    store.removePasscode()
                    passNote = "Passcode removed."
                }
            }
        }
        if !passNote.isEmpty {
            Text(passNote).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Auto-lock

    @ViewBuilder
    private var autoLockSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Auto-Lock").font(.subheadline).bold()
            Picker("Lock after Overlap is in the background for", selection: $store.autoLockMinutes) {
                Text("Never").tag(0)
                Text("1 minute").tag(1)
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("1 hour").tag(60)
            }
            .disabled(!store.canEditPrivacy)
            Text("Always locks on sleep, screen lock, and user switching.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Clear all thumbnail caches on lock", isOn: $store.purgeAllThumbnailsOnLock)
                .disabled(!store.canEditPrivacy)
            Text(store.purgeAllThumbnailsOnLock
                 ? "Empties Overlap's and macOS's Quick Look thumbnail caches. Thumbnails everywhere re-render afterwards."
                 : "Drops only hidden files' thumbnails, and resets Quick Look only if a hidden file was previewed.")
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
            } else if !store.revealed {
                Text("Reveal to see and manage hidden tags.")
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
            let entries = store.tagDefaults
                .filter { store.revealed || !store.isHiddenTag($0.key) }
                .sorted { $0.key < $1.key }
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
