import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// The Vita implementation of [SharedPreferencesStorePlatform].
///
/// **Non-endorsed**, per [ADR-0009]: depend on it alongside
/// `shared_preferences` and call `SharedPreferencesVita.registerWith()`.
///
/// A JSON file under the app's own writable directory. That is the whole
/// implementation, and it is the right one — every other platform's store is
/// also a key-value blob on disk, and the filesystem this sits on was verified
/// on hardware before this package was written.
///
/// Implements the legacy [SharedPreferencesStorePlatform] rather than the newer
/// async interface, because `SharedPreferences.getInstance()` still routes
/// through the legacy one and that is what apps in the wild actually call.
class SharedPreferencesVita extends SharedPreferencesStorePlatform {
  static void registerWith() {
    SharedPreferencesStorePlatform.instance = SharedPreferencesVita();
  }

  static const String _fileName = 'shared_preferences.json';

  Map<String, Object>? _cache;
  File? _file;

  /// The same folder as path_provider_vita's `getApplicationSupportPath`:
  /// `ux0:data/<TITLEID>/support`. Computed here, not imported, so an app can
  /// take both plugins from git: pub refuses a plugin that one package
  /// requests by tag and another by relative path.
  Future<File> _storeFile() async {
    if (_file != null) return _file!;
    final temp = Directory.systemTemp.path; // ux0:data/<TITLEID>/tmp
    final slash = temp.lastIndexOf('/');
    final root = slash > 0 ? temp.substring(0, slash) : 'ux0:data/FLUTTER';
    final support = Directory('$root/support');
    if (!support.existsSync()) await support.create(recursive: true);
    return _file = File('${support.path}/$_fileName');
  }

  /// Read once, then serve from memory.
  ///
  /// Not an optimisation so much as a correctness choice: reads here go to a
  /// memory card, and `SharedPreferences` calls `getAll` on a path that apps
  /// treat as free. Writes flush immediately, so the cache never outlives the
  /// file's truth.
  Future<Map<String, Object>> _load() async {
    if (_cache != null) return _cache!;
    final file = await _storeFile();
    if (!file.existsSync()) return _cache = <String, Object>{};
    try {
      final decoded = jsonDecode(await file.readAsString());
      _cache = (decoded as Map).cast<String, Object>();
    } on Object {
      // A corrupt store is not worth taking the app down for, and the
      // alternative -- throwing out of getInstance() -- is a crash on launch
      // with no way for the user to clear it. Start empty and overwrite.
      _cache = <String, Object>{};
    }
    return _cache!;
  }

  Future<bool> _flush() async {
    try {
      final file = await _storeFile();
      await file.writeAsString(jsonEncode(_cache), flush: true);
      return true;
    } on Object {
      return false;
    }
  }

  @override
  Future<Map<String, Object>> getAll() => _load();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    final store = await _load();
    // StringList arrives as List<String> and survives a JSON round trip as
    // List<dynamic>, so it is normalised on the way in rather than leaving a
    // cast error for whoever reads it back after a restart.
    store[key] = valueType == 'StringList'
        ? (value as List).map((e) => e.toString()).toList()
        : value;
    return _flush();
  }

  @override
  Future<bool> remove(String key) async {
    final store = await _load();
    store.remove(key);
    return _flush();
  }

  @override
  Future<bool> clear() async {
    _cache = <String, Object>{};
    return _flush();
  }
}
