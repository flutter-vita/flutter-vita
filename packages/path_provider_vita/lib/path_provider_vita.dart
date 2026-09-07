import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// The Vita implementation of [PathProviderPlatform].
///
/// Non-endorsed: `path_provider` does not know Vita exists, so an app depends
/// on this package alongside it and calls `PathProviderVita.registerWith()`.
///
/// Pure Dart. The paths are constants and a `mkdir`.
class PathProviderVita extends PathProviderPlatform {
  static void registerWith() {
    PathProviderPlatform.instance = PathProviderVita();
  }

  /// The read-only mount of the running title's own install directory. This is
  /// where `flutter_assets` lives, and nothing may be written to it.
  static const String appRoot = 'app0:';

  /// Per-app writable storage, keyed on the title id.
  ///
  /// Derived from `Directory.systemTemp` rather than a constant here: the
  /// engine builds that from the running app's SFO, which this package cannot
  /// read.
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

  /// The Vita has no user library directory. Null is the interface's
  /// "unsupported on this platform".
  @override
  Future<String?> getLibraryPath() async => null;

  /// `ux0:` is the removable card, so external and internal storage are the
  /// same place. A second path would imply a distinction the hardware lacks.
  @override
  Future<String?> getExternalStoragePath() async => null;

  @override
  Future<List<String>?> getExternalCachePaths() async => null;

  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async => null;

  /// `ux0:downloads`, where VitaShell downloads to, so files land somewhere
  /// the user already looks.
  ///
  /// Must not be null. Apps that check for null fall back to the desktop
  /// branch under our Linux platform identity and dereference
  /// `Platform.environment['HOME']!`, which is unset here and throws.
  ///
  /// Not keyed on the title id: a downloads folder is a place the user goes
  /// looking. Apps wanting privacy have [getApplicationDocumentsPath].
  @override
  Future<String?> getDownloadsPath() => _ensure('ux0:downloads');
}
