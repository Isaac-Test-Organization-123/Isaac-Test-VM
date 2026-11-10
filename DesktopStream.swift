import AppKit
import Network
import ScreenCaptureKit
import VideoToolbox

struct Options {
    var host = "127.0.0.1"
    var port: UInt16 = 54321
    var width = 1600
    var fps = 60
    var serveOnly = false

    init(_ arguments: [String]) throws {
        var i = 0
        while i < arguments.count {
            let flag = arguments[i]
            if flag == "--serve-only" {
                serveOnly = true
            } else {
                guard i + 1 < arguments.count else { throw Failure("Missing value for \(flag)") }
                i += 1
                let value = arguments[i]
                switch flag {
                case "--host":
                    guard !value.isEmpty else { throw Failure("Empty host") }
                    host = value
                case "--port":
                    guard let number = UInt16(value), number >= 49152 else {
                        throw Failure("Port must be in 49152...65535")
                    }
                    port = number
                case "--width":
                    guard let number = Int(value), (240...3840).contains(number), number % 2 == 0 else {
                        throw Failure("Width must be even and in 240...3840")
                    }
                    width = number
                case "--fps":
                    guard let number = Int(value), (1...60).contains(number) else {
                        throw Failure("FPS must be in 1...60")
                    }
                    fps = number
                default: throw Failure("Unknown option: \(flag)")
                }
            }
            i += 1
        }
    }
}

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

// Length excludes its own four bytes; timestamp is monotonic submission time in microseconds.
func record(kind: UInt8, timestamp: UInt64 = 0, payload: Data) -> Data {
    var body = Data([kind])
    body.append(bigEndian(timestamp))
    body.append(payload)
    var result = bigEndian(UInt32(body.count))
    result.append(body)
    return result
}

final class Peer {
    let connection: NWConnection
    var pending = false
    var needsKeyframe = true
    var sendSequence = 0
    init(_ connection: NWConnection) { self.connection = connection }
}

final class Streamer: NSObject, SCStreamOutput, SCStreamDelegate {
    let options: Options
    let queue = DispatchQueue(label: "desktop-stream")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var peers: [ObjectIdentifier: Peer] = [:]
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var configuration: Data?
    private var encoding = 0
    private var forceKeyframe = true
    private var starting = false
    private var outputWidth = 0
    private var outputHeight = 0
    private var latestImage: CVPixelBuffer?
    private var lastTimestamp: Int64 = 0

    init(options: Options) { self.options = options }

    func listen() throws {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(options.host), port: NWEndpoint.Port(rawValue: options.port)!)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                note("Viewer: http://\(self.options.host):\(self.options.port)")
                if !self.options.serveOnly {
                    DispatchQueue.main.async { showPicker() }
                }
            case .failed(let error):
                note("Listener failed: \(error)")
                exit(1)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections[id] = nil; self?.peers[id] = nil }
            if case .failed = state {
                self?.connections[id] = nil
                self?.peers[id] = nil
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            if self?.peers[id] == nil { connection?.cancel() }
        }
        readRequest(connection, buffered: Data())
    }

    private func readRequest(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { return }
            var bytes = buffered
            if let data { bytes.append(data) }
            guard bytes.count <= 8192 else { connection.cancel(); return }
            if let end = bytes.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: bytes[..<end.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let request = lines[0].split(separator: " ")
                guard request.count == 3, request[0] == "GET", request[2] == "HTTP/1.1" else {
                    self.respond(connection, status: "400 Bad Request", body: Data())
                    return
                }
                let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
                let allowed = ["\(self.options.host):\(self.options.port)",
                               "localhost:\(self.options.port)", "127.0.0.1:\(self.options.port)"]
                guard hosts.count == 1,
                      allowed.contains(hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces)) else {
                    self.respond(connection, status: "403 Forbidden", body: Data())
                    return
                }
                let host = hosts[0].dropFirst(5).trimmingCharacters(in: .whitespaces)
                let origins = lines.dropFirst().filter { $0.lowercased().hasPrefix("origin:") }
                guard origins.isEmpty || (origins.count == 1 &&
                    origins[0].dropFirst(7).trimmingCharacters(in: .whitespaces) == "http://\(host)") else {
                    self.respond(connection, status: "403 Forbidden", body: Data())
                    return
                }
                if request[1] == "/" {
                    self.respond(connection, status: "200 OK", body: Data(viewer.utf8), type: "text/html; charset=utf-8")
                } else if request[1] == "/stream" {
                    guard self.peers.count < 4 else {
                        self.respond(connection, status: "503 Service Unavailable", body: Data())
                        return
                    }
                    self.peers[ObjectIdentifier(connection)] = Peer(connection)
                    self.forceKeyframe = true
                    connection.send(content: Data(self.headers(status: "200 OK", type: "application/octet-stream").utf8),
                                    completion: .contentProcessed { error in
                        if error != nil { connection.cancel() }
                    })
                    if let image = self.latestImage { self.encode(image) }
                    self.watchDisconnect(connection)
                } else {
                    self.respond(connection, status: "404 Not Found", body: Data())
                }
            } else if !done && error == nil {
                self.readRequest(connection, buffered: bytes)
            } else { connection.cancel() }
        }
    }

    private func watchDisconnect(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
            connection.cancel()
        }
    }

    private func headers(status: String, type: String, length: Int? = nil) -> String {
        var result = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nConnection: close\r\n"
        result += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        result += "Content-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'\r\n"
        if let length { result += "Content-Length: \(length)\r\n" }
        return result + "\r\n"
    }

    private func respond(_ connection: NWConnection, status: String, body: Data, type: String = "text/plain") {
        var data = Data(headers(status: status, type: type, length: body.count).utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    func start(filter: SCContentFilter) {
        guard !starting else { return }
        starting = true
        Task { @MainActor in
            do {
                let config = SCStreamConfiguration()
                let bounds = filter.contentRect
                guard bounds.width > 0, bounds.height > 0 else { throw Failure("Empty display") }
                let width = min(options.width, Int(bounds.width * CGFloat(filter.pointPixelScale))) / 2 * 2
                let height = max(2, Int(CGFloat(width) * bounds.height / bounds.width) / 2 * 2)
                config.width = width
                config.height = height
                config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
                config.queueDepth = 3
                config.showsCursor = true
                config.capturesAudio = false
                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                self.stream = stream
                note("Sharing \(width)×\(height), target \(options.fps) FPS. Ctrl+C to stop.")
            } catch {
                note("Capture failed: \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    private func makeEncoder(width: Int, height: Int) throws {
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let session else { throw Failure("Hardware H.264 creation failed: \(status)") }
        encoder = session
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Main_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: min(8_000_000, max(1_500_000, width * height * 3)),
            kVTCompressionPropertyKey_ExpectedFrameRate: options.fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: options.fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
        ]
        let propertyStatus = VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary)
        guard propertyStatus == noErr else { throw Failure("Encoder settings failed: \(propertyStatus)") }
        var transfer: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == noErr else {
            throw Failure("Pixel transfer creation failed")
        }
        self.transfer = transfer
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else {
            throw Failure("Pixel pool creation failed")
        }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
        guard prepared == noErr else { throw Failure("Encoder preparation failed: \(prepared)") }
        outputWidth = width
        outputHeight = height
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
              let source = sample.imageBuffer, encoding < 2 else { return }
        do {
            if encoder == nil { try makeEncoder(width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source)) }
            guard encoder != nil, let transfer, let pool else { return }
            var owned: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &owned) == kCVReturnSuccess, let owned,
                  VTPixelTransferSessionTransferImage(transfer, from: source, to: owned) == noErr else { return }
            latestImage = owned
            encode(owned)
        } catch {
            note(error.localizedDescription)
            exit(1)
        }
    }

    private func encode(_ image: CVPixelBuffer) {
        guard let encoder, encoding < 2 else { return }
        let properties: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceKeyframe = false
        encoding += 1
        lastTimestamp = max(lastTimestamp + 1, Int64(CACurrentMediaTime() * 1_000_000))
        let result = VTCompressionSessionEncodeFrame(
            encoder, imageBuffer: image, presentationTimeStamp: CMTime(value: lastTimestamp, timescale: 1_000_000),
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard let self else { return }
            self.queue.async {
                self.encoding -= 1
                if status == noErr, let encoded { self.publish(encoded) }
                else { self.forceKeyframe = true }
            }
        }
        if result != noErr { encoding -= 1; forceKeyframe = true }
    }

    private func publish(_ sample: CMSampleBuffer) {
        guard let block = sample.dataBuffer, let format = sample.formatDescription else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        if key,
           let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
           let avcc = atoms["avcC"] as? Data, avcc.count > 3 {
            configuration = try? JSONSerialization.data(withJSONObject: [
                "codec": String(format: "avc1.%02x%02x%02x", avcc[1], avcc[2], avcc[3]),
                "description": avcc.base64EncodedString(), "width": outputWidth, "height": outputHeight,
            ])
        }
        guard let configuration else { return }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length < 16 * 1024 * 1024 else { return }
        var payload = Data(count: length)
        let status = payload.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
        }
        guard status == noErr else { return }
        let timestamp = UInt64(max(0, CMTimeGetSeconds(sample.presentationTimeStamp) * 1_000_000))
        var packet = key ? record(kind: 0, payload: configuration) : Data()
        packet.append(record(kind: key ? 1 : 2, timestamp: timestamp, payload: payload))
        for peer in peers.values {
            if peer.pending { peer.needsKeyframe = true; continue }
            if peer.needsKeyframe && !key { continue }
            peer.needsKeyframe = false
            peer.pending = true
            peer.sendSequence += 1
            let sequence = peer.sendSequence
            peer.connection.send(content: packet, completion: .contentProcessed { [weak peer] error in
                peer?.pending = false
                if error != nil { peer?.connection.cancel() }
            })
            queue.asyncAfter(deadline: .now() + 5) { [weak peer] in
                if peer?.pending == true && peer?.sendSequence == sequence { peer?.connection.cancel() }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        note("Sharing stopped: \(error.localizedDescription)")
        exit(1)
    }
}

let viewer = #"""
<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Desktop video</title>
<style>
body{margin:0;background:#161616;color:#ddd;font:14px system-ui}
header{padding:10px}canvas{display:block;width:100%;height:calc(100vh - 40px);object-fit:contain}
</style>
<header id="status">Connecting — video only</header><canvas id="screen"></canvas>
<script>
'use strict';
class FramePresenter {
  constructor({fps = 50, bufferMs = 100, maxFrames = 24} = {}) {
    if (!Number.isFinite(fps) || fps <= 0 || fps > 120 ||
        !Number.isFinite(bufferMs) || bufferMs < 0 || bufferMs > 500 ||
        !Number.isInteger(maxFrames) || maxFrames < 1) throw new Error('Invalid presentation settings');
    this.intervalMs = 1000 / fps;
    this.bufferMs = bufferMs;
    this.maxFrames = maxFrames;
    this.frames = [];
    this.reset();
  }
  reset() {
    for (const frame of this.frames) frame.close();
    this.frames.length = 0;
    this.sourceOrigin = this.localOrigin = this.nextTick = this.lastSource = null;
  }
  enqueue(frame, atMs) {
    const sourceMs = frame.timestamp / 1000;
    if (!Number.isFinite(sourceMs) || !Number.isFinite(atMs) ||
        (this.lastSource !== null && sourceMs <= this.lastSource && sourceMs > this.lastSource - 1000)) {
      frame.close();
      return;
    }
    const due = this.sourceOrigin === null ? null : this.localOrigin + sourceMs - this.sourceOrigin;
    // Re-anchor after long stalls or a source-clock restart instead of replaying stale video.
    if (due === null || sourceMs <= this.lastSource - 1000 ||
        due < atMs - 250 || due > atMs + this.bufferMs + 150) {
      this.reset();
      this.sourceOrigin = sourceMs;
      this.localOrigin = atMs + this.bufferMs;
      this.nextTick = this.localOrigin;
    }
    this.lastSource = sourceMs;
    this.frames.push(frame);
    while (this.frames.length > this.maxFrames) this.frames.shift().close();
  }
  take(atMs) {
    if (this.nextTick === null || atMs < this.nextTick) return null;
    const tick = this.nextTick + Math.floor((atMs - this.nextTick) / this.intervalMs) * this.intervalMs;
    this.nextTick = tick + this.intervalMs;
    const playhead = this.sourceOrigin + tick - this.localOrigin;
    let selected = null;
    while (this.frames.length && this.frames[0].timestamp / 1000 <= playhead) {
      if (selected) selected.close();
      selected = this.frames.shift();
    }
    return selected;
  }
}
const status = document.getElementById('status'), canvas = document.getElementById('screen');
const context = canvas.getContext('2d');
const presenter = new FramePresenter();
let animation = null;
function present(atMs) {
  const frame = presenter.take(atMs);
  if (frame) {
    try { context.drawImage(frame, 0, 0, canvas.width, canvas.height); }
    finally { frame.close(); }
  }
  animation = requestAnimationFrame(present);
}
document.addEventListener('visibilitychange', () => presenter.reset());
let decoder, configKey = '', needKey = true;
function consume(kind, timestamp, payload) {
  if (kind === 0) {
    const text = new TextDecoder().decode(payload);
    if (text === configKey && decoder?.state === 'configured') return;
    const config = JSON.parse(text);
    presenter.reset();
    if (decoder && decoder.state !== 'closed') decoder.close();
    decoder = new VideoDecoder({
      output(frame) {
        if (document.hidden) frame.close();
        else presenter.enqueue(frame, performance.now());
      },
      error(error) {
        presenter.reset(); configKey = ''; needKey = true; status.textContent = error.message;
      }
    });
    decoder.configure({
      codec: config.codec,
      description: Uint8Array.from(atob(config.description), c => c.charCodeAt(0)),
      optimizeForLatency: true
    });
    canvas.width = config.width; canvas.height = config.height;
    configKey = text; needKey = true;
  } else if (kind === 1 || kind === 2) {
    if (decoder?.state !== 'configured') return;
    if (decoder.decodeQueueSize > 8) {
      decoder.reset(); presenter.reset(); configKey = ''; needKey = true; return;
    }
    if (needKey && kind !== 1) return;
    needKey = false;
    decoder.decode(new EncodedVideoChunk({type: kind === 1 ? 'key' : 'delta', timestamp, data: payload}));
    status.textContent = 'Live — video only · 50 FPS target · 100 ms buffer';
  } else throw new Error('Unknown stream record');
}
async function run() {
  if (!isSecureContext || !('VideoDecoder' in window))
    throw new Error('WebCodecs requires a supported browser on localhost or HTTPS.');
  const response = await fetch('/stream', {cache:'no-store'});
  if (!response.ok) throw new Error(`Stream HTTP ${response.status}`);
  const reader = response.body.getReader();
  let buffer = new Uint8Array(0);
  animation = requestAnimationFrame(present);
  try {
    while (true) {
      const {value, done} = await reader.read();
      if (done) throw new Error('Stream disconnected; reload to reconnect.');
      const next = new Uint8Array(buffer.length + value.length);
      next.set(buffer); next.set(value, buffer.length); buffer = next;
      let offset = 0;
      while (buffer.length - offset >= 4) {
        const view = new DataView(buffer.buffer, buffer.byteOffset + offset);
        const length = view.getUint32(0);
        if (length < 9 || length > 16 * 1024 * 1024 + 9) throw new Error('Invalid record size');
        if (buffer.length - offset < length + 4) break;
        consume(buffer[offset + 4], Number(view.getBigUint64(5)), buffer.subarray(offset + 13, offset + 4 + length));
        offset += 4 + length;
      }
      buffer = buffer.slice(offset);
    }
  } finally {
    await reader.cancel().catch(() => {});
    if (animation !== null) cancelAnimationFrame(animation);
    presenter.reset();
    if (decoder && decoder.state !== 'closed') decoder.close();
  }
}
run().catch(error => { status.textContent = error.message; });
</script></html>
"""#

final class AppDelegate: NSObject, NSApplicationDelegate, SCContentSharingPickerObserver {
    let streamer: Streamer
    init(_ streamer: Streamer) { self.streamer = streamer }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleDisplay]
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        do { try streamer.listen() }
        catch { note(error.localizedDescription); exit(1) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        streamer.start(filter: filter)
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        note("Sharing cancelled.")
        exit(0)
    }
    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        note("Sharing picker failed: \(error.localizedDescription)")
        exit(1)
    }
}

func showPicker() {
    NSApp.activate(ignoringOtherApps: true)
    SCContentSharingPicker.shared.present(using: .display)
}

if CommandLine.arguments.contains("--help") {
    print("desktop-stream [--host 127.0.0.1] [--port 54321] [--width 1600] [--fps 60] [--serve-only]")
    print("macOS 14+. Video only. Run on the Mac to capture. High ports are NOT authentication.")
    exit(0)
}
do {
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    if options.host != "127.0.0.1" && options.host != "localhost" {
        note("WARNING: unauthenticated, unencrypted HTTP. Use only behind protected ingress; the port is not a secret.")
    }
    let streamer = Streamer(options: options)
    if options.serveOnly {
        try streamer.listen()
        dispatchMain()
    } else {
        let app = NSApplication.shared
        let delegate = AppDelegate(streamer)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
} catch {
    note(error.localizedDescription)
    exit(1)
}
