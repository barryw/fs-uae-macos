import AppKit
import AppKit
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
    public fileprivate(set) var guestControlGeneration: UInt32 = 0
    public fileprivate(set) var exceptionSequence: UInt64 = 0
    public fileprivate(set) var exceptionVector: UInt32 = 0
    public fileprivate(set) var exceptionPC: UInt32 = 0
    public fileprivate(set) var exceptionAddress: UInt32 = 0
    public fileprivate(set) var exceptionTask: UInt32 = 0
    public fileprivate(set) var debuggerStopped = false
    public fileprivate(set) var exceptionTaskName = ""
}

private struct MCPHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct MacFSUAEGuestStatus: Equatable {
    let succeeded: Bool
    let exitCode: Int?
}

func parseGuestStatus(_ data: Data, token: UInt32) -> MacFSUAEGuestStatus? {
    guard data.count >= 10 else { return nil }
    let responseToken = data[6..<10].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard responseToken == token else { return nil }
    let exitCode: Int? = if data[1] == 0x31 {
        Int(Int32(bitPattern: data[2..<6].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }))
    } else {
        nil
    }
    return MacFSUAEGuestStatus(succeeded: data[0] == 0x31, exitCode: exitCode)
}

func parseDebuggerBreakpoints(_ output: String) -> [UInt32] {
    Array(Set(output.split(whereSeparator: { $0.isWhitespace }).compactMap { token in
        guard token.count == 8, token.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(token, radix: 16)
    })).sorted()
}

public func snapshotLabel(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
    let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:"))
    return trimmed.components(separatedBy: forbidden).joined(separator: "-")
}

public struct MacFSUAESnapshot: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let configuration: String
    public let created: Date
    public let size: Int
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
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                stateChanged(nil)
            case let .failed(error):
                stateChanged(error.localizedDescription)
            case .waiting:
                break
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
    private var workerControlPaths: [String: String] = [:]
    private var workerLaunches: [String: WorkerLaunch] = [:]
    private enum GuestOperation { case command, put, get }
    private struct HDFOverride {
        let drive: Int
        let path: String
        let readOnly: Bool
    }
    private struct WorkerLaunch {
        let presentation: String
        let floppies: [String]?
        let hdfs: [HDFOverride]
    }
    private struct GuestRequest {
        let machineID: String
        let operation: GuestOperation
        let started: Date
        let token: UInt32
        let exceptionSequence: UInt64
        let taskName: String?
        var timedOut = false
        var failure: String?
    }
    private var guestCommands: [String: GuestRequest] = [:]
    private var guestCommandByMachine: [String: String] = [:]
    private var workerOutputBuffers: [String: String] = [:]
    private var workerAcknowledgements: [String: Set<String>] = [:]
    private var workerHealthDates: [String: Date] = [:]
    private var workerGuestHeartbeatDates: [String: Date] = [:]
    private var workerGuestHeartbeats: [String: UInt32] = [:]
    private var workerResetGenerationBaselines: [String: UInt32] = [:]
    private var workerAlertBaselines: [String: [UInt32]] = [:]
    private var debuggerMachines: Set<String> = []
    private var snapshotMachines: Set<String> = []
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

    public func runningMachine(configuration: String) -> MacFSUAERunningMachine? {
        runningMachines.first { $0.configuration == configuration }
    }

    @discardableResult
    public func startPresented(_ configuration: FSUAEConfiguration) throws -> MacFSUAERunningMachine {
        if let existing = presentedMachine(configuration: configuration.name) { return existing }
        if runningMachine(configuration: configuration.name) != nil {
            throw MCPFailure("\(configuration.name) is already running headless")
        }
        return try startWorker(configuration, presentation: "headed")
    }

    public func stop(_ machineID: String) throws {
        guard workerProcesses[machineID] != nil else {
            removeWorker(machineID)
            return
        }
        _ = try stopWorker(machineID)
    }

    public func restart(_ machineID: String,
                        configuration: FSUAEConfiguration) async throws -> MacFSUAERunningMachine {
        guard let launch = workerLaunches[machineID] else {
            throw MCPFailure("No running machine \(machineID)")
        }
        _ = try await stopWorkerAndWait(machineID)
        return try startWorker(configuration, presentation: launch.presentation,
                               floppies: launch.floppies, hdfs: launch.hdfs)
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

    public func snapshots(configuration: String) -> [MacFSUAESnapshot] {
        guard let directory = try? snapshotDirectory(configuration: configuration),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey,
                                                             .contentModificationDateKey,
                                                             .fileSizeKey]) else { return [] }
        return urls.compactMap { snapshot(at: $0, configuration: configuration) }
            .sorted { $0.created > $1.created }
    }

    @discardableResult
    public func saveSnapshot(machineID: String, name: String) async throws -> MacFSUAESnapshot {
        guard let machine = runningMachines.first(where: { $0.id == machineID }) else {
            throw MCPFailure("No running machine \(machineID)")
        }
        guard let label = snapshotLabel(name) else {
            throw MCPFailure("Snapshot name must contain 1 to 80 characters")
        }
        let directory = try snapshotDirectory(configuration: machine.configuration)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
        let token = UUID().uuidString.prefix(8).lowercased()
        let url = directory.appendingPathComponent("\(stamp)-\(token)--\(label).uss")
        try await runSnapshot(machineID, action: "save", url: url)
        guard let value = snapshot(at: url, configuration: machine.configuration) else {
            throw MCPFailure("Snapshot file was not created")
        }
        return value
    }

    public func restoreSnapshot(machineID: String, snapshotID: String) async throws {
        guard let machine = runningMachines.first(where: { $0.id == machineID }) else {
            throw MCPFailure("No running machine \(machineID)")
        }
        let url = try snapshotURL(snapshotID, configuration: machine.configuration)
        try await runSnapshot(machineID, action: "restore", url: url)
    }

    public func deleteSnapshot(configuration: String, snapshotID: String) throws {
        try FileManager.default.removeItem(at: snapshotURL(snapshotID,
                                                            configuration: configuration))
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
                        self.httpServer?.stop()
                        self.httpServer = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            guard let self, self.isEnabled, !self.isRunning,
                                  self.httpServer == nil else { return }
                            self.startServer()
                        }
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

    func handleMCPRequest(_ data: Data) async -> MCPHTTPReply {
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
                let result = name == "fsuae_screen_capture"
                    ? try screenCaptureToolResult(arguments)
                    : toolResult(try await callTool(name, arguments: arguments))
                return success(id: id, result: result)
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
            tool("fsuae_machine_start", "Start a machine using an exact saved configuration name. Optionally replace its startup floppy set or attach disposable HDFs without changing the saved configuration.", [
                "type": "object",
                "properties": [
                    "configuration": ["type": "string", "description": "Saved configuration name"],
                    "floppies": ["type": "array", "maxItems": 4,
                                  "items": ["type": "string"],
                                  "description": "Exact DF0-DF3 startup paths; omitted drives are ejected"],
                    "hdf": [
                        "type": "object",
                        "properties": [
                            "path": ["type": "string", "description": "Absolute host path to an existing block-aligned HDF"],
                            "drive": ["type": "integer", "minimum": 0, "maximum": 9,
                                      "description": "Unused DH0-DH9 slot; defaults to the first unused slot"],
                            "read_only": ["type": "boolean", "default": false],
                        ],
                        "required": ["path"], "additionalProperties": false,
                    ],
                    "hdfs": [
                        "type": "array", "maxItems": 10,
                        "items": [
                            "type": "object",
                            "properties": [
                                "path": ["type": "string", "description": "Absolute host path to an existing block-aligned HDF"],
                                "drive": ["type": "integer", "minimum": 0, "maximum": 9,
                                          "description": "Unused DH0-DH9 slot; defaults to the first unused slot"],
                                "read_only": ["type": "boolean", "default": false],
                            ],
                            "required": ["path"], "additionalProperties": false,
                        ],
                        "description": "Disposable HDF attachments; mutually exclusive with hdf",
                    ],
                ],
                "required": ["configuration"], "additionalProperties": false,
            ]),
            tool("fsuae_machine_stop", "Stop a machine by machine id or configuration name. Omit both when only one machine is running.",
                 stringSchema(["machine_id": "Machine UUID returned by start",
                               "configuration": "Exact saved configuration name"],
                              required: [])),
            tool("fsuae_machines_list", "List running machines, their UUIDs, configurations, presentation modes, and statuses.", empty),
            tool("fsuae_machine_wait", "Wait until Workbench is open and ready for interaction, without relying on a fixed boot delay.", [
                "type": "object",
                "properties": [
                    "machine_id": ["type": "string", "description": "Running machine UUID"],
                    "condition": ["type": "string", "enum": ["workbench"],
                                  "description": "Readiness condition"],
                    "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 300,
                                        "default": 120],
                ],
                "required": ["machine_id", "condition"], "additionalProperties": false,
            ]),
            tool("fsuae_floppy_set", "Insert or eject a floppy in a running machine. Omit path to eject the selected drive.", [
                "type": "object",
                "properties": [
                    "machine_id": ["type": "string", "description": "Running machine UUID"],
                    "drive": ["type": "integer", "minimum": 0, "maximum": 3,
                              "description": "Floppy drive number: 0 is DF0"],
                    "path": ["type": "string", "description": "Readable host ADF path; omit to eject"],
                ],
                "required": ["machine_id", "drive"], "additionalProperties": false,
            ]),
            tool("fsuae_machine_reset", "Reset one machine. A hard reset also clears a timed-out or faulted guest command so automation can recover deterministically.", [
                "type": "object",
                "properties": [
                    "machine_id": ["type": "string", "description": "Running machine UUID"],
                    "hard": ["type": "boolean", "default": true],
                ],
                "required": ["machine_id"], "additionalProperties": false,
            ]),
            tool("fsuae_machine_diagnostics", "Return one machine's health, timed-out guest request, Guru alert data, CPU registers, instruction history, and Exec task state.",
                 stringSchema(["machine_id": "Running machine UUID"],
                              required: ["machine_id"])),
            tool("fsuae_screen_capture", "Capture the latest visible Amiga frame as a cropped PNG image. Works for headed and headless machines.",
                 stringSchema(["machine_id": "Running machine UUID"],
                              required: ["machine_id"])),
            tool("fsuae_input", "Queue one keyboard or relative mouse event on a running machine.", [
                "type": "object",
                "properties": [
                    "machine_id": ["type": "string", "description": "Running machine UUID"],
                    "event": ["type": "string", "enum": ["key", "mouse_move", "mouse_button", "mouse_click"]],
                    "code": ["type": "integer", "minimum": 0, "maximum": 65535,
                             "description": "macOS virtual key code for a key event"],
                    "pressed": ["type": "boolean", "description": "Key or mouse-button state"],
                    "delta_x": ["type": "integer", "minimum": -32768, "maximum": 32767],
                    "delta_y": ["type": "integer", "minimum": -32768, "maximum": 32767],
                    "x": ["type": "integer", "minimum": 0, "maximum": 32767,
                          "description": "Absolute guest-screen x for mouse_click"],
                    "y": ["type": "integer", "minimum": 0, "maximum": 32767,
                          "description": "Absolute guest-screen y for mouse_click"],
                    "button": ["type": "integer", "minimum": 0, "maximum": 2,
                               "description": "Mouse button: 0 left, 1 middle, 2 right"],
                ],
                "required": ["machine_id", "event"], "additionalProperties": false,
            ]),
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
                               "command": "AmigaDOS command line (4085-byte maximum)"],
                              required: ["machine_id", "command"])),
            tool("fsuae_command_execute", "Run a program or AmigaDOS command, wait for completion, and return captured output and a truthful exit-code status. DOS 1.x reports exit_code_known=false because Execute only reports launch success.", [
                "type": "object",
                "properties": [
                    "machine_id": ["type": "string", "description": "Running machine UUID"],
                    "command": ["type": "string", "description": "Program or AmigaDOS command line (4085-byte maximum)"],
                    "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 300,
                                        "default": 30, "description": "Maximum wait before returning a pollable request id"],
                ],
                "required": ["machine_id", "command"], "additionalProperties": false,
            ]),
            tool("fsuae_command_result", "Poll a guest command request for captured output.",
                 stringSchema(["request_id": "Request UUID returned by fsuae_command_run"],
                              required: ["request_id"])),
            tool("fsuae_debug_command", "Execute one built-in UAE debugger command at an emulator-thread boundary. Use breakpoints before launching a program, then inspect or step it without terminal interaction.",
                 stringSchema(["machine_id": "Running machine UUID",
                               "command": "UAE debugger command, for example r, d ADDRESS, m ADDRESS, f ADDRESS, t, z, or g"],
                              required: ["machine_id", "command"])),
            tool("fsuae_debug_snapshot", "Capture CPU registers, recent instruction history, and Exec task state in one debugger-safe operation.",
                 stringSchema(["machine_id": "Running machine UUID"],
                              required: ["machine_id"])),
            tool("fsuae_debug_breakpoints", "Set, remove, list, or clear instruction breakpoints without toggle ambiguity.", [
                "type": "object",
                "properties": [
                    "machine_id": ["type": "string", "description": "Running machine UUID"],
                    "action": ["type": "string", "enum": ["set", "remove", "list", "clear"]],
                    "address": ["type": "string",
                                "description": "Hex address required by set and remove"],
                ],
                "required": ["machine_id", "action"], "additionalProperties": false,
            ]),
            tool("fsuae_debug_execution", "Continue, single-step, or step over code in a debugger-stopped machine.", [
                "type": "object",
                "properties": [
                    "machine_id": ["type": "string", "description": "Running machine UUID"],
                    "action": ["type": "string", "enum": ["continue", "step", "step_over"]],
                    "instructions": ["type": "integer", "minimum": 1, "maximum": 10000,
                                     "default": 1],
                ],
                "required": ["machine_id", "action"], "additionalProperties": false,
            ]),
            tool("fsuae_debug_wait", "Wait for a breakpoint, step, or exception to stop the emulator, then return a debugger snapshot and source location.", [
                "type": "object",
                "properties": [
                    "machine_id": ["type": "string", "description": "Running machine UUID"],
                    "timeout_seconds": ["type": "integer", "minimum": 1, "maximum": 300,
                                        "default": 30],
                ],
                "required": ["machine_id"], "additionalProperties": false,
            ]),
            tool("fsuae_machine_inspect", "Inspect host-side CPU, history, tasks, chipset, Copper, or memory state without the guest service.", [
                "type": "object",
                "properties": [
                    "machine_id": ["type": "string", "description": "Running machine UUID"],
                    "domains": ["type": "array", "uniqueItems": true,
                                "items": ["type": "string",
                                          "enum": ["cpu", "history", "tasks", "hardware",
                                                   "custom", "copper", "memory", "performance"]]],
                    "address": ["type": "string",
                                "description": "Hex start address for memory; defaults to PC"],
                    "lines": ["type": "integer", "minimum": 1, "maximum": 256,
                              "default": 16],
                ],
                "required": ["machine_id"], "additionalProperties": false,
            ]),
            tool("fsuae_snapshot_save", "Save a named snapshot of a running machine to a new .uss state file.",
                 stringSchema(["machine_id": "Running machine UUID",
                               "name": "Snapshot name (1 to 80 characters)"],
                              required: ["machine_id", "name"])),
            tool("fsuae_snapshots_list", "List all saved snapshots for a configuration.",
                 stringSchema(["configuration": "Configuration name"],
                              required: ["configuration"])),
            tool("fsuae_snapshot_restore", "Restore a saved snapshot into its running machine. Current unsaved machine state is replaced.",
                 stringSchema(["machine_id": "Running machine UUID",
                               "snapshot_id": "Snapshot id returned by fsuae_snapshots_list"],
                              required: ["machine_id", "snapshot_id"])),
            tool("fsuae_snapshot_delete", "Permanently delete a saved snapshot.",
                 stringSchema(["configuration": "Configuration name",
                               "snapshot_id": "Snapshot id returned by fsuae_snapshots_list"],
                              required: ["configuration", "snapshot_id"])),
            tool("fsuae_debug_tracking", "Turn LoadSeg tracking on or off. Only seglists loaded while it is on can be mapped back to a hunk, symbol and source line, so turn it on and reset before launching the program under test.", [
                "type": "object",
                "properties": [
                    "machine_id": ["type": "string", "description": "Running machine UUID"],
                    "enabled": ["type": "boolean", "default": true],
                ],
                "required": ["machine_id"], "additionalProperties": false,
            ]),
            tool("fsuae_debug_segments", "List the seglists the segment tracker has recorded, with each segment's address range and how much debug info is attached to it.",
                 stringSchema(["machine_id": "Running machine UUID",
                               "match": "Optional case-insensitive substring of the seglist name"],
                              required: ["machine_id"])),
            tool("fsuae_debug_symbols", "Attach symbols and source lines to a tracked seglist by reading hunk debug info from the same executable's file on this Mac.",
                 stringSchema(["machine_id": "Running machine UUID",
                               "seglist": "Seglist name exactly as fsuae_debug_segments reports it, for example SYS:Barry/spinner",
                               "host_path": "Path on this Mac to the same executable, linked with debug hunks"],
                              required: ["machine_id", "seglist", "host_path"])),
            tool("fsuae_debug_resolve", "Map an Amiga address onto its seglist, segment, nearest symbol and source line. Run it on the faulting PC from fsuae_machine_diagnostics to turn a Guru into a file and line.",
                 stringSchema(["machine_id": "Running machine UUID",
                               "address": "Amiga address in hex, with or without a 0x prefix"],
                              required: ["machine_id", "address"])),
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

    private func callTool(_ name: String, arguments: [String: Any]) async throws -> String {
        library.reload()
        switch name {
        case "fsuae_machine_start":
            let requested = try requiredString("configuration", in: arguments)
            guard let configuration = library.configuration(named: requested) else {
                throw MCPFailure("No configuration named \(requested)")
            }
            let floppies = try floppyPaths(in: arguments)
            let hdfs = try hdfOverrides(in: arguments, configuration: configuration)
            let machine = try startWorker(configuration,
                                          presentation: isHeadless ? "headless" : "headed",
                                          floppies: floppies, hdfs: hdfs)
            let attachment = hdfs.map {
                "; hdf DH\($0.drive)=\($0.path) (\($0.readOnly ? "read-only" : "read-write"))"
            }.joined()
            return "Started \(configuration.name) (\(configuration.model)); machine_id \(machine.id); pid \(machine.processIdentifier)\(attachment)"
        case "fsuae_machine_stop":
            return try await stopMachine(arguments)
        case "fsuae_machines_list":
            return try machinesJSON()
        case "fsuae_machine_wait":
            return try await waitForMachine(arguments)
        case "fsuae_floppy_set":
            return try await setFloppy(arguments)
        case "fsuae_machine_reset":
            return try resetMachine(arguments)
        case "fsuae_machine_diagnostics":
            return try await machineDiagnostics(arguments)
        case "fsuae_input":
            return try await queueInput(arguments)
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
            return try await guestCommandRun(arguments)
        case "fsuae_command_execute":
            return try await guestCommandExecute(arguments)
        case "fsuae_command_result":
            return try guestCommandResult(arguments)
        case "fsuae_debug_command":
            return try await debuggerExecute(arguments, snapshot: false)
        case "fsuae_debug_snapshot":
            return try await debuggerExecute(arguments, snapshot: true)
        case "fsuae_debug_breakpoints":
            return try await debugBreakpoints(arguments)
        case "fsuae_debug_execution":
            return try await debugExecution(arguments)
        case "fsuae_debug_wait":
            return try await debugWait(arguments)
        case "fsuae_machine_inspect":
            return try await machineInspect(arguments)
        case "fsuae_snapshot_save":
            let value = try await saveSnapshot(
                machineID: requiredString("machine_id", in: arguments),
                name: requiredString("name", in: arguments))
            return try snapshotJSON(value)
        case "fsuae_snapshots_list":
            let values = snapshots(configuration: try requiredString("configuration", in: arguments))
            return try jsonText(["snapshots": values.map(snapshotDictionary)])
        case "fsuae_snapshot_restore":
            try await restoreSnapshot(
                machineID: requiredString("machine_id", in: arguments),
                snapshotID: requiredString("snapshot_id", in: arguments))
            return "Snapshot restored"
        case "fsuae_snapshot_delete":
            try deleteSnapshot(
                configuration: requiredString("configuration", in: arguments),
                snapshotID: requiredString("snapshot_id", in: arguments))
            return "Snapshot deleted"
        case "fsuae_debug_tracking":
            return try await debugTracking(arguments)
        case "fsuae_debug_segments":
            return try await debugSegments(arguments)
        case "fsuae_debug_symbols":
            return try await debugSymbols(arguments)
        case "fsuae_debug_resolve":
            return try await debugResolve(arguments)
        case "fsuae_file_put":
            return try await guestFilePut(arguments)
        case "fsuae_file_get":
            return try await guestFileGet(arguments)
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
                             presentation: String,
                             floppies: [String]? = nil,
                             hdfs: [HDFOverride] = []) throws -> MacFSUAERunningMachine {
        guard let executable = workerExecutable else {
            throw MCPFailure("FS-UAE Worker is missing")
        }
        let id = UUID().uuidString.lowercased()
        let process = Process()
        process.executableURL = executable
        process.arguments = [configuration.url.path]
        var environment = ProcessInfo.processInfo.environment
        let controlPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsuae-\(id)-control", isDirectory: true).path
        do {
            try FileManager.default.createDirectory(atPath: controlPath,
                                                    withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw MCPFailure("Could not create the debugger control directory")
        }
        environment["FSUAE_MAC_CONTROL_DIRECTORY"] = controlPath
        var exchangePath: String?
        if configuration.hostIntegrationEnabled {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("fsuae-\(id)-exchange", isDirectory: true).path
            do {
                try FileManager.default.createDirectory(atPath: path,
                                                        withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                for tool in ["FSUAE-Diag", "FSUAE-WaitWB"] {
                    if let source = Bundle.main.url(forResource: tool, withExtension: nil,
                                                    subdirectory: "Amiga") {
                        try FileManager.default.copyItem(at: source,
                                                         to: URL(fileURLWithPath: path)
                                                            .appendingPathComponent(tool))
                    }
                }
            } catch {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: controlPath)
                throw MCPFailure("Could not create the MCP: exchange volume")
            }
            exchangePath = path
            environment["FSUAE_MAC_EXCHANGE_DIRECTORY"] = path
        }
        let framePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsuae-\(id).frame").path
        guard let transport = MacFSUAEFrameTransport(creating: framePath) else {
            try? FileManager.default.removeItem(atPath: controlPath)
            throw MCPFailure("Could not create the display channel")
        }
        environment["FSUAE_MAC_FRAME_FILE"] = framePath
        if presentation == "headless" {
            environment["FSUAE_MAC_ABSOLUTE_MOUSE"] = "1"
        }
        if let floppies {
            for drive in 0..<4 {
                environment["FSUAE_MAC_FLOPPY_\(drive)"] = drive < floppies.count
                    ? floppies[drive] : ""
            }
        }
        for hdf in hdfs {
            environment["FSUAE_MAC_HARD_DRIVE_\(hdf.drive)"] = hdf.path
            environment["FSUAE_MAC_HARD_DRIVE_\(hdf.drive)_READ_ONLY"] =
                hdf.readOnly ? "1" : "0"
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
            try? FileManager.default.removeItem(atPath: framePath)
            if let exchangePath { try? FileManager.default.removeItem(atPath: exchangePath) }
            try? FileManager.default.removeItem(atPath: controlPath)
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
        workerTransports[id] = transport
        workerFrameSources[id] = MacFSUAEFrameSource(transport: transport)
        workerFramePaths[id] = framePath
        workerControlPaths[id] = controlPath
        workerLaunches[id] = WorkerLaunch(presentation: presentation,
                                          floppies: floppies, hdfs: hdfs)
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

    private func stopMachine(_ arguments: [String: Any]) async throws -> String {
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
            return try await stopWorkerAndWait(requestedMachine)
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
            return try await stopWorkerAndWait(matches[0].id)
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
        return try await stopWorkerAndWait(runningMachines[0].id)
    }

    private func stopWorkerAndWait(_ id: String) async throws -> String {
        guard let process = workerProcesses[id] else { throw MCPFailure("No running machine \(id)") }
        _ = try stopWorker(id)
        var deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while process.isRunning && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        guard !process.isRunning else {
            throw MCPFailure("Machine \(id) did not stop after SIGKILL")
        }
        removeWorker(id)
        return "Stopped machine \(id)"
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
        for path in workerControlPaths.values { try? FileManager.default.removeItem(atPath: path) }
        workerControlPaths.removeAll()
        workerLaunches.removeAll()
        guestCommands.removeAll()
        guestCommandByMachine.removeAll()
        workerOutputBuffers.removeAll()
        workerAcknowledgements.removeAll()
        workerHealthDates.removeAll()
        workerGuestHeartbeatDates.removeAll()
        workerGuestHeartbeats.removeAll()
        workerResetGenerationBaselines.removeAll()
        workerAlertBaselines.removeAll()
        runningMachines.removeAll()
    }

    private func removeWorker(_ id: String) {
        clearGuestRequest(id)
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
        if let path = workerControlPaths.removeValue(forKey: id) {
            try? FileManager.default.removeItem(atPath: path)
        }
        workerLaunches[id] = nil
        workerOutputBuffers[id] = nil
        workerAcknowledgements[id] = nil
        workerHealthDates[id] = nil
        workerGuestHeartbeatDates[id] = nil
        workerGuestHeartbeats[id] = nil
        workerResetGenerationBaselines[id] = nil
        workerAlertBaselines[id] = nil
        runningMachines.removeAll { $0.id == id }
        if selectedPresentedMachineID == id { selectedPresentedMachineID = nil }
    }

    private func clearGuestRequest(_ machineID: String) {
        if let request = guestCommandByMachine.removeValue(forKey: machineID) {
            guestCommands[request] = nil
        }
        guard let path = workerExchangePaths[machineID] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        for name in ["FSUAE-Control-Command", "FSUAE-Control-Output",
                     "FSUAE-Control-Status", "FSUAE-Control-Transfer"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
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
            } else if line.hasPrefix("FSUAE_ACK ") {
                workerAcknowledgements[id, default: []]
                    .insert(String(line.dropFirst("FSUAE_ACK ".count)))
            }
        }
        workerOutputBuffers[id] = String(buffer.suffix(4096))
    }

    private func consumeDrives(_ id: String, encoded: String) {
        guard NSApp.mainMenu?.highlightedItem == nil,
              let data = Data(base64Encoded: encoded),
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
        guard NSApp.mainMenu?.highlightedItem == nil,
              fields.count == 18,
              let sequence = UInt64(fields[1]),
              let pc = UInt32(fields[2]),
              let execBase = UInt32(fields[3]),
              let guestHeartbeat = UInt32(fields[9]),
              let guestGeneration = UInt32(fields[10]),
              let exceptionSequence = UInt64(fields[11]),
              let exceptionVector = UInt32(fields[12]),
              let exceptionPC = UInt32(fields[13]),
              let exceptionAddress = UInt32(fields[14]),
              let exceptionTask = UInt32(fields[15]) else { return }
        let alert = fields[4...7].compactMap { UInt32($0) }
        guard alert.count == 4,
              let index = runningMachines.firstIndex(where: { $0.id == id }) else { return }
        runningMachines[index].frameSequence = sequence
        runningMachines[index].programCounter = pc
        runningMachines[index].execBase = execBase
        runningMachines[index].lastAlert = alert
        runningMachines[index].exceptionSequence = exceptionSequence
        runningMachines[index].exceptionVector = exceptionVector
        runningMachines[index].exceptionPC = exceptionPC
        runningMachines[index].exceptionAddress = exceptionAddress
        runningMachines[index].exceptionTask = exceptionTask
        runningMachines[index].debuggerStopped = fields[17] == "1"
        runningMachines[index].exceptionTaskName = fields[16] == "-" ? "" :
            Data(base64Encoded: String(fields[16])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        runningMachines[index].guestControlGeneration = guestGeneration
        let now = Date()
        if workerGuestHeartbeats[id] == nil {
            workerGuestHeartbeats[id] = guestHeartbeat
            if guestHeartbeat != 0 { workerGuestHeartbeatDates[id] = now }
        } else if workerGuestHeartbeats[id] != guestHeartbeat {
            workerGuestHeartbeats[id] = guestHeartbeat
            workerGuestHeartbeatDates[id] = now
        }
        let resetPending: Bool
        if let baseline = workerResetGenerationBaselines[id], guestGeneration != baseline {
            workerResetGenerationBaselines[id] = nil
            workerAlertBaselines[id] = alert
            if runningMachines[index].status == "booting" {
                runningMachines[index].status = "running"
            }
            resetPending = false
        } else {
            resetPending = workerResetGenerationBaselines[id] != nil
        }
        runningMachines[index].guestControlReady = !resetPending && fields[8] == "1" &&
            now.timeIntervalSince(workerGuestHeartbeatDates[id] ?? now) < 3
        workerHealthDates[id] = now
        if execBase != 0 {
            if let baseline = workerAlertBaselines[id], alert != baseline,
               alert[0] != 0, alert[0] != UInt32.max {
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
                    if health.lastAlert != foregroundAlertBaseline,
                       health.lastAlert[0] != 0, health.lastAlert[0] != UInt32.max {
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
        let guestControlAge = workerGuestHeartbeatDates[machine.id].map {
            Date().timeIntervalSince($0)
        }
        let stale = (machine.status == "running" && (heartbeatAge ?? 0) > 10) ||
            (machine.status == "booting" && (heartbeatAge ?? 0) > 10)
        var status = stale ? "unresponsive" : machine.status
        var row: [String: Any] = [
            "machine_id": machine.id, "configuration": machine.configuration,
            "model": machine.model, "pid": machine.processIdentifier,
            "presentation": machine.presentation, "status": status,
            "frame_sequence": machine.frameSequence,
            "program_counter": String(format: "0x%08x", machine.programCounter),
            "guest_control_ready": machine.guestControlReady,
            "guest_control_generation": machine.guestControlGeneration,
            "debugger_stopped": machine.debuggerStopped,
        ]
        if let heartbeatAge { row["health_age_seconds"] = heartbeatAge }
        if let guestControlAge { row["guest_control_age_seconds"] = guestControlAge }
        if machine.exceptionVector != 0 {
            var exception: [String: Any] = [
                "sequence": machine.exceptionSequence,
                "vector": machine.exceptionVector,
                "name": exceptionName(machine.exceptionVector),
                "faulting_pc": String(format: "0x%08x", machine.exceptionPC),
                "task": String(format: "0x%08x", machine.exceptionTask),
            ]
            if machine.exceptionAddress != 0 {
                exception["fault_address"] = String(format: "0x%08x",
                                                      machine.exceptionAddress)
            }
            if !machine.exceptionTaskName.isEmpty {
                exception["task_name"] = machine.exceptionTaskName
            }
            row["cpu_exception"] = exception
        }
        if let requestID = guestCommandByMachine[machine.id],
           let request = guestCommands[requestID] {
            row["guest_request_id"] = requestID
            row["guest_command_age_seconds"] = Date().timeIntervalSince(request.started)
            row["guest_command_status"] = request.failure != nil ? "failed" :
                request.timedOut ? "timeout" : "running"
            if let failure = request.failure {
                row["guest_command_failure"] = failure
                if status != "guruing" { row["status"] = "guest_service_failed" }
            } else if request.timedOut, status != "guruing" {
                status = exceptionBelongsToGuestCommand(machine, request) &&
                    (guestControlAge ?? 0) > 3
                    ? "guest_crashed" : "guest_command_timed_out"
                row["status"] = status
            }
        }
        if machine.execBase != 0 {
            row["exec_base"] = String(format: "0x%08x", machine.execBase)
            if machine.lastAlert[0] != 0, machine.lastAlert[0] != UInt32.max {
                row["last_alert"] = machine.lastAlert.map { String(format: "0x%08x", $0) }
            }
        }
        return row
    }

    private func exceptionName(_ vector: UInt32) -> String {
        switch vector {
        case 2: "bus_error"
        case 3: "address_error"
        case 4: "illegal_instruction"
        case 5: "division_by_zero"
        case 6: "chk"
        case 7: "trapv"
        case 8: "privilege_violation"
        case 10: "line_a"
        case 11: "line_f"
        case 14: "format_error"
        default: "exception_\(vector)"
        }
    }

    private func machineDiagnostics(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        guard let machine = runningMachines.first(where: { $0.id == machineID }) else {
            throw MCPFailure("No running machine \(machineID)")
        }
        var result = machineRow(machine)
        let debugger = try await debuggerExecute(["machine_id": machineID], snapshot: true)
        if let data = debugger.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            result["debugger"] = object
        }
        // A Guru is only actionable once the faulting PC has a name, so resolve
        // it here rather than making the caller know to ask. Silent when the
        // segment tracker has nothing covering the address.
        if var exception = result["cpu_exception"] as? [String: Any],
           let location = try? await resolveAddress(machineID, machine.exceptionPC),
           location["found"] as? Bool == true {
            exception["location"] = location
            result["cpu_exception"] = exception
        }
        return try jsonText(result)
    }

    private func queueInput(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        guard workerProcesses[machineID]?.isRunning == true else {
            throw MCPFailure("No running machine \(machineID)")
        }
        let event = try requiredString("event", in: arguments)
        let command: [String: Any]
        switch event {
        case "key":
            guard let code = arguments["code"] as? Int, (0...65535).contains(code),
                  let pressed = arguments["pressed"] as? Bool else {
                throw MCPFailure("key requires code 0...65535 and pressed")
            }
            command = ["command": "key", "code": code, "pressed": pressed]
        case "mouse_move":
            guard let deltaX = arguments["delta_x"] as? Int, (-32768...32767).contains(deltaX),
                  let deltaY = arguments["delta_y"] as? Int, (-32768...32767).contains(deltaY) else {
                throw MCPFailure("mouse_move requires delta_x and delta_y in -32768...32767")
            }
            command = ["command": "mouse_move", "x": deltaX, "y": deltaY]
        case "mouse_button":
            guard let button = arguments["button"] as? Int, (0...2).contains(button),
                  let pressed = arguments["pressed"] as? Bool else {
                throw MCPFailure("mouse_button requires button 0...2 and pressed")
            }
            command = ["command": "mouse_button", "button": button, "pressed": pressed]
        case "mouse_click":
            guard let x = arguments["x"] as? Int, (0...32767).contains(x),
                  let y = arguments["y"] as? Int, (0...32767).contains(y),
                  let button = arguments["button"] as? Int, (0...2).contains(button) else {
                throw MCPFailure("mouse_click requires x, y in 0...32767 and button 0...2")
            }
            var frame: MacFSUAEFrame?
            for _ in 0..<40 {
                frame = workerFrameSources[machineID]?.latest(after: 0)
                if frame != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            guard let frame else {
                throw MCPFailure("No video frame became available for machine \(machineID)")
            }
            let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
            let crop = (frame.crop.isEmpty ? bounds : frame.crop).integral.intersection(bounds)
            guard x < Int(crop.width), y < Int(crop.height) else {
                throw MCPFailure("mouse_click coordinates are outside the captured frame")
            }
            guard sendWorkerCommand(machineID, ["command": "mouse_position",
                                                 "x": x + Int(crop.minX),
                                                 "y": y + Int(crop.minY)]) else {
                throw MCPFailure("Could not position the mouse on machine \(machineID)")
            }
            try await Task.sleep(for: .milliseconds(50))
            guard sendWorkerCommand(machineID, ["command": "mouse_button", "button": button, "pressed": true]) else {
                throw MCPFailure("Could not press the mouse button on machine \(machineID)")
            }
            try await Task.sleep(for: .milliseconds(75))
            guard sendWorkerCommand(machineID, ["command": "mouse_button", "button": button, "pressed": false]) else {
                throw MCPFailure("Could not release the mouse button on machine \(machineID)")
            }
            return "Queued mouse_click on machine \(machineID)"
        default:
            throw MCPFailure("event must be key, mouse_move, mouse_button, or mouse_click")
        }
        guard sendWorkerCommand(machineID, command) else {
            throw MCPFailure("Could not queue input on machine \(machineID)")
        }
        return "Queued \(event) on machine \(machineID)"
    }

    private func waitForMachine(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        guard try requiredString("condition", in: arguments) == "workbench" else {
            throw MCPFailure("condition must be workbench")
        }
        let timeout = arguments["timeout_seconds"] as? Int ?? 120
        guard (1...300).contains(timeout) else {
            throw MCPFailure("timeout_seconds must be between 1 and 300")
        }
        guard workerProcesses[machineID]?.isRunning == true else {
            throw MCPFailure("No running machine \(machineID)")
        }

        let started = Date()
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while runningMachines.first(where: { $0.id == machineID })?.guestControlReady != true {
            guard workerProcesses[machineID]?.isRunning == true else {
                throw MCPFailure("Machine \(machineID) stopped while booting")
            }
            if let failure = guestFailure(machineID) {
                throw MCPFailure("Machine \(machineID) failed while booting: \(failure)")
            }
            guard ContinuousClock.now < deadline else {
                throw MCPFailure("Workbench did not become ready within \(timeout) seconds; guest control never became available")
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        while ContinuousClock.now < deadline {
            let remaining = max(1, Int(started.addingTimeInterval(TimeInterval(timeout))
                .timeIntervalSinceNow.rounded(.down)))
            do {
                let response = try await guestCommandExecute([
                    "machine_id": machineID,
                    "command": "MCP:FSUAE-WaitWB \(remaining)",
                    "timeout_seconds": remaining,
                ])
                if let data = response.data(using: .utf8),
                   let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if result["status"] as? String == "timeout" {
                        throw MCPFailure("Workbench did not become ready within \(timeout) seconds")
                    }
                    guard (result["output"] as? String)?.contains("WORKBENCH_READY") == true else {
                        try await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    let heartbeat = workerGuestHeartbeats[machineID]
                    try await waitForGuestControl(machineID, after: heartbeat)
                    return try jsonText(["machine_id": machineID, "condition": "workbench",
                                         "status": "ready",
                                         "elapsed_seconds": Date().timeIntervalSince(started)])
                }
            } catch let failure as MCPFailure
                where failure.message.hasPrefix("Guest control is not ready") {
                // The new guest process can exist briefly before DOS can launch tools.
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MCPFailure("Workbench did not become ready within \(timeout) seconds")
    }

    private func setFloppy(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        guard let drive = arguments["drive"] as? Int, (0...3).contains(drive) else {
            throw MCPFailure("drive must be between 0 and 3")
        }
        let path = try validatedFloppyPath(arguments["path"] as? String ?? "")
        guard workerProcesses[machineID]?.isRunning == true,
              sendWorkerCommand(machineID, ["command": "floppy", "drive": drive,
                                             "path": path]) else {
            throw MCPFailure("No running machine \(machineID)")
        }
        if path.isEmpty,
           runningMachines.first(where: { $0.id == machineID })?.drives
            .contains(where: { $0.kind == .floppy && $0.index == drive }) != true {
            return try jsonText(["machine_id": machineID, "drive": "DF\(drive)",
                                 "status": "ejected"])
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        repeat {
            if let mounted = runningMachines.first(where: { $0.id == machineID })?.drives
                .first(where: { $0.kind == .floppy && $0.index == drive })?.mediaPath,
               mounted == path {
                return try jsonText(["machine_id": machineID, "drive": "DF\(drive)",
                                     "status": path.isEmpty ? "ejected" : "inserted",
                                     "path": path])
            }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        throw MCPFailure("DF\(drive) did not acknowledge the media change")
    }

    private func resetMachine(_ arguments: [String: Any]) throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let hard = arguments["hard"] as? Bool ?? true
        guard workerProcesses[machineID]?.isRunning == true,
              sendWorkerCommand(machineID, ["command": "reset", "hard": hard]) else {
            throw MCPFailure("No running machine \(machineID)")
        }
        if let index = runningMachines.firstIndex(where: { $0.id == machineID }) {
            workerResetGenerationBaselines[machineID] =
                runningMachines[index].guestControlGeneration
            runningMachines[index].guestControlReady = false
            runningMachines[index].status = "booting"
            runningMachines[index].exceptionVector = 0
            runningMachines[index].exceptionPC = 0
            runningMachines[index].exceptionAddress = 0
            runningMachines[index].exceptionTask = 0
            runningMachines[index].exceptionTaskName = ""
        }
        clearGuestRequest(machineID)
        return try jsonText(["machine_id": machineID,
                             "status": hard ? "hard_reset" : "reset"])
    }

    private func floppyPaths(in arguments: [String: Any]) throws -> [String]? {
        guard let value = arguments["floppies"] else { return nil }
        guard let paths = value as? [String], paths.count <= 4 else {
            throw MCPFailure("floppies must contain at most four paths")
        }
        return try paths.map(validatedFloppyPath)
    }

    private func hdfOverrides(in arguments: [String: Any],
                              configuration: FSUAEConfiguration) throws -> [HDFOverride] {
        guard arguments["hdf"] == nil || arguments["hdfs"] == nil else {
            throw MCPFailure("hdf and hdfs are mutually exclusive")
        }
        let values: [[String: Any]]
        if let value = arguments["hdf"] {
            guard let hdf = value as? [String: Any] else { throw MCPFailure("hdf must be an object") }
            values = [hdf]
        } else if let value = arguments["hdfs"] {
            guard let hdfs = value as? [[String: Any]], hdfs.count <= 10 else {
                throw MCPFailure("hdfs must contain at most ten attachments")
            }
            values = hdfs
        } else {
            return []
        }

        var used = Set<Int>()
        return try values.map { hdf in
            guard let path = hdf["path"] as? String, !path.contains("\0"), path.hasPrefix("/") else {
                throw MCPFailure("hdf.path must be an absolute host path")
            }
            let drive = hdf["drive"] as? Int ?? (0..<10).first {
                configuration.value(for: "hard_drive_\($0)")?.isEmpty != false && !used.contains($0)
            }
            guard let drive, (0..<10).contains(drive), !used.contains(drive) else {
                throw MCPFailure("hdf.drive must identify an unused DH0-DH9 slot")
            }
            guard configuration.value(for: "hard_drive_\(drive)")?.isEmpty != false else {
                throw MCPFailure("DH\(drive) is already used by \(configuration.name)")
            }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey,
                                                             .fileSizeKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                  let size = metadata.fileSize, size >= 512, size.isMultiple(of: 512),
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw MCPFailure("hdf.path must be a readable, non-symlinked file whose size is a multiple of 512 bytes")
            }
            let readOnly = hdf["read_only"] as? Bool ?? false
            guard readOnly || FileManager.default.isWritableFile(atPath: url.path) else {
                throw MCPFailure("hdf.path is not writable; set read_only to true")
            }
            used.insert(drive)
            return HDFOverride(drive: drive, path: url.path, readOnly: readOnly)
        }
    }

    private func validatedFloppyPath(_ path: String) throws -> String {
        guard !path.contains("\0") else { throw MCPFailure("Floppy path contains a NUL byte") }
        guard !path.isEmpty else { return "" }
        guard path.hasPrefix("/"), FileManager.default.isReadableFile(atPath: path) else {
            throw MCPFailure("Floppy path must be an absolute, readable file")
        }
        return path
    }

    private func screenCaptureToolResult(_ arguments: [String: Any]) throws -> [String: Any] {
        let machineID = try requiredString("machine_id", in: arguments)
        guard workerProcesses[machineID]?.isRunning == true,
              let frame = workerFrameSources[machineID]?.latest(after: 0) else {
            throw MCPFailure("No video frame is available for machine \(machineID)")
        }
        let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let requested = frame.crop.isEmpty ? bounds : frame.crop
        let crop = requested.integral.intersection(bounds)
        let x = Int(crop.minX), y = Int(crop.minY)
        let width = Int(crop.width), height = Int(crop.height)
        guard width > 0, height > 0 else { throw MCPFailure("Video crop is empty") }

        var pixels = Data(capacity: width * height * 4)
        for row in y..<(y + height) {
            let start = row * frame.stride + x * 4
            pixels.append(frame.pixels[start..<(start + width * 4)])
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: .byteOrder32Little.union(
                    CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:]) else {
            throw MCPFailure("Could not encode the video frame")
        }
        let metadata = try jsonText(["machine_id": machineID, "width": width,
                                     "height": height, "sequence": frame.sequence,
                                     "rtg": frame.isRTG])
        return ["content": [
            ["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
            ["type": "text", "text": metadata],
        ], "isError": false]
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

    private func guestCommandRun(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let command = try requiredString("command", in: arguments)
        guard let data = command.data(using: .isoLatin1), !data.contains(0), data.count <= 4085 else {
            throw MCPFailure("command must be Latin-1 text of 4085 bytes or less")
        }
        return try await startGuestRequest(machineID: machineID,
                                           payload: Data([0x43]) + data,
                                           operation: .command)
    }

    private func guestCommandExecute(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let timeout = arguments["timeout_seconds"] as? Int ?? 30
        guard (1...300).contains(timeout) else {
            throw MCPFailure("timeout_seconds must be between 1 and 300")
        }
        _ = try await guestCommandRun(arguments)
        guard let request = guestCommandByMachine[machineID],
              let startedRequest = guestCommands[request] else {
            throw MCPFailure("Could not start command on machine \(machineID)")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        repeat {
            guard guestCommands[request] != nil else {
                throw MCPFailure("Guest command was cancelled by a reset or machine stop")
            }
            let statusURL = try exchangeURL(machineID: machineID,
                                            name: "FSUAE-Control-Status")
            if let status = try? Data(contentsOf: statusURL),
               parseGuestStatus(status, token: startedRequest.token) != nil {
                let heartbeat = workerGuestHeartbeats[machineID]
                do {
                    try await waitForGuestControl(machineID, after: heartbeat,
                                                  timeout: .seconds(4))
                } catch {
                    let failure = "control channel stopped after command completion"
                    if var guestRequest = guestCommands[request] {
                        guestRequest.failure = failure
                        guestCommands[request] = guestRequest
                    }
                    throw MCPFailure("Guest command failed: \(failure)")
                }
                return try guestCommandResult(["request_id": request])
            }
            if let failure = guestFailure(machineID, request: startedRequest) {
                if var guestRequest = guestCommands[request] {
                    guestRequest.failure = failure
                    guestCommands[request] = guestRequest
                }
                throw MCPFailure("Guest command failed: \(failure)")
            }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        if var guestRequest = guestCommands[request] {
            guestRequest.timedOut = true
            guestCommands[request] = guestRequest
        }
        return try jsonText(["machine_id": machineID, "request_id": request,
                             "status": "timeout",
                             "message": "Command did not complete; inspect diagnostics, then hard-reset the machine to recover"])
    }

    private func guestFailure(_ machineID: String, request: GuestRequest? = nil) -> String? {
        guard workerProcesses[machineID]?.isRunning == true else {
            return "worker stopped"
        }
        guard let machine = runningMachines.first(where: { $0.id == machineID }) else {
            return "machine disappeared"
        }
        if machine.status == "guruing" {
            return "Guru Meditation " + machine.lastAlert.map {
                String(format: "0x%08x", $0)
            }.joined(separator: " ")
        }
        if let request, exceptionBelongsToGuestCommand(machine, request) {
            var failure = "CPU exception \(machine.exceptionVector) " +
                exceptionName(machine.exceptionVector) +
                String(format: " at 0x%08x", machine.exceptionPC)
            if !machine.exceptionTaskName.isEmpty {
                failure += " in \(machine.exceptionTaskName)"
            }
            return failure
        }
        if let health = workerHealthDates[machineID], Date().timeIntervalSince(health) > 10 {
            return "worker health heartbeat stopped"
        }
        return nil
    }

    private func exceptionBelongsToGuestCommand(_ machine: MacFSUAERunningMachine,
                                                 _ request: GuestRequest) -> Bool {
        guard machine.exceptionVector != 0,
              machine.exceptionSequence != request.exceptionSequence,
              let taskName = request.taskName else { return false }
        return machine.exceptionTaskName.caseInsensitiveCompare(taskName) == .orderedSame
    }

    private func guestFilePut(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let path = try guestPath(in: arguments)
        let encoded = try requiredString("data_base64", in: arguments)
        guard let data = Data(base64Encoded: encoded), data.count <= 16 * 1_048_576 else {
            throw MCPFailure("data_base64 must contain at most 16 MiB")
        }
        return try await startGuestRequest(machineID: machineID,
                                           payload: Data([0x50]) + path,
                                           operation: .put, transfer: data)
    }

    private func guestFileGet(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        return try await startGuestRequest(machineID: machineID,
                                           payload: Data([0x47]) + guestPath(in: arguments),
                                           operation: .get)
    }

    private func guestPath(in arguments: [String: Any]) throws -> Data {
        let path = try requiredString("path", in: arguments)
        guard let data = path.data(using: .isoLatin1), !data.contains(0), data.count <= 4085 else {
            throw MCPFailure("path must be Latin-1 text of 4085 bytes or less")
        }
        return data
    }

    private func startGuestRequest(machineID: String, payload: Data,
                                   operation: GuestOperation,
                                   transfer: Data? = nil) async throws -> String {
        try await waitForGuestControl(machineID)
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
        let taskName = operation == .command ? "FS-UAE Mac control" : nil
        let acknowledgement = UUID().uuidString.lowercased()
        var preparation: [String: Any] = ["command": "clear_exception",
                                          "acknowledgement": acknowledgement]
        if let taskName { preparation["task_name"] = taskName }
        guard sendWorkerCommand(machineID, preparation) else {
            throw MCPFailure("Could not prepare guest command on machine \(machineID)")
        }
        let acknowledgementDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while workerAcknowledgements[machineID]?.remove(acknowledgement) == nil {
            guard workerProcesses[machineID]?.isRunning == true else {
                throw MCPFailure("Machine \(machineID) stopped while preparing a guest command")
            }
            guard ContinuousClock.now < acknowledgementDeadline else {
                throw MCPFailure("Worker did not acknowledge guest-command preparation")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let token = UInt32.random(in: UInt32.min...UInt32.max)
        let exceptionSequence = runningMachines.first(where: { $0.id == machineID })?
            .exceptionSequence ?? 0
        var encodedToken = token.bigEndian
        var wirePayload = Data([payload[0]])
        wirePayload.append(Data(repeating: 0, count: 5))
        withUnsafeBytes(of: &encodedToken) { wirePayload.append(contentsOf: $0) }
        wirePayload.append(payload.dropFirst())
        try wirePayload.write(to: commandURL, options: .atomic)
        let request = UUID().uuidString.lowercased()
        guestCommands[request] = GuestRequest(machineID: machineID,
                                              operation: operation, started: Date(),
                                              token: token,
                                              exceptionSequence: exceptionSequence,
                                              taskName: taskName)
        guestCommandByMachine[machineID] = request
        return try jsonText(["machine_id": machineID, "request_id": request,
                             "status": "running"])
    }

    private func waitForGuestControl(_ machineID: String,
                                     after heartbeat: UInt32? = nil,
                                     timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            guard workerProcesses[machineID]?.isRunning == true else {
                throw MCPFailure("No running machine \(machineID)")
            }
            if runningMachines.first(where: { $0.id == machineID })?.guestControlReady == true,
               heartbeat == nil || workerGuestHeartbeats[machineID] != heartbeat {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        throw MCPFailure("Guest control is not ready on machine \(machineID)")
    }

    private func guestCommandResult(_ arguments: [String: Any]) throws -> String {
        let request = try requiredString("request_id", in: arguments)
        guard let guestRequest = guestCommands[request] else {
            throw MCPFailure("No guest command request \(request)")
        }
        let machineID = guestRequest.machineID
        if let failure = guestRequest.failure ?? guestFailure(machineID, request: guestRequest) {
            if guestRequest.failure == nil {
                var failedRequest = guestRequest
                failedRequest.failure = failure
                guestCommands[request] = failedRequest
            }
            return try jsonText(["machine_id": machineID, "request_id": request,
                                 "status": "failed", "message": failure])
        }
        let statusURL = try exchangeURL(machineID: machineID, name: "FSUAE-Control-Status")
        guard let status = try? Data(contentsOf: statusURL),
              let parsed = parseGuestStatus(status, token: guestRequest.token) else {
            if guestRequest.timedOut {
                return try jsonText(["machine_id": machineID, "request_id": request,
                                     "status": "timeout",
                                     "message": "Inspect diagnostics, then hard-reset the machine to recover"])
            }
            return try jsonText(["machine_id": machineID, "request_id": request,
                                 "status": "running"])
        }
        let outputURL = try exchangeURL(machineID: machineID, name: "FSUAE-Control-Output")
        let transferURL = try exchangeURL(machineID: machineID, name: "FSUAE-Control-Transfer")
        defer {
            guestCommands[request] = nil
            if guestCommandByMachine[machineID] == request { guestCommandByMachine[machineID] = nil }
            for url in [outputURL, statusURL, transferURL] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let outputSize = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard outputSize <= 16 * 1_048_576 else {
            throw MCPFailure("Command output exceeds 16 MiB")
        }
        let output = (try? Data(contentsOf: outputURL)) ?? Data()
        var result: [String: Any] = ["machine_id": machineID, "request_id": request,
                                     "status": "completed", "succeeded": parsed.succeeded,
                                     "exit_code_known": parsed.exitCode != nil]
        if let exitCode = parsed.exitCode { result["exit_code"] = exitCode }
        if guestRequest.operation == .command {
            result["output"] = String(data: output, encoding: .isoLatin1) ?? ""
            result["output_base64"] = output.base64EncodedString()
        }
        if guestRequest.operation == .get, parsed.succeeded {
            let size = try transferURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 16 * 1_048_576 else { throw MCPFailure("File exceeds 16 MiB") }
            let data = try Data(contentsOf: transferURL)
            result["size"] = data.count
            result["data_base64"] = data.base64EncodedString()
        }
        return try jsonText(result)
    }

    private func snapshotDirectory(configuration: String) throws -> URL {
        guard library.configuration(named: configuration) != nil else {
            throw MCPFailure("Unknown configuration \(configuration)")
        }
        return library.directory.deletingLastPathComponent()
            .appendingPathComponent("Save States", isDirectory: true)
            .appendingPathComponent(configuration, isDirectory: true)
    }

    private func snapshot(at url: URL, configuration: String) -> MacFSUAESnapshot? {
        guard url.pathExtension.lowercased() == "uss" else { return nil }
        let id = url.deletingPathExtension().lastPathComponent
        guard let divider = id.range(of: "--") else { return nil }
        let values = try? url.resourceValues(forKeys: [.creationDateKey,
                                                       .contentModificationDateKey,
                                                       .fileSizeKey])
        return MacFSUAESnapshot(
            id: id, name: String(id[divider.upperBound...]), configuration: configuration,
            created: values?.creationDate ?? values?.contentModificationDate ?? .distantPast,
            size: values?.fileSize ?? 0)
    }

    private func snapshotURL(_ id: String, configuration: String) throws -> URL {
        guard snapshots(configuration: configuration).contains(where: { $0.id == id }) else {
            throw MCPFailure("Unknown snapshot \(id)")
        }
        return try snapshotDirectory(configuration: configuration)
            .appendingPathComponent(id).appendingPathExtension("uss")
    }

    private func snapshotDictionary(_ value: MacFSUAESnapshot) -> [String: Any] {
        ["snapshot_id": value.id, "name": value.name,
         "configuration": value.configuration,
         "created": ISO8601DateFormatter().string(from: value.created),
         "size_bytes": value.size]
    }

    private func snapshotJSON(_ value: MacFSUAESnapshot) throws -> String {
        try jsonText(snapshotDictionary(value))
    }

    private func runSnapshot(_ machineID: String, action: String, url: URL) async throws {
        guard workerProcesses[machineID]?.isRunning == true,
              let controlPath = workerControlPaths[machineID] else {
            throw MCPFailure("No running machine \(machineID)")
        }
        guard snapshotMachines.insert(machineID).inserted else {
            throw MCPFailure("Machine \(machineID) already has a snapshot operation running")
        }
        defer { snapshotMachines.remove(machineID) }
        let request = UUID().uuidString.lowercased()
        let resultURL = URL(fileURLWithPath: controlPath, isDirectory: true)
            .appendingPathComponent("FSUAE-Snapshot-\(request)")
        defer { try? FileManager.default.removeItem(at: resultURL) }
        guard sendWorkerCommand(machineID, ["command": "snapshot", "request_id": request,
                                             "action": action, "path": url.path]) else {
            throw MCPFailure("Could not send snapshot command to machine \(machineID)")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        repeat {
            if let data = try? Data(contentsOf: resultURL),
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                guard result["succeeded"] as? Bool == true else {
                    throw MCPFailure(result["error"] as? String ?? "Snapshot operation failed")
                }
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw MCPFailure("Snapshot operation timed out")
    }

    /// Runs debugger commands on the emulator thread and returns raw console output.
    private func runDebugger(_ machineID: String,
                             _ commands: [String]) async throws -> (succeeded: Bool, output: String) {
        guard workerProcesses[machineID]?.isRunning == true,
              let controlPath = workerControlPaths[machineID] else {
            throw MCPFailure("No running machine \(machineID)")
        }
        guard debuggerMachines.insert(machineID).inserted else {
            throw MCPFailure("Machine \(machineID) already has a debugger command running")
        }
        defer { debuggerMachines.remove(machineID) }
        let request = UUID().uuidString.lowercased()
        let resultURL = URL(fileURLWithPath: controlPath, isDirectory: true)
            .appendingPathComponent("FSUAE-Debug-\(request)")
        defer { try? FileManager.default.removeItem(at: resultURL) }
        guard sendWorkerCommand(machineID, ["command": "debug", "request_id": request,
                                             "commands": commands]) else {
            throw MCPFailure("Could not send debugger command to machine \(machineID)")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        repeat {
            if let data = try? Data(contentsOf: resultURL),
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (result["succeeded"] as? Bool ?? false,
                        result["output"] as? String ?? "")
            }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw MCPFailure("Debugger command timed out on machine \(machineID)")
    }

    /// The debugger reads one Latin-1 line; libfsuaemac rejects 1024 bytes or more.
    private func debuggerLine(_ command: String) throws -> String {
        guard let data = command.data(using: .isoLatin1), !data.contains(0),
              data.count < 1024 else {
            throw MCPFailure("Debugger command must be Latin-1 text under 1024 bytes")
        }
        return command
    }

    private func debuggerExecute(_ arguments: [String: Any], snapshot: Bool) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let commands = snapshot
            ? ["r", "H 32", "T"]
            : [try debuggerLine(try requiredString("command", in: arguments))]
        let result = try await runDebugger(machineID, commands)
        return try jsonText(["machine_id": machineID, "commands": commands,
                             "succeeded": result.succeeded, "output": result.output])
    }

    private func debugBreakpoints(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let action = try requiredString("action", in: arguments)
        guard ["set", "remove", "list", "clear"].contains(action) else {
            throw MCPFailure("action must be set, remove, list, or clear")
        }
        var listed = try await runDebugger(machineID, ["fl"])
        guard listed.succeeded else { throw MCPFailure("Could not list breakpoints") }
        var addresses = parseDebuggerBreakpoints(listed.output)

        if action == "clear", !addresses.isEmpty {
            listed = try await runDebugger(machineID, ["fd"])
            guard listed.succeeded else { throw MCPFailure("Could not clear breakpoints") }
            addresses.removeAll()
        } else if action == "set" || action == "remove" {
            let text = try requiredString("address", in: arguments)
            guard let address = parseHex(text) else {
                throw MCPFailure("Address must be hexadecimal")
            }
            let contains = addresses.contains(address)
            if (action == "set") != contains {
                let changed = try await runDebugger(
                    machineID, [String(format: "f %08x", address)])
                guard changed.succeeded else { throw MCPFailure("Could not change breakpoint") }
                if action == "set" {
                    addresses.append(address)
                    addresses.sort()
                } else {
                    addresses.removeAll { $0 == address }
                }
                listed = changed
            }
        }
        return try jsonText([
            "machine_id": machineID, "action": action,
            "breakpoints": addresses.map { String(format: "0x%08x", $0) },
            "output": listed.output,
        ])
    }

    private func debugExecution(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let action = try requiredString("action", in: arguments)
        let command: String
        switch action {
        case "continue":
            command = "g"
        case "step":
            let count = arguments["instructions"] as? Int ?? 1
            guard (1...10_000).contains(count) else {
                throw MCPFailure("instructions must be between 1 and 10000")
            }
            command = count == 1 ? "t" : "t \(count)"
        case "step_over":
            command = "z"
        default:
            throw MCPFailure("action must be continue, step, or step_over")
        }
        let result = try await runDebugger(machineID, [command])
        if let index = runningMachines.firstIndex(where: { $0.id == machineID }) {
            runningMachines[index].debuggerStopped = false
        }
        return try jsonText([
            "machine_id": machineID, "action": action, "accepted": result.succeeded,
            "state": action == "continue" ? "running" : "stepping",
            "output": result.output,
        ])
    }

    private func debugWait(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let timeout = arguments["timeout_seconds"] as? Int ?? 30
        guard (1...300).contains(timeout) else {
            throw MCPFailure("timeout_seconds must be between 1 and 300")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        repeat {
            guard let machine = runningMachines.first(where: { $0.id == machineID }) else {
                throw MCPFailure("No running machine \(machineID)")
            }
            if machine.debuggerStopped {
                let snapshot = try await runDebugger(machineID, ["r", "H 32", "T"])
                var payload = machineRow(machine)
                payload["status"] = "stopped"
                payload["reason"] = machine.exceptionVector == 0
                    ? "breakpoint_or_step" : exceptionName(machine.exceptionVector)
                payload["debugger_output"] = snapshot.output
                if let location = try? await resolveAddress(machineID, machine.programCounter),
                   location["found"] as? Bool == true {
                    payload["location"] = location
                }
                return try jsonText(payload)
            }
            try await Task.sleep(for: .milliseconds(25))
        } while ContinuousClock.now < deadline
        return try jsonText([
            "machine_id": machineID, "status": "timeout", "debugger_stopped": false,
        ])
    }

    private func machineInspect(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        guard let machine = runningMachines.first(where: { $0.id == machineID }) else {
            throw MCPFailure("No running machine \(machineID)")
        }
        let requested = arguments["domains"] as? [String]
            ?? ["cpu", "history", "tasks", "hardware", "performance"]
        let allowed = Set(["cpu", "history", "tasks", "hardware", "custom",
                           "copper", "memory", "performance"])
        guard !requested.isEmpty, requested.allSatisfy(allowed.contains) else {
            throw MCPFailure("domains contains an unsupported inspection domain")
        }
        let lines = arguments["lines"] as? Int ?? 16
        guard (1...256).contains(lines) else {
            throw MCPFailure("lines must be between 1 and 256")
        }
        let memoryAddress: UInt32
        if let text = optionalString("address", in: arguments) {
            guard let parsed = parseHex(text) else {
                throw MCPFailure("Address must be hexadecimal")
            }
            memoryAddress = parsed
        } else {
            memoryAddress = machine.programCounter
        }
        let commandByDomain: [String: String] = [
            "cpu": "r", "history": "H 32", "tasks": "T", "hardware": "c",
            "custom": "e", "copper": "o 0 32",
            "memory": String(format: "m %x %d", memoryAddress, lines),
        ]
        let pairs: [(domain: String, command: String)] = requested.compactMap { domain in
            commandByDomain[domain].map { (domain: domain, command: $0) }
        }
        var inspection: [String: Any] = [:]
        if !pairs.isEmpty {
            let result = try await runDebugger(machineID, pairs.map { $0.command })
            for (domain, value) in debuggerSections(result.output, pairs: pairs) {
                inspection[domain] = value
            }
        }
        if requested.contains("performance") {
            inspection["performance"] = [
                "frame_sequence": machine.frameSequence,
                "program_counter": String(format: "0x%08x", machine.programCounter),
                "speed": machine.speed,
                "paused": machine.isPaused,
                "debugger_stopped": machine.debuggerStopped,
            ]
        }
        return try jsonText([
            "machine_id": machineID, "source": "emulator", "domains": inspection,
        ])
    }

    private func debuggerSections(_ output: String,
                                  pairs: [(domain: String, command: String)]) -> [String: String] {
        var sections: [String: String] = [:]
        for index in pairs.indices {
            let marker = "> \(pairs[index].command)\n"
            guard let markerRange = output.range(of: marker) else { continue }
            let start = markerRange.upperBound
            let end: String.Index
            if index + 1 < pairs.count {
                let next = "> \(pairs[index + 1].command)\n"
                end = output.range(of: next, range: start..<output.endIndex)?.lowerBound
                    ?? output.endIndex
            } else {
                end = output.endIndex
            }
            sections[pairs[index].domain] = String(output[start..<end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return sections
    }

    // MARK: - Segment tracker
    //
    // The tracker patches LoadSeg so every seglist the guest loads is recorded
    // with its real load address. Point it at the host-side executable and a
    // crash address becomes a symbol and a source line. The debugger reports
    // all of this as text, so these tools parse its fixed formats back into
    // JSON rather than making the caller read console output.

    private func debugTracking(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let enabled = arguments["enabled"] as? Bool ?? true
        let result = try await runDebugger(machineID, ["Ze \(enabled ? 1 : 0)"])
        return try jsonText([
            "machine_id": machineID,
            "enabled": enabled,
            "succeeded": result.succeeded,
            "output": result.output,
            "note": enabled
                ? "Only seglists loaded from now on are tracked. Reset the machine before launching the program under test, or nothing will be recorded."
                : "Tracking is off and the seglists recorded so far have been discarded.",
        ])
    }

    private func debugSegments(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let match = optionalString("match", in: arguments)
        // Z reports whether tracking is on, which is the answer whenever the
        // list comes back empty. Zl lists the seglists; Zs would filter, but it
        // also dumps every symbol of every match, so filter here instead.
        let result = try await runDebugger(machineID, ["Z", "Zl"])
        let tracking = result.output.contains("SegmentTracker is enabled")
        var seglists = parseSeglists(result.output)
        if let match {
            seglists = seglists.filter {
                ($0["name"] as? String ?? "").localizedCaseInsensitiveContains(match)
            }
        }
        var payload: [String: Any] = ["machine_id": machineID, "tracking": tracking,
                                      "seglists": seglists]
        if !tracking {
            payload["note"] = "Segment tracking is off. Enable it with fsuae_debug_tracking, then reset before launching the program under test."
        }
        return try jsonText(payload)
    }

    private func debugSymbols(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let seglist = try requiredString("seglist", in: arguments)
        let hostPath = try requiredString("host_path", in: arguments)
        guard FileManager.default.fileExists(atPath: hostPath) else {
            throw MCPFailure("No file at \(hostPath)")
        }
        // Zf takes quoted arguments and gives no way to escape a quote, so a
        // path containing one cannot be expressed.
        guard !seglist.contains("'"), !hostPath.contains("'") else {
            throw MCPFailure("Seglist name and host path must not contain a single quote")
        }
        let line = try debuggerLine("Zf '\(seglist)' '\(hostPath)'")
        let result = try await runDebugger(machineID, [line])
        // Zf reports every outcome in prose, so read it back out of the text.
        let failures = ["Error adding debug info", "Error loading hunk file",
                        "No loaded segment list", "Usage: Zf"]
        let failure = failures.first { result.output.contains($0) }
        var payload: [String: Any] = [
            "machine_id": machineID, "seglist": seglist, "host_path": hostPath,
            "loaded": result.succeeded && failure == nil,
            "output": result.output,
        ]
        if let failure {
            payload["error"] = failure
        } else {
            // A file with no debug hunks loads without complaint and resolves
            // nothing, which is the easiest way to lose an afternoon.
            let totals = countDebugInfo(result.output)
            payload["symbols"] = totals.symbols
            payload["source_files"] = totals.sourceFiles
            if totals.symbols == 0, totals.sourceFiles == 0 {
                payload["note"] = "Loaded, but the file carries no debug hunks: addresses will resolve to a segment and no further. Relink the executable with debug information."
            }
        }
        return try jsonText(payload)
    }

    /// Totals the counts debug_info_dump_file() prints per segment:
    /// `  segment #00: CODE [000021c8]  123 symbols,    4 src files`
    func countDebugInfo(_ output: String) -> (symbols: Int, sourceFiles: Int) {
        var symbols = 0
        var sourceFiles = 0
        for line in output.split(separator: "\n") where line.contains("segment #") {
            symbols += countBefore("symbols", in: String(line)) ?? 0
            sourceFiles += countBefore("src files", in: String(line)) ?? 0
        }
        return (symbols, sourceFiles)
    }

    private func debugResolve(_ arguments: [String: Any]) async throws -> String {
        let machineID = try requiredString("machine_id", in: arguments)
        let text = try requiredString("address", in: arguments)
        guard let address = parseHex(text) else {
            throw MCPFailure("Address must be hexadecimal, for example 0021ab34 or 0x21ab34")
        }
        var payload = try await resolveAddress(machineID, address)
        payload["machine_id"] = machineID
        return try jsonText(payload)
    }

    private func resolveAddress(_ machineID: String, _ address: UInt32) async throws -> [String: Any] {
        let result = try await runDebugger(machineID, [String(format: "Za %x", address)])
        var payload = parseAddressLookup(result.output)
        payload["address"] = String(format: "0x%08x", address)
        if payload["found"] as? Bool != true {
            payload["output"] = result.output
        }
        return payload
    }

    func parseHex(_ text: String) -> UInt32? {
        var digits = text.trimmingCharacters(in: .whitespaces).lowercased()
        if digits.hasPrefix("0x") { digits.removeFirst(2) }
        guard !digits.isEmpty, digits.count <= 8,
              digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return UInt32(digits, radix: 16)
    }

    /// Parses `Zl` output: a `'name' @address` line per seglist, then one
    /// indented `#nn [start,size,end]` line per segment, optionally carrying
    /// symbol and source-file counts once debug info is attached.
    func parseSeglists(_ output: String) -> [[String: Any]] {
        var seglists: [[String: Any]] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.hasPrefix("'"), let range = text.range(of: "' @") {
                let name = String(text[text.index(after: text.startIndex)..<range.lowerBound])
                let address = parseHex(String(text[range.upperBound...])) ?? 0
                seglists.append(["name": name,
                                 "address": String(format: "0x%08x", address),
                                 "segments": [[String: Any]]()])
            } else if text.hasPrefix("  #"), !seglists.isEmpty,
                      let segment = parseSegment(text) {
                var last = seglists.removeLast()
                var segments = last["segments"] as? [[String: Any]] ?? []
                segments.append(segment)
                last["segments"] = segments
                seglists.append(last)
            }
        }
        return seglists
    }

    /// `  #00 [0021a004,00004000,0021e004]  123 symbols,    4 src files`
    func parseSegment(_ text: String) -> [String: Any]? {
        guard let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]") else {
            return nil
        }
        let index = Int(text[text.index(text.startIndex, offsetBy: 3)..<open]
            .trimmingCharacters(in: .whitespaces)) ?? 0
        let fields = text[text.index(after: open)..<close].split(separator: ",")
        guard fields.count == 3,
              let start = parseHex(String(fields[0])),
              let size = parseHex(String(fields[1])) else { return nil }
        var segment: [String: Any] = [
            "index": index,
            "start": String(format: "0x%08x", start),
            "size": Int(size),
            "end": String(format: "0x%08x", start &+ size),
        ]
        let tail = String(text[text.index(after: close)...])
        if let symbols = countBefore("symbols", in: tail) {
            segment["symbols"] = symbols
            segment["source_files"] = countBefore("src files", in: tail) ?? 0
        }
        return segment
    }

    func countBefore(_ label: String, in text: String) -> Int? {
        guard let range = text.range(of: label) else { return nil }
        return Int(text[..<range.lowerBound].split(separator: " ").last ?? "")
    }

    /// Parses `Za` output. The header names the seglist and segment; up to two
    /// indented lines follow, the nearest symbol and then the nearest source
    /// line, either of which is absent when no debug info covers the address.
    func parseAddressLookup(_ output: String) -> [String: Any] {
        var payload: [String: Any] = ["found": false]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if text.contains(": '"), let header = parseLookupHeader(text) {
                payload = header
                payload["found"] = true
            } else if text.hasPrefix("    "), payload["found"] as? Bool == true,
                      let entry = parseLookupEntry(text) {
                // A source line ends in ":<line>"; a symbol name does not.
                if let (file, number) = splitSourceLocation(entry.label) {
                    payload["source_file"] = file
                    payload["source_line"] = number
                    payload["source_address"] = entry.address
                    payload["source_offset"] = entry.offset
                } else {
                    payload["symbol"] = entry.label
                    payload["symbol_address"] = entry.address
                    payload["symbol_offset"] = entry.offset
                }
            }
        }
        return payload
    }

    /// `0021ab34: 'SYS:Barry/spinner' #00 [0021a004,00004000,0021e004] +00001b30`
    func parseLookupHeader(_ text: String) -> [String: Any]? {
        guard let nameStart = text.range(of: ": '"),
              let nameEnd = text.range(of: "' #", range: nameStart.upperBound..<text.endIndex),
              let segment = parseSegment("  #" + text[nameEnd.upperBound...]) else {
            return nil
        }
        var payload: [String: Any] = [
            "seglist": String(text[nameStart.upperBound..<nameEnd.lowerBound]),
            "segment": segment,
        ]
        if let plus = text.range(of: "] +"),
           let offset = parseHex(String(text[plus.upperBound...])) {
            payload["segment_offset"] = String(format: "0x%08x", offset)
        }
        return payload
    }

    /// `    0021aa00 +00000134  _main`
    func parseLookupEntry(_ text: String) -> (address: String, offset: String, label: String)? {
        let body = text.trimmingCharacters(in: .whitespaces)
        guard let split = body.range(of: "  ") else { return nil }
        let head = body[..<split.lowerBound].split(separator: " ")
        guard head.count == 2, head[1].hasPrefix("+"),
              let address = parseHex(String(head[0])),
              let offset = parseHex(String(head[1].dropFirst())) else { return nil }
        return (String(format: "0x%08x", address),
                String(format: "0x%08x", offset),
                String(body[split.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    func splitSourceLocation(_ label: String) -> (file: String, line: Int)? {
        guard let colon = label.lastIndex(of: ":"),
              let number = Int(label[label.index(after: colon)...]) else { return nil }
        return (String(label[..<colon]), number)
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
