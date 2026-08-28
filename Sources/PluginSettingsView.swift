import SwiftUI

/// Settings sheet for every installed plugin that declares tunables in its
/// manifest (`settings: [PluginSetting]`). Controls render by type — bool →
/// toggle, number → slider, choice → picker — grouped by `section`. Changes
/// apply live: the store persists the value and re-runs suggestions.
struct PluginSettingsView: View {
    @EnvironmentObject var store: TagStore
    @Environment(\.dismiss) private var dismiss

    private var plugins: [DiscoveredPlugin] {
        PluginRegistry.discover()
            .filter { !($0.manifest.settings ?? []).isEmpty }
            .sorted { $0.manifest.name < $1.manifest.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Plugin Settings").font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if plugins.isEmpty {
                Text("No installed plugin declares settings.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(plugins) { plugin in
                            pluginSection(plugin)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    private func pluginSection(_ plugin: DiscoveredPlugin) -> some View {
        let schema = plugin.manifest.settings ?? []
        // Preserve manifest order of sections; nil-section controls come first.
        var sections: [(name: String?, items: [PluginSetting])] = []
        for s in schema {
            if let idx = sections.firstIndex(where: { $0.name == s.section }) {
                sections[idx].items.append(s)
            } else {
                sections.append((s.section, [s]))
            }
        }
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, sec in
                    if let name = sec.name {
                        Text(name).font(.caption.bold()).foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    ForEach(sec.items, id: \.key) { setting in
                        control(plugin: plugin, setting: setting)
                    }
                }
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { store.resetPluginSettings(plugin.id) }
                        .font(.caption)
                }
            }
            .padding(6)
        } label: {
            Text(plugin.manifest.name).font(.headline)
        }
    }

    private func currentValue(_ plugin: DiscoveredPlugin, _ setting: PluginSetting) -> SettingValue {
        store.pluginSettings[plugin.id]?[setting.key] ?? setting.defaultValue
    }

    @ViewBuilder
    private func control(plugin: DiscoveredPlugin, setting: PluginSetting) -> some View {
        switch setting.type {
        case "bool":
            Toggle(isOn: Binding(
                get: { currentValue(plugin, setting).boolValue ?? false },
                set: { store.setPluginSetting(plugin.id, key: setting.key, value: .bool($0)) })) {
                labelView(setting)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        case "number":
            let lo = setting.min ?? 0
            let hi = Swift.max(setting.max ?? 1, lo + 0.0001)
            let step = setting.step ?? 0.05
            let value = currentValue(plugin, setting).numberValue ?? lo
            HStack {
                labelView(setting)
                Slider(value: Binding(
                    get: { currentValue(plugin, setting).numberValue ?? lo },
                    set: { store.setPluginSetting(plugin.id, key: setting.key,
                                                  value: .number(($0 / step).rounded() * step)) }),
                       in: lo...hi)
                    .frame(maxWidth: 220)
                Text(step >= 1 ? String(Int(value)) : String(format: "%.2f", value))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        case "choice":
            Picker(selection: Binding(
                get: { currentValue(plugin, setting).stringValue ?? "" },
                set: { store.setPluginSetting(plugin.id, key: setting.key, value: .string($0)) })) {
                ForEach(setting.choices ?? [], id: \.value) { c in
                    Text(c.label).tag(c.value)
                }
            } label: {
                labelView(setting)
            }
            .pickerStyle(.menu)
        default:
            EmptyView()
        }
    }

    private func labelView(_ setting: PluginSetting) -> some View {
        Text(setting.label)
            .help(setting.help ?? "")
            .frame(minWidth: 140, alignment: .leading)
    }
}