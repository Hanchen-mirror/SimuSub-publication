#!/usr/bin/env python3
"""Exercise real URLSession CDP transport against an isolated loopback fixture."""
import base64
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time

root = Path(__file__).resolve().parents[1]
methods = []
errors = []

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args):
        pass
    def do_GET(self):
        if self.path == '/json/version':
            body = json.dumps({'webSocketDebuggerUrl': f'ws://127.0.0.1:{self.server.server_port}/devtools/browser/fixture'}).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
            return
        if self.path.startswith('/json/close/'):
            self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()
            return
        if self.path != '/devtools/browser/fixture':
            self.send_error(404); return
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101); self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade'); self.send_header('Sec-WebSocket-Accept', accept); self.end_headers()
        self.connection.settimeout(20)
        def read(n):
            data = self.rfile.read(n)
            if len(data) != n: raise EOFError()
            return data
        def send(value):
            data = json.dumps(value).encode()
            header = bytes([0x81, len(data)]) if len(data) < 126 else b'\x81\x7e' + struct.pack('!H', len(data))
            self.wfile.write(header + data); self.wfile.flush()
        try:
            while True:
                first, second = read(2)
                if first & 15 == 8: break
                assert first & 15 == 1, 'CDP must use text frames'
                length = second & 127
                if length == 126: length = struct.unpack('!H', read(2))[0]
                elif length == 127: length = struct.unpack('!Q', read(8))[0]
                mask = read(4) if second & 128 else None
                data = read(length)
                if mask: data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
                message = json.loads(data); method = message['method']; methods.append(method)
                result = {}
                if method == 'Target.createTarget':
                    assert message['params'] == {'url': 'about:blank', 'background': True}
                    result = {'targetId': 'owned-fixture'}
                elif method == 'Target.attachToTarget': result = {'sessionId': 'fixture-session'}
                elif method == 'Target.closeTarget':
                    assert message['params']['targetId'] == 'owned-fixture'
                    result = {'success': True}
                else:
                    assert message['sessionId'] == 'fixture-session'
                    if method == 'Page.navigate': time.sleep(1.2)
                    if method == 'Runtime.evaluate': result = {'result': {'type': 'object', 'value': {'data': {'transport': 'ok'}, 'transport': 'ok', 'ready': True, 'userAgent': 'Fixture'}}}
                    if method == 'Network.getCookies': result = {'cookies': []}
                send({'method': 'Page.fixtureEvent', 'params': {}})
                send({'id': message['id'], 'result': result})
                if method == 'Target.closeTarget': break
        except (EOFError, ConnectionResetError, BrokenPipeError): pass
        except Exception as error: errors.append(str(error))
        self.close_connection = True

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='simusub-cdp-check-') as directory:
        path = Path(directory)
        (path/'Main.swift').write_text('''import Foundation
        enum LiveMonitorError: Error { case invalidResponse; case unavailable(String) }
        final class BrowserBridgeJob: @unchecked Sendable { func cancel() {} ; func run(_ url: URL, script: String) -> Data? { nil } }
        @main struct Check {
            static func main() async {
                UserDefaults.standard.register(defaults: ["liveMonitor.browserEndpoint": "http://127.0.0.1:PORT"])
                let port = LiveBrowserPort()
                for player in [false, true] {
                    let result = await port.page(URL(string: "https://www.youtube.com/watch?v=fixture")!, player: player)
                    guard (result?["data"] as? [String: Any])?["transport"] as? String == "ok" else { fatalError("CDP response missing") }
                    if player { precondition(result?["cookies"] is [Any]) }
                }
                for address in ["https://www.youtube.com/", "https://www.bilibili.com/"] {
                    let result = await port.page(URL(string: address)!, player: false)
                    precondition(result?["cookies"] is [Any])
                }
                guard let socket = await port.captureSocket() else { fatalError("Missing capture socket") }
                let capture = PortCaptureSession(socketURL: socket)
                do {
                    try await capture.open(URL(string: "https://www.youtube.com/watch?v=fixture")!)
                    let response = try await capture.evaluate("({transport:'ok'})")
                    precondition(response["transport"] as? String == "ok")
                    await capture.close()
                } catch { fatalError("Persistent CDP capture transport failed") }
                print("PASS: CDP discovery, text frames, session routing, events, delayed response, cookies, persistent capture, owned-tab cleanup")
            }
        }
        '''.replace('PORT', str(server.server_port)))
        subprocess.run(['swiftc', '-parse-as-library', str(root/'Sources/SimulSubtitleMac/LiveBrowserPort.swift'), str(root/'Sources/SimulSubtitleMac/BrowserCaptureSession.swift'), str(path/'Main.swift'), '-o', str(path/'check')], check=True)
        subprocess.run([str(path/'check')], check=True, timeout=30)
    assert not errors, errors
    assert methods.count('Target.closeTarget') == 5, methods
    assert methods.count('Network.getCookies') == 3, methods
finally:
    server.shutdown(); server.server_close()
