import 'dart:io';

/// The console's mount points, and how to join a path to one.
///
/// Vita paths are `<mount>:<path>`, not POSIX. The colon is part of the mount
/// name and there is no single root above them: `ux0:` and `ur0:` are siblings
/// with nothing containing both. So the browser's top level is a list of
/// mounts rather than a directory, which is why [roots] exists at all.
///
/// The Dart runtime handles these because the port taught it to -- see the
/// temp directory in `patches/dart-sdk/0010-runtime-bin-for-vita.patch`, which
/// resolves to `ux0:data/<title-id>/tmp`. That spelling, with no slash after
/// the colon, is the one this file follows.
abstract final class VitaPaths {
  /// Every mount the console can present, whether or not it is fitted.
  ///
  /// Most consoles have `ux0:` and `ur0:` only. `uma0:` appears when the second
  /// slot holds a card, `imc0:` on the 1 GB models, and `xmc0:` on a Vita TV
  /// with an SD card. Listing all of them and probing costs a handful of stats
  /// and means the picker adapts to the hardware rather than assuming mine.
  ///
  /// `app0:` is deliberately absent. It is this application's own read-only
  /// install mount, so nothing a user wants to import lives there, and offering
  /// it invites picking a file that cannot be written back to.
  static const List<(String path, String label)> candidates = [
    ('ux0:', 'Memory card'),
    ('ur0:', 'Internal storage'),
    ('uma0:', 'Second slot'),
    ('imc0:', 'Internal memory'),
    ('xmc0:', 'SD card'),
  ];

  /// Whether this is running on a Vita, asked of the filesystem.
  ///
  /// `Platform.operatingSystem` cannot answer: the port reports "linux" on
  /// purpose, because a truthful "vita" stops the Flutter framework from
  /// starting at all (see `patches/dart-sdk/0001-add-vita-host-and-target-os.patch`).
  ///
  /// `app0:` is the running application's own read-only install mount. It
  /// exists on every Vita, always, and on nothing else, which makes it a
  /// sharper test than any of the storage mounts: those depend on what is
  /// fitted.
  ///
  /// Callers use this to skip features the console cannot offer, so it is
  /// worth having somewhere shared rather than re-derived per app.
  static bool get isVita {
    try {
      return Directory('app0:').existsSync();
    } catch (_) {
      return false;
    }
  }

  /// The mounts that actually answer, in [candidates] order.
  static List<(String path, String label)> roots() {
    final List<(String, String)> found = [];
    for (final (path, label) in candidates) {
      try {
        if (Directory(path).existsSync()) {
          found.add((path, label));
        }
      } catch (_) {
        // A mount that throws on stat is a mount that is not there.
      }
    }
    return found;
  }

  /// Join [name] onto [dir], respecting the mount colon.
  ///
  /// `ux0:` + `data` is `ux0:data`, with no separator, because the colon
  /// already is one. Everything below that joins with `/` as usual.
  static String join(String dir, String name) {
    if (dir.endsWith(':') || dir.endsWith('/')) {
      return '$dir$name';
    }
    return '$dir/$name';
  }

  /// The directory containing [path], or null when [path] is a mount.
  ///
  /// Returning null at a mount is what stops the browser walking off the top
  /// of `ux0:` into a parent that does not exist.
  static String? parentOf(String path) {
    if (path.endsWith(':')) {
      return null;
    }
    final int slash = path.lastIndexOf('/');
    if (slash < 0) {
      // `ux0:data` -- the parent is the mount itself, colon included.
      final int colon = path.indexOf(':');
      return colon < 0 ? null : path.substring(0, colon + 1);
    }
    final String head = path.substring(0, slash);
    return head.endsWith(':') ? head : (head.isEmpty ? null : head);
  }

  /// The last segment of [path], for display.
  static String basename(String path) {
    if (path.endsWith(':')) {
      return path;
    }
    final int slash = path.lastIndexOf('/');
    if (slash >= 0) {
      return path.substring(slash + 1);
    }
    final int colon = path.indexOf(':');
    return colon >= 0 ? path.substring(colon + 1) : path;
  }

  /// [name] inside [directory], suffixed until it names nothing that exists.
  ///
  /// Never overwrite. The picker chose a directory, not a file, so the user was
  /// never shown the thing they would be destroying.
  static String unusedPath(String directory, String name) {
    String candidate = join(directory, name);
    if (!File(candidate).existsSync()) {
      return candidate;
    }
    final String extension = extensionOf(name);
    final String stem = extension.isEmpty
        ? name
        : name.substring(0, name.length - extension.length - 1);
    for (int n = 2; n < 1000; n++) {
      final String suffixed = extension.isEmpty ? '$stem ($n)' : '$stem ($n).$extension';
      candidate = join(directory, suffixed);
      if (!File(candidate).existsSync()) {
        return candidate;
      }
    }
    return candidate;
  }

  /// Lowercase extension without the dot, or an empty string.
  static String extensionOf(String name) {
    final int dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }
}
