import AppKit
import AVFoundation
import CMacFSUAEEngine
import Combine
import Foundation

public struct MacFSUAEFrame: Sendable {
    public let width: Int
    public let height: Int
    public let stride: Int
    public let crop: CGRect
    public let refreshRate: Double
    public let isRTG: Bool
    public let sequence: UInt64
    public let pixels: Data
}

public struct MacFSUAEDrive: Identifiable, Equatable, Sendable {
    public enum Kind: Int32, Sendable {
        case floppy = 0
        case hardDisk = 1
    }

    public let kind: Kind
    public let index: Int
    public let isActive: Bool
    public let mediaPath: String
    public var id: String { "\(kind.rawValue):\(index)" }
    public var name: String { kind == .floppy ? "DF\(index)" : "DH\(index)" }
}

public struct MacFSUAEHealth: Sendable {
    public let frameSequence: UInt64
    public let programCounter: UInt32
    public let execBase: UInt32
    public let lastAlert: [UInt32]
    public let guestControlReady: Bool
    public let guestControlHeartbeat: UInt32
    public let guestControlGeneration: UInt32
    public let exceptionSequence: UInt64
    public let exceptionVector: UInt32
    public let exceptionPC: UInt32
    public let exceptionAddress: UInt32
    public let exceptionTask: UInt32
    public let debuggerStopped: Bool
    public let exceptionTaskName: String
}

public final class MacFSUAEFrameSource: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: MacFSUAEFrame?
    private let transport: MacFSUAEFrameTransport?

    public init() { transport = nil }

    init(transport: MacFSUAEFrameTransport) { self.transport = transport }

    func publish(_ frame: MacFSUAEFrame) {
        lock.withLock { self.frame = frame }
    }

    public func latest(after sequence: UInt64) -> MacFSUAEFrame? {
        if let transport { return transport.latest(after: sequence) }
        return lock.withLock { () -> MacFSUAEFrame? in
            guard frame?.sequence != sequence else { return nil }
            return frame
        }
    }
}

public final class MacFSUAEFrameTransport: @unchecked Sendable {
    public let path: String
    private let value: OpaquePointer

    public init?(creating path: String) {
        guard let value = path.withCString({ MacFSUAEFrameTransportCreate($0) }) else { return nil }
        self.path = path
        self.value = value
    }

    public init?(opening path: String) {
        guard let value = path.withCString({ MacFSUAEFrameTransportOpen($0) }) else { return nil }
        self.path = path
        self.value = value
    }

    deinit { MacFSUAEFrameTransportClose(value) }

    public func publish(_ frame: MacFSUAEFrame) {
        frame.pixels.withUnsafeBytes { pixels in
            guard let base = pixels.baseAddress else { return }
            var value = fsuaemac_video_frame(
                pixels: base.assumingMemoryBound(to: UInt8.self),
                width: UInt32(frame.width), height: UInt32(frame.height),
                stride: UInt32(frame.stride), crop_x: UInt32(frame.crop.minX),
                crop_y: UInt32(frame.crop.minY), crop_width: UInt32(frame.crop.width),
                crop_height: UInt32(frame.crop.height), refresh_rate: frame.refreshRate,
                flags: frame.isRTG ? 1 : 0, sequence: frame.sequence)
            _ = MacFSUAEFrameTransportPublish(self.value, &value)
        }
    }

    func latest(after sequence: UInt64) -> MacFSUAEFrame? {
        var value = fsuaemac_video_frame()
        var pixels: UnsafeMutableRawPointer?
        guard MacFSUAEFrameTransportCopyLatest(self.value, sequence, &value, &pixels) != 0,
              let pixels else { return nil }
        let data = Data(bytesNoCopy: pixels, count: Int(value.stride * value.height),
                        deallocator: .free)
        return MacFSUAEFrame(
            width: Int(value.width), height: Int(value.height), stride: Int(value.stride),
            crop: CGRect(x: Int(value.crop_x), y: Int(value.crop_y),
                         width: Int(value.crop_width), height: Int(value.crop_height)),
            refreshRate: value.refresh_rate, isRTG: value.flags & 1 != 0,
            sequence: value.sequence, pixels: data)
    }
}

private final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "com.barrywalker.fsuae.audio",
                                      qos: .userInteractive)
    private let speedLock = NSLock()
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 44_100,
                                       channels: 2,
                                       interleaved: true)!
    private var started = false
    private var playbackSpeed = 1.0
    private var isEnabled = true

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ packet: fsuaemac_audio_samples) {
        // ponytail: fast modes mute audio; add rate conversion if users need pitched fast audio.
        guard speedLock.withLock({ playbackSpeed == 1 && isEnabled }) else { return }
        guard let samples = packet.samples, packet.frame_count > 0 else { return }
        let data = Data(bytes: samples,
                        count: Int(packet.frame_count * packet.channel_count) *
                            MemoryLayout<Int16>.size)
        let frameCount = packet.frame_count
        queue.async { [self] in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: frameCount),
                  let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else { return }
            buffer.frameLength = frameCount
            data.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: data.count)
            if !started {
                try? engine.start()
                player.play()
                started = true
            }
            // ponytail: serial scheduling is enough for the proof; add a bounded ring if profiling shows drift.
            player.scheduleBuffer(buffer)
        }
    }

    func setSpeed(_ speed: Double) {
        speedLock.withLock { playbackSpeed = speed }
        queue.async { [self] in
            player.stop()
            started = false
        }
    }

    func setEnabled(_ enabled: Bool) {
        speedLock.withLock { isEnabled = enabled }
        guard !enabled else { return }
        queue.async { [self] in
            player.stop()
            engine.stop()
            started = false
        }
    }

    func stop() {
        queue.sync {
            player.stop()
            engine.stop()
            started = false
        }
    }
}

private func receiveVideo(_ frame: UnsafePointer<fsuaemac_video_frame>?,
                          _ context: UnsafeMutableRawPointer?) {
    guard let frame, let context, let pixels = frame.pointee.pixels else { return }
    let value = frame.pointee
    let copied = Data(bytes: pixels, count: Int(value.stride * value.height))
    let session = Unmanaged<MacFSUAEEngineSession>.fromOpaque(context).takeUnretainedValue()
    session.frames.publish(MacFSUAEFrame(
        width: Int(value.width), height: Int(value.height), stride: Int(value.stride),
        crop: CGRect(x: Int(value.crop_x), y: Int(value.crop_y),
                     width: Int(value.crop_width), height: Int(value.crop_height)),
        refreshRate: value.refresh_rate, isRTG: value.flags & 1 != 0,
        sequence: value.sequence, pixels: copied))
}

private func receiveAudio(_ samples: UnsafePointer<fsuaemac_audio_samples>?,
                          _ context: UnsafeMutableRawPointer?) {
    guard let samples, let context else { return }
    Unmanaged<MacFSUAEEngineSession>.fromOpaque(context)
        .takeUnretainedValue().audio?.play(samples.pointee)
}

private func receiveLog(_ message: UnsafePointer<CChar>?,
                        _ context: UnsafeMutableRawPointer?) {
    guard let message, let context else { return }
    let text = String(cString: message).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let session = Unmanaged<MacFSUAEEngineSession>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in session.status = text }
}

private func receiveDriveStatus(_ status: UnsafePointer<fsuaemac_drive_status>?,
                                _ context: UnsafeMutableRawPointer?) {
    guard let status, let context,
          let kind = MacFSUAEDrive.Kind(rawValue: Int32(status.pointee.kind)) else { return }
    let value = status.pointee
    let drive = MacFSUAEDrive(kind: kind, index: Int(value.index),
                              isActive: value.active != 0,
                              mediaPath: value.media_path.map(String.init(cString:)) ?? "")
    let session = Unmanaged<MacFSUAEEngineSession>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in session.updateDriveStatus(drive) }
}

func updatingDriveStatuses(_ current: [MacFSUAEDrive], with drive: MacFSUAEDrive)
    -> [MacFSUAEDrive] {
    var drives = current
    if drive.index < 0 {
        return drives.map {
            $0.kind == drive.kind
                ? MacFSUAEDrive(kind: $0.kind, index: $0.index,
                                isActive: drive.isActive, mediaPath: $0.mediaPath)
                : $0
        }
    }
    if let index = drives.firstIndex(where: { $0.id == drive.id }) {
        drives[index] = drive
    } else {
        drives.append(drive)
        drives.sort { ($0.kind.rawValue, $0.index) < ($1.kind.rawValue, $1.index) }
    }
    return drives
}

@MainActor
public final class MacFSUAEEngineSession: ObservableObject {
    public static let shared = MacFSUAEEngineSession()

    @Published public private(set) var isRunning = false
    @Published public fileprivate(set) var status = "Ready"
    @Published public private(set) var isPaused = false
    @Published public private(set) var emulationSpeed = 1.0
    @Published public private(set) var activeConfiguration: URL?
    @Published public private(set) var drives: [MacFSUAEDrive] = []
    nonisolated public let frames = MacFSUAEFrameSource()

    public var floppyDrives: [MacFSUAEDrive] { drives.filter { $0.kind == .floppy } }
    public var hardDrives: [MacFSUAEDrive] { drives.filter { $0.kind == .hardDisk } }

    nonisolated fileprivate let audio: AudioOutput?
    private let presentsVideo: Bool
    private var loaded = false

    public init(presentsVideo: Bool = true, playsAudio: Bool = true) {
        self.presentsVideo = presentsVideo
        audio = playsAudio ? AudioOutput() : nil
    }

    public func start(configuration url: URL) {
        guard !isRunning else { return }
        drives.removeAll()
        do {
            try loadRuntime()
        } catch {
            status = error.localizedDescription
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        if presentsVideo {
            MacFSUAEEngineSetVideoCallback(receiveVideo, context)
        } else {
            MacFSUAEEngineSetVideoCallback(nil, nil)
        }
        if audio != nil {
            MacFSUAEEngineSetAudioCallback(receiveAudio, context)
        } else {
            MacFSUAEEngineSetAudioCallback(nil, nil)
        }
        MacFSUAEEngineSetLogCallback(receiveLog, context)
        MacFSUAEEngineSetDriveStatusCallback(receiveDriveStatus, context)

        let started = url.path.withCString { path in
            var configuration = fsuaemac_configuration(configuration_path: path)
            return MacFSUAEEngineStart(&configuration) != 0
        }
        isRunning = started
        activeConfiguration = started ? url : nil
        if started {
            _ = MacFSUAEEngineSetSpeed(emulationSpeed)
            audio?.setSpeed(emulationSpeed)
        }
        status = started ? "Machine running" : String(cString: MacFSUAEEngineLastError())
    }

    public func stop() {
        guard isRunning else { return }
        MacFSUAEEngineStop()
        audio?.stop()
        MacFSUAEEngineUnload()
        loaded = false
        isRunning = false
        isPaused = false
        activeConfiguration = nil
        drives.removeAll()
        status = "Stopped"
    }

    public func pause() {
        guard isRunning else { return }
        isPaused.toggle()
        _ = MacFSUAEEngineQueuePause(isPaused ? 1 : 0)
    }

    public func reset(hard: Bool = false) {
        guard isRunning else { return }
        _ = MacFSUAEEngineQueueReset(hard ? 1 : 0)
    }

    public func health() -> MacFSUAEHealth? {
        var value = fsuaemac_health()
        guard MacFSUAEEngineGetHealth(&value) != 0 else { return nil }
        let taskName = withUnsafeBytes(of: &value.exception_task_name) { bytes in
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            return String(data: Data(bytes.prefix(length)), encoding: .isoLatin1) ?? ""
        }
        return MacFSUAEHealth(
            frameSequence: value.frame_sequence, programCounter: value.program_counter,
            execBase: value.exec_base,
            lastAlert: [value.last_alert.0, value.last_alert.1,
                        value.last_alert.2, value.last_alert.3],
            guestControlReady: value.guest_control_ready != 0,
            guestControlHeartbeat: value.guest_control_heartbeat,
            guestControlGeneration: value.guest_control_generation,
            exceptionSequence: value.exception_sequence,
            exceptionVector: value.exception_vector,
            exceptionPC: value.exception_pc,
            exceptionAddress: value.exception_address,
            exceptionTask: value.exception_task,
            debuggerStopped: value.debugger_stopped != 0,
            exceptionTaskName: taskName)
    }

    public func clearException(taskName: String? = nil) {
        guard isRunning else { return }
        if let taskName {
            taskName.withCString { MacFSUAEEngineClearException($0) }
        } else {
            MacFSUAEEngineClearException(nil)
        }
    }

    public func debugCommand(_ command: String) -> String? {
        var output = [CChar](repeating: 0, count: 1_048_576)
        let succeeded = command.withCString {
            MacFSUAEEngineDebugCommand($0, &output, UInt32(output.count), 5_000)
        }
        guard succeeded != 0 else { return nil }
        let bytes = output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public func saveState(to url: URL) -> Bool {
        guard isRunning else { return false }
        return url.path.withCString { MacFSUAEEngineSnapshot($0, 0, 60_000) != 0 }
    }

    public func restoreState(from url: URL) -> Bool {
        guard isRunning else { return false }
        return url.path.withCString { MacFSUAEEngineSnapshot($0, 1, 60_000) != 0 }
    }

    public func setAudioEnabled(_ enabled: Bool) {
        audio?.setEnabled(enabled)
    }

    public func setSpeed(_ multiplier: Double) {
        guard isRunning, [0.0, 1.0, 2.0, 4.0].contains(multiplier),
              MacFSUAEEngineSetSpeed(multiplier) != 0 else { return }
        emulationSpeed = multiplier
        audio?.setSpeed(multiplier)
    }

    public func insertFloppy(_ url: URL, into drive: Int = 0) {
        guard isRunning, (0..<4).contains(drive) else { return }
        _ = url.path.withCString { MacFSUAEEngineQueueFloppy(Int32(drive), $0) }
        status = url.lastPathComponent
    }

    public func ejectFloppy(_ drive: Int) {
        guard isRunning, (0..<4).contains(drive) else { return }
        _ = "".withCString { MacFSUAEEngineQueueFloppy(Int32(drive), $0) }
        status = "DF\(drive) ejected"
    }

    func updateDriveStatus(_ drive: MacFSUAEDrive) {
        drives = updatingDriveStatuses(drives, with: drive)
    }

    public func sendKey(_ keyCode: UInt16, pressed: Bool) -> Bool {
        MacFSUAEEngineQueueKey(keyCode, pressed ? 1 : 0) != 0
    }

    public func sendMouseMove(deltaX: Int32, deltaY: Int32) -> Bool {
        MacFSUAEEngineQueueMouseMove(deltaX, deltaY) != 0
    }

    public func sendMousePosition(x: Int32, y: Int32) -> Bool {
        MacFSUAEEngineQueueMousePosition(x, y) != 0
    }

    public func sendMouseButton(_ button: UInt32, pressed: Bool) -> Bool {
        MacFSUAEEngineQueueMouseButton(button, pressed ? 1 : 0) != 0
    }

    private func loadRuntime() throws {
        guard !loaded else { return }
        let environment = ProcessInfo.processInfo.environment["FSUAE_MAC_RUNTIME"]
        let bundled = Bundle.main.privateFrameworksURL?.appendingPathComponent("libfsuaemac.dylib").path
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../../.build/fsuae-3/libfsuaemac.dylib").standardized.path
        guard let path = [environment, bundled, development].compactMap({ $0 })
            .first(where: FileManager.default.fileExists(atPath:)),
              MacFSUAEEngineLoad(path) != 0 else {
            throw NSError(domain: "MacFSUAEKit", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "libfsuaemac.dylib not found. Run macos/scripts/build-runtime.sh."])
        }
        loaded = true
    }
}
