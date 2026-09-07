// Everything the panel reads off the memory card, and the one thing it writes.
//
// ADR-0016 decision 3 keeps the reliability-critical half free of a platform
// channel: the C layer republishes a state file and this side polls it. That
// decision is about the *channel*, not about the filesystem -- ux0:data is
// readable from Dart directly, so the log archive, the crash dumps and the
// install registry are read here rather than pushed through C.
//
// Deleting a title is the exception. It needs ScePromoterUtil, which needs PAF
// resident and a state machine that already lives in C, so the panel asks for
// it by writing one line the watcher picks up. A request that arrives while
// Flutter is dead simply never arrives, which is the correct behaviour.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const dataDir = 'ux0:data/flutter-vita';
const statePath = '$dataDir/receiver-state.txt';
const requestPath = '$dataDir/receiver-request.txt';
const panelRequestPath = '$dataDir/panel-request.txt';
const logDir = '$dataDir/logs';
const appLogPath = '$dataDir/app.log';
const deployLogPath = '$dataDir/deploy.log';
const receiverLogPath = '$dataDir/m3.log';
const installedPath = '$dataDir/installed.txt';
const dumpDir = 'ux0:data';

/// What the mDNS responder has actually done, from the file it writes.
///
/// The panel showed WAITING through every unreachable stretch of 2026-09-01
/// and it was telling the truth: the console had an address and the socket was
/// listening. What it had no way to say was that nothing could look the name
/// up. These four numbers are what the responder knows, so this is where the
/// panel gets to stop guessing.
class MdnsStatus {
  const MdnsStatus({
    required this.joined,
    required this.announced,
    required this.queries,
    required this.lastQueryAge,
  });

  /// Whether the console joined 224.0.0.251. False means queries cannot reach
  /// us at all.
  final bool joined;

  /// A records sent unasked. Zero means the name is not being published, and
  /// no host will resolve it.
  final int announced;

  /// Queries answered. Zero is not alarming on its own -- measured on
  /// 2026-09-01, this console has never received one, and the name resolves
  /// entirely off the announcements.
  final int queries;

  /// Seconds since the last query, or -1 if there has never been one.
  final int lastQueryAge;

  static const unknown =
      MdnsStatus(joined: false, announced: -1, queries: 0, lastQueryAge: -1);

  /// True when the file was there and says the name is being published.
  bool get publishing => announced > 0;

  /// Never throws. A missing or half-written file is "we cannot tell", which
  /// the panel renders differently from "it is broken".
  static MdnsStatus read() {
    try {
      final f = File('$dataDir/mdns.txt');
      if (!f.existsSync()) return unknown;
      var joined = false;
      var announced = -1, queries = 0, last = -1;
      for (final line in f.readAsLinesSync()) {
        final parts = line.trim().split(' ');
        if (parts.length != 2) continue;
        final v = int.tryParse(parts[1]) ?? 0;
        switch (parts[0]) {
          case 'joined':
            joined = v != 0;
          case 'announced':
            announced = v;
          case 'queries':
            queries = v;
          case 'last':
            last = v;
        }
      }
      return MdnsStatus(
          joined: joined,
          announced: announced,
          queries: queries,
          lastQueryAge: last);
    } catch (_) {
      return unknown;
    }
  }
}

/// Everything the C layer publishes, as one immutable snapshot.
class ReceiverState {
  const ReceiverState({
    this.seq = 0,
    this.ip = '',
    this.port = 0,
    this.status = 'Starting',
    this.detail = '',
    this.self = '',
    this.recvDone = 0,
    this.recvTotal = 0,
    this.lastCmdAge = -1,
    this.log = const [],
  });

  final int seq;
  final String ip;
  final int port;
  final String status;
  final String detail;
  final String self;
  final int recvDone;
  final int recvTotal;

  /// Seconds since a host last sent a command, or -1 if none ever has.
  final int lastCmdAge;

  final List<String> log;

  bool get receiving => recvTotal > 0;

  /// `key value` per line, oldest log line first. Deliberately not JSON: the
  /// writer is 300 lines of C with no allocator to spare, and every field
  /// here is a single token or the rest of the line.
  static ReceiverState parse(String text) {
    var seq = 0, port = 0, done = 0, total = 0, lastCmd = -1;
    var ip = '', status = 'Starting', detail = '', self = '';
    final log = <String>[];
    for (final line in text.split('\n')) {
      final space = line.indexOf(' ');
      if (space < 0) continue;
      final key = line.substring(0, space);
      final value = line.substring(space + 1);
      switch (key) {
        case 'seq':
          seq = int.tryParse(value) ?? 0;
        case 'ip':
          ip = value == '-' ? '' : value;
        case 'port':
          port = int.tryParse(value) ?? 0;
        case 'status':
          status = value;
        case 'detail':
          detail = value;
        case 'self':
          self = value;
        case 'recv':
          final parts = value.split(' ');
          if (parts.length == 2) {
            done = int.tryParse(parts[0]) ?? 0;
            total = int.tryParse(parts[1]) ?? 0;
          }
        case 'lastcmd':
          lastCmd = int.tryParse(value) ?? -1;
        case 'log':
          log.add(value);
      }
    }
    return ReceiverState(
      seq: seq,
      ip: ip,
      port: port,
      status: status,
      detail: detail,
      self: self,
      recvDone: done,
      recvTotal: total,
      lastCmdAge: lastCmd,
      log: log,
    );
  }

  static ReceiverState? read() {
    try {
      final file = File(statePath);
      if (!file.existsSync()) return null;
      return parse(file.readAsStringSync());
    } on FileSystemException {
      // The writer renames into place, so a read can lose the race exactly
      // once per publish. Next tick.
      return null;
    }
  }
}

/// The DEPLOY console's history, newest last.
///
/// `launch` ends the receiver's process, so the C side's in-memory ring is empty
/// at every boot and the console showed nothing about the deploy that just
/// happened -- which is the one you go looking for. receiver_dev.c appends every
/// note to a file instead.
///
/// Read from the end. The file is capped at 64 KB and this only ever wants the
/// last screenful, so seeking beats reading the whole thing on a memory card,
/// and the first partial line after the seek is dropped.
List<String> readDeployLog({int lines = 200, int window = 16 * 1024}) {
  try {
    final file = File(deployLogPath);
    if (!file.existsSync()) return const [];
    final length = file.lengthSync();
    if (length == 0) return const [];
    final start = length > window ? length - window : 0;
    final handle = file.openSync();
    String text;
    try {
      handle.setPositionSync(start);
      text = const Utf8Decoder(allowMalformed: true)
          .convert(handle.readSync(length - start));
    } finally {
      handle.closeSync();
    }
    if (start > 0) {
      final nl = text.indexOf('\n');
      if (nl >= 0) text = text.substring(nl + 1);
    }
    final all = text.split('\n')..removeWhere((l) => l.trim().isEmpty);
    return all.length <= lines ? all : all.sublist(all.length - lines);
  } on FileSystemException {
    return const [];
  }
}

/// Forget the deploy history. The C side holds no handle open -- it appends
/// and closes per line -- so removing the file underneath it is safe, and the
/// next note recreates it.
void clearDeployLog() {
  for (final path in [deployLogPath, '$deployLogPath.1']) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } on FileSystemException {
      // Gone, or held. Either way there is nothing useful to do about it.
    }
  }
}

/// One file in the log archive, or one of the two live logs.
class LogFile {
  LogFile(this.path, this.label, this.size, {this.live = false});

  final String path;
  final String label;
  final int size;

  /// Live logs are being written right now, so they are never deleted by the
  /// clear button and never rotated out from under a reader.
  final bool live;

  String read({int tail = 200}) {
    try {
      final lines = File(path).readAsLinesSync();
      if (lines.length <= tail) return lines.join('\n');
      return lines.sublist(lines.length - tail).join('\n');
    } on FileSystemException catch (e) {
      return 'could not read: ${e.osError?.message ?? e.message}';
    }
  }
}

/// Newest first. The archive is numbered, not dated, because this console's
/// clock is whatever it was last set to; the index only has to increase.
List<LogFile> listLogs() {
  final out = <LogFile>[];
  void live(String path, String label) {
    final f = File(path);
    if (f.existsSync()) {
      out.add(LogFile(path, label, f.lengthSync(), live: true));
    }
  }

  live(appLogPath, 'app (live)');
  live(receiverLogPath, 'receiver (live)');

  final dir = Directory(logDir);
  if (dir.existsSync()) {
    final archived = <LogFile>[];
    for (final e in dir.listSync()) {
      if (e is! File || !e.path.endsWith('.log')) continue;
      final name = e.path.split('/').last;
      archived.add(LogFile(e.path, name.substring(0, name.length - 4),
          e.lengthSync()));
    }
    archived.sort((a, b) => b.label.compareTo(a.label));
    out.addAll(archived);
  }
  return out;
}

/// Removes the archive. The two live logs stay: one is open for writing by
/// this very process, and removing a file the engine holds is a way to find
/// out what the console does with a dangling handle.
int clearLogs() {
  var removed = 0;
  final dir = Directory(logDir);
  if (dir.existsSync()) {
    for (final e in dir.listSync()) {
      if (e is File && e.path.endsWith('.log')) {
        try {
          e.deleteSync();
          removed++;
        } on FileSystemException {
          // Held open, or gone between the listing and here. Skip it.
        }
      }
    }
  }
  return removed;
}

/// One psp2dmp in ux0:data.
class CrashFile {
  CrashFile(this.path, this.name, this.size, this.stamp);

  final String path;
  final String name;
  final int size;

  /// Seconds since the epoch, out of the filename. The console's clock may be
  /// wrong but it is monotonic enough to sort by.
  final int stamp;

  /// When it happened, by this console's clock.
  ///
  /// The rest of the filename is `<pid>-eboot.bin`, which names every dump on
  /// the card identically and was what this row showed first. The clock can be
  /// wrong -- it is whatever the console was last set to -- but a wrong date
  /// still distinguishes one crash from another, and a repeated hex address
  /// does not.
  String get subject {
    if (stamp <= 0) return name;
    final t = DateTime.fromMillisecondsSinceEpoch(stamp * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}  '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Uint8List readBytes() => File(path).readAsBytesSync();
}

List<CrashFile> listCrashes() {
  final out = <CrashFile>[];
  final dir = Directory(dumpDir);
  if (!dir.existsSync()) return out;
  for (final e in dir.listSync(followLinks: false)) {
    if (e is! File || !e.path.endsWith('.psp2dmp')) continue;
    final name = e.path.split('/').last;
    final parts = name.split('-');
    final stamp = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
    try {
      out.add(CrashFile(e.path, name, e.lengthSync(), stamp));
    } on FileSystemException {
      continue;
    }
  }
  out.sort((a, b) => b.stamp.compareTo(a.stamp));
  return out;
}

bool deleteCrash(CrashFile crash) {
  try {
    File(crash.path).deleteSync();
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Every psp2dmp in ux0:data, one at a time, yielding between each.
///
/// Nothing on this console removes these, so they accumulate -- there were 53
/// the day this was written, a few hundred megabytes of dumps of crashes that
/// were debugged weeks ago.
///
/// The first version was a plain loop of deleteSync. It ran on the UI thread,
/// which on this platform is also the thread that builds frames and dispatches
/// touches, so the panel stopped painting and stopped answering for as long as
/// the card took to unlink fifty files -- indistinguishable from a hang, and
/// reported as one. The await hands the event loop back after every file, so
/// frames keep going out and `onProgress` has something to draw.
Future<int> clearCrashes(void Function(int done, int total) onProgress) async {
  final files = listCrashes();
  var removed = 0;
  for (final c in files) {
    if (deleteCrash(c)) removed++;
    onProgress(removed, files.length);
    await Future<void>.delayed(Duration.zero);
  }
  return removed;
}

/// A title this receiver installed, and how much of ux0:data it is holding.
class InstalledApp {
  InstalledApp(this.titleId, this.cacheBytes,
      {required this.present, required this.name});

  final String titleId;
  final int cacheBytes;

  /// What the LiveArea calls it, from the title's own param.sfo, or the title
  /// id again when there is nothing to read.
  ///
  /// Six rows reading FVTA0000n tell you nothing about which is the gallery
  /// and which is localsend, and the id is the part you never chose.
  final String name;

  /// Whether ux0:app/<id> is actually there.
  ///
  /// installed.txt is a list of what this receiver has installed, not a list of
  /// what is installed. A title deleted any other way stays in it, and a RUN
  /// button on that row hands the console to a title that does not exist --
  /// sceAppMgrLaunchAppByUri fails quietly and the receiver has already exited,
  /// so you end up on the LiveArea home screen. That is how FVTA00004 stranded
  /// this console twice on 2026-08-31.
  final bool present;
}

/// The receiver is left out. It installed itself and the registry records that,
/// but a row you cannot delete, cannot run because you are already in it, and
/// whose data directory is the one holding the list, is a row that only takes
/// up space.
List<InstalledApp> listInstalled(String self) {
  final file = File(installedPath);
  if (!file.existsSync()) return const [];
  final seen = <String>{};
  final out = <InstalledApp>[];
  for (final raw in file.readAsLinesSync()) {
    final id = raw.trim();
    if (id.isEmpty || id == self || !seen.add(id)) continue;
    out.add(InstalledApp(id, _dirBytes('ux0:data/$id'),
        present: Directory('ux0:app/$id').existsSync(),
        name: appTitle(id) ?? id));
  }
  // By what the row shows. A list ordered by a column that is no longer first
  // looks unordered.
  out.sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.titleId.compareTo(b.titleId);
  });
  return out;
}

/// The TITLE field out of `ux0:app/<id>/sce_sys/param.sfo`, or null.
///
/// SFO is a small binary table: a header giving where the key and data tables
/// start and how many entries there are, then fixed 16-byte index entries. No
/// parser ships with the SDK and the format is four fields wide, so it is read
/// here rather than shelled out to.
///
/// Every failure returns null. This runs on files written by other people's
/// installers, and the receiver must not be the thing that cannot start because
/// one of them is malformed.
String? appTitle(String titleId) {
  try {
    final f = File('ux0:app/$titleId/sce_sys/param.sfo');
    if (!f.existsSync()) return null;
    final b = f.readAsBytesSync();
    if (b.length < 20) return null;
    final d = ByteData.sublistView(b);
    if (d.getUint32(0, Endian.little) != 0x46535000) return null;  // "\0PSF"
    final keyTable = d.getUint32(8, Endian.little);
    final dataTable = d.getUint32(12, Endian.little);
    final count = d.getUint32(16, Endian.little);
    if (count > 1024) return null;
    for (var i = 0; i < count; i++) {
      final at = 20 + i * 16;
      if (at + 16 > b.length) return null;
      final keyAt = keyTable + d.getUint16(at, Endian.little);
      final len = d.getUint32(at + 4, Endian.little);
      final dataAt = dataTable + d.getUint32(at + 12, Endian.little);
      if (keyAt >= b.length || dataAt + len > b.length) continue;
      var end = keyAt;
      while (end < b.length && b[end] != 0) end++;
      if (String.fromCharCodes(b, keyAt, end) != 'TITLE') continue;
      var stop = dataAt;
      final limit = dataAt + len;
      while (stop < limit && b[stop] != 0) stop++;
      final title = utf8.decode(b.sublist(dataAt, stop), allowMalformed: true)
          .trim();
      return title.isEmpty ? null : title;
    }
    return null;
  } catch (_) {
    return null;
  }
}

int _dirBytes(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) return 0;
  var total = 0;
  try {
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is File) total += e.lengthSync();
    }
  } on FileSystemException {
    return total;
  }
  return total;
}

/// Removes ux0:data/<titleid>, and nothing else.
///
/// Not savedata (ux0:user/00/savedata), not the install itself. An app's cache
/// is the thing you clear to make it start from scratch; a save is the thing
/// you clear when you meant to and there is no undo on this device.
bool clearAppCache(String titleId) {
  final dir = Directory('ux0:data/$titleId');
  if (!dir.existsSync()) return true;
  try {
    dir.deleteSync(recursive: true);
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Drop a title id from the registry, without touching the title.
///
/// For rows whose ux0:app directory is gone: there is nothing to delete and
/// nothing to run, and the only useful thing left to do with the row is stop
/// showing it. Rewritten rather than edited in place, for the same reason the
/// C side rewrites it -- a handful of nine-byte lines cannot be left half
/// consistent by a rewrite, and can by a seek and a blank-out.
void forgetInstalled(String titleId) {
  final file = File(installedPath);
  if (!file.existsSync()) return;
  final kept = file
      .readAsLinesSync()
      .where((l) => l.trim().isNotEmpty && l.trim() != titleId)
      .toList();
  file.writeAsStringSync(kept.isEmpty ? '' : '${kept.join('\n')}\n',
      flush: true);
}

/// One line the C watcher picks up within two seconds and then removes.
void requestDelete(String titleId) => _request('delete $titleId');

/// Hand the console to another title. Ends this process, so nothing after it
/// on the Dart side runs.
void requestLaunch(String titleId) => _request('launch $titleId');

void _request(String line) {
  File(requestPath).writeAsStringSync('$line\n', flush: true);
}

String humanBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}


/// A command for the panel itself, read and consumed on the poll tick.
///
/// The panel is a screen you press, and the one thing that cannot press it is
/// the machine building it. `tap` exists in the dev server but not in minimal
/// mode, and minimal mode's allowlist is compiled into the pinned engine
/// (ADR-0016 decision 2), so reaching the CRASHES tab from the host would mean
/// re-pinning an engine to debug a layout.
///
/// This is the same trick as receiver-request.txt pointed at the other half:
/// `put` one line onto the card, the panel picks it up within 500 ms and
/// removes it. Shipped rather than kept behind a debug flag, because the
/// person who needs to see this screen is usually not holding the console.
///
///   printf 'put 12 ux0:data/flutter-vita/panel-request.txt\ntab crashes\n' | nc ...
///
/// Verbs: `tab <deploy|logs|crashes|apps>`, `select <index>`, `back`, and
/// `action <name>` for a button.
///
/// `action` exists because the buttons on this panel are the parts most worth
/// testing and the parts I cannot reach: DELETE ALL froze the console for as
/// long as the card took to unlink fifty dumps, and the only ways to check the
/// fix were to hand the console to someone or to run different code than the
/// button runs. Each tab decides what its names mean.
class PanelCommand {
  const PanelCommand(this.seq, this.verb, this.arg);

  final int seq;
  final String verb;
  final String arg;

  int get index => int.tryParse(arg) ?? -1;
}

PanelCommand? readPanelRequest(int seq) {
  try {
    final file = File(panelRequestPath);
    if (!file.existsSync()) return null;
    final text = file.readAsStringSync().trim();
    file.deleteSync();
    if (text.isEmpty) return null;
    final space = text.indexOf(' ');
    if (space < 0) return PanelCommand(seq, text, '');
    return PanelCommand(
        seq, text.substring(0, space), text.substring(space + 1).trim());
  } on FileSystemException {
    return null;
  }
}
