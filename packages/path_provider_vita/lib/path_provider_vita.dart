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

  /// `ux0:downloads`, the device's own convention — the directory VitaShell
  /// downloads into, so a file that lands here is somewhere the user already
  /// knows to look.
  ///
  /// This returned null until 2026-08-21, on the reasoning that "there is no
  /// Downloads folder, and no browser or mail client that would fill one".
  /// Both halves were wrong. localsend fills one, and it is the corpus app
  /// this port cares most about; and the claim that "callers already handle
  /// null" did not survive contact with a real caller:
  ///
  ///     Unhandled Exception: Null check operator used on a null value
  ///     #0  getDefaultDestinationDirectory (util/native/directories.dart:29)
  ///     #1  ReceiveController._prepareUploadHandler (receive_controller.dart:216)
  ///
  /// localsend *does* check for null. Its fallback is the problem: under
  /// [ADR-0008]'s Linux identity it takes the desktop branch and reaches for
  /// `Platform.environment['HOME']!`, which is unset here, so the `!` throws.
  /// The exception escaped a shelf handler, no response was ever written, and
  /// the sending device simply waited — the symptom being "nothing happens on
  /// the Vita", with discovery working perfectly the whole time.
  ///
  /// Returning a real path is the fix that works for every app rather than
  /// one, because it means the desktop fallback is never entered at all.
  ///
  /// Not keyed on the title id, unlike the paths above: a downloads folder is
  /// a place the user goes looking, and burying it under a nine-character id
  /// would defeat the point. Apps that want privacy have
  /// [getApplicationDocumentsPath].
  @override
  Future<String?> getDownloadsPath() => _ensure('ux0:downloads');
}
