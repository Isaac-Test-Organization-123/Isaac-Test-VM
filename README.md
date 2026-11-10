# Desktop video streamer

One Swift source file, one native executable, one HTTP port. Captures a selected
macOS display with ScreenCaptureKit, hardware-encodes H.264 with VideoToolbox,
and serves an embedded WebCodecs/canvas viewer. No VNC, input control, audio,
external assets, packages, or separate bridge.

## Build

Requires macOS 14+, Xcode Command Line Tools, and a hardware H.264 encoder.
On the Mac that will host capture:

```sh
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" DesktopStream.swift -o desktop-stream
```

Distribute the resulting `desktop-stream` executable to a compatible Mac of the
same architecture. No Swift source or HTML assets are needed at runtime.
The binary is intentionally not checked into Git.

## Run on the capture host

```sh
./desktop-stream
```

Approve the normal macOS display-sharing picker on **that Mac**. Open
`http://localhost:54321` in a browser with H.264 WebCodecs support
(a current Chromium browser is recommended).
The executable captures the Mac on which it runs, not the viewer's machine.
It does not request Accessibility permission or inject input.
Stop with Ctrl+C or stop sharing through macOS. Reload the viewer to reconnect.

Defaults: loopback `127.0.0.1`, port **54321**, output width up to 1600 pixels,
target 60 FPS, aspect ratio preserved. The source may deliver fewer frames.
The viewer renders immediately; the old experimental pacing buffer is removed.

```sh
./desktop-stream --port 55001 --width 1280 --fps 30
./desktop-stream --help
```

Ports must be in **49152–65535**. Width must be even, 240–3840; FPS 1–60.
Four streaming viewers maximum. Slow senders skip dependent frames until a
keyframe; a send stuck for five seconds is disconnected. Encode submissions are
bounded to two frames. HTTP headers are capped at 8 KiB with a five-second
admission timeout. These are prototype bounds, not a hardened public server.

## Remote viewing

Keep the default loopback bind and forward the one port through SSH:

```sh
ssh -N -L 54321:127.0.0.1:54321 user@capture-host
```

Then open `http://localhost:54321` on the viewing machine.
The default port is intentionally high, **not secret or an access control**.
Any process/user able to reach the listener can view the shared screen.

`--host 0.0.0.0` is available for a protected deployment, but exposes
unauthenticated plaintext HTTP on all IPv4 interfaces. Do not expose it directly
to the internet. Use an authenticated TLS ingress, enforce viewer authorization,
disable proxy response buffering, and forward to this private port.
The proxy must rewrite upstream `Host` to `127.0.0.1:<port>` and strip upstream
`Origin` after doing its own browser Origin validation; the embedded viewer uses
same-origin `/stream`. TLS and viewer authentication are not implemented here.
A plain HTTP URL on a remote IP is not a WebCodecs secure context; use HTTPS
ingress or the localhost SSH tunnel.

## Protocol

- `GET /`: self-contained viewer.
- `GET /stream`: close-delimited HTTP/1.1 binary response.

Each record is `[u32 body length][u8 kind][u64 timestamp][payload]`,
all integers big-endian. Length excludes its own four bytes. Timestamp is
host monotonic encode-submission time in microseconds (zero for configuration),
not a measurement of when pixels physically changed.
Kind 0 is JSON `{codec, description, width, height}`, with base64 avcC in
`description`. Kind 1 is an H.264 keyframe, kind 2 a dependent frame; video
payloads are AVCC length-prefixed samples, not Annex B.
Configuration precedes every keyframe, so new viewers can join without GOP
replay. The latest owned pixel buffer is retained to encode a fresh keyframe
when a viewer joins an idle desktop. Video record payloads are capped below 16 MiB.
No browser input endpoint exists.

## Capture-free validation

```sh
python3 test_stream.py
```

Build first. Tests require Python 3 and Node.js and exercise the executable's CLI,
HTTP admission/routes, connection limits, and the actual embedded JavaScript
parser/decoder recovery using synthetic records. A temporary harness also
hardware-encodes generated black pixels and checks the native wire framing.
They start `--serve-only`,
which serves HTTP **without initializing AppKit, opening the picker, or starting
capture**. Tests do not authorize or record your screen.
Actual macOS consent, real desktop capture and live browser video still require
a separate test on the intended capture host.
