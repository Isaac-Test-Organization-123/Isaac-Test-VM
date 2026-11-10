import http.client
import json
from pathlib import Path
import platform
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent
BINARY = ROOT / "desktop-stream"


class StreamTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            cls.port = sock.getsockname()[1]
        if cls.port < 49152:
            raise RuntimeError("Test requires an available dynamic/private port")
        cls.process = subprocess.Popen(
            [str(BINARY), "--serve-only", "--port", str(cls.port)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        for _ in range(100):
            if cls.process.poll() is not None:
                raise RuntimeError("HTTP-only server exited")
            try:
                with socket.create_connection(("127.0.0.1", cls.port), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.05)
        cls.process.terminate()
        cls.process.wait(timeout=5)
        raise RuntimeError("HTTP-only server did not become ready")

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)

    def request(self, path="/", headers=None, method="GET"):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
        connection.request(method, path, headers=headers or {})
        response = connection.getresponse()
        body = response.read()
        connection.close()
        return response.status, body

    def test_cli(self):
        self.assertEqual(subprocess.run([str(BINARY), "--help"], capture_output=True).returncode, 0)
        for args in [
            ["--port", "49151"], ["--port", "65536"], ["--width", "241"],
            ["--fps", "0"], ["--fps", "61"], ["--host"], ["--unknown", "x"],
        ]:
            self.assertNotEqual(subprocess.run([str(BINARY), *args], capture_output=True).returncode, 0)

    def test_routes(self):
        status, html = self.request()
        self.assertEqual(status, 200)
        self.assertIn(b"VideoDecoder", html)
        self.assertNotIn(b"keydown", html)
        self.assertEqual(self.request("/input")[0], 404)
        self.assertEqual(self.request(method="POST")[0], 400)

    def test_admission(self):
        self.assertEqual(self.request(headers={"Host": "attacker.example"})[0], 403)
        self.assertEqual(self.request(headers={"Origin": "https://attacker.example"})[0], 403)
        self.assertEqual(self.request(headers={"Origin": f"http://127.0.0.1:{self.port}"})[0], 200)
        with socket.create_connection(("127.0.0.1", self.port), timeout=2) as sock:
            sock.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nX-Large: " + b"x" * 9000)
            self.assertEqual(sock.recv(1), b"")

    def test_stream_limit(self):
        connections = []
        try:
            for _ in range(4):
                connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=2)
                connection.request("GET", "/stream")
                response = connection.getresponse()
                connections.append((connection, response))
                self.assertEqual(response.status, 200)
                self.assertEqual(response.getheader("Content-Type"), "application/octet-stream")
            self.assertEqual(self.request("/stream")[0], 503)
        finally:
            for connection, response in connections:
                response.close()
                connection.close()

    def test_hardware_encoder(self):
        source = (ROOT / "DesktopStream.swift").read_text().split(
            'if CommandLine.arguments.contains("--help") {', 1
        )[0]
        harness = r"""
extension Streamer {
    func testSyntheticFrame() throws {
        try makeEncoder(width: 320, height: 200)
        var image: CVPixelBuffer?
        guard let pool, let encoder,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &image) == kCVReturnSuccess,
              let image else { throw Failure("No synthetic buffer") }
        CVPixelBufferLockBaseAddress(image, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(image) {
            memset(CVPixelBufferGetBaseAddressOfPlane(image, plane), plane == 0 ? 16 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        queue.async { self.encode(image) }
        queue.sync {}
        VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
        queue.sync {
            guard let configuration else { fatalError("No hardware encoder output/configuration") }
            let packet = record(kind: 0, payload: configuration)
            precondition(packet.count == configuration.count + 13)
            precondition(Array(packet.prefix(4)) == withUnsafeBytes(of: UInt32(configuration.count + 9).bigEndian) { Array($0) })
            precondition(packet[4] == 0)
            precondition(Array(packet[5..<13]) == Array(repeating: UInt8(0), count: 8))
            let object = try! JSONSerialization.jsonObject(with: configuration) as! [String: Any]
            precondition((object["codec"] as! String).hasPrefix("avc1."))
            precondition(Data(base64Encoded: object["description"] as! String)!.count > 4)
        }
        print("PASS synthetic hardware H.264 and native record framing")
    }
}
try Streamer(options: Options([])).testSyntheticFrame()
"""
        with tempfile.TemporaryDirectory(prefix="desktop-stream-test-") as directory:
            path = Path(directory)
            (path / "main.swift").write_text(source + harness)
            built = subprocess.run(
                ["xcrun", "swiftc", "-swift-version", "5", "-warnings-as-errors",
                 "-target", f"{platform.machine()}-apple-macos14.0", str(path / "main.swift"),
                 "-o", str(path / "encoder-test")],
                capture_output=True, text=True, timeout=60,
            )
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run(
                [str(path / "encoder-test")], capture_output=True, text=True, timeout=20,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_embedded_viewer(self):
        source = (ROOT / "DesktopStream.swift").read_text()
        script = source.split("<script>\n", 1)[1].split("</script>", 1)[0]
        harness = r"""
const vm = require('node:vm'), assert = require('node:assert/strict');
const script = JSON.parse(process.argv[1]);
function record(kind, payload, timestamp=123456n) {
  const body = Buffer.alloc(13 + payload.length);
  body.writeUInt32BE(9 + payload.length); body[4] = kind;
  body.writeBigUInt64BE(timestamp, 5); Buffer.from(payload).copy(body, 13); return body;
}
const config = Buffer.from(JSON.stringify({
  codec:'avc1.4d002a', description:Buffer.from([1,77,0,42]).toString('base64'), width:320, height:200
}));
async function check(chunks, expected, invalid=false, overload=false) {
  const decoded = [], frames = [], status = {}, canvas = {getContext:()=>({drawImage(){}})};
  let queue = overload ? 9 : 0, cancelled = false;
  const sandbox = {
    document:{getElementById:id=>id==='status'?status:canvas, addEventListener(){}},
    performance:{now:()=>0}, requestAnimationFrame:()=>1, cancelAnimationFrame(){},
    TextDecoder, Uint8Array, DataView, Number, JSON, Error, isSecureContext:true,
    atob:s=>Buffer.from(s,'base64').toString('binary'),
    EncodedVideoChunk:class {constructor(o){Object.assign(this,o)}},
    VideoDecoder:class {
      state='unconfigured';
      constructor(callbacks){this.callbacks=callbacks}
      configure(){this.state='configured'}
      get decodeQueueSize(){const value=queue; queue=0; return value}
      decode(c){
        decoded.push(c);
        const frame = {timestamp:c.timestamp,closed:0,close(){this.closed++;assert.equal(this.closed,1)}};
        frames.push(frame); this.callbacks.output(frame);
      }
      reset(){this.state='unconfigured'}
      close(){assert.notEqual(this.state,'closed'); this.state='closed'}
    },
    fetch:async()=>({ok:true,body:{getReader:()=>({
      read:async()=>chunks.length?{value:chunks.shift(),done:false}:{done:true},
      cancel:async()=>{cancelled=true}
    })}})
  };
  sandbox.window = sandbox;
  vm.runInNewContext(script, sandbox);
  for(let i=0;i<100 && !cancelled;i++) await new Promise(resolve=>setImmediate(resolve));
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(cancelled,true);
  frames.forEach(frame=>assert.equal(frame.closed,1));
  assert.deepEqual(decoded.map(c=>c.type),expected);
  if(decoded.length) assert.equal(decoded[0].timestamp,123456);
  if(invalid) assert.match(status.textContent,/Invalid record size/);
}
(async()=>{
  const bytes = Buffer.concat([record(0,config),record(1,[7]),record(2,[8])]);
  await check(Array.from(bytes,b=>Uint8Array.of(b)),['key','delta']);
  await check([bytes],['key','delta']);
  await check([record(2,[8]),record(0,config),record(1,[7])],['key']);
  await check([Buffer.from([0,0,0,8])],[],true);
  await check([bytes,record(0,config),record(1,[7])],['key'],false,true);
  console.log('PASS embedded viewer: fragmented/coalesced records, keyframe gate, malformed lengths, overload recovery');
})().catch(e=>{console.error(e);process.exitCode=1});
"""
        result = subprocess.run(
            ["node", "-e", harness, json.dumps(script)], capture_output=True, text=True,
            timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_frame_pacing(self):
        source = (ROOT / "DesktopStream.swift").read_text()
        presenter = "class FramePresenter" + source.split("class FramePresenter", 1)[1].split("const status =", 1)[0]
        harness = r"""
const assert = require('node:assert/strict');
function frame(ms) {
  return {timestamp:ms*1000,closed:0,close(){this.closed++;assert.equal(this.closed,1)}};
}
const p = new FramePresenter();
const a = frame(0), b = frame(10), c = frame(20);
p.enqueue(a,0); p.enqueue(b,10); p.enqueue(c,20);
assert.equal(p.take(99),null);
assert.equal(p.take(100),a); a.close();
assert.equal(p.take(119),null);
assert.equal(p.take(120),c); c.close();
assert.equal(b.closed,1);
assert.equal(p.take(120),null);
assert.equal(p.take(140),null);

// A delayed animation callback chooses one newest due frame, not a draw burst.
p.reset();
const burst = [0,20,40,60,80].map(frame);
burst.forEach(f=>p.enqueue(f,f.timestamp/1000));
assert.equal(p.take(180),burst[4]); burst[4].close();
burst.forEach(f=>assert.equal(f.closed,1));
assert.equal(p.take(180),null);

// Retained media is bounded and all frames are closed exactly once.
p.reset();
const bounded = Array.from({length:30},(_,i)=>frame(i));
bounded.forEach(f=>p.enqueue(f,f.timestamp/1000));
assert.equal(p.frames.length,24);
bounded.slice(0,6).forEach(f=>assert.equal(f.closed,1));
p.reset(); bounded.forEach(f=>assert.equal(f.closed,1));

// A late source timeline re-anchors instead of immediately draining old timestamps.
const old = frame(0), late = frame(20);
p.enqueue(old,0); p.enqueue(late,1000);
assert.equal(old.closed,1);
assert.equal(p.take(1099),null);
assert.equal(p.take(1100),late); late.close();
p.reset();

// Clock restarts, duplicate timestamps, invalid samples and invalid configuration.
const previous = frame(5000), restarted = frame(0), duplicate = frame(0), invalid = frame(NaN);
p.enqueue(previous,0); p.enqueue(restarted,1);
assert.equal(previous.closed,1);
p.enqueue(duplicate,2); assert.equal(duplicate.closed,1);
p.enqueue(invalid,3); assert.equal(invalid.closed,1);
p.reset(); assert.equal(restarted.closed,1);
assert.throws(()=>new FramePresenter({fps:0}));
assert.throws(()=>new FramePresenter({bufferMs:501}));
assert.throws(()=>new FramePresenter({maxFrames:0}));
console.log('PASS 50 FPS/100 ms pacing, no catch-up bursts, queue bounds, re-anchor and frame disposal');
"""
        result = subprocess.run(
            ["node", "-e", presenter + harness], capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
