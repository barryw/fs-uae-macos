import Combine
import Darwin
import Foundation
@preconcurrency import Network

struct MCPHTTPReply: Sendable {
    let status: Int
    let body: Data?
}

public struct MacFSUAERunningMachine: Identifiable, Equatable, Sendable {
    public let id: String
    public let configuration: String
    public let model: String
    public let processIdentifier: Int32
    public let presentation: String
    public fileprivate(set) var status: String
    public fileprivate(set) var frameSequence: UInt64 = 0
    public fileprivate(set) var programCounter: UInt32 = 0
    public fileprivate(set) var execBase: UInt32 = 0
    public fileprivate(set) var lastAlert: [UInt32] = [0, 0, 0, 0]
    public fileprivate(set) var isPaused = false
    public fileprivate(set) var speed = 1.0
    public fileprivate(set) var drives: [MacFSUAEDrive] = []
    public fileprivate(set) var guestControlReady = false
}

private struct MCPHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private final class MCPHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (Data) async -> MCPHTTPReply

    private let handler: Handler
    private let queue = DispatchQueue(label: "com.barrywalker.fsuae.mcp", qos: .userInitiated)
    private var listener: NWListener?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start(port: UInt16, stateChanged: @escaping @Sendable (String?) -> Void) throws {
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionLimit = 32
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                stateChanged(nil)
            case let .failed(error), let .waiting(error):
                stateChanged(error.localizedDescription)
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(from: connection, accumulated: Data())
    }

    private func receive(from connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var requestData = accumulated
            if let data { requestData.append(data) }
            if requestData.count > 24 * 1_048_576 {
                send(.init(status: 413, body: nil), to: connection)
                return
            }
            switch parse(requestData) {
            case let .success(request):
                Task {
                    let reply = await process(request)
                    send(reply, to: connection)
                }
            case .failure:
                send(.init(status: 400, body: nil), to: connection)
            case nil:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receive(from: connection, accumulated: requestData)
                }
            }
        }
    }

    private enum ParseResult {
        case success(MCPHTTPRequest)
        case failure
    }

    private func parse(_ data: Data) -> ParseResult? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator) else { return nil }
        guard let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            return .failure
        }
        let lines = header.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return .failure }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .failure }
        let bodyStart = range.upperBound
        guard data.count >= bodyStart + length else { return nil }
        return .success(MCPHTTPRequest(
            method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }

    private func process(_ request: MCPHTTPRequest) async -> MCPHTTPReply {
        if request.headers["origin"] != nil {
            return .init(status: 403, body: nil)
        }
        guard request.path == "/mcp" else { return .init(status: 404, body: nil) }
        if request.method == "GET" { return .init(status: 405, body: nil) }
        guard request.method == "POST" else { return .init(status: 405, body: nil) }
        guard request.headers["content-type"]?.lowercased().contains("application/json") == true else {
            return .init(status: 415, body: nil)
        }
        return await handler(request.body)
    }

    private func send(_ reply: MCPHTTPReply, to connection: NWConnection) {
        let reason = switch reply.status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        default: "Error"
        }
        let body = reply.body ?? Data()
        var header = "HTTP/1.1 \(reply.status) \(reason)\r\n"
        if reply.body != nil { header += "Content-Type: application/json\r\n" }
        if reply.status == 405 { header += "Allow: POST\r\n" }
        header += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}

@MainActor
public final class MacFSUAEMCPServer: ObservableObject {
    public static let shared = MacFSUAEMCPServer()

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var isRunning = false
    @Published public private(set) var isHeadless: Bool
    @Published public private(set) var port: Int
    @Published public private(set) var status = "Off"
    @Published public private(set) var controlsActiveSession = false
    @Published public private(set) var runningMachines: [MacFSUAERunningMachine] = []

    public var endpoint: String { "http://127.0.0.1:\(port)/mcp" }
    public var hidesMCPDisplay: Bool {
        isEnabled && isHeadless && controlsActiveSession && session.isRunning
    }

    private let defaults: UserDefaults
    private let library: FSUAEConfigurationLibrary
    private let session: MacFSUAEEngineSession
    private var httpServer: MCPHTTPServer?
    private var subscriptions: Set<AnyCancellable> = []
    private var workerProcesses: [String: Process] = [:]
    private var workerInputPipes: [String: Pipe] = [:]
    private var workerStatusPipes: [String: Pipe] = [:]
    private var workerTransports: [String: MacFSUAEFrameTransport] = [:]
    private var workerFrameSources: [String: MacFSUAEFrameSource] = [:]
    private var workerFramePaths: [String: String] = [:]
    private var workerExchangePaths: [String: String] = [:]
    private enum GuestOperation { case command, put, get }
    private struct GuestRequest { let machineID: String; let operation: GuestOperation }
    private var guestCommands: [String: GuestRequest] = [:]
    private var guestCommandByMachine: [String: String] = [:]
    private var workerOutputBuffers: [String: String] = [:]
    private var workerHealthDates: [String: Date] = [:]
    private var workerAlertBaselines: [String: [UInt32]] = [:]
    private var foregroundMachineID: String?
    private var foregroundAlertBaseline: [UInt32]?
    private var selectedPresentedMachineID: String?

    private enum Key {
        static let enabled = "fsuae.mcp.enabled"
        static let headless = "fsuae.mcp.headless"
        static let port = "fsuae.mcp.port"
    }

    init(defaults: UserDefaults = .standard,
         library: FSUAEConfigurationLibrary = .shared,
         session: MacFSUAEEngineSession = .shared,
         startAutomatically: Bool = true) {
        signal(SIGPIPE, SIG_IGN)
        self.defaults = defaults
        self.library = library
        self.session = session
        isEnabled = defaults.bool(forKey: Key.enabled)
        isHeadless = defaults.bool(forKey: Key.headless)
        let savedPort = defaults.integer(forKey: Key.port)
        port = (1024...65_535).contains(savedPort) ? savedPort : 6800
        session.$isRunning.dropFirst().sink { [weak self] running in
            if !running {
                self?.controlsActiveSession = false
                self?.foregroundMachineID = nil
                self?.foregroundAlertBaseline = nil
            }
        }.store(in: &subscriptions)
        if isEnabled && startAutomatically { startServer() }
    }

    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        if enabled {
            startServer()
        } else {
            stopServer()
            stopAllWorkers()
        }
    }

    public func setHeadless(_ headless: Bool) {
        isHeadless = headless
        defaults.set(headless, forKey: Key.headless)
    }

    @discardableResult
    public func setPort(_ newPort: Int) -> Bool {
        guard (1024...65_535).contains(newPort) else {
            status = "Port must be between 1024 and 65535"
            return false
        }
        guard newPort != port else {
            status = isRunning ? "Listening" : isEnabled ? status : "Off"
            return true
        }
        port = newPort
        defaults.set(newPort, forKey: Key.port)
        if isEnabled {
            stopServer()
            startServer()
        }
        return true
    }

    public func shutdown() {
        stopServer()
        stopAllWorkers()
    }

    public func presentedMachine(configuration: String) -> MacFSUAERunningMachine? {
        runningMachines.first { $0.configuration == configuration && $0.presentation == "headed" }
    }

    @discardableResult
    public func startPresented(_ configuration: FSUAEConfiguration) throws -> MacFSUAERunningMachine {
        if let existing = presentedMachine(configuration: configuration.name) { return existing }
        return try startWorker(configuration, presentation: "headed")
    }

    public func stop(_ machineID: String) throws {
        guard workerProcesses[machineID] != nil else {
            removeWorker(machineID)
            return
        }
        _ = try stopWorker(machineID)
    }

    public func frameSource(for machineID: String) -> MacFSUAEFrameSource? {
        workerFrameSources[machineID]
    }

    public func inputControls(for machineID: String) -> MacFSUAEInputControls {
        MacFSUAEInputControls(
            key: { [weak self] code, pressed in
                MainActor.assumeIsolated {
                    self?.sendWorkerCommand(machineID, ["command": "key", "code": code,
                                                         "pressed": pressed]) ?? false
                }
            },
            mouseMove: { [weak self] x, y in
                MainActor.assumeIsolated {
                    self?.sendWorkerCommand(machineID, ["command": "mouse_move", "x": x, "y": y]) ?? false
                }
            },
            mouseButton: { [weak self] button, pressed in
                MainActor.assumeIsolated {
                    self?.sendWorkerCommand(machineID, ["command": "mouse_button",
                                                         "button": button, "pressed": pressed]) ?? false
                }
            })
    }

    public func selectPresentedMachine(_ machineID: String?) {
        selectedPresentedMachineID = machineID
        for machine in runningMachines where machine.presentation == "headed" {
            let selected = machine.id == machineID
            _ = sendWorkerCommand(machine.id, ["command": "audio", "enabled": selected])
        }
    }

    public func pause(_ machineID: String) {
        guard sendWorkerCommand(machineID, ["command": "pause"]),
              let index = runningMachines.firstIndex(where: { $0.id == machineID }) else { return }
        runningMachines[index].isPaused.toggle()
        runningMachines[index].status = runningMachines[index].isPaused ? "paused" : "running"
    }

    public func reset(_ machineID: String, hard: Bool = false) {
        _ = sendWorkerCommand(machineID, ["command": "reset", "hard": hard])
    }

    public func setSpeed(_ speed: Double, for machineID: String) {
        guard [0.0, 1.0, 2.0, 4.0].contains(speed),
              sendWorkerCommand(machineID, ["command": "speed", "value": speed]),
              let index = runningMachines.firstIndex(where: { $0.id == machineID }) else { return }
        runningMachines[index].speed = speed
    }

    public func insertFloppy(_ url: URL, drive: Int, machineID: String) {
        _ = sendWorkerCommand(machineID, ["command": "floppy", "drive": drive,
                                           "path": url.path])
    }

    public func ejectFloppy(_ drive: Int, machineID: String) {
        _ = sendWorkerCommand(machineID, ["command": "floppy", "drive": drive, "path": ""])
    }

    private func startServer() {
        status = "Starting…"
        let server = MCPHTTPServer { [weak self] data in
            guard let self else { return MCPHTTPReply(status: 503, body: nil) }
            return await self.handleMCPRequest(data)
        }
        do {
            try server.start(port: UInt16(port)) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    if let error {
                        self.isRunning = false
                        self.status = error
                    } else {
                        self.isRunning = true
                        self.status = "Listening"
                    }
                }
            }
            httpServer = server
        } catch {
            isRunning = false
            status = error.localizedDescription
        }
    }

    private func stopServer() {
        httpServer?.stop()
        httpServer = nil
        isRunning = false
        status = "Off"
    }

    func handleMCPRequest(_ data: Data) -> MCPHTTPReply {
        let request: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPFailure("Request must be a JSON object")
            }
            request = object
        } catch {
            return .init(status: 200, body: jsonRPC(id: NSNull(), error: -32700,
                                                    message: "Parse error"))
        }

        guard request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else {
            return .init(status: 200, body: jsonRPC(id: request["id"] ?? NSNull(),
                                                    error: -32600, message: "Invalid Request"))
        }
        guard let id = request["id"] else { return .init(status: 202, body: nil) }
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return success(id: id, result: [
                "protocolVersion": "2025-11-25",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "fs-uae-mac", "version": "0.1.0"],
            ])
        case "ping":
            return success(id: id, result: [:])
        case "tools/list":
            return success(id: id, result: ["tools": toolDefinitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return failure(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try callTool(name, arguments: arguments)
                return success(id: id, result: toolResult(text))
            } catch let error as MCPUnknownTool {
                return failure(id: id, code: -32602, message: error.localizedDescription)
            } catch {
                return success(id: id, result: toolResult("Error: \(error.localizedDescription)",
                                                          isError: true))
            }
        default:
            return failure(id: id, code: -32601, message: "Method not found")
        }
    }

    private var toolDefinitions: [[String: Any]] {
        let empty: [String: Any] = ["type": "object", "properties": [:],
                                    "additionalProperties": false]
        func stringSchema(_ properties: [String: String], required: [String]) -> [String: Any] {
            ["type": "object",
             "properties": Dictionary(uniqueKeysWithValues: properties.map {
                 ($0.key, ["type": "string", "description": $0.value])
             }),
             "required": required, "additionalProperties": false]
        }
        return [
            tool("fsuae_machine_start", "Start a machine using an exact saved configuration name.",
                 stringSchema(["configuration": "Saved configuration name"],
                              required: ["configuration"])),
            tool("fsuae_machine_stop", "Stop a machine by machine id or configuration name. Omit both when only one machine is running.",
                 stringSchema(["machine_id": "Machine UUID returned by start",
                               "configuration": "Exact saved configuration name"],
                              required: [])),
            tool("fsuae_machines_list", "List running machines, their UUIDs, configurations, presentation modes, and statuses.", empty),
            tool("fsuae_configurations_list", "List saved FS-UAE configurations and models.", empty),
            tool("fsuae_exchange_put", "Place a base64-encoded file on a machine's drive-independent MCP: volume.",
                 stringSchema(["machine_id": "Running machine UUID",
                               "name": "Single Amiga filename on MCP:",
                               "data_base64": "File contents encoded as base64 (16 MiB maximum)"],
                              required: ["machine_id", "name", "data_base64"])),
            tool("fsuae_exchange_get", "Read a file from a machine's drive-independent MCP: volume as base64.",
                 stringSchema(["machine_id": "Running machine UUID",
                               "name": "Single Amiga filename on MCP:"],
                              required: ["machine_id", "name"])),
            tool("fsuae_command_run", "Run an AmigaDOS command through the guest service and return a request id.",
                 stringSchema(["machine_id": "Running machine UUID",
                               "command": "AmigaDOS command line (4095-byte maximum)"],
                              required: ["machine_id", "command"])),
            tool("fsuae_command_result", "Poll a guest command request for captured output.",
                 stringSchema(["request_id": "Request UUID returned by fsuae_command_run"],
                              required: ["request_id"])),
            tool("fsuae_file_put", "Write a base64-encoded file to any AmigaDOS path through the guest service.",
                 stringSchema(["machine_id": "Running machine UUID",
                               "path": "Destination AmigaDOS path",
                               "data_base64": "File contents encoded as base64 (16 MiB maximum)"],
                              required: ["machine_id", "path", "data_base64"])),
            tool("fsuae_file_get", "Read any AmigaDOS file through the guest service.",
                 stringSchema(["machine_id": "Running machine UUID",
                               "path": "Source AmigaDOS path"],
                              required: ["machine_id", "path"])),
            tool("fsuae_configuration_add", "Create a configuration for an Amiga model.", [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "New configuration name"],
                    "model": ["type": "string", "description": "FS-UAE Amiga model",
                              "enum": FSUAEModelProfile.all.map(\.id)],
                ],
                "required": ["name"], "additionalProperties": false,
            ]),
            tool("fsuae_configuration_delete", "Move a saved configuration to Trash.",
                 stringSchema(["configuration": "Exact saved configuration name"],
                              required: ["configuration"])),
            tool("fsuae_configuration_duplicate", "Duplicate a saved configuration.",
                 stringSchema(["source": "Exact source configuration name",
                               "name": "New configuration name"],
                              required: ["source", "name"])),
        ]
    }

    private func tool(_ name: String, _ description: String, _ schema: [String: Any]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": schema]
    }

    private func callTool(_ name: String, arguments: [String: Any]) throws -> String {
        library.reload()
        switch name {
        case "fsuae_machine_start":
            let requested = try requiredString("configuration", in: arguments)
            guard let configuration = library.configuration(named: requested) else {
                throw MCPFailure("No configuration named \(requested)")
            }
            let machine = try startWorker(configuration,
                                          presentation: isHeadless ? "headless" : "headed")
            return "Started \(configuration.name) (\(configuration.model)); machine_id \(machine.id); pid \(machine.processIdentifier)"
        case "fsuae_machine_stop":
            return try stopMachine(arguments)
        case "fsuae_machines_list":
            return try machinesJSON()
        case "fsuae_configurations_list":
            let rows = library.configurations.map { configuration in
                let sessions = runningMachines.filter {
                    $0.configuration == configuration.name
                }.map(\.id)
                let foreground = session.activeConfiguration == configuration.url
                return ["name": configuration.name, "model": configuration.model,
                        "running": foreground || !sessions.isEmpty,
                        "machine_ids": foreground ? [foregroundMachineID].compactMap { $0 } + sessions
                                                  : sessions] as [String: Any]
            }
            let data = try JSONSerialization.data(withJSONObject: rows,
                                                   options: [.prettyPrinted, .sortedKeys])
            return String(decoding: data, as: UTF8.self)
        case "fsuae_exchange_put":
            return try exchangePut(arguments)
        case "fsuae_exchange_get":
            return try exchangeGet(arguments)
        case "fsuae_command_run":
            return try guestCommandRun(arguments)
        case "fsuae_command_result":
            return try guestCommandResult(arguments)
        case "fsuae_file_put":
            return try guestFilePut(arguments)
        case "fsuae_file_get":
            return try guestFileGet(arguments)
        case "fsuae_configuration_add":
            let name = try requiredString("name", in: arguments)
            let model = arguments["model"] as? String ?? "A500"
            try library.add(named: name, model: model)
            return "Created \(name) (\(model))"
        case "fsuae_configuration_delete":
            let name = try requiredString("configuration", in: arguments)
            if let configuration = library.configuration(named: name), session.isRunning,
               session.activeConfiguration == configuration.url {
                throw MCPFailure("Stop \(configuration.name) before deleting it")
            }
            guard !runningMachines.contains(where: { $0.configuration == name }) else {
                throw MCPFailure("Stop \(name) before deleting it")
            }
            try library.delete(named: name)
            return "Moved \(name) to Trash"
        case "fsuae_configuration_duplicate":
            let source = try requiredString("source", in: arguments)
            let name = try requiredString("name", in: arguments)
            try library.duplicate(source, named: name)
            return "Duplicated \(source) as \(name)"
        default:
            throw MCPUnknownTool(name)
        }
    }

    private func startWorker(_ configuration: FSUAEConfiguration,
                             presentation: String) throws -> MacFSUAERunningMachine {
        guard let executable = workerExecutable else {
            throw MCPFailure("FS-UAE Worker is missing")
        }
        let id = UUID().uuidString.lowercased()
        let process = Process()
        process.executableURL = executable
        process.arguments = [configuration.url.path]
        var environment = ProcessInfo.processInfo.environment
        var exchangePath: String?
        if isEnabled {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("fsuae-\(id)-exchange", isDirectory: true).path
            do {
                try FileManager.default.createDirectory(atPath: path,
                                                        withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                if let diagnostic = Bundle.main.url(forResource: "FSUAE-Diag",
                                                     withExtension: nil,
                                                     subdirectory: "Amiga") {
                    try FileManager.default.copyItem(at: diagnostic,
                                                     to: URL(fileURLWithPath: path)
                                                        .appendingPathComponent("FSUAE-Diag"))
                }
            } catch {
                try? FileManager.default.removeItem(atPath: path)
                throw MCPFailure("Could not create the MCP: exchange volume")
            }
            exchangePath = path
            environment["FSUAE_MAC_EXCHANGE_DIRECTORY"] = path
        }
        var transport: MacFSUAEFrameTransport?
        var framePath: String?
        if presentation == "headed" {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("fsuae-\(id).frame").path
            guard let created = MacFSUAEFrameTransport(creating: path) else {
                throw MCPFailure("Could not create the display channel")
            }
            transport = created
            framePath = path
            environment["FSUAE_MAC_FRAME_FILE"] = path
        }
        if environment["FSUAE_MAC_RUNTIME"] == nil,
           let runtime = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("libfsuaemac.dylib"),
           FileManager.default.fileExists(atPath: runtime.path) {
            environment["FSUAE_MAC_RUNTIME"] = runtime.path
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        let statusPipe = Pipe()
        process.standardError = statusPipe
        statusPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.consumeWorkerOutput(id, text: text) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.removeWorker(id) }
        }
        do {
            try process.run()
        } catch {
            if let framePath { try? FileManager.default.removeItem(atPath: framePath) }
            if let exchangePath { try? FileManager.default.removeItem(atPath: exchangePath) }
            throw MCPFailure("Could not start FS-UAE Worker: \(error.localizedDescription)")
        }
        guard process.isRunning else {
            throw MCPFailure("FS-UAE Worker exited during startup")
        }
        let machine = MacFSUAERunningMachine(
            id: id, configuration: configuration.name, model: configuration.model,
            processIdentifier: process.processIdentifier, presentation: presentation,
            status: "booting")
        workerProcesses[id] = process
        workerInputPipes[id] = inputPipe
        workerStatusPipes[id] = statusPipe
        if let exchangePath { workerExchangePaths[id] = exchangePath }
        if let transport, let framePath {
            workerTransports[id] = transport
            workerFrameSources[id] = MacFSUAEFrameSource(transport: transport)
            workerFramePaths[id] = framePath
        }
        workerOutputBuffers[id] = ""
        workerHealthDates[id] = Date()
        runningMachines.append(machine)
        return machine
    }

    private var workerExecutable: URL? {
        let environment = ProcessInfo.processInfo.environment["FSUAE_MAC_WORKER"].map {
            URL(fileURLWithPath: $0)
        }
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("FS-UAE Worker")
        return [environment, sibling].compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func stopMachine(_ arguments: [String: Any]) throws -> String {
        let requestedMachine = optionalString("machine_id", in: arguments)
        let requestedConfiguration = optionalString("configuration", in: arguments)
        if let requestedMachine {
            if requestedMachine == foregroundMachineID {
                guard session.isRunning else { throw MCPFailure("The foreground session is not running") }
                session.stop()
                controlsActiveSession = false
                foregroundMachineID = nil
                return "Stopped machine \(requestedMachine)"
            }
            return try stopWorker(requestedMachine)
        }

        if let requestedConfiguration {
            let matches = runningMachines.filter { $0.configuration == requestedConfiguration }
            let foregroundMatches = session.isRunning &&
                library.configuration(named: requestedConfiguration)?.url == session.activeConfiguration
            guard matches.count + (foregroundMatches ? 1 : 0) > 0 else {
                throw MCPFailure("No running machine named \(requestedConfiguration)")
            }
            guard matches.count + (foregroundMatches ? 1 : 0) == 1 else {
                throw MCPFailure("More than one \(requestedConfiguration) is running; specify machine_id")
            }
            if foregroundMatches {
                let id = foregroundMachineID
                session.stop()
                controlsActiveSession = false
                foregroundMachineID = nil
                return "Stopped machine \(id ?? requestedConfiguration)"
            }
            return try stopWorker(matches[0].id)
        }

        let count = runningMachines.count + (session.isRunning ? 1 : 0)
        guard count > 0 else { return "No machine is running" }
        guard count == 1 else { throw MCPFailure("More than one machine is running; specify machine_id") }
        if session.isRunning {
            let id = foregroundMachineID
            session.stop()
            controlsActiveSession = false
            foregroundMachineID = nil
            return "Stopped machine \(id ?? "foreground")"
        }
        return try stopWorker(runningMachines[0].id)
    }

    private func stopWorker(_ id: String) throws -> String {
        guard let process = workerProcesses[id] else { throw MCPFailure("No running machine \(id)") }
        if runningMachines.first(where: { $0.id == id })?.status == "stopping" {
            return "Machine \(id) is stopping"
        }
        updateWorker(id, status: "stopping")
        if !sendWorkerCommand(id, ["command": "stop"]) {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak process] in
            guard let self, let process, process.isRunning,
                  self.workerProcesses[id] === process else { return }
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        return "Stopping machine \(id)"
    }

    private func stopAllWorkers() {
        for process in workerProcesses.values where process.isRunning { process.terminate() }
        for pipe in workerStatusPipes.values {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        workerProcesses.removeAll()
        workerInputPipes.removeAll()
        workerStatusPipes.removeAll()
        workerTransports.removeAll()
        workerFrameSources.removeAll()
        for path in workerFramePaths.values { try? FileManager.default.removeItem(atPath: path) }
        workerFramePaths.removeAll()
        for path in workerExchangePaths.values { try? FileManager.default.removeItem(atPath: path) }
        workerExchangePaths.removeAll()
        guestCommands.removeAll()
        guestCommandByMachine.removeAll()
        workerOutputBuffers.removeAll()
        workerHealthDates.removeAll()
        workerAlertBaselines.removeAll()
        runningMachines.removeAll()
    }

    private func removeWorker(_ id: String) {
        if let request = guestCommandByMachine.removeValue(forKey: id) {
            guestCommands[request] = nil
        }
        workerProcesses[id] = nil
        workerInputPipes[id] = nil
        workerStatusPipes[id]?.fileHandleForReading.readabilityHandler = nil
        workerStatusPipes[id] = nil
        workerTransports[id] = nil
        workerFrameSources[id] = nil
        if let path = workerFramePaths.removeValue(forKey: id) {
            try? FileManager.default.removeItem(atPath: path)
        }
        if let path = workerExchangePaths.removeValue(forKey: id) {
            try? FileManager.default.removeItem(atPath: path)
        }
        workerOutputBuffers[id] = nil
        workerHealthDates[id] = nil
        workerAlertBaselines[id] = nil
        runningMachines.removeAll { $0.id == id }
        if selectedPresentedMachineID == id { selectedPresentedMachineID = nil }
    }

    private func sendWorkerCommand(_ id: String, _ command: [String: Any]) -> Bool {
        guard let pipe = workerInputPipes[id],
              let data = try? JSONSerialization.data(withJSONObject: command) else { return false }
        do {
            try pipe.fileHandleForWriting.write(contentsOf: data + Data([0x0a]))
            return true
        } catch {
            return false
        }
    }

    private func updateWorker(_ id: String, status: String) {
        guard let index = runningMachines.firstIndex(where: { $0.id == id }) else { return }
        runningMachines[index].status = status
    }

    private func consumeWorkerOutput(_ id: String, text: String) {
        var buffer = workerOutputBuffers[id, default: ""] + text
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line == "FSUAE_STATUS running" {
                updateWorker(id, status: "running")
            } else if line == "FSUAE_STATUS stopping" {
                updateWorker(id, status: "stopping")
            } else if line.hasPrefix("FSUAE_HEALTH ") {
                consumeHealth(id, fields: line.split(separator: " "))
            } else if line.hasPrefix("FSUAE_DRIVES ") {
                consumeDrives(id, encoded: String(line.dropFirst("FSUAE_DRIVES ".count)))
            }
        }
        workerOutputBuffers[id] = String(buffer.suffix(4096))
    }

    private func consumeDrives(_ id: String, encoded: String) {
        guard let data = Data(base64Encoded: encoded),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let index = runningMachines.firstIndex(where: { $0.id == id }) else { return }
        runningMachines[index].drives = rows.compactMap { row in
            guard let rawKind = row["kind"] as? Int,
                  let kind = MacFSUAEDrive.Kind(rawValue: Int32(rawKind)),
                  let drive = row["index"] as? Int else { return nil }
            return MacFSUAEDrive(kind: kind, index: drive,
                                 isActive: row["active"] as? Bool ?? false,
                                 mediaPath: row["path"] as? String ?? "")
        }
    }

    private func consumeHealth(_ id: String, fields: [Substring]) {
        guard fields.count == 9,
              let sequence = UInt64(fields[1]),
              let pc = UInt32(fields[2]),
              let execBase = UInt32(fields[3]) else { return }
        let alert = fields[4...7].compactMap { UInt32($0) }
        guard alert.count == 4,
              let index = runningMachines.firstIndex(where: { $0.id == id }) else { return }
        runningMachines[index].frameSequence = sequence
        runningMachines[index].programCounter = pc
        runningMachines[index].execBase = execBase
        runningMachines[index].lastAlert = alert
        runningMachines[index].guestControlReady = fields[8] == "1"
        workerHealthDates[id] = Date()
        if execBase != 0 {
            if let baseline = workerAlertBaselines[id], alert != baseline, alert[0] != 0 {
                runningMachines[index].status = "guruing"
            } else if workerAlertBaselines[id] == nil {
                workerAlertBaselines[id] = alert
            }
        }
    }

    private func machinesJSON() throws -> String {
        var rows = runningMachines.map(machineRow)
        if session.isRunning,
           let configuration = library.configurations.first(where: {
               $0.url == session.activeConfiguration
           }), let id = foregroundMachineID {
            var row: [String: Any] = [
                "machine_id": id, "configuration": configuration.name,
                "model": configuration.model, "pid": getpid(), "presentation": "headed",
                "status": session.isPaused ? "paused" : "running",
            ]
            if let health = session.health() {
                row["frame_sequence"] = health.frameSequence
                row["program_counter"] = String(format: "0x%08x", health.programCounter)
                if health.execBase != 0 {
                    row["exec_base"] = String(format: "0x%08x", health.execBase)
                    if foregroundAlertBaseline == nil { foregroundAlertBaseline = health.lastAlert }
                    if health.lastAlert != foregroundAlertBaseline, health.lastAlert[0] != 0 {
                        row["status"] = "guruing"
                        row["last_alert"] = health.lastAlert.map {
                            String(format: "0x%08x", $0)
                        }
                    }
                }
            }
            rows.append(row)
        }
        let data = try JSONSerialization.data(withJSONObject: rows,
                                               options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func machineRow(_ machine: MacFSUAERunningMachine) -> [String: Any] {
        let heartbeatAge = workerHealthDates[machine.id].map { Date().timeIntervalSince($0) }
        let stale = (machine.status == "running" && (heartbeatAge ?? 0) > 3) ||
            (machine.status == "booting" && (heartbeatAge ?? 0) > 10)
        let status = stale ? "unresponsive" : machine.status
        var row: [String: Any] = [
            "machine_id": machine.id, "configuration": machine.configuration,
            "model": machine.model, "pid": machine.processIdentifier,
            "presentation": machine.presentation, "status": status,
            "frame_sequence": machine.frameSequence,
            "program_counter": String(format: "0x%08x", machine.programCounter),
            "guest_control_ready": machine.guestControlReady,
        ]
        if machine.execBase != 0 {
            row["exec_base"] = String(format: "0x%08x", machine.execBase)
            if status == "guruing" {
                row["last_alert"] = machine.lastAlert.map { String(format: "0x%08x", $0) }
            }
        }
        return row
    }

    private func exchangePut(_ arguments: [String: Any]) throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let name = try exchangeName(in: arguments)
        let encoded = try requiredString("data_base64", in: arguments)
        guard let data = Data(base64Encoded: encoded), data.count <= 16 * 1_048_576 else {
            throw MCPFailure("data_base64 must contain at most 16 MiB")
        }
        let url = try exchangeURL(machineID: machineID, name: name)
        try data.write(to: url, options: .atomic)
        return try jsonText(["machine_id": machineID, "amiga_path": "MCP:\(name)",
                             "size": data.count])
    }

    private func exchangeGet(_ arguments: [String: Any]) throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let name = try exchangeName(in: arguments)
        let url = try exchangeURL(machineID: machineID, name: name)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                       .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 16 * 1_048_576 else {
            throw MCPFailure("MCP:\(name) is not a regular file of 16 MiB or less")
        }
        let data = try Data(contentsOf: url)
        return try jsonText(["machine_id": machineID, "amiga_path": "MCP:\(name)",
                             "size": data.count, "data_base64": data.base64EncodedString()])
    }

    private func guestCommandRun(_ arguments: [String: Any]) throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let command = try requiredString("command", in: arguments)
        guard let data = command.data(using: .isoLatin1), !data.contains(0), data.count <= 4095 else {
            throw MCPFailure("command must be Latin-1 text of 4095 bytes or less")
        }
        return try startGuestRequest(machineID: machineID, payload: Data([0x43]) + data,
                                     operation: .command)
    }

    private func guestFilePut(_ arguments: [String: Any]) throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let path = try guestPath(in: arguments)
        let encoded = try requiredString("data_base64", in: arguments)
        guard let data = Data(base64Encoded: encoded), data.count <= 16 * 1_048_576 else {
            throw MCPFailure("data_base64 must contain at most 16 MiB")
        }
        return try startGuestRequest(machineID: machineID, payload: Data([0x50]) + path,
                                     operation: .put, transfer: data)
    }

    private func guestFileGet(_ arguments: [String: Any]) throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        return try startGuestRequest(machineID: machineID,
                                     payload: Data([0x47]) + guestPath(in: arguments),
                                     operation: .get)
    }

    private func guestPath(in arguments: [String: Any]) throws -> Data {
        let path = try requiredString("path", in: arguments)
        guard let data = path.data(using: .isoLatin1), !data.contains(0), data.count <= 4094 else {
            throw MCPFailure("path must be Latin-1 text of 4094 bytes or less")
        }
        return data
    }

    private func startGuestRequest(machineID: String, payload: Data,
                                   operation: GuestOperation, transfer: Data? = nil) throws -> String {
        guard runningMachines.first(where: { $0.id == machineID })?.guestControlReady == true else {
            throw MCPFailure("Guest control is not ready on machine \(machineID)")
        }
        guard guestCommandByMachine[machineID] == nil else {
            throw MCPFailure("Machine \(machineID) already has an uncollected command")
        }
        let commandURL = try exchangeURL(machineID: machineID, name: "FSUAE-Control-Command")
        let outputURL = try exchangeURL(machineID: machineID, name: "FSUAE-Control-Output")
        let statusURL = try exchangeURL(machineID: machineID, name: "FSUAE-Control-Status")
        let transferURL = try exchangeURL(machineID: machineID, name: "FSUAE-Control-Transfer")
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: statusURL)
        if let transfer {
            try transfer.write(to: transferURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: transferURL)
        }
        try payload.write(to: commandURL, options: .atomic)
        let request = UUID().uuidString.lowercased()
        guestCommands[request] = GuestRequest(machineID: machineID, operation: operation)
        guestCommandByMachine[machineID] = request
        return try jsonText(["machine_id": machineID, "request_id": request,
                             "status": "running"])
    }

    private func guestCommandResult(_ arguments: [String: Any]) throws -> String {
        let request = try requiredString("request_id", in: arguments)
        guard let guestRequest = guestCommands[request] else {
            throw MCPFailure("No guest command request \(request)")
        }
        let machineID = guestRequest.machineID
        let statusURL = try exchangeURL(machineID: machineID, name: "FSUAE-Control-Status")
        guard let status = try? Data(contentsOf: statusURL), let byte = status.first else {
            return try jsonText(["machine_id": machineID, "request_id": request,
                                 "status": "running"])
        }
        let outputURL = try exchangeURL(machineID: machineID, name: "FSUAE-Control-Output")
        let output = (try? Data(contentsOf: outputURL)) ?? Data()
        guard output.count <= 16 * 1_048_576 else {
            throw MCPFailure("Command output exceeds 16 MiB")
        }
        guestCommands[request] = nil
        guestCommandByMachine[machineID] = nil
        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(at: statusURL)
        var result: [String: Any] = ["machine_id": machineID, "request_id": request,
                                     "status": "completed", "succeeded": byte == 0x31]
        if guestRequest.operation == .command {
            result["output"] = String(data: output, encoding: .isoLatin1) ?? ""
            result["output_base64"] = output.base64EncodedString()
        }
        let transferURL = try exchangeURL(machineID: machineID, name: "FSUAE-Control-Transfer")
        if guestRequest.operation == .get, byte == 0x31 {
            let data = try Data(contentsOf: transferURL)
            guard data.count <= 16 * 1_048_576 else { throw MCPFailure("File exceeds 16 MiB") }
            result["size"] = data.count
            result["data_base64"] = data.base64EncodedString()
        }
        if guestRequest.operation != .command { try? FileManager.default.removeItem(at: transferURL) }
        return try jsonText(result)
    }

    private func exchangeName(in arguments: [String: Any]) throws -> String {
        let name = try requiredString("name", in: arguments)
        guard name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              !name.contains("\0") else {
            throw MCPFailure("name must be one filename, not a path")
        }
        return name
    }

    private func exchangeURL(machineID: String, name: String) throws -> URL {
        guard workerProcesses[machineID]?.isRunning == true,
              let path = workerExchangePaths[machineID] else {
            throw MCPFailure("No running machine \(machineID)")
        }
        return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(name)
    }

    private func jsonText(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object,
                                               options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func optionalString(_ key: String, in arguments: [String: Any]) -> String? {
        guard let value = arguments[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func requiredString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPFailure("Missing \(key)")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func toolResult(_ text: String, isError: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func success(id: Any, result: Any) -> MCPHTTPReply {
        .init(status: 200, body: json(["jsonrpc": "2.0", "id": id, "result": result]))
    }

    private func failure(id: Any, code: Int, message: String) -> MCPHTTPReply {
        .init(status: 200, body: jsonRPC(id: id, error: code, message: message))
    }

    private func jsonRPC(id: Any, error: Int, message: String) -> Data {
        json(["jsonrpc": "2.0", "id": id,
              "error": ["code": error, "message": message]])
    }

    private func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

private struct MCPFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct MCPUnknownTool: LocalizedError {
    let name: String
    init(_ name: String) { self.name = name }
    var errorDescription: String? { "Unknown tool \(name)" }
}
