import Foundation

// Drives the MCP server the app publishes on 127.0.0.1:6800 and checks that the
// guest control service survives repeated use on any Amiga model. The fixture is
// a self-contained 68000/Kickstart-1.3 executable, so nothing here depends on
// C:, RAM:, Workbench commands, or the CPU model.
//
//   macos/scripts/stress-test-mcp.sh A500

struct StressFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    guard condition else { throw StressFailure(message()) }
}

@MainActor
func unwrap<T>(_ value: T?, _ message: @autoclosure () -> String) throws -> T {
    guard let value else { throw StressFailure(message()) }
    return value
}

let endpoint = URL(string: "http://127.0.0.1:6800/mcp")!
let configuration = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "A4000"
let diagnosticPath = ProcessInfo.processInfo.environment["FSUAE_DIAGNOSTIC"]
    ?? ".build/amiga/FSUAE-Diag"

var nextRequestID = 0

/// One tools/call round trip. Returns the parsed JSON when the tool answers with
/// JSON, and the raw text when it answers in prose.
@MainActor
func call(_ name: String, _ arguments: [String: Any],
          timeout: TimeInterval = 330) async throws -> Any {
    nextRequestID += 1
    var request = URLRequest(url: endpoint, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": nextRequestID, "method": "tools/call",
        "params": ["name": name, "arguments": arguments],
    ])
    let (data, _) = try await URLSession.shared.data(for: request)
    let payload = try unwrap(JSONSerialization.jsonObject(with: data) as? [String: Any],
                             "\(name): reply was not a JSON object")
    if let error = payload["error"] as? [String: Any] {
        throw StressFailure("\(name): \(error["message"] as? String ?? "\(error)")")
    }
    let result = try unwrap(payload["result"] as? [String: Any], "\(name): no result")
    let text = (result["content"] as? [[String: Any]] ?? [])
        .map { $0["text"] as? String ?? "" }
        .joined(separator: "\n")
    if result["isError"] as? Bool == true { throw StressFailure("\(name): \(text)") }
    guard let body = text.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: body) else { return text }
    return json
}

@MainActor
func callObject(_ name: String, _ arguments: [String: Any],
                timeout: TimeInterval = 330) async throws -> [String: Any] {
    let value = try await call(name, arguments, timeout: timeout)
    return try unwrap(value as? [String: Any], "\(name): expected a JSON object, got \(value)")
}

@MainActor
func expectNoMachines() async throws {
    let machines = try await call("fsuae_machines_list", [:])
    try expect((machines as? [Any])?.isEmpty == true,
               "expected no running machines, got \(machines)")
}

@MainActor
func start() async throws -> String {
    try await expectNoMachines()
    let result = try await call("fsuae_machine_start", ["configuration": configuration])
    let text = try unwrap(result as? String, "fsuae_machine_start: expected prose")
    // "Started A4000 (A4000); machine_id <uuid>; pid 1234"
    let fields = text.components(separatedBy: "machine_id ")
    try expect(fields.count == 2, "fsuae_machine_start: no machine_id in \(text)")
    return String(fields[1].prefix { $0 != ";" }).trimmingCharacters(in: .whitespaces)
}

@MainActor
func waitReady(_ machine: String) async throws {
    _ = try await call("fsuae_machine_wait", [
        "machine_id": machine, "condition": "workbench", "timeout_seconds": 120,
    ], timeout: 150)
}

@MainActor
func stop(_ machine: String) async throws {
    _ = try await call("fsuae_machine_stop", ["machine_id": machine], timeout: 30)
    try await expectNoMachines()
}

@discardableResult
@MainActor
func execute(_ machine: String, _ command: String,
             timeoutSeconds: Int = 30) async throws -> [String: Any] {
    let result = try await callObject("fsuae_command_execute", [
        "machine_id": machine, "command": command, "timeout_seconds": timeoutSeconds,
    ], timeout: TimeInterval(timeoutSeconds + 20))
    try expect(result["status"] as? String == "completed", "\(command): \(result)")
    return result
}

@MainActor
func installDiagnostic(_ machine: String) async throws {
    guard let data = FileManager.default.contents(atPath: diagnosticPath) else {
        throw StressFailure("no fixture at \(diagnosticPath); run macos/scripts/build-amiga-tools.sh first")
    }
    _ = try await call("fsuae_exchange_put", [
        "machine_id": machine, "name": "FSUAE-Diag",
        "data_base64": data.base64EncodedString(),
    ])
}

@MainActor
func poll(_ requestID: String, timeoutSeconds: Int = 30) async throws -> [String: Any] {
    let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
    repeat {
        let result = try await callObject("fsuae_command_result", ["request_id": requestID])
        if result["status"] as? String != "running" { return result }
        try await Task.sleep(for: .milliseconds(50))
    } while ContinuousClock.now < deadline
    throw StressFailure("request \(requestID) never left the running state")
}

@MainActor
func pinged(_ machine: String) async throws {
    let result = try await execute(machine, "MCP:FSUAE-Diag PING")
    try expect(result["succeeded"] as? Bool == true, "PING did not succeed: \(result)")
    // Kickstart 1.x launches through Execute(), which cannot report an exit code.
    if result["exit_code_known"] as? Bool == true {
        try expect(result["exit_code"] as? Int == 0, "PING exit code: \(result)")
    }
    let output = (result["output"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    try expect(output == "PING ok", "PING output was \(output)")
}

@MainActor
func note(_ message: String) {
    print("\(configuration): \(message)")
    fflush(stdout)
}

var machine: String?
do {
    note("boot")
    machine = try await start()
    let id = machine!
    try await waitReady(id)
    try await installDiagnostic(id)

    for index in 0..<50 {
        try await pinged(id)
        if index % 10 == 9 { note("\(index + 1)/50 commands") }
    }

    note("file round-trip")
    let payload = Data((0..<16).flatMap { _ in (0...255).map(UInt8.init) })
    let put = try await callObject("fsuae_file_put", [
        "machine_id": id, "path": "MCP:guest-stress.bin",
        "data_base64": payload.base64EncodedString(),
    ])
    let stored = try await poll(unwrap(put["request_id"] as? String, "file_put: no request_id"))
    try expect(stored["succeeded"] as? Bool == true, "file_put: \(stored)")
    let get = try await callObject("fsuae_file_get", ["machine_id": id,
                                                      "path": "MCP:guest-stress.bin"])
    let fetched = try await poll(unwrap(get["request_id"] as? String, "file_get: no request_id"))
    try expect(fetched["succeeded"] as? Bool == true, "file_get: \(fetched)")
    let returned = Data(base64Encoded: fetched["data_base64"] as? String ?? "")
    try expect(returned == payload, "file round-trip returned \(returned?.count ?? -1) bytes")

    note("stale response and timeout recovery")
    let slow = try await callObject("fsuae_command_run", [
        "machine_id": id, "command": "MCP:FSUAE-Diag WAIT",
    ])
    let slowID = try unwrap(slow["request_id"] as? String, "command_run: no request_id")
    // A status block from an earlier generation must not be mistaken for this
    // request completing.
    let stale = Data([0x31, 0x31, 0, 0, 0, 0, 0xde, 0xad, 0xbe, 0xef])
    _ = try await call("fsuae_exchange_put", [
        "machine_id": id, "name": "FSUAE-Control-Status",
        "data_base64": stale.base64EncodedString(),
    ])
    let afterStale = try await callObject("fsuae_command_result", ["request_id": slowID])
    try expect(afterStale["status"] as? String == "running",
               "stale status was accepted: \(afterStale)")
    let recovered = try await poll(slowID, timeoutSeconds: 10)
    try expect(recovered["succeeded"] as? Bool == true, "slow command: \(recovered)")

    let timedOut = try await callObject("fsuae_command_execute", [
        "machine_id": id, "command": "MCP:FSUAE-Diag WAIT", "timeout_seconds": 1,
    ], timeout: 20)
    try expect(timedOut["status"] as? String == "timeout", "expected a timeout: \(timedOut)")
    let diagnostics = try await callObject("fsuae_machine_diagnostics", ["machine_id": id])
    try expect(diagnostics["guest_command_status"] as? String == "timeout",
               "diagnostics did not report the timeout: \(diagnostics)")
    _ = try await call("fsuae_machine_reset", ["machine_id": id, "hard": true])
    try await waitReady(id)
    try await pinged(id)
    try await stop(id)
    machine = nil

    for cycle in 0..<3 {
        note("lifecycle \(cycle + 1)/3")
        let cycled = try await start()
        machine = cycled
        try await waitReady(cycled)
        try await installDiagnostic(cycled)
        try await pinged(cycled)
        try await stop(cycled)
        machine = nil
    }
    print("""
    \(configuration) guest service stress passed: 50 repeated commands, \
    file round-trip, stale status, timeout recovery, 4 lifecycle cycles
    """)
} catch {
    if let leaked = machine {
        do { try await stop(leaked) } catch { print("cleanup failed: \(error)") }
    }
    FileHandle.standardError.write(Data("\(configuration) stress failed: \(error)\n".utf8))
    exit(1)
}
