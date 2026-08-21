import Combine
import Foundation

public struct FSUAEOptionChoice: Identifiable, Hashable, Sendable {
    public let value: String
    public let title: String
    public var id: String { value }

    public init(_ value: String, _ title: String) {
        self.value = value
        self.title = title
    }
}

public struct FSUAEModelProfile: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let chipset: String
    public let defaultCPU: String
    public let defaultChipMemory: String
    public let defaultSlowMemory: String
    public let defaultMotherboardRAM: String
    public let defaultFloppyCount: Int
    public let supportsZorroIII: Bool
    public let cpuChoices: [String]
    public let acceleratorChoices: [String]
    public let defaultAccelerator: String
    public let defaultGraphicsCard: String

    public static let all: [Self] = {
        let m68k = ["68000", "68010"]
        let ec020 = ["68EC020", "68020"]
        let m030 = ["68EC030", "68030"]
        let m040 = ["68EC040", "68LC040", "68040-NOMMU", "68040"]
        let m060 = ["68EC060", "68LC060", "68060-NOMMU", "68060"]
        let blizzard = ["blizzard-1230-iv", "blizzard-1240", "blizzard-1260", "blizzard-ppc"]

        func profile(_ id: String, _ title: String, _ chipset: String, _ cpu: String,
                     _ chip: String, _ slow: String = "0", motherboard: String = "0",
                     floppies: Int = 1, z3: Bool = false, cpus: [String],
                     accelerators: [String] = [], defaultAccelerator: String = "0",
                     defaultGraphics: String = "none") -> Self {
            Self(id: id, title: title, chipset: chipset, defaultCPU: cpu,
                 defaultChipMemory: chip, defaultSlowMemory: slow,
                 defaultMotherboardRAM: motherboard, defaultFloppyCount: floppies,
                 supportsZorroIII: z3, cpuChoices: cpus,
                 acceleratorChoices: accelerators, defaultAccelerator: defaultAccelerator,
                 defaultGraphicsCard: defaultGraphics)
        }

        return [
            profile("A1000", "Amiga 1000", "OCS", "68000", "512", cpus: m68k),
            profile("A500", "Amiga 500", "OCS", "68000", "512", "512", cpus: m68k),
            profile("A500/512K", "Amiga 500 (512 KB)", "OCS", "68000", "512", cpus: m68k),
            profile("A500+", "Amiga 500+", "ECS", "68000", "1024", cpus: m68k),
            profile("A600", "Amiga 600", "ECS", "68000", "1024", cpus: m68k),
            profile("A1200", "Amiga 1200", "AGA", "68EC020", "2048", cpus: ec020,
                    accelerators: blizzard),
            profile("A1200/3.0", "Amiga 1200 (Kickstart 3.0)", "AGA", "68EC020", "2048",
                    cpus: ec020, accelerators: blizzard),
            profile("A1200/020", "Amiga 1200 (68020)", "AGA", "68020", "2048", z3: true,
                    cpus: ec020, accelerators: blizzard),
            profile("A1200/1230", "Amiga 1200 (Blizzard 1230 IV)", "AGA", "68030", "2048",
                    z3: true, cpus: m030, accelerators: blizzard,
                    defaultAccelerator: "blizzard-1230-iv"),
            profile("A1200/1240", "Amiga 1200 (Blizzard 1240)", "AGA", "68040-NOMMU", "2048",
                    z3: true, cpus: m040, accelerators: blizzard,
                    defaultAccelerator: "blizzard-1240"),
            profile("A1200/1260", "Amiga 1200 (Blizzard 1260)", "AGA", "68060-NOMMU", "2048",
                    z3: true, cpus: m060, accelerators: blizzard,
                    defaultAccelerator: "blizzard-1260"),
            profile("A1200/PPC", "Amiga 1200 (Blizzard PPC)", "AGA", "68060-NOMMU", "2048",
                    z3: true, cpus: m060, accelerators: blizzard,
                    defaultAccelerator: "blizzard-ppc"),
            profile("A3000", "Amiga 3000", "ECS", "68030", "2048", motherboard: "8192",
                    z3: true, cpus: m030 + m040 + m060),
            profile("A4000", "Amiga 4000", "AGA", "68EC030", "2048", motherboard: "8192",
                    floppies: 2, z3: true, cpus: m030 + m040 + m060,
                    accelerators: ["cyberstorm-ppc"]),
            profile("A4000/040", "Amiga 4000 (68040)", "AGA", "68040-NOMMU", "2048",
                    motherboard: "8192", floppies: 2, z3: true, cpus: m040 + m060,
                    accelerators: ["cyberstorm-ppc"]),
            profile("A4000/PPC", "Amiga 4000 (CyberStorm PPC)", "AGA", "68060-NOMMU", "2048",
                    motherboard: "8192", floppies: 2, z3: true, cpus: m060,
                    accelerators: ["cyberstorm-ppc"], defaultAccelerator: "cyberstorm-ppc"),
            profile("A4000/OS4", "Amiga 4000 (PPC / OS4)", "AGA", "68060-NOMMU", "2048",
                    motherboard: "8192", floppies: 2, z3: true, cpus: m060,
                    accelerators: ["cyberstorm-ppc"], defaultAccelerator: "cyberstorm-ppc",
                    defaultGraphics: "picasso-iv-z3"),
            profile("CD32", "Amiga CD32", "AGA", "68EC020", "2048", floppies: 0,
                    cpus: ec020),
            profile("CD32/FMV", "Amiga CD32 + FMV", "AGA", "68EC020", "2048", floppies: 0,
                    cpus: ec020),
            profile("CDTV", "Commodore CDTV", "ECS", "68000", "512", floppies: 0,
                    cpus: m68k),
        ]
    }()

    public static func profile(for id: String) -> Self {
        all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame } ?? all[1]
    }

    public var hasIDE: Bool {
        id == "A600" || id.hasPrefix("A1200") || id.hasPrefix("A4000")
    }

    public var hasSCSI: Bool { id == "A3000" }
    public var hasBuiltInCD: Bool { id == "CDTV" || id.hasPrefix("CD32") }
    public var defaultCDCount: Int { hasBuiltInCD ? 1 : 0 }
    public var defaultHardDriveController: String { id == "A4000/OS4" ? "scsi_cpuboard" : "uae" }
}

public struct FSUAEConfiguration: Identifiable, Equatable, Sendable {
    public var url: URL
    public var text: String
    public var id: URL { url }
    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var model: String { value(for: "amiga_model") ?? "A500" }
    public var modelProfile: FSUAEModelProfile { .profile(for: model) }
    public var hostIntegrationEnabled: Bool {
        ["1", "true", "yes"].contains(value(for: "host_integration")?.lowercased() ?? "")
    }

    public init(url: URL, text: String) {
        self.url = url
        self.text = text
    }

    public init(contentsOf url: URL) throws {
        self.init(url: url, text: try String(contentsOf: url, encoding: .utf8))
    }

    public func value(for key: String) -> String? {
        values(for: key).first
    }

    private func values(for key: String) -> [String] {
        let wanted = Self.normalized(key)
        var inSection = false
        var values: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inSection = trimmed.lowercased() == "[fs-uae]"
            } else if inSection, !trimmed.hasPrefix("#"),
                      let separator = trimmed.firstIndex(of: "=") {
                let found = Self.normalized(String(trimmed[..<separator]))
                if found == wanted {
                    values.append(String(trimmed[trimmed.index(after: separator)...])
                        .trimmingCharacters(in: .whitespaces))
                }
            }
        }
        return values
    }

    public mutating func setValue(_ value: String?, for key: String) {
        var lines = text.components(separatedBy: .newlines)
        let wanted = Self.normalized(key)
        var inSection = false
        var insertion = lines.count

        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if inSection { insertion = index; break }
                inSection = trimmed.lowercased() == "[fs-uae]"
            } else if inSection, !trimmed.hasPrefix("#"),
                      let separator = trimmed.firstIndex(of: "="),
                      Self.normalized(String(trimmed[..<separator])) == wanted {
                if let value, !value.isEmpty {
                    lines[index] = "\(key) = \(value)"
                } else {
                    lines.remove(at: index)
                }
                text = lines.joined(separator: "\n")
                return
            }
        }

        guard let value, !value.isEmpty else { return }
        if !inSection {
            if !lines.isEmpty, lines.last != "" { lines.append("") }
            lines.append("[fs-uae]")
            insertion = lines.count
        }
        lines.insert("\(key) = \(value)", at: insertion)
        text = lines.joined(separator: "\n")
    }

    private static func normalized(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    public static func memoryChoices(for key: String) -> [FSUAEOptionChoice] {
        let standard = FSUAEOptionChoice("", "Model Default")
        switch normalized(key) {
        case "chip_memory":
            return [standard, .init("256", "256 KB"), .init("512", "512 KB"),
                    .init("1024", "1 MB"), .init("1536", "1.5 MB"),
                    .init("2048", "2 MB")]
        case "slow_memory":
            return [standard, .init("0", "None"), .init("512", "512 KB"),
                    .init("1024", "1 MB"), .init("1536", "1.5 MB"),
                    .init("1792", "1.8 MB")]
        case "fast_memory":
            return [standard, .init("0", "None"), .init("1024", "1 MB"),
                    .init("2048", "2 MB"), .init("4096", "4 MB"),
                    .init("8192", "8 MB")]
        case "motherboard_ram":
            return [standard, .init("0", "None"), .init("1024", "1 MB"),
                    .init("2048", "2 MB"), .init("4096", "4 MB"),
                    .init("8192", "8 MB"), .init("16384", "16 MB"),
                    .init("32768", "32 MB"), .init("65536", "64 MB")]
        case "zorro_iii_memory":
            return [standard, .init("0", "None"), .init("1024", "1 MB"),
                    .init("2048", "2 MB"), .init("4096", "4 MB"),
                    .init("8192", "8 MB"), .init("16384", "16 MB"),
                    .init("32768", "32 MB"), .init("65536", "64 MB"),
                    .init("131072", "128 MB"), .init("262144", "256 MB"),
                    .init("393216", "384 MB"), .init("524288", "512 MB"),
                    .init("786432", "768 MB"), .init("1048576", "1024 MB")]
        case "graphics_memory", "graphics_card_memory":
            return [standard, .init("0", "None"), .init("1024", "1 MB"),
                    .init("2048", "2 MB"), .init("4096", "4 MB"),
                    .init("8192", "8 MB"), .init("16384", "16 MB"),
                    .init("32768", "32 MB"), .init("65536", "64 MB"),
                    .init("131072", "128 MB"), .init("262144", "256 MB")]
        case "accelerator_memory":
            return [standard, .init("1024", "1 MB"), .init("2048", "2 MB"),
                    .init("4096", "4 MB"), .init("8192", "8 MB"),
                    .init("16384", "16 MB"), .init("32768", "32 MB"),
                    .init("65536", "64 MB"), .init("131072", "128 MB"),
                    .init("262144", "256 MB")]
        default:
            return []
        }
    }

    public static func canonicalMemoryValue(_ value: String, for key: String) -> String? {
        guard let kilobytes = memoryKilobytes(from: value, small: ["chip_memory", "slow_memory"]
            .contains(normalized(key))) else { return nil }
        return memoryChoices(for: key).first { $0.value == String(kilobytes) }?.value
    }

    public var supportsZorroIIIMemory: Bool {
        if let cpu = value(for: "cpu")?.uppercased() {
            if ["68000", "68010", "68EC020"].contains(cpu) { return false }
            if ["68020", "68EC030", "68030", "68EC040", "68LC040", "68040-NOMMU",
                "68040", "68EC060", "68LC060", "68060-NOMMU", "68060"].contains(cpu) {
                return true
            }
        }
        return modelProfile.supportsZorroIII
    }

    public var effectiveCPU: String {
        if let cpu = value(for: "cpu"), !cpu.isEmpty, cpu.caseInsensitiveCompare("auto") != .orderedSame {
            return cpu.uppercased()
        }
        switch effectiveAccelerator {
        case "blizzard-1230-iv": return "68EC030"
        case "blizzard-1240": return "68040-NOMMU"
        case "blizzard-1260", "blizzard-ppc", "cyberstorm-ppc": return "68060-NOMMU"
        default: return modelProfile.defaultCPU
        }
    }

    public var effectiveAccelerator: String {
        let value = value(for: "accelerator") ?? ""
        return value.isEmpty ? modelProfile.defaultAccelerator : value.lowercased()
    }

    public var maximumAcceleratorMemory: Int {
        effectiveAccelerator == "cyberstorm-ppc" ? 131_072 : 262_144
    }

    public var maximumGraphicsMemory: Int {
        let configured = value(for: "graphics_card") ?? ""
        let card = (configured.isEmpty ? modelProfile.defaultGraphicsCard : configured).lowercased()
        return switch card {
        case "none": 0
        case "picasso-ii", "picasso-ii+": 2_048
        case "picasso-iv", "picasso-iv-z2", "picasso-iv-z3": 4_096
        case "uaegfx-z2": 8_192
        case "uaegfx-z3": 262_144
        case "uaegfx": supportsZorroIIIMemory ? 262_144 : 8_192
        default: 0
        }
    }

    public func optionChoices(for key: String) -> [FSUAEOptionChoice] {
        let profile = modelProfile
        switch Self.normalized(key) {
        case "amiga_model":
            return FSUAEModelProfile.all.map { .init($0.id, $0.title) }
        case "ntsc_mode":
            return [.init("", "Model Default (PAL)"), .init("0", "PAL"), .init("1", "NTSC")]
        case "accuracy":
            return [.init("", "Default (Accurate)"), .init("1", "Accurate"),
                    .init("0", "Faster"), .init("-1", "Fastest")]
        case "cpu":
            return [.init("", "Model Default (\(profile.defaultCPU))")]
                + profile.cpuChoices.map { .init($0, $0) }
        case "fpu":
            let none = FSUAEOptionChoice("0", "None")
            let values: [FSUAEOptionChoice]
            if effectiveCPU.contains("020") || effectiveCPU.contains("030") {
                values = [none, .init("68881", "68881"), .init("68882", "68882")]
            } else if effectiveCPU.contains("040") {
                values = [none, .init("68040", "68040 (internal)")]
            } else if effectiveCPU.contains("060") {
                values = [none, .init("68060", "68060 (internal)")]
            } else {
                values = [none]
            }
            return [.init("", "CPU / model default")] + values
        case "mmu":
            var values = [FSUAEOptionChoice("", "CPU / model default"), .init("0", "None")]
            if effectiveCPU.contains("030") { values.append(.init("68030", "68030")) }
            if effectiveCPU.contains("040") { values.append(.init("68040", "68040")) }
            if effectiveCPU.contains("060") { values.append(.init("68060", "68060")) }
            return values
        case "accelerator":
            var values = [FSUAEOptionChoice("", profile.defaultAccelerator == "0"
                ? "Model Default (None)" : "Model Default (\(Self.acceleratorTitle(profile.defaultAccelerator)))")]
            if profile.defaultAccelerator != "0" { values.append(.init("0", "None")) }
            values += profile.acceleratorChoices.map { .init($0, Self.acceleratorTitle($0)) }
            return values
        case "graphics_card":
            var values = [FSUAEOptionChoice("", profile.defaultGraphicsCard == "none"
                ? "Model Default (None)" : "Model Default (\(Self.graphicsTitle(profile.defaultGraphicsCard)))")]
            if profile.defaultGraphicsCard != "none" { values.append(.init("none", "None")) }
            values += [FSUAEOptionChoice("uaegfx", "UAEGFX (Auto)"),
                       .init("uaegfx-z2", "UAEGFX Zorro II"),
                       .init("picasso-ii", "Picasso II Zorro II"),
                       .init("picasso-ii+", "Picasso II+ Zorro II"),
                       .init("picasso-iv", "Picasso IV (Auto)"),
                       .init("picasso-iv-z2", "Picasso IV Zorro II")]
            if supportsZorroIIIMemory {
                values.insert(.init("uaegfx-z3", "UAEGFX Zorro III"), at: 3)
                values.append(.init("picasso-iv-z3", "Picasso IV Zorro III"))
            }
            return values
        case "network_card":
            return [.init("", "Model Default (None)"), .init("0", "None"), .init("a2065", "A2065")]
        case "sound_card":
            return [.init("", "Model Default (None)"), .init("0", "None"), .init("toccata", "Toccata")]
        case "floppy_drive_count":
            return [.init("", "Model Default (\(profile.defaultFloppyCount))")]
                + (0...4).map { .init(String($0), String($0)) }
        case "floppy_drive_speed":
            return [.init("", "Default (100%)"), .init("100", "100%"), .init("200", "200%"),
                    .init("400", "400%"), .init("800", "800%"), .init("0", "Turbo")]
        case "cdrom_drive_count":
            return [.init("", "Model Default (\(profile.defaultCDCount))"),
                    .init("0", "None"), .init("1", "1")]
        case "cdrom_drive_0_controller":
            return driveControllerChoices(defaultValue: profile.hasBuiltInCD
                ? "Built in" : profile.defaultHardDriveController)
        case let option where option.hasPrefix("hard_drive_") && option.hasSuffix("_controller"):
            return driveControllerChoices(defaultValue: profile.defaultHardDriveController)
        case let option where option.hasPrefix("hard_drive_") && option.hasSuffix("_type"):
            return [.init("", "Auto-detect"), .init("rdb", "RDB hard disk image")]
        case "jit_memory":
            return [.init("", "Default"), .init("direct", "Direct"), .init("indirect", "Indirect")]
        case "stereo_separation":
            return [.init("", "Default (70%)")]
                + stride(from: 100, through: 0, by: -10).map { .init(String($0), "\($0)%") }
        default:
            return []
        }
    }

    private func driveControllerChoices(defaultValue: String) -> [FSUAEOptionChoice] {
        var values = [FSUAEOptionChoice("", "Model Default (\(Self.controllerTitle(defaultValue)))"),
                      .init("uae", "UAE virtual controller")]
        if modelProfile.hasIDE { values.append(.init("ide", "Built-in IDE")) }
        if modelProfile.hasSCSI { values.append(.init("scsi", "Built-in SCSI")) }
        if effectiveAccelerator != "0" { values.append(.init("scsi_cpuboard", "Accelerator SCSI")) }
        return values
    }

    private static func acceleratorTitle(_ value: String) -> String {
        switch value {
        case "blizzard-1230-iv": "Blizzard 1230 IV"
        case "blizzard-1240": "Blizzard 1240"
        case "blizzard-1260": "Blizzard 1260"
        case "blizzard-ppc": "Blizzard PPC"
        case "cyberstorm-ppc": "CyberStorm PPC"
        default: value
        }
    }

    private static func graphicsTitle(_ value: String) -> String {
        switch value {
        case "picasso-iv-z3": "Picasso IV Zorro III"
        default: value
        }
    }

    private static func controllerTitle(_ value: String) -> String {
        switch value {
        case "uae": "UAE virtual controller"
        case "ide": "Built-in IDE"
        case "scsi": "Built-in SCSI"
        case "scsi_cpuboard": "Accelerator SCSI"
        default: value
        }
    }

    fileprivate func validateMemory() throws {
        let keys = ["chip_memory", "slow_memory", "fast_memory", "zorro_iii_memory",
                    "motherboard_ram", "graphics_memory", "graphics_card_memory",
                    "accelerator_memory"]
        for key in keys {
            for value in values(for: key) where !value.isEmpty {
                guard Self.canonicalMemoryValue(value, for: key) != nil else {
                    throw FSUAEConfigurationError.invalidMemory(key, value)
                }
                if ["zorro_iii_memory", "motherboard_ram"].contains(key),
                   Self.canonicalMemoryValue(value, for: key) != "0", !supportsZorroIIIMemory {
                    throw FSUAEConfigurationError.requires32BitAddressing(key)
                }
                if let canonical = Self.canonicalMemoryValue(value, for: key).flatMap(Int.init) {
                    if key == "accelerator_memory", effectiveAccelerator == "0" ||
                        canonical > maximumAcceleratorMemory {
                        throw FSUAEConfigurationError.invalidMemory(key, value)
                    }
                    if ["graphics_memory", "graphics_card_memory"].contains(key),
                       canonical > maximumGraphicsMemory {
                        throw FSUAEConfigurationError.invalidMemory(key, value)
                    }
                }
            }
        }
    }

    fileprivate func validateKnownChoices() throws {
        let keys = ["amiga_model", "accuracy", "cpu", "fpu", "mmu", "accelerator",
                    "graphics_card", "network_card", "sound_card", "floppy_drive_count",
                    "floppy_drive_speed", "cdrom_drive_count", "cdrom_drive_0_controller",
                    "jit_memory", "stereo_separation"]
            + (0..<10).flatMap { ["hard_drive_\($0)_controller", "hard_drive_\($0)_type"] }
        for key in keys {
            let allowed = optionChoices(for: key).map(\.value)
            for value in values(for: key) where !value.isEmpty {
                if key == "floppy_drive_count", value.caseInsensitiveCompare("auto") == .orderedSame {
                    continue
                }
                if ["cpu", "fpu", "mmu"].contains(key),
                   value.caseInsensitiveCompare("auto") == .orderedSame { continue }
                if key == "accelerator", value == "0" { continue }
                if key == "graphics_card", value.caseInsensitiveCompare("none") == .orderedSame {
                    continue
                }
                guard allowed.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
                    throw FSUAEConfigurationError.invalidOption(key, value)
                }
            }
        }
        for value in values(for: "ntsc_mode") where !value.isEmpty {
            guard ["0", "1"].contains(value) else {
                throw FSUAEConfigurationError.invalidOption("ntsc_mode", value)
            }
        }
        if !modelProfile.acceleratorChoices.contains(effectiveAccelerator), effectiveAccelerator != "0" {
            throw FSUAEConfigurationError.invalidOption("accelerator", effectiveAccelerator)
        }

        let ranges: [(String, ClosedRange<Int>)] = [
            ("cpu_idle", 0...10),
            ("floppy_drive_volume", 0...100),
            ("floppy_drive_volume_empty", 0...100),
        ] + (0..<10).map { ("hard_drive_\($0)_priority", -128...127) }
        for (key, range) in ranges {
            for value in values(for: key) where !value.isEmpty {
                guard Int(value).map(range.contains) == true else {
                    throw FSUAEConfigurationError.invalidOption(key, value)
                }
            }
        }

        let booleans = ["jit_compiler", "blizzard_scsi_kit", "cdrom_drive_0_delay", "cdfs",
                        "bsdsocket_library", "clipboard_sharing", "host_integration",
                        "save_states", "line_doubling", "low_resolution"]
            + (0..<10).map { "hard_drive_\($0)_read_only" }
        for key in booleans {
            for value in values(for: key) where !value.isEmpty {
                guard value == "0" || value == "1" else {
                    throw FSUAEConfigurationError.invalidOption(key, value)
                }
            }
        }
    }

    private static func memoryKilobytes(from value: String, small: Bool) -> Int? {
        var number = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty else { return nil }
        var factor = 1
        var hasUnit = false
        if let suffix = number.last, "KkMm".contains(suffix) {
            hasUnit = true
            factor = "Mm".contains(suffix) ? 1024 : 1
            number.removeLast()
        }
        guard let parsed = Int(number) else { return nil }
        if !small, !hasUnit, parsed < 1024 {
            factor = 1024
        }
        let result = parsed.multipliedReportingOverflow(by: factor)
        return result.overflow ? nil : result.partialValue
    }
}

private enum FSUAEConfigurationError: LocalizedError {
    case invalidMemory(String, String)
    case invalidOption(String, String)
    case invalidModel(String)
    case requires32BitAddressing(String)

    var errorDescription: String? {
        switch self {
        case let .invalidMemory(key, value):
            "\(key) has an unsupported value (\(value))."
        case let .invalidOption(key, value):
            "\(key) is not valid for this machine (\(value))."
        case let .invalidModel(model):
            "Unknown Amiga model (\(model))."
        case let .requires32BitAddressing(key):
            "\(key) requires a machine with 32-bit addressing."
        }
    }
}

@MainActor
public final class FSUAEConfigurationLibrary: ObservableObject {
    public static let shared = FSUAEConfigurationLibrary()

    @Published public private(set) var configurations: [FSUAEConfiguration] = []
    public let directory: URL

    public init(fileManager: FileManager = .default, directory explicitDirectory: URL? = nil) {
        if let explicitDirectory {
            directory = explicitDirectory
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            let legacy = home.appendingPathComponent("FS-UAE", isDirectory: true)
                .appendingPathComponent("Configurations", isDirectory: true)
            let legacyFiles = try? fileManager.contentsOfDirectory(at: legacy,
                                                                   includingPropertiesForKeys: nil)
            directory = legacyFiles?.contains(where: { $0.pathExtension.lowercased() == "fs-uae" }) == true
                ? legacy
                : home.appendingPathComponent("Documents/FS-UAE/Configurations", isDirectory: true)
        }
        reload()
    }

    public func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        configurations = urls.filter { $0.pathExtension.lowercased() == "fs-uae" }
            .compactMap { try? FSUAEConfiguration(contentsOf: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func draft() -> FSUAEConfiguration {
        var number = 1
        var url = directory.appendingPathComponent("New Configuration.fs-uae")
        while FileManager.default.fileExists(atPath: url.path) {
            number += 1
            url = directory.appendingPathComponent("New Configuration \(number).fs-uae")
        }
        return FSUAEConfiguration(url: url,
                           text: "# FS-UAE configuration\n\n[fs-uae]\namiga_model = A500\n")
    }

    public func configuration(named name: String) -> FSUAEConfiguration? {
        let suffix = ".fs-uae"
        let clean = name.lowercased().hasSuffix(suffix)
            ? String(name.dropLast(suffix.count)) : name
        return configurations.first {
            $0.name.caseInsensitiveCompare(clean) == .orderedSame
        }
    }

    @discardableResult
    public func add(named name: String, model: String = "A500") throws -> URL {
        guard FSUAEModelProfile.all.contains(where: {
            $0.id.caseInsensitiveCompare(model) == .orderedSame
        }) else {
            throw FSUAEConfigurationError.invalidModel(model)
        }
        let url = directory.appendingPathComponent(name).appendingPathExtension("fs-uae")
        let configuration = FSUAEConfiguration(
            url: url,
            text: "# FS-UAE configuration\n\n[fs-uae]\namiga_model = \(model)\n")
        return try save(configuration, named: name)
    }

    @discardableResult
    public func duplicate(_ sourceName: String, named name: String) throws -> URL {
        guard let source = configuration(named: sourceName) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let url = directory.appendingPathComponent(name).appendingPathExtension("fs-uae")
        return try save(FSUAEConfiguration(url: url, text: source.text), named: name)
    }

    public func delete(named name: String) throws {
        guard let configuration = configuration(named: name) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.trashItem(at: configuration.url, resultingItemURL: nil)
        reload()
    }

    @discardableResult
    public func save(_ configuration: FSUAEConfiguration, named name: String) throws -> URL {
        try configuration.validateMemory()
        try configuration.validateKnownChoices()
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains(":") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(clean).appendingPathExtension("fs-uae")
        if destination != configuration.url,
           FileManager.default.fileExists(atPath: destination.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        try configuration.text.write(to: destination, atomically: true, encoding: .utf8)
        if configuration.url != destination,
           FileManager.default.fileExists(atPath: configuration.url.path),
           configurations.contains(where: { $0.url == configuration.url }) {
            try FileManager.default.removeItem(at: configuration.url)
        }
        reload()
        return destination
    }
}
