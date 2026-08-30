#!/usr/bin/env python3
# Sends one file to the LocalSend receiver on the Vita and times the upload.
#
#   python3 tools/localsend-bench.py <vita-ip> <file>
#
# This is the end-to-end number the TLS work was aimed at, and until now it was
# produced by hand: a phone, a stopwatch, and a screenshot. That is not a
# measurement anyone can repeat, and three of this project's performance numbers
# collapsed in one session for exactly that reason (ADR-0017).
#
# It drives the LocalSend v2 protocol directly -- prepare-upload, then upload --
# so the receiver cannot tell it from a phone. Two things have to be true on the
# device first: ls_quick_save must be on, or the app waits for a tap that never
# comes, and ls_https decides whether this talks TLS. Both live in
# ux0:data/<TITLEID>/support/shared_preferences.json, which the dev server can
# get and put. With no ls_https key the app's own default applies, which is
# HTTPS -- the path worth measuring.
#
# The receiver's certificate is self-signed and regenerated per install, so it
# is not verified here. The point is BoringSSL's throughput on this console.
import http.client, json, os, ssl, sys, time

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.0.32"
BLOB = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "blob5m.bin")
PORT = 53317
size = os.path.getsize(BLOB)
name = os.path.basename(BLOB)

ctx = ssl._create_unverified_context()

def conn():
    return http.client.HTTPSConnection(HOST, PORT, context=ctx, timeout=180)

prep = {
    "info": {"alias": "Mac Bench", "version": "2.1", "deviceModel": "Mac",
             "deviceType": "desktop", "fingerprint": "BENCHFINGERPRINT0000000000000001",
             "port": 53317, "protocol": "https", "download": False},
    "files": {"f1": {"id": "f1", "fileName": name, "size": size,
                     "fileType": "application/octet-stream"}},
}

t0 = time.time()
c = conn()
c.request("POST", "/api/localsend/v2/prepare-upload", json.dumps(prep),
          {"Content-Type": "application/json"})
r = c.getresponse()
body = r.read()
print(f"prepare-upload {r.status} in {time.time()-t0:.2f}s: {body[:200].decode(errors='replace')}")
if r.status != 200:
    sys.exit(1)
sess = json.loads(body)
token = sess["files"]["f1"]
c.close()

data = open(BLOB, "rb").read()
c = conn()
t1 = time.time()
c.request("POST",
          f"/api/localsend/v2/upload?sessionId={sess['sessionId']}&fileId=f1&token={token}",
          data, {"Content-Type": "application/octet-stream",
                 "Content-Length": str(size)})
r = c.getresponse()
r.read()
dt = time.time() - t1
print(f"upload {r.status}: {size} B in {dt:.2f}s = {size/1024/dt:.0f} KB/s")
