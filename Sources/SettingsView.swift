import AppKit
import SwiftUI

/// Overlap ▸ Settings: the toolbar and Explore's keys.
struct OverlapSettingsView: View {
    @ObservedObject private var bindings = ExploreKeyBindings.shared
    @AppStorage(LibraryTabPicker.labelsKey) private var tabLabels = true
    @State private var recording: ExploreAction?
    @State private var monitor: Any?
    @State private var note = "Click a key, then press the new one. Esc cancels."

    var body: some View {
        Form {
            Section("Toolbar") {
                Toggle("Show Library and Queue as words", isOn: $tabLabels)
                Text("Off shows icons, which take less room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Explore Keys") {
                ForEach(ExploreAction.allCases) { action in
                    LabeledContent(action.title) {
                        Button(recording == action ? "Press a key…" : bindings.label(action)) {
                            startRecording(action)
                        }
                        .frame(minWidth: 90)
                    }
                }
            }
            Section {
                HStack {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Defaults") {
                        stopRecording()
                        bindings.reset()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onDisappear { stopRecording() }
    }

    private func startRecording(_ action: ExploreAction) {
        stopRecording()
        recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { record(event, for: action) }
            return nil
        }
    }

    private func stopRecording() {
        recording = nil
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func record(_ event: NSEvent, for action: ExploreAction) {
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            note = "Use a key without ⌘, ⌃ or ⌥."
            return
        }
        let key = ExploreKey(keyCode: event.keyCode, label: Self.label(for: event))
        if bindings.assign(key, to: action) {
            note = "Click a key, then press the new one. Esc cancels."
            stopRecording()
        } else {
            note = "\(key.label) is taken: T tags, arrows move, Tab and Delete keep their jobs."
        }
    }

    private static func label(for event: NSEvent) -> String {
        switch event.keyCode {
        case 49:
            return "Space"
        case 36:
            return "Return"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        }
    }
}
