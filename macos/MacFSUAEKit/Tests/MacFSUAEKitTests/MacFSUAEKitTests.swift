import CoreGraphics
import Foundation
import Testing
@testable import MacFSUAEKit

@Test func frameSourceReturnsOnlyNewFrames() {
    let source = MacFSUAEFrameSource()
    let frame = MacFSUAEFrame(width: 2, height: 1, stride: 8,
                              crop: CGRect(x: 0, y: 0, width: 2, height: 1),
                              refreshRate: 50, isRTG: false, sequence: 1,
                              pixels: Data(repeating: 0, count: 8))
    source.publish(frame)
    #expect(source.latest(after: 0)?.sequence == 1)
    #expect(source.latest(after: 1) == nil)
}

@Test func driveStatusUpdatesMediaAndAggregateHardDiskActivity() {
    var drives: [MacFSUAEDrive] = []
    drives = updatingDriveStatuses(drives, with: MacFSUAEDrive(
        kind: .floppy, index: 1, isActive: false, mediaPath: "Disk.adf"))
    drives = updatingDriveStatuses(drives, with: MacFSUAEDrive(
        kind: .hardDisk, index: 0, isActive: false, mediaPath: "System.hdf"))
    drives = updatingDriveStatuses(drives, with: MacFSUAEDrive(
        kind: .hardDisk, index: -1, isActive: true, mediaPath: ""))

    #expect(drives.first(where: { $0.kind == .floppy })?.name == "DF1")
    #expect(drives.first(where: { $0.kind == .floppy })?.mediaPath == "Disk.adf")
    #expect(drives.first(where: { $0.kind == .hardDisk })?.isActive == true)
}

@MainActor
@Test func keyboardMappingCoversModifiersAndPersistsOverrides() {
    let suite = "fsuae-keyboard-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let mapping = MacFSUAEKeyboardMapping(defaults: defaults)

    #expect(mapping.target(for: 56) == 56) // left shift
    #expect(mapping.target(for: 60) == 60) // right shift
    #expect(mapping.target(for: 59) == 59) // control
    #expect(mapping.target(for: 55) == 55) // open Amiga
    #expect(mapping.target(for: 54) == 54) // closed Amiga
    #expect(MacFSUAEKeyboardLayout.keys.filter { $0.amigaTitle != nil }
        .allSatisfy { mapping.target(for: $0.code) != nil })

    mapping.setTarget(54, for: 55)
    #expect(MacFSUAEKeyboardMapping(defaults: defaults).target(for: 55) == 54)
    mapping.reset()
    #expect(mapping.target(for: 55) == 55)
}

@Test func configurationEditingPreservesUnknownOptions() {
    var configuration = FSUAEConfiguration(
        url: URL(fileURLWithPath: "/tmp/Test.fs-uae"),
        text: "# launcher comment\n[fs-uae]\namiga_model = A500\nuae_magic_option = keep-me\n")
    configuration.setValue("A4000/040", for: "amiga_model")
    configuration.setValue("/Games/System.hdf", for: "hard_drive_0")

    #expect(configuration.model == "A4000/040")
    #expect(configuration.value(for: "hard_drive_0") == "/Games/System.hdf")
    #expect(configuration.text.contains("uae_magic_option = keep-me"))
    #expect(configuration.text.contains("# launcher comment"))
}

@MainActor
@Test func configurationLibraryDoesNotOverwriteAnotherConfiguration() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let existing = directory.appendingPathComponent("Existing.fs-uae")
    try "[fs-uae]\namiga_model = A500\n".write(to: existing, atomically: true, encoding: .utf8)
    let draft = FSUAEConfiguration(url: directory.appendingPathComponent("Draft.fs-uae"),
                                   text: "[fs-uae]\namiga_model = A4000\n")

    #expect(throws: CocoaError.self) {
        _ = try FSUAEConfigurationLibrary(directory: directory).save(draft, named: "Existing")
    }
    #expect(try String(contentsOf: existing, encoding: .utf8).contains("A500"))
}

@MainActor
@Test func configurationLibraryRejectsInvalidMemory() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let library = FSUAEConfigurationLibrary(directory: directory)
    var configuration = library.draft()

    configuration.setValue("4096", for: "chip_memory")
    #expect(throws: (any Error).self) { try library.save(configuration, named: "Invalid") }

    configuration.setValue("1M", for: "chip_memory")
    configuration.setValue("16384", for: "zorro_iii_memory")
    #expect(throws: (any Error).self) { try library.save(configuration, named: "Invalid Z3") }

    configuration.setValue("A1200/020", for: "amiga_model")
    #expect(try library.save(configuration, named: "Valid").lastPathComponent == "Valid.fs-uae")

    configuration.setValue("A500", for: "amiga_model")
    configuration.setValue(nil, for: "cpu")
    #expect(!configuration.optionChoices(for: "graphics_card").contains { $0.value == "uaegfx-z3" })
    configuration.setValue("68040", for: "cpu")
    #expect(throws: (any Error).self) { try library.save(configuration, named: "Invalid CPU") }

    configuration.setValue("A4000/040", for: "amiga_model")
    configuration.setValue(nil, for: "cpu")
    #expect(configuration.modelProfile.defaultFloppyCount == 2)
    #expect(configuration.optionChoices(for: "graphics_card").contains { $0.value == "uaegfx-z3" })
}

@MainActor
@Test func mcpListsToolsAndManagesConfigurations() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let suite = "fsuae-mcp-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }
    let server = MacFSUAEMCPServer(defaults: defaults,
                                   library: FSUAEConfigurationLibrary(directory: directory),
                                   session: MacFSUAEEngineSession(),
                                   startAutomatically: false)

    func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": method, "params": params,
        ])
        let reply = await server.handleMCPRequest(data)
        #expect(reply.status == 200)
        let body = try #require(reply.body)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    let initialized = try await request("initialize")
    let initializeResult = try #require(initialized["result"] as? [String: Any])
    #expect(initializeResult["protocolVersion"] as? String == "2025-11-25")

    let listedTools = try await request("tools/list")
    let toolsResult = try #require(listedTools["result"] as? [String: Any])
    let tools = try #require(toolsResult["tools"] as? [[String: Any]])
    #expect(tools.count == 22)
    let start = try #require(tools.first { $0["name"] as? String == "fsuae_machine_start" })
    let startSchema = try #require(start["inputSchema"] as? [String: Any])
    let startProperties = try #require(startSchema["properties"] as? [String: Any])
    #expect(startProperties["hdf"] != nil)
    #expect(startProperties["hdfs"] != nil)
    let input = try #require(tools.first { $0["name"] as? String == "fsuae_input" })
    let inputSchema = try #require(input["inputSchema"] as? [String: Any])
    let inputProperties = try #require(inputSchema["properties"] as? [String: Any])
    #expect(inputProperties["event"] != nil)

    let listedMachines = try await request("tools/call", params: [
        "name": "fsuae_machines_list", "arguments": [:],
    ])
    let machineResult = try #require(listedMachines["result"] as? [String: Any])
    let machineContent = try #require(machineResult["content"] as? [[String: Any]])
    #expect(machineContent.first?["text"] as? String == "[\n\n]")

    _ = try await request("tools/call", params: [
        "name": "fsuae_configuration_add",
        "arguments": ["name": "Agent A1200", "model": "A1200"],
    ])
    _ = try await request("tools/call", params: [
        "name": "fsuae_configuration_duplicate",
        "arguments": ["source": "Agent A1200", "name": "Agent A1200 Copy"],
    ])
    #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("Agent A1200.fs-uae").path))
    #expect(FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("Agent A1200 Copy.fs-uae").path))
}

@Test func sharedFrameTransportPublishesLatestFrame() throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("fsuae-frame-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    let writer = try #require(MacFSUAEFrameTransport(creating: path))
    let reader = try #require(MacFSUAEFrameTransport(opening: path))
    let pixels = Data(repeating: 0x5a, count: 16)
    writer.publish(MacFSUAEFrame(width: 2, height: 2, stride: 8,
                                 crop: CGRect(x: 0, y: 0, width: 2, height: 2),
                                 refreshRate: 50, isRTG: false, sequence: 42,
                                 pixels: pixels))
    let frame = try #require(reader.latest(after: 0))
    #expect(frame.sequence == 42)
    #expect(frame.pixels == pixels)
    #expect(reader.latest(after: 42)?.sequence == nil)
}
