import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// The Vita implementation of [PathProviderPlatform].
///
/// **Non-endorsed**, per [ADR-0009]: `path_provider` does not know Vita exists,
/// so an app depends on this package alongside it and calls
/// `PathProviderVita.registerWith()`. That is the mechanism Flutter provides
/// for a platform the plugin author has never heard of, and it is what Samsung
/// ships for Tizen — `camera_tizen` asks for exactly the same two lines.
///
/// Pure Dart. There is no native code and no plugin registration, because the
/// paths below are constants and a `mkdir`, and `dart:io` on this port already
/// does the rest — verified on hardware by the conformance app, which passes
/// read, stat, mkdir, write, append, list, rename and delete.
class PathProviderVita extends PathProviderPlatform {
  static void registerWith() {
    PathProviderPlatform.instance = PathProviderVita();
  }

  /// The read-only mount of the running title's own install directory. This is
  /// where `flutter_assets` lives, and nothing may be written to it.
  static const String appRoot = 'app0:';

  /// Per-app writable storage.
  ///
  /// Keyed on the title id so two flutter-vita apps never share a directory.
  /// Resolved from `Directory.systemTemp`, which the engine builds from the
  /// running app's own SFO, rather than from a constant here: one source of
  /// truth beats two that can disagree, and this package has no way to read
  /// the SFO itself.
  static String get _dataRoot {
    final temp = Directory.systemTemp.path; // ux0:data/<TITLEID>/tmp
    final slash = temp.lastIndexOf('/');
    return slash > 0 ? temp.substring(0, slash) : 'ux0:data/FLUTTER';
  }

  static Future<String> _ensure(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return path;
  }

  @override
  Future<String?> getTemporaryPath() => _ensure('$_dataRoot/tmp');

  @override
  Future<String?> getApplicationSupportPath() => _ensure('$_dataRoot/support');

  @override
  Future<String?> getApplicationDocumentsPath() => _ensure('$_dataRoot/documents');

  @override
  Future<String?> getApplicationCachePath() => _ensure('$_dataRoot/cache');

  /// Deliberately null rather than a guess.
  ///
  /// The Vita has no notion of a user library directory, and returning
  /// something plausible would send an app's data somewhere no convention
  /// points at. The interface documents null as "unsupported on this
  /// platform", and callers already handle it.
  @override
  Future<String?> getLibraryPath() async => null;

  /// Also null, and for a sharper reason: `ux0:` *is* the removable card on
  /// most consoles, so "external storage" and "storage" are the same place.
  /// Reporting a second path would imply a distinction the hardware does not
  /// have.
  @override
  Future<String?> getExternalStoragePath() async => null;

  @override
  Future<List<String>?> getExternalCachePaths() async => null;

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async => null;

  /// There is no Downloads folder, and no browser or mail client that would
  /// fill one.
  @override
  Future<String?> getDownloadsPath() async => null;
}
