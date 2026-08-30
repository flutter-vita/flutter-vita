import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
// The interface every platform implementation must extend, and the one thing
// `package:file_picker/file_picker.dart` does not export. Nothing in that
// package's public surface reaches it, because `file_picker` ships all of its
// platforms itself and never expected a third-party one. Importing through
// `src/` is the only way in, and it is why this package pins a caret range on
// file_picker rather than accepting any version.
// ignore: implementation_imports
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';

import 'src/file_browser.dart';
import 'src/root_navigator.dart';
import 'src/vita_paths.dart';

export 'src/vita_paths.dart' show VitaPaths;

/// The Vita implementation of [FilePickerPlatform].
///
/// **Non-endorsed**, per ADR-0009: `file_picker` does not know the Vita exists,
/// so an app depends on this package alongside it and calls
/// `FilePickerVita.registerWith()`.
///
/// ## Why this one draws its own UI
///
/// The other Vita plugins in this repository forward to a system API:
/// `url_launcher_vita` calls `sceAppUtilLaunchWebBrowser`, and that is the
/// whole plugin. There is no such call here. The console's file manager is a
/// separate application, and nothing in the SDK opens a file chooser modally
/// and returns a path.
///
/// So this pushes a route onto the app's own Navigator and lets the user
/// browse. Two consequences the caller should know about, because neither is
/// true of any other platform:
///
///   * The picker is inside the application. It uses the app's theme, the app
///     keeps rendering underneath it, and `lockParentWindow` means nothing.
///
///   * There must be a Navigator to push onto. Every Flutter app that has run
///     `runApp` with a `MaterialApp` or `CupertinoApp` has one; a call made
///     before the first frame does not, and returns null rather than throwing.
///
/// ## What is not supported, and why
///
///   * `withReadStream`, `onFileLoading`, `compressionQuality`,
///     `cancelUploadOnWindowBlur`, `readSequential`. These describe cloud
///     providers, image re-encoding and browser tabs. Files here are on a
///     memory card and are read in one go.
///
///   * `clearTemporaryFiles`. Nothing is cached: [pickFiles] returns the file
///     where it already sits, so there is nothing to clear. It answers true
///     rather than throwing, which is the honest answer to "is the cache
///     empty".
///
///   * `pickFileAndDirectoryPaths`. Inherited as unimplemented, matching every
///     platform but macOS.
class FilePickerVita extends FilePickerPlatform {
  static void registerWith() {
    FilePickerPlatform.instance = FilePickerVita();
  }

  /// Pushes the browser and waits. Null when there is no Navigator or the user
  /// backed out.
  Future<List<String>?> _browse({
    required FileBrowserMode mode,
    String? title,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    String? saveFileName,
    String? initialDirectory,
  }) async {
    final NavigatorState? navigator = findRootNavigator();
    if (navigator == null) {
      return null;
    }
    return navigator.push<List<String>>(
      MaterialPageRoute<List<String>>(
        builder: (context) => FileBrowserPage(
          mode: mode,
          title: title,
          allowedExtensions: allowedExtensions,
          allowMultiple: allowMultiple,
          saveFileName: saveFileName,
          initialDirectory: initialDirectory,
        ),
      ),
    );
  }

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async {
    final List<String>? picked = await _browse(
      mode: FileBrowserMode.openFile,
      title: dialogTitle ?? 'Choose a file',
      allowedExtensions: _extensionsFor(type, allowedExtensions),
      allowMultiple: allowMultiple,
      initialDirectory: initialDirectory,
    );
    if (picked == null || picked.isEmpty) {
      return null;
    }

    final List<PlatformFile> files = [];
    for (final String path in picked) {
      final File file = File(path);
      int size;
      try {
        size = file.lengthSync();
      } catch (_) {
        size = 0;
      }
      files.add(
        PlatformFile(
          path: path,
          name: VitaPaths.basename(path),
          size: size,
          // `withData` is honoured because callers use it to avoid a second
          // read, and a memory card file small enough to pick is small enough
          // to hold. `withReadStream` is not: see the class comment.
          bytes: withData ? _readOrNull(file) : null,
        ),
      );
    }
    return FilePickerResult(files);
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async {
    final List<String>? picked = await _browse(
      mode: FileBrowserMode.pickDirectory,
      title: dialogTitle ?? 'Choose a folder',
      initialDirectory: initialDirectory,
    );
    return (picked == null || picked.isEmpty) ? null : picked.single;
  }

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    // The user picks the directory; the name comes from the caller. Typing a
    // name here would mean the on-screen keyboard over a file list on a 544 px
    // screen, and every caller in the corpus already generates a name.
    final String name = fileName ?? 'untitled';
    final List<String>? picked = await _browse(
      mode: FileBrowserMode.saveInDirectory,
      title: dialogTitle ?? 'Choose where to save',
      saveFileName: name,
      initialDirectory: initialDirectory,
    );
    if (picked == null || picked.isEmpty) {
      return null;
    }

    final String target = _unusedPath(picked.single, name);
    if (bytes != null) {
      // Matching the desktop implementations, which write the bytes and return
      // the path. A caller that passes bytes expects the file to exist.
      try {
        File(target).writeAsBytesSync(bytes);
      } catch (_) {
        return null;
      }
    }
    return target;
  }

  @override
  Future<bool?> clearTemporaryFiles() async => true;

  /// Never overwrite. The picker chose a directory, not a file, so the user
  /// was never shown the thing they would be destroying.
  static String _unusedPath(String directory, String name) {
    String candidate = VitaPaths.join(directory, name);
    if (!File(candidate).existsSync()) {
      return candidate;
    }
    final String extension = VitaPaths.extensionOf(name);
    final String stem = extension.isEmpty
        ? name
        : name.substring(0, name.length - extension.length - 1);
    for (int n = 2; n < 1000; n++) {
      final String suffixed = extension.isEmpty ? '$stem ($n)' : '$stem ($n).$extension';
      candidate = VitaPaths.join(directory, suffixed);
      if (!File(candidate).existsSync()) {
        return candidate;
      }
    }
    return candidate;
  }

  static Uint8List? _readOrNull(File file) {
    try {
      return file.readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  /// [FileType] collapsed to extensions, since there are no MIME types or UTIs
  /// to hand a dialog that does not exist.
  static List<String>? _extensionsFor(FileType type, List<String>? custom) {
    switch (type) {
      case FileType.custom:
        return custom;
      case FileType.image:
        return const ['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'];
      case FileType.audio:
        return const ['mp3', 'wav', 'ogg', 'm4a', 'aac', 'flac'];
      case FileType.video:
        return const ['mp4', 'mov', 'mkv', 'avi', 'webm'];
      case FileType.media:
        return const [
          'jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp',
          'mp4', 'mov', 'mkv', 'avi', 'webm',
        ];
      case FileType.any:
        return null;
    }
  }
}
