// A psp2dmp reader, in Dart, on the console that produced the file.
//
// The Vita writes ux0:data/psp2core-<time>-<title>.psp2dmp whenever a process
// faults. Reading one has meant pulling it over the network and running
// vita-parse-core against the matching ELF (tools/analyse-crash.sh), which
// works and is the only way to get line numbers -- but it needs the host, the
// ELF, and a Python venv, and none of those exist at the moment you are
// holding a console that just died.
//
// This reads the part that needs none of them. A psp2dmp is an ELF32 core:
// PT_NOTE segments carry MODULE_INFO, THREAD_INFO and THREAD_REG_INFO, and
// those three answer the question you actually have first -- which thread
// stopped, why, and in which module. Symbolication stays on the host, where
// the ELF is.
//
// Field offsets follow vita-parse-core (github.com/xyzz/vita-parse-core,
// MIT); they are the console's own structures and are not documented anywhere
// else.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A loaded module and the address ranges it occupies.
class CoreModule {
  CoreModule(this.uid, this.name, this.segments);

  final int uid;
  final String name;
  final List<CoreSegment> segments;
}

class CoreSegment {
  CoreSegment(this.index, this.attr, this.start, this.size);

  final int index;
  final int attr;
  final int start;
  final int size;

  bool contains(int addr) => addr >= start && addr < start + size;

  /// 5 is RX, 6 is RW; the low nibble is what carries it.
  String get kind => switch (attr & 0xF) {
    5 => 'RX',
    6 => 'RW',
    _ => '',
  };
}

class CoreThread {
  CoreThread(this.uid, this.name, this.status, this.stopReason, this.pc);

  final int uid;
  final String name;
  final int status;
  final int stopReason;
  final int pc;

  /// Filled from THREAD_REG_INFO, which is a separate note keyed by thread id.
  List<int> gpr = const [];

  int get lr => gpr.length > 14 ? gpr[14] : 0;
  int get sp => gpr.length > 13 ? gpr[13] : 0;

  bool get faulted => stopReason != 0;

  String get statusText => switch (status) {
    1 => 'running',
    8 => 'waiting',
    16 => 'not started',
    _ => '0x${status.toRadixString(16)}',
  };

  String get reasonText => switch (stopReason) {
    0 => 'no reason',
    0x30002 => 'undefined instruction',
    0x30003 => 'prefetch abort',
    0x30004 => 'data abort',
    0x60080 => 'division by zero',
    _ => '0x${stopReason.toRadixString(16)}',
  };
}

class CoreDump {
  CoreDump(this.modules, this.threads);

  final List<CoreModule> modules;
  final List<CoreThread> threads;

  /// The thread the console stopped on, or null if nothing is marked.
  CoreThread? get culprit {
    for (final t in threads) {
      if (t.faulted) return t;
    }
    return null;
  }

  /// `module@segment + 0xoffset`, or an empty string when the address is in no
  /// mapped segment -- which is itself the answer sometimes, because a jump
  /// through a null pointer lands nowhere.
  String locate(int addr) {
    final a = addr & ~1; // Thumb addresses carry the mode in bit 0.
    for (final m in modules) {
      for (final s in m.segments) {
        if (s.contains(a)) {
          final off = a - s.start;
          return '${m.name}@${s.index} + 0x${off.toRadixString(16)}';
        }
      }
    }
    return '';
  }
}

String _hex8(int v) =>
    '0x${v.toUnsigned(32).toRadixString(16).padLeft(8, '0')}';

/// `0x...` with eight digits, for anything printed beside a register name.
String hex8(int v) => _hex8(v);

String _cstr(Uint8List d, int off) {
  var end = off;
  while (end < d.length && d[end] != 0) {
    end++;
  }
  return const AsciiDecoder(allowInvalid: true).convert(d, off, end);
}

/// Throws [FormatException] on anything that is not a psp2dmp.
CoreDump parseCore(Uint8List raw) {
  var data = raw;
  // Gzipped when the console felt like it; both forms turn up in ux0:data.
  if (data.length > 2 && data[0] == 0x1F && data[1] == 0x8B) {
    data = Uint8List.fromList(gzip.decode(data));
  }
  if (data.length < 52 ||
      data[0] != 0x7F ||
      data[1] != 0x45 ||
      data[2] != 0x4C ||
      data[3] != 0x46) {
    throw const FormatException('not an ELF core');
  }

  final b = ByteData.sublistView(data);
  int u32(int o) => b.getUint32(o, Endian.little);
  int u16(int o) => b.getUint16(o, Endian.little);

  final notes = <String, Uint8List>{};
  final phoff = u32(28), phentsize = u16(42), phnum = u16(44);
  for (var i = 0; i < phnum; i++) {
    final o = phoff + i * phentsize;
    if (o + 32 > data.length) break;
    if (u32(o) != 4) continue; // PT_NOTE
    var p = u32(o + 4);
    final end = p + u32(o + 16);
    while (p + 12 <= end && p + 12 <= data.length) {
      final namesz = u32(p), descsz = u32(p + 4);
      p += 12;
      final name = _cstr(data, p);
      p += (namesz + 3) & ~3;
      if (p + descsz > data.length) break;
      notes[name] = Uint8List.sublistView(data, p, p + descsz);
      p += (descsz + 3) & ~3;
    }
  }

  final modules = <CoreModule>[];
  final mi = notes['MODULE_INFO'];
  if (mi != null && mi.length >= 8) {
    final m = ByteData.sublistView(mi);
    final count = m.getUint32(4, Endian.little);
    var off = 8;
    for (var i = 0; i < count && off + 0x50 <= mi.length; i++) {
      final uid = m.getUint32(off + 4, Endian.little);
      final numSegs = m.getUint32(off + 0x4C, Endian.little);
      final name = _cstr(mi, off + 0x24);
      off += 0x50;
      final segs = <CoreSegment>[];
      for (var s = 0; s < numSegs && off + 0x14 <= mi.length; s++) {
        segs.add(
          CoreSegment(
            s + 1,
            m.getUint32(off + 4, Endian.little),
            m.getUint32(off + 8, Endian.little),
            m.getUint32(off + 12, Endian.little),
          ),
        );
        off += 0x14;
      }
      off += 0x10; // ARM exception table bounds; nothing here reads them.
      modules.add(CoreModule(uid, name, segs));
    }
  }

  final threads = <CoreThread>[];
  final byUid = <int, CoreThread>{};
  final ti = notes['THREAD_INFO'];
  if (ti != null && ti.length >= 8) {
    final t = ByteData.sublistView(ti);
    final count = t.getUint32(4, Endian.little);
    var off = 8;
    for (var i = 0; i < count && off + 0xA0 <= ti.length; i++) {
      final size = t.getUint32(off, Endian.little);
      if (size < 0xA0) break;
      final thread = CoreThread(
        t.getUint32(off + 4, Endian.little),
        _cstr(ti, off + 8),
        t.getUint16(off + 0x30, Endian.little),
        t.getUint32(off + 0x74, Endian.little),
        t.getUint32(off + 0x9C, Endian.little),
      );
      threads.add(thread);
      byUid[thread.uid] = thread;
      off += size;
    }
  }

  final ri = notes['THREAD_REG_INFO'];
  if (ri != null && ri.length >= 8) {
    final r = ByteData.sublistView(ri);
    final count = r.getUint32(4, Endian.little);
    var off = 8;
    for (var i = 0; i < count && off + 8 <= ri.length; i++) {
      final size = r.getUint32(off, Endian.little);
      if (size < 8 + 16 * 4) break;
      final tid = r.getUint32(off + 4, Endian.little);
      byUid[tid]?.gpr = [
        for (var g = 0; g < 16; g++)
          r.getUint32(off + 8 + 4 * g, Endian.little),
      ];
      off += size;
    }
  }

  // The faulted thread first: it is the only one anybody opened the file for.
  threads.sort((a, b) {
    if (a.faulted != b.faulted) return a.faulted ? -1 : 1;
    return a.uid.compareTo(b.uid);
  });

  return CoreDump(modules, threads);
}
