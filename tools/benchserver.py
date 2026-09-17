#!/usr/bin/env python3
# Feeds the Vita the same bytes three ways, so the conformance app's throughput
# probes can tell the layers apart: raw TCP on 5301, HTTP on 5302, HTTPS on
# 5303. Run it on the machine named by _benchHost in
# samples/gallery/lib/probes.dart and leave it up for the run.
#
#   python3 tools/benchserver.py
#
# The TLS certificate is self-signed and generated on first run next to this
# file. The probes accept it for that one host by name, which is the point --
# they are measuring BoringSSL's throughput, not the trust store.
#
# BENCH_CIPHER=ECDHE-RSA-AES128-GCM-SHA256 pins a TLS 1.2 suite, which also caps
# the version, because 1.3 suites cannot be selected through set_ciphers.
import http.server, socket, ssl, subprocess, threading, os

SIZE = 5 * 1024 * 1024
BLOB = bytes(os.urandom(SIZE))
HERE = os.path.dirname(os.path.abspath(__file__))

def raw_server():
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", 5301)); s.listen(8)
    while True:
        c, _ = s.accept()
        threading.Thread(target=lambda c=c: (c.sendall(BLOB), c.close()), daemon=True).start()

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        c = getattr(self.connection, "cipher", None)
        if c and c():
            print("cipher", c(), flush=True)
        # /blob/<bytes>, so one server answers every size a probe wants.
        try:
            n = int(self.path.rsplit("/", 1)[-1])
        except ValueError:
            n = SIZE
        n = max(0, min(n, SIZE))
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(n))
        self.end_headers()
        self.wfile.write(BLOB[:n])
    def do_PUT(self):
        n = int(self.headers.get("Content-Length", 0)); got = 0
        while got < n:
            got += len(self.rfile.read(min(65536, n - got)))
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()

def http_server(port, tls):
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", port), H)
    if tls:
        crt, key = os.path.join(HERE, "bench.crt"), os.path.join(HERE, "bench.key")
        if not os.path.exists(crt):
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                            "-keyout", key, "-out", crt, "-days", "30",
                            "-subj", "/CN=192.168.0.30"], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(crt, key)
        forced = os.environ.get("BENCH_CIPHER")
        if forced:
            # TLS 1.3 suites are not selectable through set_ciphers, so pinning
            # a 1.2 suite means capping the version too.
            ctx.maximum_version = ssl.TLSVersion.TLSv1_2
            ctx.set_ciphers(forced)
            print("forcing", forced, flush=True)
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    srv.serve_forever()

threading.Thread(target=raw_server, daemon=True).start()
threading.Thread(target=lambda: http_server(5302, False), daemon=True).start()
threading.Thread(target=lambda: http_server(5303, True), daemon=True).start()
print("bench server up: raw 5301, http 5302, https 5303", flush=True)
threading.Event().wait()
