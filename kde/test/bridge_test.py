#!/usr/bin/env python3
"""End-to-end test of protect-bridge.py against a fake console with a self-signed certificate.

Run: python3 kde/test/bridge_test.py   (needs openssl to make the certificate)

    python3 kde/test/bridge_test.py --serve [PORT] [--tls]   just run the fake console (over plain
                                                     HTTP, or HTTPS with a new self-signed certificate)
                                                     for trying the widget with plasmawindowed
"""

import base64
import hashlib
import http.client
import http.server
import json
import os
import shutil
import signal
import ssl
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.join(HERE, "..", "package", "contents", "code", "protect-bridge.py")
KEY = "test-key"
# A 64×36 gradient.
JPEG = base64.b64decode("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZGNywtQFdBRkxOUlNSMj5aYVpQYEpRUk//2wBDAQ4ODhMREyYVFSZPNS01T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0//wAARCAAkAEADASIAAhEBAxEB/8QAFwABAQEBAAAAAAAAAAAAAAAAAAUEBv/EABgQAQEAAwAAAAAAAAAAAAAAAAATARJh/8QAFwEBAQEBAAAAAAAAAAAAAAAAAAIBBP/EABURAQEAAAAAAAAAAAAAAAAAAAAR/9oADAMBAAIRAxEAPwDmYkVCPCPHSmp8SKhHhHgVPiRUI8I8Cp8SKhHhHgVviRUIkWJT4kVCJEE+JFQiRBPiRUIkQbdcGuASk1wa4ADXBrgANcGuAB//2Q==")
EVENT = {"type": "add", "item": {"modelKey": "event", "id": "66f0aa", "type": "smartDetectZone",
                                 "start": int(time.time() * 1000), "device": "cam1", "smartDetectTypes": ["person"]}}
DEVICE = {"type": "update", "item": {"modelKey": "camera", "id": "cam1", "state": "DISCONNECTED", "stats": {"x": 1}}}
STATS = {"type": "update", "item": {"modelKey": "camera", "id": "cam1", "stats": {"rx": 1}}}


def ws_frame(text):
    data = text.encode()
    if len(data) < 126:
        return struct.pack("!BB", 0x81, len(data)) + data
    return struct.pack("!BBH", 0x81, 126, len(data)) + data


class FakeConsole(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    snapshots = 0

    def log_message(self, *args):
        pass

    def send_json(self, status, obj, headers=None):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        prefix = "/proxy/protect/integration/v1/"
        path = urllib.parse.urlsplit(self.path).path
        if self.headers.get("X-API-KEY") != KEY:
            return self.send_json(401, {"error": {"code": 401, "message": "Unauthorized"}})
        if not path.startswith(prefix):
            return self.send_json(404, {"error": "nope"})
        path = path[len(prefix):]
        if self.headers.get("Upgrade", "").lower() == "websocket":
            return self.websocket(path)
        policy = {"RateLimit-Policy": '"10-in-1sec"; q=10; w=1'}
        if path == "meta/info":
            return self.send_json(200, {"applicationVersion": "6.1.79"}, policy)
        if path == "nvrs":
            return self.send_json(200, {"name": "Test NVR"}, policy)
        if path == "cameras":
            return self.send_json(200, [{"id": "cam1", "name": "Front ", "state": "CONNECTED", "lcdMessage": {}},
                                        {"id": "cam2", "name": "Back Door", "state": "CONNECTED"},
                                        {"id": "cam3", "name": "Garage", "state": "DISCONNECTED"}]
                                  + [{"id": "cam%d" % n, "name": "Camera %d" % n, "state": "CONNECTED"}
                                     for n in range(4, 4 + int(os.environ.get("FAKE_EXTRA_CAMERAS", "0")))], policy)
        if path.startswith("cameras/") and path.endswith("/snapshot"):
            FakeConsole.snapshots += 1
            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(JPEG)))
            self.end_headers()
            self.wfile.write(JPEG)
            return None
        return self.send_json(404, {"error": {"message": "No such thing"}})

    def websocket(self, path):
        accept = base64.b64encode(hashlib.sha1((self.headers["Sec-WebSocket-Key"]
                                                + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        self.wfile.flush()
        sock = self.connection
        time.sleep(0.3)
        if path == "subscribe/events":
            sock.sendall(ws_frame(json.dumps(EVENT)))
        else:
            sock.sendall(ws_frame(json.dumps(STATS)))
            sock.sendall(ws_frame(json.dumps(DEVICE)))
        sock.settimeout(1)
        # Answer pings until the bridge goes away.
        buf = b""
        deadline = time.time() + 60
        while time.time() < deadline:
            try:
                chunk = sock.recv(4096)
            except (TimeoutError, OSError):
                continue
            if not chunk:
                break
            buf += chunk
            while len(buf) >= 6:
                op, ln = buf[0] & 0x0F, buf[1] & 0x7F
                if len(buf) < 6 + ln:
                    break
                mask, payload = buf[2:6], buf[6:6 + ln]
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
                buf = buf[6 + ln:]
                if op == 0x9:
                    sock.sendall(struct.pack("!BB", 0x8A, len(payload)) + payload)
                elif op == 0x8:
                    return
        self.close_connection = True


class TLSServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        pass    # the bridge hangs up on purpose after reading the certificate


def main():
    if not shutil.which("openssl"):
        print("SKIP: openssl not found")
        return 0
    tmp = tempfile.mkdtemp(prefix="protect-bridge-test-")
    cert, keyfile, fp = make_certificate(tmp)

    server = TLSServer(("127.0.0.1", 0), FakeConsole)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, keyfile)
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    console = "https://127.0.0.1:%d" % server.server_address[1]

    # A stand-in secret-tool: prints the key, or fails like a locked keyring while `locked` exists.
    bindir = os.path.join(tmp, "bin")
    os.makedirs(bindir)
    with open(os.path.join(bindir, "secret-tool"), "w") as fh:
        fh.write('#!/bin/sh\n[ -e "%s/locked" ] && { echo "Cannot unlock" >&2; exit 5; }\nprintf %%s "%s"\n' % (tmp, KEY))
    os.chmod(os.path.join(bindir, "secret-tool"), 0o755)
    env = dict(os.environ, XDG_RUNTIME_DIR=os.path.join(tmp, "run"), XDG_DATA_HOME=os.path.join(tmp, "data"),
               PROTECT_CAMERAS_HOST=console, PROTECT_CAMERAS_API_KEY=KEY,
               PATH=bindir + os.pathsep + os.environ.get("PATH", ""))
    os.makedirs(env["XDG_RUNTIME_DIR"], mode=0o700)
    if os.environ.get("PROTECT_CAMERAS_DEBUG"):
        print("logs in", env["XDG_RUNTIME_DIR"])

    def start():
        out = subprocess.run([sys.executable, BRIDGE, "start", "--instance", "42"], env=env, capture_output=True,
                             text=True, timeout=20)
        assert out.returncode == 0, out.stderr
        return json.loads(out.stdout.strip().splitlines()[-1])

    info = start()

    def call(method, path, query=None, body=None, token=None, raw=False):
        q = dict(query or {}, token=token or info["token"])
        conn = http.client.HTTPConnection("127.0.0.1", info["port"], timeout=40)
        data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
        conn.request(method, path + "?" + urllib.parse.urlencode(q), body=data)
        resp = conn.getresponse()
        payload = resp.read()
        conn.close()
        if raw:
            return resp.status, resp.getheader("Content-Type"), payload
        return json.loads(payload)

    checks = 0
    try:
        assert call("GET", "/health", token="wrong")["error"]["kind"] == "forbidden"
        assert call("GET", "/health")["version"]
        # A malformed request gets an error reply, not a dropped connection.
        assert call("POST", "/config", body=[])["error"]["status"] == 400
        checks += 1

        # Uses PROTECT_CAMERAS_HOST/API_KEY when no console is configured.
        r = call("POST", "/config", body={"host": "", "pin": None})
        assert r["host"] == console and r["source"] == "environment" and "error" not in r, r
        gen = r["gen"]
        # Same settings again: nothing torn down.
        assert call("POST", "/config", body={"host": "", "pin": None})["changed"] is False
        checks += 1

        # Self-signed: refused, with the fingerprint browsers show.
        r = call("GET", "/api", {"path": "cameras"})
        assert r["error"]["kind"] == "untrustedCertificate", r
        assert r["error"]["fingerprint"] == fp, (r, fp)
        status, ctype, body = call("GET", "/snapshot", {"camera": "cam1"}, raw=True)
        assert status == 502 and json.loads(body)["error"]["kind"] == "untrustedCertificate"
        checks += 1

        # A different pin: certificateChanged.
        r = call("POST", "/config", body={"host": "", "pin": "AA:" + fp[3:]})
        assert r["changed"] and r["gen"] == gen + 1
        assert call("GET", "/api", {"path": "meta/info"})["error"]["kind"] == "certificateChanged"
        checks += 1

        # Trusted.
        r = call("POST", "/config", body={"host": "", "pin": fp})
        gen = r["gen"]
        assert call("GET", "/api", {"path": "meta/info"})["body"]["applicationVersion"] == "6.1.79"
        assert call("GET", "/api", {"path": "nvrs"})["body"]["name"] == "Test NVR"
        cams = call("GET", "/api", {"path": "cameras"})["body"]
        assert cams[0]["id"] == "cam1"
        assert call("GET", "/api", {"path": "../../etc/passwd"})["error"]["status"] == 404
        checks += 1

        status, ctype, body = call("GET", "/snapshot", {"camera": "cam1", "hq": "1"}, raw=True)
        assert status == 200 and ctype == "image/jpeg" and body == JPEG
        status, _, _ = call("GET", "/snapshot", {"camera": "../x"}, raw=True)
        assert status == 502
        checks += 1

        # Push channels: the event, the slimmed device update (stats-only updates dropped), and a live state.
        seen_event = seen_device = live = False
        seq, version = 0, -1
        deadline = time.time() + 20
        while time.time() < deadline and not (seen_event and seen_device and live):
            r = call("GET", "/poll", {"after": seq, "version": version, "timeout": 5})
            seq, version = r["seq"], r["version"]
            for m in r["messages"]:
                assert m["gen"] == gen
                if m["channel"] == "events":
                    assert m["item"]["id"] == "66f0aa" and m["type"] == "add"
                    seen_event = True
                if m["channel"] == "devices":
                    assert m["item"] == {"modelKey": "camera", "id": "cam1", "state": "DISCONNECTED"}, m
                    seen_device = True
            live = r["states"].get("events", {}).get("state") == "open"
        assert seen_event and seen_device and live, (seen_event, seen_device, live)
        checks += 1

        # Thumbnails, the log and pruning.
        before = FakeConsole.snapshots
        r = call("POST", "/thumbnail", {"event": "66f0aa", "camera": "cam1"})
        assert open(r["path"], "rb").read() == JPEG
        assert r["path"].startswith(env["XDG_DATA_HOME"])
        # A snapshot from moments ago is reused rather than fetched again.
        assert FakeConsole.snapshots == before
        r2 = call("POST", "/thumbnail", {"event": "../../evil", "camera": "cam1"})
        assert os.path.basename(r2["path"]) == "evil.jpg" and os.path.dirname(r2["path"]) == os.path.dirname(r["path"])
        # Just saved: kept even though it isn't listed (its event may not be marked yet).
        assert call("POST", "/prune", body={"keep": []})["removed"] == 0
        old = time.time() - 600
        os.utime(r2["path"], (old, old))
        assert call("POST", "/prune", body={"keep": ["66f0aa"]})["removed"] == 1
        assert os.path.exists(r["path"]) and not os.path.exists(r2["path"])
        assert call("POST", "/prune", body={"keep": [], "all": True})["removed"] == 1
        assert not os.path.exists(r["path"])
        assert call("GET", "/log") == []
        assert call("PUT", "/log", body=[{"id": "x"}])["ok"]
        assert call("GET", "/log") == [{"id": "x"}]
        assert call("PUT", "/log", body=b"not json")["error"]["kind"] == "network"
        assert call("GET", "/log") == [{"id": "x"}]
        checks += 1

        # Reconnect keeps working.
        assert call("POST", "/reconnect")["ok"]
        deadline = time.time() + 10
        live = False
        while time.time() < deadline and not live:
            r = call("GET", "/poll", {"after": seq, "version": version, "timeout": 2})
            seq, version = r["seq"], r["version"]
            live = r["states"]["events"]["state"] == "open" and any(m["channel"] == "events" for m in r["messages"])
        assert live
        checks += 1

        # A console set in Settings reads its key from the keyring.
        r = call("POST", "/config", body={"host": console, "pin": fp})
        assert "error" not in r, r
        gen = r["gen"]
        assert call("GET", "/api", {"path": "cameras"})["body"][0]["id"] == "cam1"
        # A keyring that fails for a moment keeps the working connection.
        open(os.path.join(tmp, "locked"), "w").close()
        r = call("POST", "/config", body={"host": console, "pin": fp})
        assert r["gen"] == gen and not r["changed"] and "error" not in r, r
        assert call("GET", "/api", {"path": "cameras"})["body"][0]["id"] == "cam1"
        # But not for a different console.
        r = call("POST", "/config", body={"host": "https://127.0.0.2:1", "pin": None})
        assert r["error"]["kind"] == "keyring" and r["error"]["detail"] == "Cannot unlock", r
        os.remove(os.path.join(tmp, "locked"))
        checks += 1

        # Starting again finds the running bridge.
        again = start()
        assert again["pid"] == info["pid"] and again["token"] == info["token"]
        checks += 1
    finally:
        try:
            call("POST", "/quit")
        except OSError:
            pass
        info_file = os.path.join(env["XDG_RUNTIME_DIR"], "protect-cameras-kde", "bridge-42.json")
        deadline = time.time() + 5
        while os.path.exists(info_file) and time.time() < deadline:
            time.sleep(0.1)
        try:
            os.kill(info["pid"], signal.SIGTERM)
        except OSError:
            pass
        server.shutdown()
    # It cleans up after itself on the way out.
    assert not os.path.exists(info_file)
    checks += 1
    shutil.rmtree(tmp, ignore_errors=True)
    print("%d bridge checks passed" % checks)
    return 0


def make_certificate(directory):
    cert, keyfile = os.path.join(directory, "cert.pem"), os.path.join(directory, "key.pem")
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=unifi",
                    "-keyout", keyfile, "-out", cert], check=True, capture_output=True)
    fp = subprocess.run(["openssl", "x509", "-in", cert, "-noout", "-fingerprint", "-sha256"],
                        check=True, capture_output=True, text=True).stdout.strip().split("=", 1)[1].upper()
    return cert, keyfile, fp


def serve(port, tls):
    server = TLSServer(("127.0.0.1", port), FakeConsole)
    scheme = "http"
    if tls:
        cert, keyfile, fp = make_certificate(tempfile.mkdtemp(prefix="protect-fake-console-"))
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(cert, keyfile)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = "https"
        print("Certificate SHA-256", fp)
    print("Fake console at %s://127.0.0.1:%d (API key %s)" % (scheme, server.server_address[1], KEY), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    if "--serve" in sys.argv:
        rest = [a for a in sys.argv[sys.argv.index("--serve") + 1:] if a.isdigit()]
        sys.exit(serve(int(rest[0]) if rest else 0, "--tls" in sys.argv))
    sys.exit(main())
