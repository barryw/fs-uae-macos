import MacFSUAEKit
import SwiftUI

struct KeyboardSettingsView: View {
    @ObservedObject private var mapping = MacFSUAEKeyboardMapping.shared
    @State private var searchText = ""
    @State private var selectedKeyCode: UInt16?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Keyboard Mapping", systemImage: "keyboard")
                        .font(.title2.weight(.semibold))
                    Text("Map physical Mac keys to the Amiga keyboard. Changes apply immediately.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search keys", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            Table(filteredKeys, selection: $selectedKeyCode) {
                TableColumn("Mac Key") { key in
                    Text(key.macTitle)
                        .font(.system(.body, design: .monospaced))
                }
                .width(min: 150, ideal: 190)

                TableColumn("Amiga Key") { key in
                    Text(targetTitle(for: key.code))
                        .foregroundStyle(mapping.target(for: key.code) == nil ? .tertiary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 12) {
                Text("\(filteredKeys.count) of \(MacFSUAEKeyboardLayout.keys.count) Mac keys")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                if let selectedKey {
                    Text("Map \(selectedKey.macTitle) to")
                        .foregroundStyle(.secondary)
                    Picker("Amiga Key", selection: targetBinding(for: selectedKey.code)) {
                        Text("Not Mapped").tag(MacFSUAEKeyboardMapping.notMapped)
                        Divider()
                        ForEach(MacFSUAEKeyboardLayout.amigaKeys) { target in
                            Text(target.amigaTitle ?? target.macTitle).tag(target.code)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 210)
                } else {
                    Text("Select a Mac key to change its mapping")
                        .foregroundStyle(.secondary)
                }
                Button("Reset Defaults") { mapping.reset() }
                    .disabled(mapping.isDefault)
            }
        }
        .padding(20)
        .frame(width: 680, height: 560)
    }

    private var filteredKeys: [MacFSUAEKeyDefinition] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return MacFSUAEKeyboardLayout.keys }
        return MacFSUAEKeyboardLayout.keys.filter {
            $0.macTitle.localizedCaseInsensitiveContains(query) ||
                ($0.amigaTitle?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    private var selectedKey: MacFSUAEKeyDefinition? {
        guard let selectedKeyCode else { return nil }
        return MacFSUAEKeyboardLayout.keys.first { $0.code == selectedKeyCode }
    }

    private func targetTitle(for hostCode: UInt16) -> String {
        guard let target = mapping.target(for: hostCode) else { return "Not Mapped" }
        return MacFSUAEKeyboardLayout.amigaKeys.first { $0.code == target }?.amigaTitle
            ?? "Key \(target)"
    }

    private func targetBinding(for hostCode: UInt16) -> Binding<UInt16> {
        Binding {
            mapping.target(for: hostCode) ?? MacFSUAEKeyboardMapping.notMapped
        } set: { target in
            mapping.setTarget(target == MacFSUAEKeyboardMapping.notMapped ? nil : target,
                              for: hostCode)
        }
    }
}
