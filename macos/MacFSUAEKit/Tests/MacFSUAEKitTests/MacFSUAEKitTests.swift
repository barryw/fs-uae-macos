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

@Test func guestStatusRejectsPartialAndStaleResponses() {
    let token: UInt32 = 0x1234_5678
    let completed = Data([0x31, 0x31, 0, 0, 0, 0, 0x12, 0x34, 0x56, 0x78])

    #expect(parseGuestStatus(completed, token: token) ==
        MacFSUAEGuestStatus(succeeded: true, exitCode: 0))
    #expect(parseGuestStatus(completed.dropLast(), token: token) == nil)
    #expect(parseGuestStatus(completed, token: 0x1234_5679) == nil)

    let failed = Data([0x30, 0x31, 0xff, 0xff, 0xff, 0xfb, 0x12, 0x34, 0x56, 0x78])
    #expect(parseGuestStatus(failed, token: token) ==
        MacFSUAEGuestStatus(succeeded: false, exitCode: -5))
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
    #expect(tools.count == 26)
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

/// Exact console text the segment tracker emits, so a change to either the
/// debugger's format or the parsers shows up here rather than as an empty
/// Guru report.
@MainActor
private func segtrackerParser() -> MacFSUAEMCPServer {
    MacFSUAEMCPServer(defaults: UserDefaults(suiteName: "fsuae-parse-\(UUID().uuidString)")!,
                      library: FSUAEConfigurationLibrary(
                          directory: FileManager.default.temporaryDirectory
                              .appendingPathComponent(UUID().uuidString, isDirectory: true)),
                      session: MacFSUAEEngineSession(),
                      startAutomatically: false)
}

@MainActor
@Test func parsesSeglistListing() {
    let output = """
    > Zl
    'SYS:Barry/spinner' @0021a000
      #00 [0021a004,00004000,0021e004]  123 symbols,    4 src files
      #01 [00220004,00001000,00221004]
    'dh0:c/list' @00300000
      #00 [00300004,00000800,00300804]
    found 2 seglists.
    """
    let seglists = segtrackerParser().parseSeglists(output)
    #expect(seglists.count == 2)
    #expect(seglists[0]["name"] as? String == "SYS:Barry/spinner")
    #expect(seglists[0]["address"] as? String == "0x0021a000")
    let segments = seglists[0]["segments"] as? [[String: Any]]
    #expect(segments?.count == 2)
    #expect(segments?[0]["start"] as? String == "0x0021a004")
    #expect(segments?[0]["size"] as? Int == 0x4000)
    #expect(segments?[0]["end"] as? String == "0x0021e004")
    #expect(segments?[0]["symbols"] as? Int == 123)
    #expect(segments?[0]["source_files"] as? Int == 4)
    // The second segment carries no debug info, so it reports no counts.
    #expect(segments?[1]["symbols"] == nil)
    #expect(seglists[1]["name"] as? String == "dh0:c/list")
}

@MainActor
@Test func parsesAddressLookupWithSymbolAndSourceLine() {
    let output = """
    > Za 21ab34
    0021ab34: 'SYS:Barry/spinner' #00 [0021a004,00004000,0021e004] +00001b30
        0021aa00 +00000134  _main
        0021ab20 +00000014  spinner.c:142
    """
    let found = segtrackerParser().parseAddressLookup(output)
    #expect(found["found"] as? Bool == true)
    #expect(found["seglist"] as? String == "SYS:Barry/spinner")
    #expect(found["segment_offset"] as? String == "0x00001b30")
    #expect(found["symbol"] as? String == "_main")
    #expect(found["symbol_address"] as? String == "0x0021aa00")
    #expect(found["symbol_offset"] as? String == "0x00000134")
    #expect(found["source_file"] as? String == "spinner.c")
    #expect(found["source_line"] as? Int == 142)
    #expect(found["source_offset"] as? String == "0x00000014")
    let segment = found["segment"] as? [String: Any]
    #expect(segment?["index"] as? Int == 0)
    #expect(segment?["start"] as? String == "0x0021a004")
}

@MainActor
@Test func parsesAddressLookupWithoutDebugInfo() {
    let server = segtrackerParser()
    // A tracked seglist with no symbols attached yet: header only.
    let bare = server.parseAddressLookup("""
    > Za 21ab34
    0021ab34: 'SYS:Barry/spinner' #00 [0021a004,00004000,0021e004] +00001b30
    """)
    #expect(bare["found"] as? Bool == true)
    #expect(bare["symbol"] == nil)
    #expect(bare["source_file"] == nil)

    let missing = server.parseAddressLookup("""
    > Za 7c0f10
    007c0f10: not found in any segments.
    """)
    #expect(missing["found"] as? Bool == false)
}

@MainActor
@Test func parsesHexAddressesLeniently() {
    let server = segtrackerParser()
    #expect(server.parseHex("0021ab34") == 0x0021ab34)
    #expect(server.parseHex("0x21AB34") == 0x21ab34)
    #expect(server.parseHex(" 21ab34 ") == 0x21ab34)
    #expect(server.parseHex("") == nil)
    #expect(server.parseHex("nothex") == nil)
    #expect(server.parseHex("1234567890") == nil)
}

@MainActor
@Test func countsDebugHunksInLoadOutput() {
    let server = segtrackerParser()
    // Real Zf output for a file linked without debug information.
    let bare = server.countDebugInfo("""
    file '/Users/barry/.build/amiga/FSUAE-Diag': 6 segments
      segment #00: CODE [000021c8]    0 symbols,   0 src files
      segment #01: DATA [00000034]    0 symbols,   0 src files
      segment #05: BSS  [0000101c]    0 symbols,   0 src files
    """)
    #expect(bare.symbols == 0)
    #expect(bare.sourceFiles == 0)

    let withInfo = server.countDebugInfo("""
    file '/Users/barry/spinner': 2 segments
      segment #00: CODE [000021c8]  123 symbols,   4 src files
      segment #01: DATA [00000034]   17 symbols,   1 src files
    """)
    #expect(withInfo.symbols == 140)
    #expect(withInfo.sourceFiles == 5)
}
