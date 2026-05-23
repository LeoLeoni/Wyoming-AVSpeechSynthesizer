import AVFoundation
import Foundation
import Network

// MARK: - CLI

if CommandLine.arguments.contains("--list-voices") {
    for v in AVSpeechSynthesisVoice.speechVoices().sorted(by: { $0.name < $1.name }) {
        print("Voice: \(v.name)  Locale: \(v.language)")
    }
    exit(0)
}

var port: UInt16 = 10200
var voiceName = ""
var idx = 1
let args = CommandLine.arguments
while idx < args.count {
    switch args[idx] {
    case "--port":
        idx += 1
        if idx < args.count, let n = UInt16(args[idx]) { port = n }
    case "--voice":
        idx += 1
        if idx < args.count { voiceName = args[idx] }
    default:
        break
    }
    idx += 1
}

guard !voiceName.isEmpty else {
    FileHandle.standardError.write(Data("--voice is required. Use --list-voices to see installed voices.\n".utf8))
    exit(1)
}

guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == voiceName }) else {
    FileHandle.standardError.write(Data("Voice '\(voiceName)' not found. Use --list-voices.\n".utf8))
    exit(1)
}

// stderr is unbuffered when redirected by launchd, so logs appear immediately in .err file.
func log(_ msg: String) {
    let line = "[\(Date())] \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
}

log("Wyoming AVSpeech listening on port \(port), voice '\(voice.name)' [\(voice.language)]")

// MARK: - Server

let synthesis = Synthesis(voice: voice)
let listener = try! NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
listener.newConnectionHandler = { conn in
    Task { await handleConnection(conn) }
}
listener.start(queue: .global())

RunLoop.main.run()

// MARK: - Connection loop

func handleConnection(_ conn: NWConnection) async {
    conn.start(queue: .global())
    log("connection opened from \(conn.endpoint)")
    var buffer = Data()
    while let line = await readLine(into: &buffer, from: conn) {
        guard var json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = json["type"] as? String else {
            log("ignored non-JSON line (\(line.count) bytes)")
            continue
        }

        // Wyoming has two ways to attach data: inline `data` object, or `data_length`
        // pointing at a separate JSON blob immediately after the header line.
        // HA uses data_length, so we must read it and graft it into json["data"].
        if let dataLength = json["data_length"] as? Int, dataLength > 0,
           let dataBytes = await readBytes(dataLength, into: &buffer, from: conn),
           let dataObj = try? JSONSerialization.jsonObject(with: dataBytes) as? [String: Any] {
            json["data"] = dataObj
        }

        // payload_length is for binary trailing data (e.g. audio chunks); drain it.
        if let payloadLength = json["payload_length"] as? Int, payloadLength > 0 {
            _ = await readBytes(payloadLength, into: &buffer, from: conn)
        }

        switch type {
        case "describe":
            send(describeResponse(), to: conn)
        case "synthesize":
            let text = (json["data"] as? [String: Any])?["text"] as? String ?? ""
            log("synthesize: \"\(text.prefix(80))\"")
            await handleSynthesize(json["data"] as? [String: Any], on: conn)
        default:
            continue
        }
    }
    log("connection closed")
    conn.cancel()
}

// MARK: - Message handlers

func handleSynthesize(_ data: [String: Any]?, on conn: NWConnection) async {
    let text = (data?["text"] as? String) ?? ""
    var sentStart = false
    var lastRate = 22050

    if !text.isEmpty {
        for await (rate, pcm) in await synthesis.synthesizeStreaming(text: text) {
            lastRate = rate
            if !sentStart {
                send([
                    "type": "audio-start",
                    "data": ["rate": rate, "width": 2, "channels": 1]
                ], to: conn)
                sentStart = true
            }
            send([
                "type": "audio-chunk",
                "data": ["rate": rate, "width": 2, "channels": 1],
                "payload_length": pcm.count
            ], payload: pcm, to: conn)
        }
    }

    // Always send audio-start + audio-stop so HA never hangs waiting on a malformed reply.
    if !sentStart {
        send([
            "type": "audio-start",
            "data": ["rate": lastRate, "width": 2, "channels": 1]
        ], to: conn)
    }
    send(["type": "audio-stop"], to: conn)
}

func describeResponse() -> [String: Any] {
    let attribution: [String: Any] = ["name": "Apple", "url": "https://developer.apple.com"]
    return [
        "type": "info",
        "data": [
            "tts": [[
                "name": "macos-avspeech",
                "description": "macOS AVSpeechSynthesizer",
                "attribution": attribution,
                "installed": true,
                "version": "1.0.0",
                "voices": [[
                    "name": voice.name,
                    "description": voice.name,
                    "attribution": attribution,
                    "installed": true,
                    "languages": [voice.language],
                    "speakers": NSNull()
                ]]
            ]],
            "asr": [[String: Any]](),
            "wake": [[String: Any]](),
            "handle": [[String: Any]](),
            "intent": [[String: Any]](),
            "satellite": NSNull()
        ]
    ]
}

// MARK: - Wire helpers

// Encode a Wyoming message: JSON header + newline + optional raw payload.
// Fire-and-forget; NWConnection serializes sends in order.
func send(_ message: [String: Any], payload: Data? = nil, to conn: NWConnection) {
    guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
    data.append(0x0a)
    if let payload = payload { data.append(payload) }
    conn.send(content: data, completion: .contentProcessed { _ in })
}

// Read until \n (consumed), returning the line bytes (no newline).
// Returns nil on disconnect.
func readLine(into buffer: inout Data, from conn: NWConnection) async -> Data? {
    while true {
        if let newlineIdx = buffer.firstIndex(of: 0x0a) {
            let line = buffer.subdata(in: buffer.startIndex..<newlineIdx)
            buffer.removeSubrange(buffer.startIndex...newlineIdx)
            return line
        }
        guard let chunk = await receive(from: conn) else { return nil }
        buffer.append(chunk)
    }
}

// Read exactly `count` bytes. Returns nil on disconnect.
func readBytes(_ count: Int, into buffer: inout Data, from conn: NWConnection) async -> Data? {
    while buffer.count < count {
        guard let chunk = await receive(from: conn) else { return nil }
        buffer.append(chunk)
    }
    let bytes = buffer.subdata(in: buffer.startIndex..<(buffer.startIndex + count))
    buffer.removeFirst(count)
    return bytes
}

// One async wrapper around NWConnection.receive. Returns nil when the peer closes.
func receive(from conn: NWConnection) async -> Data? {
    await withCheckedContinuation { continuation in
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, _ in
            if let data = data, !data.isEmpty {
                continuation.resume(returning: data)
            } else if isComplete {
                continuation.resume(returning: nil)
            } else {
                continuation.resume(returning: Data())
            }
        }
    }
}
