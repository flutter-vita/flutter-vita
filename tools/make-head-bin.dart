// Write the sce_sys/package/head.bin a fresh title id needs to be promoted.
//
//     dart tools/make-head-bin.dart <titleid> -o head.bin
//     dart tools/make-head-bin.dart FVTA00002 --content-id EP9000-FVTA00002_00-...
//     dart tools/make-head-bin.dart --verify head.bin
//
// The promoter will install an extracted .vpk into any directory it is given,
// but it refuses one without a package header. Measured on 2026-08-31, with the
// same package each time:
//
//     no head.bin                          result 0x8010111C
//     head.bin, content id edited by hand  result 0x80871004   (digest checked)
//     head.bin, valid, id not the package's result 0x80870005
//
// so the header is read, its digests are verified, and its content id has to be
// the one being installed. That is the whole of what stands between this port
// and registering title ids of its own.
//
// ## The format
//
// head.bin is a PKG header. Everything in it is boilerplate except the content
// id and three digests, and the offsets of all four are read out of the header
// itself:
//
//     0x30        content id, 48 bytes, "EP9000-<TITLEID>_00-0000000000000000"
//     be32 @0xD0  length of the header region; digest of [0, len) goes at [len]
//     be32 @0x08  offset of the pkg-info region
//     be32 @0x10  its length; digest of [off, off+len-64) goes at be32 @0xD4
//     be32 @0xE8  length of everything; digest of [0, len) goes at [len]
//
// **The digest takes no key.** It is SHA1 of the region, then a fixed
// rearrangement of those 20 bytes into a 64-byte block, then SHA1 of that,
// first 16 bytes. There is no secret here and nothing is being defeated: the
// console computes the same function over the same public bytes.
//
// ## Where the template came from, and why it is not VitaShell's
//
// VitaShell does this too and ships a head.bin as an embedded resource. It is
// GPLv3 and this repo is zlib-licensed, so none of it is here. What is here is
// a header **this console wrote**, lifted from ux0:app/FVTA00002/sce_sys/package
// after an ordinary install, with only the four fields above rewritten. The
// format above was read from VitaShell's source as fact -- offsets and an
// algorithm, not expression -- and implemented from scratch.
//
// The implementation is checked against reality rather than against a
// description: `--verify` recomputes all three digests of a header the
// promoter itself wrote and requires them to match. Both samples taken from
// this console pass. tools/test-vpk.sh also compares this output with the
// bridge's own writer, bridge/src/vpk.c, byte for byte.
//
// Until 2026-10-16 this was tools/make-head-bin.py. It is Dart now so that the
// tools need no Python: Dart comes with the Flutter SDK the tools download.
// Only dart: libraries, so it runs as a plain script without a package config.
import 'dart:io';
import 'dart:typed_data';

const contentIdOff = 0x30;
const contentIdLen = 48;

/// The keyless digest described above. Sixteen bytes.
Uint8List fpkgDigest(List<int> data) {
  final a = sha1(data);
  // The 64-byte block is mostly a repeat of two slices of the first hash.
  // Reproduced exactly because the console checks the result, not because any
  // of it is meaningful.
  final buf = Uint8List(64);
  buf.setRange(0, 8, a, 4);
  buf.setRange(8, 16, a, 4);
  buf.setRange(16, 20, a, 12);
  buf[20] = a[16];
  buf[21] = a[1];
  buf[22] = a[2];
  buf[23] = a[3];
  buf.setRange(24, 32, buf, 16);
  return Uint8List.sublistView(sha1(buf), 0, 16);
}

/// SHA-1 (FIPS 180-4). dart:io has no hash functions, and a package would need
/// a package config; the console checks only this one, over a few KB.
Uint8List sha1(List<int> data) {
  int rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;
  final h = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
  final padded = Uint8List(((data.length + 8) ~/ 64 + 1) * 64)
    ..setRange(0, data.length, data);
  padded[data.length] = 0x80;
  final view = ByteData.sublistView(padded);
  view.setUint32(padded.length - 8, (data.length * 8) >> 32);
  view.setUint32(padded.length - 4, (data.length * 8) & 0xFFFFFFFF);
  final w = Uint32List(80);
  for (var block = 0; block < padded.length; block += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = view.getUint32(block + i * 4);
    }
    for (var i = 16; i < 80; i++) {
      w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }
    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4];
    for (var i = 0; i < 80; i++) {
      final int f, k;
      if (i < 20) {
        f = (b & c) | (~b & d);
        k = 0x5A827999;
      } else if (i < 40) {
        f = b ^ c ^ d;
        k = 0x6ED9EBA1;
      } else if (i < 60) {
        f = (b & c) | (b & d) | (c & d);
        k = 0x8F1BBCDC;
      } else {
        f = b ^ c ^ d;
        k = 0xCA62C1D6;
      }
      final t = (rotl(a, 5) + (f & 0xFFFFFFFF) + e + k + w[i]) & 0xFFFFFFFF;
      e = d;
      d = c;
      c = rotl(b, 30);
      b = a;
      a = t;
    }
    h[0] = (h[0] + a) & 0xFFFFFFFF;
    h[1] = (h[1] + b) & 0xFFFFFFFF;
    h[2] = (h[2] + c) & 0xFFFFFFFF;
    h[3] = (h[3] + d) & 0xFFFFFFFF;
    h[4] = (h[4] + e) & 0xFFFFFFFF;
  }
  final out = ByteData(20);
  for (var i = 0; i < 5; i++) {
    out.setUint32(i * 4, h[i]);
  }
  return out.buffer.asUint8List();
}

int be32(Uint8List buf, int off) => ByteData.sublistView(buf).getUint32(off);

/// The three (start, end, destination offset) triples, from the header.
List<(int, int, int)> regions(Uint8List head) {
  final hdrLen = be32(head, 0xD0);
  final infoOff = be32(head, 0x08), infoLen = be32(head, 0x10);
  final infoOut = be32(head, 0xD4);
  final allLen = be32(head, 0xE8);
  return [
    (0, hdrLen, hdrLen),
    (infoOff, infoOff + infoLen - 64, infoOut),
    (0, allLen, allLen),
  ];
}

void sign(Uint8List head) {
  // In order: each digest covers bytes an earlier one may have written, so
  // they cannot be computed in parallel or reordered.
  for (final (start, end, out) in regions(head)) {
    head.setRange(out, out + 16, fpkgDigest(head.sublist(start, end)));
  }
}

bool verify(Uint8List head) {
  var ok = true;
  var i = 0;
  for (final (start, end, out) in regions(head)) {
    i++;
    final want = head.sublist(out, out + 16);
    final got = fpkgDigest(head.sublist(start, end));
    var good = true;
    for (var j = 0; j < 16; j++) {
      if (want[j] != got[j]) good = false;
    }
    final at = '0x${out.toRadixString(16).padLeft(4, '0')}';
    stdout.writeln('  digest $i at $at  ${good ? 'ok' : 'MISMATCH'}');
    ok &= good;
  }
  return ok;
}

String contentIdOf(Uint8List head) {
  final field = head.sublist(contentIdOff, contentIdOff + contentIdLen);
  final end = field.indexOf(0);
  return String.fromCharCodes(end < 0 ? field : field.sublist(0, end));
}

Never usage(String message) {
  stderr.writeln('usage: make-head-bin.dart <titleid> [-o head.bin] '
      '[--template FILE] [--content-id ID] | --verify HEAD_BIN');
  stderr.writeln('!! $message');
  exit(2);
}

void main(List<String> argv) {
  final here = File.fromUri(Platform.script).parent.path;
  String? titleId, contentId, verifyPath;
  var output = 'head.bin';
  var template = '$here/pkg/head-template.bin';
  for (var i = 0; i < argv.length; i++) {
    String value() => i + 1 < argv.length ? argv[++i] : usage('${argv[i]} needs a value');
    switch (argv[i]) {
      case '-o' || '--output':
        output = value();
      case '--template':
        template = value();
      case '--content-id':
        contentId = value();
      case '--verify':
        verifyPath = value();
      case final a when a.startsWith('-'):
        usage('unknown option $a');
      case final a:
        if (titleId != null) usage('one title id only');
        titleId = a;
    }
  }

  if (verifyPath != null) {
    final head = File(verifyPath).readAsBytesSync();
    stdout.writeln('$verifyPath: ${head.length} bytes, content id ${contentIdOf(head)}');
    exit(verify(head) ? 0 : 1);
  }

  if (titleId == null) usage('a title id is required unless --verify is given');
  // Nine characters, upper case. The promoter is not forgiving about this and
  // neither is the shell, and a lower-case id fails somewhere much later.
  if (titleId.length != 9 || titleId != titleId.toUpperCase()) {
    stderr.writeln("!! title id must be 9 upper-case characters: '$titleId'");
    exit(2);
  }

  final head = File(template).readAsBytesSync();
  final id = contentId ?? 'EP9000-${titleId}_00-0000000000000000';
  if (id.length >= contentIdLen) {
    stderr.writeln("!! content id too long: '$id'");
    exit(2);
  }
  head.fillRange(contentIdOff, contentIdOff + contentIdLen, 0);
  head.setRange(contentIdOff, contentIdOff + id.length, id.codeUnits);

  sign(head);
  File(output).writeAsBytesSync(head);
  stdout.writeln('$output: ${head.length} bytes, content id $id');
  exit(verify(head) ? 0 : 1);
}
