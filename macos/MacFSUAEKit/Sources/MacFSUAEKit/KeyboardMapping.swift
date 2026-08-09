import Combine
import Foundation

public struct MacFSUAEKeyDefinition: Identifiable, Hashable, Sendable {
    public let code: UInt16
    public let macTitle: String
    public let amigaTitle: String?
    public var id: UInt16 { code }

    public init(_ code: UInt16, _ macTitle: String, _ amigaTitle: String? = nil) {
        self.code = code
        self.macTitle = macTitle
        self.amigaTitle = amigaTitle
    }
}

public enum MacFSUAEKeyboardLayout {
    public static let keys: [MacFSUAEKeyDefinition] = [
        .init(53, "Escape", "Esc"),
        .init(122, "F1", "F1"), .init(120, "F2", "F2"),
        .init(99, "F3", "F3"), .init(118, "F4", "F4"),
        .init(96, "F5", "F5"), .init(97, "F6", "F6"),
        .init(98, "F7", "F7"), .init(100, "F8", "F8"),
        .init(101, "F9", "F9"), .init(109, "F10", "F10"),
        .init(103, "F11"), .init(111, "F12"),
        .init(50, "`", "`"), .init(18, "1", "1"), .init(19, "2", "2"),
        .init(20, "3", "3"), .init(21, "4", "4"), .init(23, "5", "5"),
        .init(22, "6", "6"), .init(26, "7", "7"), .init(28, "8", "8"),
        .init(25, "9", "9"), .init(29, "0", "0"), .init(27, "-", "-"),
        .init(24, "=", "="), .init(51, "Delete", "Backspace"),
        .init(48, "Tab", "Tab"),
        .init(12, "Q", "Q"), .init(13, "W", "W"), .init(14, "E", "E"),
        .init(15, "R", "R"), .init(17, "T", "T"), .init(16, "Y", "Y"),
        .init(32, "U", "U"), .init(34, "I", "I"), .init(31, "O", "O"),
        .init(35, "P", "P"), .init(33, "[", "["), .init(30, "]", "]"),
        .init(42, "\\", "\\"),
        .init(57, "Caps Lock", "Caps Lock"),
        .init(0, "A", "A"), .init(1, "S", "S"), .init(2, "D", "D"),
        .init(3, "F", "F"), .init(5, "G", "G"), .init(4, "H", "H"),
        .init(38, "J", "J"), .init(40, "K", "K"), .init(37, "L", "L"),
        .init(41, ";", ";"), .init(39, "'", "'"), .init(36, "Return", "Return"),
        .init(56, "Left Shift", "Left Shift"), .init(60, "Right Shift", "Right Shift"),
        .init(6, "Z", "Z"), .init(7, "X", "X"), .init(8, "C", "C"),
        .init(9, "V", "V"), .init(11, "B", "B"), .init(45, "N", "N"),
        .init(46, "M", "M"), .init(43, ",", ","), .init(47, ".", "."),
        .init(44, "/", "/"),
        .init(59, "Left Control", "Control"), .init(62, "Right Control", "Control"),
        .init(58, "Left Option", "Left Alt"), .init(61, "Right Option", "Right Alt"),
        .init(55, "Left Command", "Open Amiga (Left)"),
        .init(54, "Right Command", "Closed Amiga (Right)"),
        .init(49, "Space", "Space"),
        .init(123, "Left Arrow", "Left Arrow"), .init(124, "Right Arrow", "Right Arrow"),
        .init(125, "Down Arrow", "Down Arrow"), .init(126, "Up Arrow", "Up Arrow"),
        .init(114, "Help / Insert", "Amiga #"),
        .init(115, "Home", "Keypad ("), .init(116, "Page Up", "Keypad )"),
        .init(119, "End", "Help"), .init(117, "Forward Delete", "Delete"),
        .init(121, "Page Down", "Closed Amiga (Right)"),
        .init(10, "ISO Section", "Amiga < >"),
        .init(82, "Keypad 0", "Keypad 0"), .init(83, "Keypad 1", "Keypad 1"),
        .init(84, "Keypad 2", "Keypad 2"), .init(85, "Keypad 3", "Keypad 3"),
        .init(86, "Keypad 4", "Keypad 4"), .init(87, "Keypad 5", "Keypad 5"),
        .init(88, "Keypad 6", "Keypad 6"), .init(89, "Keypad 7", "Keypad 7"),
        .init(91, "Keypad 8", "Keypad 8"), .init(92, "Keypad 9", "Keypad 9"),
        .init(65, "Keypad .", "Keypad ."), .init(67, "Keypad *", "Keypad *"),
        .init(69, "Keypad +", "Keypad +"), .init(75, "Keypad /", "Keypad /"),
        .init(78, "Keypad -", "Keypad -"), .init(76, "Keypad Enter", "Keypad Enter"),
    ]

    public static let amigaKeys = keys.filter { $0.amigaTitle != nil && $0.code != 62 && $0.code != 121 }

    public static func macTitle(for code: UInt16) -> String {
        keys.first { $0.code == code }?.macTitle ?? "Key \(code)"
    }
}

@MainActor
public final class MacFSUAEKeyboardMapping: ObservableObject {
    public static let shared = MacFSUAEKeyboardMapping()
    public static let notMapped = UInt16.max

    @Published private var overrides: [UInt16: UInt16]
    private let defaults: UserDefaults
    private let defaultsKey = "fsuae.keyboardMapping"
    public var isDefault: Bool { overrides.isEmpty }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([UInt16: UInt16].self, from: data) {
            overrides = saved
        } else {
            overrides = [:]
        }
    }

    public func target(for hostCode: UInt16) -> UInt16? {
        if let target = overrides[hostCode] {
            return target == Self.notMapped ? nil : target
        }
        return Self.defaultTarget(for: hostCode)
    }

    public func setTarget(_ target: UInt16?, for hostCode: UInt16) {
        let value = target ?? Self.notMapped
        if target == Self.defaultTarget(for: hostCode) {
            overrides.removeValue(forKey: hostCode)
        } else {
            overrides[hostCode] = value
        }
        save()
    }

    public func reset() {
        overrides.removeAll()
        defaults.removeObject(forKey: defaultsKey)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(overrides), forKey: defaultsKey)
    }

    private static func defaultTarget(for hostCode: UInt16) -> UInt16? {
        switch hostCode {
        case 62: return 59
        case 121: return 54
        default:
            return MacFSUAEKeyboardLayout.keys.first { $0.code == hostCode }?.amigaTitle == nil
                ? nil : hostCode
        }
    }
}
