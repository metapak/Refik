import Foundation
import Darwin
import RefikInteractionWire

func editorFocusStream() -> Never {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/refik")
    let socketURL = root.appendingPathComponent("events.sock")
    guard EditorFocusHost.ancestor(of: getpid()) != nil, HookWire.secureFile(socketURL, socket: true),
          let token = HookWire.secret(root.appendingPathComponent("signal.token")) else { exit(0) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0); guard fd >= 0 else { exit(0) }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketURL.path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { exit(0) }
    withUnsafeMutablePointer(to: &address.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { chars in
            for (i, b) in bytes.enumerated() { chars[i] = CChar(bitPattern: b) }; chars[bytes.count] = 0
        }
    }
    let connected = withUnsafePointer(to: &address) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { exit(0) }
    HookWire.timeout(fd, seconds: 3)
    guard HookWire.send(HookFrame(type: "editor-focus-connect", token: token), fd: fd),
          let data = HookWire.receive(fd, requireNewline: true, deadline: HookWire.uptime + 3),
          let ready = try? JSONDecoder().decode(HookFrame.self, from: data), ready.type == "editor-focus-ready",
          let epoch = ready.epoch, UUID(uuidString: epoch) != nil else { exit(0) }
    while let data = HookWire.receive(STDIN_FILENO, requireNewline: true),
          let control = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = control["type"] as? String {
        if type == "poll" {
            guard HookWire.send(HookFrame(type: "editor-focus-poll", epoch: epoch), fd: fd),
                  let bytes = HookWire.receive(fd, requireNewline: true, deadline: HookWire.uptime + 3),
                  let challenge = try? JSONDecoder().decode(HookFrame.self, from: bytes),
                  challenge.type == "editor-focus-challenge", challenge.epoch == epoch,
                  let nonce = challenge.actionID, UUID(uuidString: nonce) != nil,
                  let output = try? JSONSerialization.data(withJSONObject: ["type": "challenge", "epoch": epoch, "nonce": nonce]) else { exit(0) }
            FileHandle.standardOutput.write(output + Data([10]))
            continue
        }
        guard ["response", "blur"].contains(type), let object = control["observation"],
              let bytes = try? JSONSerialization.data(withJSONObject: object),
              let observation = try? JSONDecoder().decode(EditorFocusObservation.self, from: bytes), observation.isValid else { exit(0) }
        if type == "blur" {
            guard !observation.focused,
                  HookWire.send(HookFrame(type: "editor-focus-blur", epoch: epoch, editorFocus: observation), fd: fd) else { exit(0) }
        } else {
            guard control["epoch"] as? String == epoch, let nonce = control["nonce"] as? String, UUID(uuidString: nonce) != nil,
                  HookWire.send(HookFrame(type: "editor-focus", epoch: epoch, actionID: nonce, editorFocus: observation), fd: fd) else { exit(0) }
        }
    }
    close(fd); exit(0)
}
