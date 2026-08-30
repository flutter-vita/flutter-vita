import 'package:flutter/material.dart';

import 'src/file_browser.dart';
import 'src/root_navigator.dart';

export 'src/file_browser.dart' show FileBrowserMode;
export 'src/vita_paths.dart' show VitaPaths;

/// A file browser for a console that has no file-chooser dialog to call.
///
/// Every other platform that `file_picker` or `file_selector` supports hands
/// the job to the system: an Intent on Android, `UIDocumentPickerViewController`
/// on iOS, the XDG portal on Linux. The Vita has no equivalent. Its file manager
/// is a separate application and nothing in the SDK opens a chooser modally and
/// returns a path.
///
/// So the picker is a route pushed onto the calling app's own Navigator, in the
/// app's theme, with the app still running underneath it.
///
/// ## Why this is its own package
///
/// It started inside `file_picker_vita`. Then localsend needed a picker too and
/// turned out to pin `file_selector`, a different package with a different
/// interface -- and to pin `file_picker` 8.0.2 besides, whose interface is
/// `FilePicker.platform` where 11.x has `FilePickerPlatform.instance`.
///
/// A Dart package cannot depend on two major versions of the same package, so
/// one adapter cannot serve both. The browser itself never needed either
/// dependency: it deals in paths. Splitting it out means the console gets one
/// picker that behaves the same way everywhere, and each packaging of it is the
/// fifty lines that translate one interface into [browseForPaths].
Future<List<String>?> browseForPaths({
  required FileBrowserMode mode,
  String? title,
  List<String>? allowedExtensions,
  bool allowMultiple = false,
  String? saveFileName,
  String? initialDirectory,
}) async {
  // No context is passed in, because none of these interfaces has one to pass:
  // they were shaped by platforms where the picker is not part of the app. See
  // findRootNavigator for why this walks the tree rather than asking apps to
  // register a navigator key.
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
