import Darwin
import Foundation
import MacFSUAEKit

@main
struct FSUAEWorker {
    @MainActor
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: FS-UAE Worker CONFIGURATION\n", stderr)
            Darwin.exit(64)
        }

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let framePath = ProcessInfo.processInfo.environment["FSUAE_MAC_FRAME_FILE"]
        let transport = framePath.flatMap(MacFSUAEFrameTransport.init(opening:))
        let session = MacFSUAEEngineSession(presentsVideo: transport != nil,
                                            playsAudio: transport != nil)
        session.start(configuration: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard session.isRunning else {
            fputs("FS-UAE Worker: \(session.status)\n", stderr)
            Darwin.exit(1)
        }
        fputs("FSUAE_STATUS running\n", stderr)
        fflush(stderr)
        session.setAudioEnabled(false)

        Task.detached {
            while let line = readLine() {
                await handleCommand(line, session: session)
            }
        }

        let interrupt = terminationSource(SIGINT, session: session)
        let terminate = terminationSource(SIGTERM, session: session)
        interrupt.resume()
        terminate.resume()

        let parent = getppid()
        var heartbeat = ContinuousClock.now
        var driveUpdate = ContinuousClock.now
        var lastSequence: UInt64 = 0
        var lastDrives: [MacFSUAEDrive] = []
        while session.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
            if getppid() != parent { session.stop() }
            if let frame = session.frames.latest(after: lastSequence) {
                transport?.publish(frame)
                lastSequence = frame.sequence
            }
            if driveUpdate.duration(to: .now) >= .milliseconds(100), session.drives != lastDrives {
                emitDrives(session.drives)
                lastDrives = session.drives
                driveUpdate = .now
            }
            if heartbeat.duration(to: .now) >= .seconds(1), let health = session.health() {
                let alert = health.lastAlert.map(String.init).joined(separator: " ")
                fputs("FSUAE_HEALTH \(health.frameSequence) \(health.programCounter) \(health.execBase) \(alert) \(health.guestControlReady ? 1 : 0)\n", stderr)
                fflush(stderr)
                heartbeat = .now
            }
        }
    }

    @MainActor
    private static func handleCommand(_ line: String, session: MacFSUAEEngineSession) {
        guard let data = line.data(using: .utf8),
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = command["command"] as? String else { return }
        switch name {
        case "key":
            if let code = command["code"] as? Int, let pressed = command["pressed"] as? Bool {
                _ = session.sendKey(UInt16(code), pressed: pressed)
            }
        case "mouse_move":
            if let x = command["x"] as? Int, let y = command["y"] as? Int {
                _ = session.sendMouseMove(deltaX: Int32(x), deltaY: Int32(y))
            }
        case "mouse_button":
            if let button = command["button"] as? Int,
               let pressed = command["pressed"] as? Bool {
                _ = session.sendMouseButton(UInt32(button), pressed: pressed)
            }
        case "pause": session.pause()
        case "reset": session.reset(hard: command["hard"] as? Bool ?? false)
        case "speed":
            if let speed = command["value"] as? Double { session.setSpeed(speed) }
        case "floppy":
            guard let drive = command["drive"] as? Int else { return }
            if let path = command["path"] as? String, !path.isEmpty {
                session.insertFloppy(URL(fileURLWithPath: path), into: drive)
            } else {
                session.ejectFloppy(drive)
            }
        case "audio": session.setAudioEnabled(command["enabled"] as? Bool ?? false)
        case "stop": session.stop()
        default: break
        }
    }

    private static func emitDrives(_ drives: [MacFSUAEDrive]) {
        let rows: [[String: Any]] = drives.map {
            ["kind": $0.kind.rawValue, "index": $0.index,
             "active": $0.isActive, "path": $0.mediaPath]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
        fputs("FSUAE_DRIVES \(data.base64EncodedString())\n", stderr)
        fflush(stderr)
    }

    private static func terminationSource(
        _ signal: Int32, session: MacFSUAEEngineSession
    ) -> DispatchSourceSignal {
        let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
        source.setEventHandler {
            fputs("FSUAE_STATUS stopping\n", stderr)
            fflush(stderr)
            Task { @MainActor in session.stop() }
        }
        return source
    }
}
