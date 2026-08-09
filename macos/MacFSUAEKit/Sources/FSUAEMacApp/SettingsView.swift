import MacFSUAEKit
import SwiftUI

struct AppSettingsView: View {
    var body: some View {
        TabView {
            KeyboardSettingsView()
                .tabItem { Label("Keyboard", systemImage: "keyboard") }

            AgentControlSettingsView()
                .tabItem { Label("Agent Control", systemImage: "point.3.connected.trianglepath.dotted") }
        }
    }
}

private struct AgentControlSettingsView: View {
    @EnvironmentObject private var server: MacFSUAEMCPServer
    @State private var portText = ""
    @FocusState private var portFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Agent Control", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.title2.weight(.semibold))
                Text("Allow local MCP clients to manage machines and configurations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                Section("Model Context Protocol") {
                    Toggle("Enable MCP server", isOn: enabledBinding)

                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(server.isRunning ? .green
                                      : server.isEnabled ? .orange : .secondary.opacity(0.45))
                                .frame(width: 8, height: 8)
                            Text(server.status)
                                .foregroundStyle(.secondary)
                        }
                    }

                    LabeledContent("Address") {
                        Text("127.0.0.1")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent("Port") {
                        TextField("Port", text: $portText)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 88)
                            .focused($portFocused)
                            .onSubmit(commitPort)
                    }

                    LabeledContent("Endpoint") {
                        Text(server.endpoint)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Section("Execution") {
                    Toggle("Headless", isOn: headlessBinding)
                        .disabled(!server.isEnabled)
                    LabeledContent("Active sessions") {
                        Text("\(server.runningMachines.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text("Each MCP-started machine runs in an isolated process without presenting the Metal display. The app is never activated by a tool call.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Available Tools") {
                    tool("Start or stop a machine", "playpause", "using a named configuration")
                    tool("List running machines", "list.bullet.rectangle", "with UUID, configuration, and health")
                    tool("List configurations", "list.bullet", "including model and running state")
                    tool("Add or duplicate configurations", "plus.square.on.square", "without overwriting existing files")
                    tool("Delete configurations", "trash", "by moving them to Trash")
                }
            }
            .formStyle(.grouped)
        }
        .padding(20)
        .frame(width: 680, height: 560)
        .onAppear { portText = String(server.port) }
        .onChange(of: portFocused) { _, focused in
            if !focused { commitPort() }
        }
        .onChange(of: server.port) { _, port in portText = String(port) }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { server.isEnabled }, set: { server.setEnabled($0) })
    }

    private var headlessBinding: Binding<Bool> {
        Binding(get: { server.isHeadless }, set: { server.setHeadless($0) })
    }

    private func commitPort() {
        guard let port = Int(portText), server.setPort(port) else {
            portText = String(server.port)
            return
        }
        portText = String(server.port)
    }

    private func tool(_ title: String, _ symbol: String, _ detail: String) -> some View {
        LabeledContent {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}
