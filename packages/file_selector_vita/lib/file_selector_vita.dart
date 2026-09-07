import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:vita_file_browser/vita_file_browser.dart';

export 'package:vita_file_browser/vita_file_browser.dart' show VitaPaths;

/// The Vita implementation of [FileSelectorPlatform].
///
/// **Non-endorsed**, per ADR-0009: `file_selector` does not know the Vita
/// exists, so an app depends on this package alongside it and calls
/// `FileSelectorVita.registerWith()`.
///
/// This is the one localsend needs. It reports `TargetPlatform.linux`
/// (ADR-0008), so both of its picking paths take the desktop branch:
/// `openFiles()` chooses what to send, and `getDirectoryPath()` chooses where
/// received files land. Without an implementation both throw
/// `UnimplementedError` from the platform interface's defaults, which is why
/// the Vita could receive files and never send one.
///
/// The UI is `vita_file_browser`, shared with `file_picker_vita`.
///
/// ## What is not supported, and why
///
///   * [getSavePath] and [getSaveLocation] return the *directory* the user
///     chose joined to `suggestedName`, never a name the user typed. Naming a
///     file means the on-screen keyboard over a file list on a 544 px screen.
///     A caller that passes no `suggestedName` gets null rather than a file
///     called "untitled" it never asked for.
///
///   * `confirmButtonText` is ignored. The browser's confirm button says what
///     it does, and a caller's word for it would have to fit a button sized for
///     this screen.
///
///   * [XTypeGroup] is read for `extensions` only. There are no UTIs or MIME
///     types here to hand a dialog that does not exist, and `webWildCards` is
///     for browsers.
class FileSelectorVita extends FileSelectorPlatform {
  static void registerWith() {
    FileSelectorPlatform.instance = FileSelectorVita();
  }

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final List<String>? picked = await browseForPaths(
      mode: FileBrowserMode.openFile,
      title: 'Choose a file',
      allowedExtensions: _extensionsOf(acceptedTypeGroups),
      initialDirectory: initialDirectory,
    );
    return (picked == null || picked.isEmpty) ? null : XFile(picked.single);
  }

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final List<String>? picked = await browseForPaths(
      mode: FileBrowserMode.openFile,
      title: 'Choose files',
      allowedExtensions: _extensionsOf(acceptedTypeGroups),
      allowMultiple: true,
      initialDirectory: initialDirectory,
    );
    // An empty list is the documented way to say the user cancelled. Callers
    // iterate it, so null would be the wrong shape as well as the wrong answer.
    return (picked ?? const <String>[]).map(XFile.new).toList();
  }

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    final List<String>? picked = await browseForPaths(
      mode: FileBrowserMode.pickDirectory,
      title: 'Choose a folder',
      initialDirectory: initialDirectory,
    );
    return (picked == null || picked.isEmpty) ? null : picked.single;
  }

  @override
  Future<List<String>> getDirectoryPaths({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    // The browser picks one directory at a time: multi-select across a tree
    // needs a selection model the confirm bar has no room for, and no caller in
    // the test apps asks for more than one. One in a list is honest; throwing
    // would fail a caller that can work with one.
    final String? single = await getDirectoryPath(
      initialDirectory: initialDirectory,
      confirmButtonText: confirmButtonText,
    );
    return single == null ? const <String>[] : <String>[single];
  }

  @override
  Future<String?> getSavePath({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? suggestedName,
    String? confirmButtonText,
  }) async {
    if (suggestedName == null) {
      return null;
    }
    final List<String>? picked = await browseForPaths(
      mode: FileBrowserMode.saveInDirectory,
      title: 'Choose where to save',
      saveFileName: suggestedName,
      initialDirectory: initialDirectory,
    );
    if (picked == null || picked.isEmpty) {
      return null;
    }
    return VitaPaths.unusedPath(picked.single, suggestedName);
  }

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    final String? path = await getSavePath(
      acceptedTypeGroups: acceptedTypeGroups,
      initialDirectory: options.initialDirectory,
      suggestedName: options.suggestedName,
      confirmButtonText: options.confirmButtonText,
    );
    return path == null ? null : FileSaveLocation(path);
  }

  /// The union of every group's extensions, lowercased and undotted.
  ///
  /// A group with no extensions means "any file" -- that is how callers spell
  /// an unfiltered pick alongside filtered ones -- so it collapses the whole
  /// filter rather than contributing nothing to it.
  static List<String>? _extensionsOf(List<XTypeGroup>? groups) {
    if (groups == null || groups.isEmpty) {
      return null;
    }
    final Set<String> extensions = <String>{};
    for (final XTypeGroup group in groups) {
      final List<String>? groupExtensions = group.extensions;
      if (groupExtensions == null || groupExtensions.isEmpty) {
        return null;
      }
      extensions.addAll(
        groupExtensions.map((e) => e.toLowerCase().replaceAll('.', '')),
      );
    }
    return extensions.isEmpty ? null : extensions.toList();
  }
}
