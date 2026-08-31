#!/usr/bin/env python3
"""Write the sce_sys/package/head.bin a fresh title id needs to be promoted.

    ./tools/make-head-bin.py <titleid> -o head.bin
    ./tools/make-head-bin.py FVTA00005 --content-id EP9000-FVTA00005_00-...

The promoter will install an extracted .vpk into any directory it is given, but
it refuses one without a package header. Measured on 2026-08-31, with the same
package each time:

    no head.bin                          result 0x8010111C
    head.bin, content id edited by hand  result 0x80871004   (digest checked)
    head.bin, valid, id not the package's result 0x80870005

so the header is read, its digests are verified, and its content id has to be
the one being installed. That is the whole of what stands between this port and
registering title ids of its own.

## The format

head.bin is a PKG header. Everything in it is boilerplate except the content id
and three digests, and the offsets of all four are read out of the header
itself:

    0x30        content id, 48 bytes, "EP9000-<TITLEID>_00-0000000000000000"
    be32 @0xD0  length of the header region; digest of [0, len) goes at [len]
    be32 @0x08  offset of the pkg-info region
    be32 @0x10  its length; digest of [off, off+len-64) goes at be32 @0xD4
    be32 @0xE8  length of everything; digest of [0, len) goes at [len]

**The digest takes no key.** It is SHA1 of the region, then a fixed
rearrangement of those 20 bytes into a 64-byte block, then SHA1 of that, first
16 bytes. There is no secret here and nothing is being defeated: the console
computes the same function over the same public bytes.

## Where the template came from, and why it is not VitaShell's

VitaShell does this too and ships a head.bin as an embedded resource. It is
GPLv3 and this repo is BSD-3-Clause, so none of it is here. What is here is a
header **this console wrote**, lifted from ux0:app/FVTA00002/sce_sys/package
after an ordinary install, with only the four fields above rewritten. The format
above was read from VitaShell's source as fact -- offsets and an algorithm, not
expression -- and implemented from scratch in a different language.

The implementation is checked against reality rather than against a description:
`--verify` recomputes all three digests of a header the promoter itself wrote
and requires them to match. Both samples taken from this console pass.
"""
import argparse, hashlib, struct, sys

CONTENT_ID_OFF = 0x30
CONTENT_ID_LEN = 48


def fpkg_digest(data: bytes) -> bytes:
    """The keyless digest described above. Sixteen bytes."""
    a = hashlib.sha1(data).digest()
    # The 64-byte block is mostly a repeat of two slices of the first hash.
    # Reproduced exactly because the console checks the result, not because
    # any of it is meaningful.
    buf = bytearray(64)
    buf[0:8] = a[4:12]
    buf[8:16] = a[4:12]
    buf[16:20] = a[12:16]
    buf[20] = a[16]
    buf[21] = a[1]
    buf[22] = a[2]
    buf[23] = a[3]
    buf[24:32] = buf[16:24]
    return hashlib.sha1(bytes(buf)).digest()[:16]


def be32(buf: bytes, off: int) -> int:
    return struct.unpack_from(">I", buf, off)[0]


def regions(head: bytes):
    """The three (source slice, destination offset) pairs, from the header."""
    hdr_len = be32(head, 0xD0)
    info_off, info_len = be32(head, 0x08), be32(head, 0x10)
    info_out = be32(head, 0xD4)
    all_len = be32(head, 0xE8)
    return [
        ((0, hdr_len), hdr_len),
        ((info_off, info_off + info_len - 64), info_out),
        ((0, all_len), all_len),
    ]


def sign(head: bytearray) -> bytearray:
    # In order: each digest covers bytes an earlier one may have written, so
    # they cannot be computed in parallel or reordered.
    for (start, end), out in regions(bytes(head)):
        head[out:out + 16] = fpkg_digest(bytes(head[start:end]))
    return head


def verify(head: bytes) -> bool:
    ok = True
    for i, ((start, end), out) in enumerate(regions(head), 1):
        want = head[out:out + 16]
        got = fpkg_digest(head[start:end])
        good = want == got
        print(f"  digest {i} at {out:#06x}  {'ok' if good else 'MISMATCH'}")
        ok &= good
    return ok


def main() -> int:
    here = __file__.rsplit("/", 1)[0]
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("titleid", nargs="?", help="nine characters, e.g. FVTA00005")
    ap.add_argument("-o", "--output", default="head.bin")
    ap.add_argument("--template", default=f"{here}/pkg/head-template.bin")
    ap.add_argument("--content-id", help="override the derived content id")
    ap.add_argument("--verify", metavar="HEAD_BIN",
                    help="check an existing head.bin instead of writing one")
    args = ap.parse_args()

    if args.verify:
        with open(args.verify, "rb") as f:
            head = f.read()
        cid = head[CONTENT_ID_OFF:CONTENT_ID_OFF + CONTENT_ID_LEN]
        cid = cid.split(b"\x00")[0].decode(errors="replace")
        print(f"{args.verify}: {len(head)} bytes, content id {cid}")
        return 0 if verify(head) else 1

    if not args.titleid:
        ap.error("a title id is required unless --verify is given")
    tid = args.titleid
    # Nine characters, upper case. The promoter is not forgiving about this and
    # neither is the shell, and a lower-case id fails somewhere much later.
    if len(tid) != 9 or tid != tid.upper():
        print(f"!! title id must be 9 upper-case characters: {tid!r}",
              file=sys.stderr)
        return 2

    with open(args.template, "rb") as f:
        head = bytearray(f.read())

    content_id = args.content_id or f"EP9000-{tid}_00-0000000000000000"
    if len(content_id) >= CONTENT_ID_LEN:
        print(f"!! content id too long: {content_id!r}", file=sys.stderr)
        return 2
    head[CONTENT_ID_OFF:CONTENT_ID_OFF + CONTENT_ID_LEN] = \
        content_id.encode().ljust(CONTENT_ID_LEN, b"\0")

    sign(head)
    with open(args.output, "wb") as f:
        f.write(bytes(head))
    print(f"{args.output}: {len(head)} bytes, content id {content_id}")
    return 0 if verify(bytes(head)) else 1


if __name__ == "__main__":
    sys.exit(main())
