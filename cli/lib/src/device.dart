import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// A Vita on the network, and the two things that can be listening on it.
///
/// The bridge (port 1341) installs and launches; the app (port 1339) serves
/// logs, screenshots and synthetic input while it runs. Only one is up at a
/// time, because launching the app replaces the bridge and `handoff` puts it
/// back.
enum VitaRole {
  bridge(1341, 'bridge'),
  app(1339, 'app');

  const VitaRole(this.port, this.label);
  final int port;
  final String label;
}

/// The name the console announces over mDNS (the dev server's responder).
/// Every command tries it before sweeping the subnet.
const kVitaHostName = 'fluttervita.local';

class VitaDevice {
  VitaDevice(this.host, this.role);

  final String host;
  final VitaRole role;

  @override
  String toString() => '$host:${role.port} (${role.label})';

  /// The address to connect to. A `.local` name is resolved for IPv4 only:
  /// asking for both families makes macOS wait about five seconds for an
  /// AAAA answer the console never sends, on every connection.
  static Future<InternetAddress> resolve(
    String host, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return literal;
    final found = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    ).timeout(timeout);
    if (found.isEmpty) throw SocketException('no address for $host');
    return found.first;
  }

  Future<Socket> _connect({Duration? timeout}) async {
    final address = await resolve(host);
    return Socket.connect(address, role.port, timeout: timeout);
  }

  /// Send one command and read until the far end closes.
  ///
  /// The protocol has no framing: several commands reply and stay open, while
  /// `log`, `get` and `shot` close the connection to signal the end of their
  /// payload. Reading to EOF is what works for both, so every call here is one
  /// connection.
  Future<Uint8List> _send(
    String command, {
    List<int>? payload,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final socket = await _connect(timeout: timeout);
    try {
      socket.add('$command\n'.codeUnits);
      if (payload != null) {
        socket.add(payload);
      }
      await socket.flush();

      final builder = BytesBuilder(copy: false);
      await socket.forEach(builder.add).timeout(timeout);
      return builder.takeBytes();
    } finally {
      socket.destroy();
    }
  }

  Future<String> _sendText(String command, {Duration? timeout}) async {
    final bytes = await _send(
      command,
      timeout: timeout ?? const Duration(seconds: 30),
    );
    return String.fromCharCodes(bytes);
  }

  Future<String> log() => _sendText('log', timeout: const Duration(minutes: 2));

  Future<String> shotInfo() => _sendText('shotinfo');

  /// The framebuffer as the display controller holds it, 960x544 RGBA.
  ///
  /// Deliberately paired with [shotInfo] by callers: the pixels alone prove
  /// only what is in memory, and the descriptor says whether the hardware is
  /// scanning that buffer.
  Future<Uint8List> screenshot() =>
      _send('shot', timeout: const Duration(minutes: 3));

  Future<String> tap(int x, int y) => _sendText('tap $x $y');

  /// The first chunk of the reply, for a command that answers one line and
  /// keeps the connection open (`stat`, `exist`): reading to EOF would wait
  /// for the whole timeout.
  Future<String> ask(String command,
      {Duration timeout = const Duration(seconds: 4)}) async {
    final socket = await _connect(timeout: timeout);
    try {
      socket.add('$command\n'.codeUnits);
      await socket.flush();
      return String.fromCharCodes(await socket.first.timeout(timeout));
    } finally {
      socket.destroy();
    }
  }

  /// Exit the app and bring the bridge back up.
  ///
  /// The bridge can take longer than the reply to appear, so callers wait for
  /// [VitaRole.bridge] to answer rather than trusting this returning.
  Future<String> handoff() => _sendText('handoff');

  Future<String> launch() => _sendText('launch');

  Future<void> put(String devicePath, List<int> bytes) async {
    final reply = await _sendText(
      'put ${bytes.length} $devicePath',
      timeout: const Duration(minutes: 3),
    );
    if (!reply.contains('OK')) {
      throw VitaException('put $devicePath failed: ${reply.trim()}');
    }
  }

  Future<void> stage(List<int> eboot) async {
    final socket = await _connect();
    try {
      socket.add('stage ${eboot.length}\n'.codeUnits);
      socket.add(eboot);
      await socket.flush();
      final builder = BytesBuilder(copy: false);
      await socket
          .forEach(builder.add)
          .timeout(const Duration(minutes: 5));
      final reply = String.fromCharCodes(builder.takeBytes());
      if (!reply.contains('OK')) {
        throw VitaException('stage failed: ${reply.trim()}');
      }
    } finally {
      socket.destroy();
    }
  }

  Future<void> install() async {
    final reply = await _sendText('install', timeout: const Duration(minutes: 2));
    if (!reply.contains('OK')) {
      throw VitaException('install failed: ${reply.trim()}');
    }
  }

  /// Poll until a device answers in [role], or give up.
  ///
  /// Used after launch and handoff, both of which take seconds to tens of
  /// seconds depending on what the system is doing. Measured on hardware: a
  /// handoff has answered in 4 seconds and has also taken over a minute.
  static Future<VitaDevice?> waitFor(
    String host,
    VitaRole role, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final device = await probe(host, role);
      if (device != null) {
        return device;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return null;
  }

  /// Is something answering as [role] on this host?
  static Future<VitaDevice?> probe(
    String host,
    VitaRole role, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    Socket? socket;
    try {
      socket = await VitaDevice(host, role)._connect(timeout: timeout);
      socket.add('ping\n'.codeUnits);
      await socket.flush();

      // First chunk, not read-to-EOF. `ping` is one of the commands that keeps
      // the connection open for another, so waiting for EOF would stall every
      // probe until its timeout and turn a sweep into minutes.
      final reply = String.fromCharCodes(await socket.first.timeout(timeout));

      // The bridge answers "pong bridge" and the app answers "pong". Checking
      // the reply rather than just the open port matters: something else on
      // the network could hold 1339, and installing into it would be worse
      // than finding nothing.
      final ok = role == VitaRole.bridge
          ? reply.contains('bridge')
          : reply.contains('pong');
      return ok ? VitaDevice(host, role) : null;
    } on Exception {
      return null;
    } finally {
      socket?.destroy();
    }
  }
}

class VitaException implements Exception {
  VitaException(this.message);
  final String message;
  @override
  String toString() => message;
}
