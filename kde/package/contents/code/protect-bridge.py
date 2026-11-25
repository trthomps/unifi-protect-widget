#!/usr/bin/env python3
"""Talks to the UniFi Protect console on behalf of the Plasma widget.

QML can't pin a self-signed certificate, send a header on a websocket or an <img>, so this does
the network side of ProtectAPI.swift and ProtectSocket: certificate pinning, the request pacer,
the two push channels, snapshots and the event log on disk. It listens on 127.0.0.1 behind a
random token, and exits on its own a few minutes after the widget stops talking to it.

    protect-bridge.py start --instance ID    start (or reuse) the bridge, print {port, token, ...}

Standard library only. PROTECT_CAMERAS_DEBUG=1 logs to $XDG_RUNTIME_DIR/protect-cameras-kde/.
"""

import base64
import collections
import hashlib
import http.client
import http.server
import json
import os
import re
import secrets
import select
import signal
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.parse

VERSION = "1"
SERVICE = "io.github.trthomps.protect-cameras"
USER_AGENT = "ProtectCameras/kde"
DEBUG = bool(os.environ.get("PROTECT_CAMERAS_DEBUG"))
IDLE_EXIT = 180          # seconds without a request from the widget
MAX_MESSAGE = 4 * 1024 * 1024


def log(message):
    if DEBUG:
        sys.stderr.write("[protect-bridge %s] %s\n" % (time.strftime("%H:%M:%S"), message))
        sys.stderr.flush()


# MARK: - Errors (ProtectError in Models.swift)

class ProtectError(Exception):
    def __init__(self, kind, detail=None, status=None, fingerprint=None):
        super().__init__(kind, detail)
        self.kind = kind
        self.detail = detail
        self.status = status
        self.fingerprint = fingerprint

    def to_json(self):
        out = {"kind": self.kind}
        if self.detail:
            out["detail"] = self.detail
        if self.status:
            out["status"] = self.status
        if self.fingerprint:
            out["fingerprint"] = self.fingerprint
        return out

    def __str__(self):
        return "%s(%s)" % (self.kind, self.detail or self.status or self.fingerprint or "")


def network_error(exc, host):
    if isinstance(exc, ProtectError):
        return exc
    if isinstance(exc, socket.gaierror):
        return ProtectError("network", "Couldn't find %s on the network." % host)
    if isinstance(exc, (socket.timeout, TimeoutError)):
        return ProtectError("network", "The console didn't answer in time.")
    if isinstance(exc, ConnectionRefusedError):
        return ProtectError("network", "%s refused the connection. Check the address and port." % host)
    if isinstance(exc, ssl.SSLError):
        return ProtectError("network", "TLS failed: %s" % (exc.reason or exc))
    text = getattr(exc, "strerror", None) or str(exc) or exc.__class__.__name__
    return ProtectError("network", text)


def server_message(body):
    """Protect answers `{"error":{"code":401,"message":"Unauthorized"}}`."""
    try:
        obj = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(obj, dict):
        return None
    nested = obj.get("error")
    if isinstance(nested, dict) and isinstance(nested.get("message"), str):
        text = nested["message"]
        return None if text in ("Unauthorized", "Forbidden") else (text or None)
    for key in ("error", "message"):
        if isinstance(obj.get(key), str) and obj[key]:
            return obj[key]
    return None


def fingerprint_of(der):
    """Colon-separated uppercase SHA-256 of the leaf certificate, as browsers show it."""
    digest = hashlib.sha256(der).hexdigest().upper()
    return ":".join(digest[i:i + 2] for i in range(0, len(digest), 2))


# MARK: - Request pacing (RequestPacer in ProtectAPI.swift)

class Pacer:
    """Keeps requests under the console's per-key rate limit (shared with the websockets): 80% of
    whatever it advertises in RateLimit-Policy, and a pause for everything after a 429."""

    def __init__(self):
        self.lock = threading.Lock()
        self.interval = 1.0 / 6
        self.next_slot = 0.0
        self.seeded = False

    def acquire(self):
        with self.lock:
            now = time.monotonic()
            slot = max(now, self.next_slot)
            self.next_slot = slot + self.interval
        if slot > now:
            time.sleep(slot - now)

    def seed(self, policy):
        if self.seeded or not policy:
            return
        quota = window = None
        for part in policy.split(",")[0].split(";"):
            pair = part.strip().split("=", 1)
            if len(pair) != 2:
                continue
            try:
                if pair[0] == "q":
                    quota = float(pair[1])
                elif pair[0] == "w":
                    window = float(pair[1])
            except ValueError:
                pass
        if quota and window and quota > 0 and window > 0:
            with self.lock:
                self.interval = window / (quota * 0.8)
                self.seeded = True
            log("rate limit %s/%ss -> one request every %.3fs" % (quota, window, self.interval))

    def back_off(self, seconds):
        with self.lock:
            self.next_slot = max(self.next_slot, time.monotonic() + seconds)


# MARK: - Console connection (ProtectConnection, TrustDelegate)

class Console:
    def __init__(self, host_url, api_key, pinned):
        parsed = urllib.parse.urlsplit(host_url)
        self.url = host_url
        self.scheme = parsed.scheme or "https"
        self.hostname = parsed.hostname or ""
        self.port = parsed.port or (80 if self.scheme == "http" else 443)
        self.base_path = parsed.path.rstrip("/")
        self.api_key = api_key
        self.pinned = pinned or None
        self.pacer = Pacer()
        self.pool = []
        self.pool_lock = threading.Lock()
        self.prefer_pinned = False
        self.closed = False

    @property
    def host_header(self):
        host = "[%s]" % self.hostname if ":" in self.hostname else self.hostname
        default = 80 if self.scheme == "http" else 443
        return host if self.port == default else "%s:%d" % (host, self.port)

    def integration_path(self, path):
        return self.base_path + "/proxy/protect/integration/v1/" + path

    def _connect(self, timeout):
        return socket.create_connection((self.hostname, self.port), timeout=timeout)

    def _system_trusted(self, timeout):
        ctx = ssl.create_default_context()
        raw = self._connect(timeout)
        try:
            return ctx.wrap_socket(raw, server_hostname=self.hostname)
        except BaseException:
            raw.close()
            raise

    def _pinned(self, timeout):
        """Returns (socket, fingerprint); the socket only if it matches the pin."""
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        raw = self._connect(timeout)
        try:
            tls = ctx.wrap_socket(raw, server_hostname=self.hostname)
        except BaseException:
            raw.close()
            raise
        fp = fingerprint_of(tls.getpeercert(binary_form=True) or b"")
        if self.pinned and fp == self.pinned:
            return tls, fp
        tls.close()
        return None, fp

    def open_socket(self, timeout=20):
        """A connected socket, TLS unless the console URL is http://. A certificate the system
        trusts is always fine (so renewals never trip the pin); the pin only vouches for a
        self-signed one. Anything else raises untrustedCertificate / certificateChanged."""
        if self.closed:
            raise ProtectError("cancelled")
        try:
            if self.scheme == "http":
                return self._connect(timeout)
            if self.prefer_pinned and self.pinned:
                tls, _ = self._pinned(timeout)
                if tls:
                    return tls
            try:
                tls = self._system_trusted(timeout)
                self.prefer_pinned = False
                return tls
            except ssl.SSLCertVerificationError as exc:
                log("system trust refused %s: %s" % (self.hostname, exc.verify_message))
            tls, fp = self._pinned(timeout)
            if tls:
                self.prefer_pinned = True
                return tls
            raise ProtectError("certificateChanged" if self.pinned else "untrustedCertificate", fingerprint=fp)
        except ProtectError:
            raise
        except (OSError, ssl.SSLError) as exc:
            raise network_error(exc, self.hostname)

    # HTTP with a small keep-alive pool, so the ~1/s live view doesn't redo the TLS handshake.

    def _take(self):
        with self.pool_lock:
            if self.pool:
                return self.pool.pop(), True
        return _Connection(self), False

    def _give_back(self, conn):
        with self.pool_lock:
            if not self.closed and len(self.pool) < 4:
                self.pool.append(conn)
                return
        conn.close()

    def close(self):
        self.closed = True
        with self.pool_lock:
            pool, self.pool = self.pool, []
        for conn in pool:
            conn.close()

    def get(self, path, accept="application/json", query=None):
        url = self.integration_path(path)
        if query:
            url += "?" + urllib.parse.urlencode(query)
        headers = {"X-API-KEY": self.api_key, "Accept": accept, "User-Agent": USER_AGENT}
        attempt = 0
        while True:
            self.pacer.acquire()
            conn, reused = self._take()
            try:
                conn.request("GET", url, headers=headers)
                resp = conn.getresponse()
                body = resp.read()
            except ProtectError:
                conn.close()
                raise
            except (http.client.RemoteDisconnected, ConnectionResetError, BrokenPipeError,
                    http.client.BadStatusLine) as exc:
                conn.close()
                if reused:
                    continue        # an idle keep-alive connection the console had closed
                raise network_error(exc, self.hostname)
            except (OSError, ssl.SSLError, http.client.HTTPException) as exc:
                conn.close()
                raise network_error(exc, self.hostname)
            if resp.will_close:
                conn.close()
            else:
                self._give_back(conn)
            log("GET %s -> %d (%d bytes)" % (url, resp.status, len(body)))
            self.pacer.seed(resp.getheader("RateLimit-Policy"))
            if resp.status == 429:
                try:
                    wait = float(resp.getheader("Retry-After") or 1.5)
                except ValueError:
                    wait = 1.5
                self.pacer.back_off(min(max(wait, 1), 30))
                if attempt < 2:
                    attempt += 1
                    continue
            break
        if 200 <= resp.status < 300:
            return body
        if resp.status == 401:
            raise ProtectError("unauthorized", server_message(body), 401)
        if resp.status == 403:
            raise ProtectError("forbidden", server_message(body), 403)
        if resp.status == 429:
            raise ProtectError("http", "The console is rate-limiting requests. Things will catch up in a moment.", 429)
        raise ProtectError("http", server_message(body), resp.status)


class _Connection(http.client.HTTPConnection):
    def __init__(self, console):
        super().__init__(console.hostname, console.port, timeout=20)
        self.console = console

    def connect(self):
        self.sock = self.console.open_socket(20)


# MARK: - Push channels (ProtectSocket)

class Channel(threading.Thread):
    """One of the Integration API's push channels (`subscribe/events` or `subscribe/devices`).
    Reconnects with backoff until stopped."""

    def __init__(self, bridge, console, gen, path, name):
        super().__init__(daemon=True, name=name)
        self.bridge = bridge
        self.console = console
        self.gen = gen
        self.path = path
        self.channel = name
        self.stopped = threading.Event()
        self.wake = threading.Event()
        self.kicked = False
        self.sock = None
        self.state = {"state": "idle"}

    def stop(self):
        self.stopped.set()
        self.kick()

    def kick(self):
        """Skip the backoff wait, and replace even a socket that looks open: after sleep or a
        network switch it may be half-open."""
        self.kicked = True
        self.wake.set()
        sock = self.sock
        if sock:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    def set_state(self, state, error=None, retry_in=None):
        self.state = {"state": state}
        if error:
            self.state["error"] = error.to_json()
        if retry_in:
            self.state["retryIn"] = retry_in
        self.bridge.queue.touch()

    def run(self):
        failures = 0
        while not self.stopped.is_set():
            self.kicked = False
            self.set_state("connecting")
            self.console.pacer.acquire()
            if self.stopped.is_set():
                break
            opened = False
            failure = None
            try:
                sock, buf = self.handshake()
                self.sock = sock
                opened = True
                failures = 0
                self.set_state("open")
                self.receive(sock, buf)
            except ProtectError as exc:
                failure = exc
            except Exception as exc:  # noqa: BLE001 - any failure means reconnect
                failure = network_error(exc, self.console.hostname)
            finally:
                if self.sock:
                    try:
                        self.sock.close()
                    except OSError:
                        pass
                    self.sock = None
            if self.stopped.is_set():
                break
            log("socket %s closed: %s" % (self.path, failure))
            if self.kicked:
                failures = 0
                continue
            # A socket that never opened counts as a failed connect; one that dropped after
            # working retries quickly.
            failures = 1 if opened else failures + 1
            delay = min(60, 2 ** min(failures, 6))
            self.set_state("waiting", failure, delay)
            self.wake.wait(delay)
            self.wake.clear()
        self.set_state("idle")

    def handshake(self):
        sock = self.console.open_socket(15)
        try:
            sock.settimeout(15)
            key = base64.b64encode(os.urandom(16)).decode()
            request = ("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                       "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nX-API-KEY: %s\r\n"
                       "User-Agent: %s\r\n\r\n") % (self.console.integration_path(self.path),
                                                    self.console.host_header, key, self.console.api_key, USER_AGENT)
            sock.sendall(request.encode())
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = sock.recv(4096)
                if not chunk:
                    raise ProtectError("network", "The console closed the connection.")
                data += chunk
                if len(data) > 65536:
                    raise ProtectError("decoding", "Oversized websocket handshake.")
            head, _, rest = data.partition(b"\r\n\r\n")
            lines = head.decode("latin-1").split("\r\n")
            parts = lines[0].split(" ", 2)
            status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
            if status == 401:
                raise ProtectError("unauthorized", None, 401)
            if status == 403:
                raise ProtectError("forbidden", None, 403)
            if status != 101:
                raise ProtectError("http", None, status or None)
            headers = {}
            for line in lines[1:]:
                name, _, value = line.partition(":")
                headers[name.strip().lower()] = value.strip()
            expected = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode())
                                        .digest()).decode()
            if headers.get("sec-websocket-accept") != expected:
                raise ProtectError("decoding", "The console's websocket handshake didn't check out.")
            return sock, bytearray(rest)
        except BaseException:
            sock.close()
            raise

    def send(self, sock, opcode, payload=b""):
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header = struct.pack("!BB", 0x80 | opcode, 0x80 | length)
        elif length < 65536:
            header = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, length)
        else:
            header = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, length)
        sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def receive(self, sock, buf):
        """Reads frames until the socket fails. Pings every 15 seconds; one that isn't answered
        (by a pong or anything else) in 10 seconds means the connection is dead."""
        sock.settimeout(1.0)
        last_ping = time.monotonic()
        awaiting = None
        message = None
        while not self.stopped.is_set() and not self.kicked:
            try:
                chunk = sock.recv(65536)
            except (socket.timeout, TimeoutError, ssl.SSLWantReadError):
                chunk = None
            if chunk == b"":
                raise ProtectError("network", "The console closed the event stream.")
            if chunk:
                buf.extend(chunk)
                awaiting = None
            while len(buf) >= 2:
                b0, b1 = buf[0], buf[1]
                opcode = b0 & 0x0F
                length = b1 & 0x7F
                at = 2
                if length == 126:
                    if len(buf) < 4:
                        break
                    length = struct.unpack("!H", bytes(buf[2:4]))[0]
                    at = 4
                elif length == 127:
                    if len(buf) < 10:
                        break
                    length = struct.unpack("!Q", bytes(buf[2:10]))[0]
                    at = 10
                if length > MAX_MESSAGE:
                    raise ProtectError("decoding", "A websocket message was too large.")
                mask = None
                if b1 & 0x80:
                    if len(buf) < at + 4:
                        break
                    mask = bytes(buf[at:at + 4])
                    at += 4
                if len(buf) < at + length:
                    break
                payload = bytes(buf[at:at + length])
                del buf[:at + length]
                if mask:
                    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
                fin = b0 & 0x80
                if opcode in (0x1, 0x2):
                    message = bytearray(payload)
                elif opcode == 0x0 and message is not None:
                    message.extend(payload)
                elif opcode == 0x8:
                    code = struct.unpack("!H", payload[:2])[0] if len(payload) >= 2 else None
                    try:
                        self.send(sock, 0x8, payload[:2])
                    except OSError:
                        pass
                    raise ProtectError("network", "The console closed the event stream%s."
                                       % (" (%d)" % code if code else ""))
                elif opcode == 0x9:
                    self.send(sock, 0xA, payload)
                    continue
                else:
                    continue
                if message is not None and len(message) > MAX_MESSAGE:
                    raise ProtectError("decoding", "A websocket message was too large.")
                if fin and message is not None:
                    self.deliver(bytes(message))
                    message = None
            now = time.monotonic()
            if awaiting is not None and now - awaiting > 10:
                raise ProtectError("network", "The event stream stopped answering.")
            if awaiting is None and now - last_ping >= 15:
                self.send(sock, 0x9, b"keepalive")
                last_ping = awaiting = now

    def deliver(self, data):
        try:
            obj = json.loads(data)
        except (ValueError, UnicodeDecodeError):
            log("ignored %s message: %r" % (self.channel, data[:200]))
            return
        if not isinstance(obj, dict) or not isinstance(obj.get("item"), dict):
            return
        item = obj["item"]
        if self.channel == "events":
            if item.get("modelKey") != "event":
                return
            log("event %s: %s" % (obj.get("type"), json.dumps(item)[:400]))
            self.bridge.queue.push({"gen": self.gen, "channel": "events", "type": obj.get("type"), "item": item})
            return
        # Devices: only what the widget uses (cameras coming, going, connecting, renamed). The
        # channel also carries frequent stats updates that would otherwise wake it up for nothing.
        if item.get("modelKey") != "camera":
            return
        action = obj.get("type")
        slim = {"modelKey": "camera", "id": item.get("id")}
        for key in ("state", "name"):
            if key in item:
                slim[key] = item[key]
        if action in ("add", "remove") or len(slim) > 2:
            self.bridge.queue.push({"gen": self.gen, "channel": "devices", "type": action, "item": slim})


class MessageQueue:
    """Push messages for the widget's long poll, newest 1000 kept."""

    def __init__(self):
        self.cond = threading.Condition()
        self.items = collections.deque(maxlen=1000)
        self.seq = 0
        self.version = 0     # bumped on any change, including socket states

    def push(self, message):
        with self.cond:
            self.seq += 1
            message["seq"] = self.seq
            self.items.append(message)
            self.version += 1
            self.cond.notify_all()

    def touch(self):
        with self.cond:
            self.version += 1
            self.cond.notify_all()

    def wait(self, after, seen_version, timeout):
        with self.cond:
            self.cond.wait_for(lambda: self.seq > after or self.version != seen_version, timeout)
            items = [m for m in self.items if m["seq"] > after]
            gap = bool(after and self.items and self.items[0]["seq"] > after + 1)
            return self.seq, self.version, items, gap


# MARK: - Keyring (SecretStore in Preferences.swift)

def read_key(host):
    """The API key for `host` from the Secret Service, or None. Raises keyring errors."""
    try:
        result = subprocess.run(["secret-tool", "lookup", "service", SERVICE, "account", "apikey:" + host],
                                capture_output=True, text=True, timeout=25, stdin=subprocess.DEVNULL)
    except FileNotFoundError:
        raise ProtectError("keyring", "secret-tool isn't installed. It comes with libsecret (libsecret-tools on Debian/Ubuntu).")
    except subprocess.TimeoutExpired:
        raise ProtectError("keyring", "The keyring didn't answer in time. Is it locked?")
    if result.returncode == 0:
        key = result.stdout.rstrip("\r\n").strip()
        return key or None
    if result.returncode == 1:
        return None
    raise ProtectError("keyring", result.stderr.strip() or "secret-tool failed (exit %d)." % result.returncode)


def normalized_host(text):
    """Accepts `192.168.1.1`, `https://unifi.local/`, or `host:8443` (ProtectAPI.normalizedHost)."""
    text = (text or "").strip()
    if not text:
        return None
    if "://" not in text:
        text = "https://" + text
    text = text.rstrip("/")
    parsed = urllib.parse.urlsplit(text)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return None
    try:
        parsed.port
    except ValueError:
        return None
    return text


# MARK: - The bridge

SAFE_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
API_PATHS = {"meta/info", "nvrs", "cameras"}


def safe_name(event_id):
    """Event ids are hex; anything else is reduced to safe characters so it can't escape the folder."""
    safe = "".join(c for c in str(event_id) if (c.isascii() and c.isalnum()) or c == "-")[:100]
    return safe or "invalid"


def atomic_write(path, data):
    tmp = "%s.%d.tmp" % (path, os.getpid())
    with open(tmp, "wb") as fh:
        fh.write(data)
    os.replace(tmp, path)


class Snapshot:
    def __init__(self):
        self.done = threading.Event()
        self.data = None
        self.error = None


class Bridge:
    def __init__(self, data_dir):
        self.data_dir = data_dir
        self.thumb_dir = os.path.join(data_dir, "thumbnails")
        self.queue = MessageQueue()
        self.lock = threading.Lock()
        self.console = None
        self.channels = []
        self.gen = 0
        self.key_signature = None
        self.host = None
        self.source = None
        self.config_error = None
        self.snap_lock = threading.Lock()
        self.inflight = {}
        self.last_snapshot = {}
        self.last_activity = time.monotonic()

    # Configuration

    def configure(self, host_text, pin):
        host = normalized_host(host_text)
        env_host = normalized_host(os.environ.get("PROTECT_CAMERAS_HOST", ""))
        env_key = (os.environ.get("PROTECT_CAMERAS_API_KEY") or "").strip() or None
        key = source = None
        error = None
        try:
            if host:
                key = read_key(host)
                source = "keyring"
                if not key and env_key and env_host == host:
                    key, source = env_key, "environment"
            elif env_host and env_key:
                host, key, source = env_host, env_key, "environment"
        except ProtectError as exc:
            error = exc
        if not error and not (host and key):
            error = ProtectError("notConfigured")
        with self.lock:
            # A keyring that's briefly locked or slow shouldn't drop a working connection: keep
            # using the key we already have for the same console.
            if error and error.kind == "keyring" and self.console is not None \
                    and self.key_signature and self.key_signature[:2] == (host, pin or None):
                log("keyring lookup failed, keeping the current connection: %s" % error)
                return {"gen": self.gen, "changed": False, "host": self.host, "source": self.source}
        signature = (host, pin or None, hashlib.sha256(key.encode()).hexdigest() if key else None)
        with self.lock:
            changed = signature != self.key_signature
            if changed:
                self._teardown()
                self.gen += 1
                self.key_signature = signature
                self.host = host
                self.source = source if not error else None
                if not error:
                    self.console = Console(host, key, pin)
                    self.channels = [Channel(self, self.console, self.gen, "subscribe/events", "events"),
                                     Channel(self, self.console, self.gen, "subscribe/devices", "devices")]
                    for channel in self.channels:
                        channel.start()
            self.config_error = error
            self.queue.touch()
            out = {"gen": self.gen, "changed": changed, "host": host, "source": self.source}
            if error:
                out["error"] = error.to_json()
            return out

    def _teardown(self):
        for channel in self.channels:
            channel.stop()
        self.channels = []
        if self.console:
            self.console.close()
        self.console = None
        with self.snap_lock:
            self.last_snapshot = {}

    def reconnect(self):
        with self.lock:
            for channel in self.channels:
                channel.kick()

    def states(self):
        with self.lock:
            out = {c.channel: c.state for c in self.channels}
            if self.config_error:
                out["error"] = self.config_error.to_json()
            return out

    def require_console(self):
        console = self.console
        if console is None:
            raise self.config_error or ProtectError("notConfigured")
        return console

    # Fetching

    def api(self, path):
        if path not in API_PATHS:
            raise ProtectError("http", "Unknown path.", 404)
        body = self.require_console().get(path)
        try:
            return json.loads(body)
        except (ValueError, UnicodeDecodeError):
            raise ProtectError("decoding", "Couldn't read %s." % path)

    def snapshot(self, camera_id, hq, max_age=0.0):
        """A JPEG of what the camera sees now, or joins the fetch already running for it, so an
        event's thumbnail isn't lost to the grid or live view holding the slot."""
        if not SAFE_ID.match(camera_id or ""):
            raise ProtectError("http", "Bad camera id.", 400)
        console = self.require_console()
        with self.snap_lock:
            cached = self.last_snapshot.get(camera_id)
            if max_age and cached and time.monotonic() - cached[0] < max_age:
                return cached[1]
            flight = self.inflight.get(camera_id)
            owner = flight is None
            if owner:
                flight = self.inflight[camera_id] = Snapshot()
        if not owner:
            flight.done.wait(30)
            if flight.data is not None:
                return flight.data
            raise flight.error or ProtectError("network", "The snapshot didn't arrive in time.")
        try:
            flight.data = console.get("cameras/%s/snapshot" % camera_id, accept="image/jpeg",
                                      query={"highQuality": "true" if hq else "false"})
            with self.snap_lock:
                if self.console is console:
                    self.last_snapshot[camera_id] = (time.monotonic(), flight.data)
            return flight.data
        except ProtectError as exc:
            flight.error = exc
            raise
        finally:
            flight.done.set()
            with self.snap_lock:
                if self.inflight.get(camera_id) is flight:
                    del self.inflight[camera_id]

    def save_thumbnail(self, event_id, camera_id):
        data = self.snapshot(camera_id, False, max_age=3)
        os.makedirs(self.thumb_dir, exist_ok=True)
        path = os.path.join(self.thumb_dir, safe_name(event_id) + ".jpg")
        atomic_write(path, data)
        return path

    def prune(self, keep, everything=False):
        """Deletes thumbnails of events no longer in `keep`, except ones saved in the last two
        minutes (an event the widget hasn't marked yet), unless `everything` (clearing the log)."""
        keep = {safe_name(k) + ".jpg" for k in keep}
        removed = 0
        try:
            names = os.listdir(self.thumb_dir)
        except FileNotFoundError:
            return 0
        recent = time.time() - 120
        for name in names:
            path = os.path.join(self.thumb_dir, name)
            try:
                # One being saved for an event the widget hasn't marked yet.
                if not everything and os.path.getmtime(path) > recent:
                    continue
            except OSError:
                continue
            if name not in keep:
                try:
                    os.remove(os.path.join(self.thumb_dir, name))
                    removed += 1
                except OSError:
                    pass
        return removed

    @property
    def log_path(self):
        return os.path.join(self.data_dir, "events.json")

    def read_log(self):
        try:
            with open(self.log_path, "rb") as fh:
                return fh.read()
        except FileNotFoundError:
            return b"[]"

    def write_log(self, data):
        json.loads(data)   # refuse anything that isn't JSON
        os.makedirs(self.data_dir, exist_ok=True)
        atomic_write(self.log_path, data)


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "ProtectBridge/" + VERSION
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    @property
    def bridge(self):
        return self.server.bridge

    def reply(self, status, body, content_type="application/json"):
        if not isinstance(body, (bytes, bytearray)):
            body = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > 16 * 1024 * 1024:
            self.close_connection = True    # the unread body would be parsed as the next request
            raise ProtectError("http", "Too large.", 413)
        return self.rfile.read(length) if length else b""

    def route(self, method):
        url = urllib.parse.urlsplit(self.path)
        query = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query).items()}
        if not secrets.compare_digest(query.get("token", ""), self.server.token):
            return self.reply(403, {"error": {"kind": "forbidden", "detail": "Bad bridge token."}})
        self.bridge.last_activity = time.monotonic()
        route = (method, url.path)
        b = self.bridge
        try:
            if route == ("GET", "/health"):
                return self.reply(200, {"version": VERSION, "gen": b.gen, "pid": os.getpid()})
            if route == ("POST", "/config"):
                cfg = json.loads(self.body() or b"{}")
                return self.reply(200, b.configure(cfg.get("host", ""), cfg.get("pin")))
            if route == ("POST", "/reconnect"):
                b.reconnect()
                return self.reply(200, {"ok": True})
            if route == ("GET", "/api"):
                return self.reply(200, {"gen": b.gen, "body": b.api(query.get("path", ""))})
            if route == ("GET", "/snapshot"):
                try:
                    data = b.snapshot(query.get("camera", ""), query.get("hq") == "1")
                except ProtectError as exc:
                    return self.reply(502, json.dumps({"error": exc.to_json()}).encode())
                return self.reply(200, data, "image/jpeg")
            if route == ("POST", "/thumbnail"):
                return self.reply(200, {"path": b.save_thumbnail(query.get("event", ""), query.get("camera", ""))})
            if route == ("POST", "/prune"):
                req = json.loads(self.body() or b"{}")
                return self.reply(200, {"removed": b.prune(req.get("keep") or [], bool(req.get("all")))})
            if route == ("GET", "/log"):
                return self.reply(200, b.read_log())
            if route == ("PUT", "/log"):
                b.write_log(self.body())
                return self.reply(200, {"ok": True})
            if route == ("GET", "/poll"):
                after = int(query.get("after") or 0)
                seen = int(query.get("version") or -1)
                timeout = min(max(float(query.get("timeout") or 25), 0), 30)
                seq, version, items, gap = b.queue.wait(after, seen, timeout)
                return self.reply(200, {"seq": seq, "version": version, "gen": b.gen, "messages": items,
                                        "gap": gap, "states": b.states()})
            if route == ("POST", "/quit"):
                self.reply(200, {"ok": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return None
            return self.reply(404, {"error": {"kind": "http", "status": 404}})
        except ProtectError as exc:
            return self.reply(200, {"gen": b.gen, "error": exc.to_json()})
        except (ValueError, OSError) as exc:
            return self.reply(200, {"gen": b.gen, "error": {"kind": "network", "detail": str(exc)}})

    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")


# MARK: - Process management

def runtime_dir():
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    path = os.path.join(base, "protect-cameras-kde-%d" % os.getuid() if base == "/tmp" else "protect-cameras-kde")
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def data_root():
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "protect-cameras-kde")


def ping(info):
    try:
        conn = http.client.HTTPConnection("127.0.0.1", int(info["port"]), timeout=3)
        conn.request("GET", "/health?token=" + urllib.parse.quote(info["token"]))
        resp = conn.getresponse()
        data = json.loads(resp.read())
        conn.close()
        return data.get("version") == VERSION and data.get("pid") == info.get("pid")
    except (OSError, ValueError, KeyError, TypeError, http.client.HTTPException):
        return False


def is_bridge(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as fh:
            return b"protect-bridge" in fh.read()
    except OSError:
        return False


def serve(instance, info_path, ready_fd):
    bridge = Bridge(os.path.join(data_root(), instance))
    server = Server(("127.0.0.1", 0), Handler)
    server.bridge = bridge
    server.token = secrets.token_urlsafe(24)
    info = {"pid": os.getpid(), "port": server.server_address[1], "token": server.token,
            "version": VERSION, "dataDir": bridge.data_dir}
    fd = os.open(info_path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(info, fh)
    os.replace(info_path + ".tmp", info_path)
    os.write(ready_fd, (json.dumps(info) + "\n").encode())
    os.close(ready_fd)

    def idle_watch():
        while True:
            time.sleep(15)
            if time.monotonic() - bridge.last_activity > IDLE_EXIT:
                log("idle, exiting")
                server.shutdown()
                return

    threading.Thread(target=idle_watch, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    log("listening on 127.0.0.1:%d" % info["port"])
    try:
        server.serve_forever(poll_interval=1)
    finally:
        try:
            with open(info_path) as fh:
                if json.load(fh).get("pid") == os.getpid():
                    os.remove(info_path)
        except (OSError, ValueError):
            pass
        os._exit(0)


def start(instance):
    instance = re.sub(r"[^A-Za-z0-9_-]", "", instance) or "default"
    rt = runtime_dir()
    info_path = os.path.join(rt, "bridge-%s.json" % instance)
    try:
        with open(info_path) as fh:
            info = json.load(fh)
    except (OSError, ValueError):
        info = None
    if info and ping(info):
        print(json.dumps(info))
        return 0
    if info and isinstance(info.get("pid"), int) and is_bridge(info["pid"]):
        try:
            os.kill(info["pid"], signal.SIGTERM)
        except OSError:
            pass

    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        # Detach completely: the widget's command runner waits for stdout to close.
        os.close(read_fd)
        os.setsid()
        if os.fork() != 0:
            os._exit(0)
        devnull = os.open(os.devnull, os.O_RDWR)
        os.dup2(devnull, 0)
        os.dup2(devnull, 1)
        err = os.open(os.path.join(rt, "bridge-%s.log" % instance), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600) \
            if DEBUG else devnull
        os.dup2(err, 2)
        try:
            serve(instance, info_path, write_fd)
        except BaseException as exc:  # noqa: BLE001
            log("bridge failed: %r" % exc)
            os._exit(1)
    os.close(write_fd)
    os.waitpid(pid, 0)
    data = b""
    deadline = time.monotonic() + 10
    while b"\n" not in data and time.monotonic() < deadline:
        ready, _, _ = select.select([read_fd], [], [], max(0, deadline - time.monotonic()))
        if not ready:
            break
        chunk = os.read(read_fd, 4096)
        if not chunk:
            break
        data += chunk
    os.close(read_fd)
    if b"\n" not in data:
        sys.stderr.write("The bridge didn't start.\n")
        return 1
    sys.stdout.write(data.decode())
    return 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "start":
        instance = argv[argv.index("--instance") + 1] if "--instance" in argv[:-1] else "default"
        return start(instance)
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
