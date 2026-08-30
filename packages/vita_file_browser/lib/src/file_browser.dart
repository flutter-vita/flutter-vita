import 'dart:io';

import 'package:flutter/material.dart';

import 'vita_paths.dart';

enum FileBrowserMode {
  /// Choose one or more existing files.
  openFile,

  /// Choose a directory.
  pickDirectory,

  /// Choose the directory to write a file into. The name is decided by the
  /// caller, not here: naming a file needs the on-screen keyboard, and the
  /// callers that reach this all arrive with a name they generated.
  saveInDirectory,
}

/// A file browser drawn in Flutter, because the console has no dialog to call.
///
/// Every other platform `file_picker` supports hands the job to the system: an
/// Intent on Android, `UIDocumentPickerViewController` on iOS, the XDG portal
/// on Linux. The Vita has no equivalent. Its own file manager is a separate
/// application and there is no way to invoke one modally and get a path back.
///
/// So the picker is a route. That is a real difference from every other
/// implementation and worth stating plainly: this one draws inside the calling
/// app's own Navigator, in the app's theme, and the app keeps running
/// underneath it.
class FileBrowserPage extends StatefulWidget {
  const FileBrowserPage({
    super.key,
    required this.mode,
    this.title,
    this.allowedExtensions,
    this.allowMultiple = false,
    this.saveFileName,
    this.initialDirectory,
  });

  final FileBrowserMode mode;
  final String? title;

  /// Lowercase, no dots. Null or empty means every file is offered.
  final List<String>? allowedExtensions;
  final bool allowMultiple;

  /// Shown in [FileBrowserMode.saveInDirectory] so the user can see what is
  /// about to be written before choosing where.
  final String? saveFileName;
  final String? initialDirectory;

  @override
  State<FileBrowserPage> createState() => _FileBrowserPageState();
}

class _FileBrowserPageState extends State<FileBrowserPage> {
  /// Null means the mount list, which is the level above every directory.
  String? _directory;

  List<FileSystemEntity> _entries = const [];
  final Set<String> _selected = <String>{};
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final String? start = widget.initialDirectory;
    if (start != null && Directory(start).existsSync()) {
      _open(start);
    }
  }

  Set<String> get _filter {
    final List<String>? given = widget.allowedExtensions;
    if (given == null) return const {};
    return given.map((e) => e.toLowerCase().replaceAll('.', '')).toSet();
  }

  bool _isOffered(FileSystemEntity entity) {
    if (entity is Directory) return true;
    if (widget.mode != FileBrowserMode.openFile) return false;
    final Set<String> filter = _filter;
    if (filter.isEmpty) return true;
    return filter.contains(VitaPaths.extensionOf(VitaPaths.basename(entity.path)));
  }

  void _open(String path) {
    setState(() {
      _loading = true;
      _error = null;
    });
    List<FileSystemEntity> listed;
    try {
      // Synchronous on purpose. A memory card directory is small and the async
      // listing would need a cancellation path for the case where the user
      // taps into another directory before this one finishes.
      listed = Directory(path).listSync(followLinks: false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _directory = path;
        _entries = const [];
        _loading = false;
        _error = '$error';
      });
      return;
    }

    final List<FileSystemEntity> offered = listed.where(_isOffered).toList()
      ..sort((a, b) {
        final bool aDir = a is Directory;
        final bool bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return VitaPaths.basename(a.path).toLowerCase().compareTo(
              VitaPaths.basename(b.path).toLowerCase(),
            );
      });

    if (!mounted) return;
    setState(() {
      _directory = path;
      _entries = offered;
      _loading = false;
    });
  }

  void _up() {
    final String? here = _directory;
    if (here == null) return;
    final String? parent = VitaPaths.parentOf(here);
    if (parent == null) {
      setState(() {
        _directory = null;
        _entries = const [];
        _error = null;
      });
    } else {
      _open(parent);
    }
  }

  void _tapFile(File file) {
    if (!widget.allowMultiple) {
      Navigator.of(context).pop<List<String>>([file.path]);
      return;
    }
    setState(() {
      if (!_selected.remove(file.path)) _selected.add(file.path);
    });
  }

  @override
  Widget build(BuildContext context) {
    final bool atRoot = _directory == null;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44.0,
        leading: const CloseButton(),
        title: Text(
          atRoot ? (widget.title ?? 'Choose a file') : _directory!,
          style: const TextStyle(fontSize: 15.0),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!atRoot)
            IconButton(
              icon: const Icon(Icons.arrow_upward),
              tooltip: 'Up',
              onPressed: _up,
            ),
        ],
      ),
      body: atRoot ? _buildRoots() : _buildListing(),
      bottomNavigationBar: _buildConfirmBar(),
    );
  }

  Widget _buildRoots() {
    final List<(String, String)> roots = VitaPaths.roots();
    if (roots.isEmpty) {
      return const _Message('No storage is mounted.');
    }
    return ListView(
      children: [
        for (final (path, label) in roots)
          ListTile(
            leading: const Icon(Icons.sd_storage),
            title: Text(label),
            subtitle: Text(path),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(path),
          ),
      ],
    );
  }

  Widget _buildListing() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _Message('Cannot read this directory.\n$_error');
    }
    if (_entries.isEmpty) {
      return _Message(
        widget.mode == FileBrowserMode.openFile && _filter.isNotEmpty
            ? 'Nothing here matching ${_filter.map((e) => '.$e').join(', ')}.'
            : 'This directory is empty.',
      );
    }
    return ListView.builder(
      itemCount: _entries.length,
      itemBuilder: (context, index) {
        final FileSystemEntity entity = _entries[index];
        final String name = VitaPaths.basename(entity.path);
        if (entity is Directory) {
          return ListTile(
            leading: const Icon(Icons.folder),
            title: Text(name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(entity.path),
          );
        }
        final File file = entity as File;
        return ListTile(
          leading: widget.allowMultiple
              ? Checkbox(
                  value: _selected.contains(file.path),
                  onChanged: (_) => _tapFile(file),
                )
              : const Icon(Icons.insert_drive_file),
          title: Text(name),
          subtitle: Text(_describeSize(file)),
          onTap: () => _tapFile(file),
        );
      },
    );
  }

  Widget? _buildConfirmBar() {
    final String? here = _directory;

    if (widget.mode == FileBrowserMode.openFile) {
      if (!widget.allowMultiple || _selected.isEmpty) return null;
      return _ConfirmBar(
        label: 'Open ${_selected.length} file${_selected.length == 1 ? '' : 's'}',
        onPressed: () => Navigator.of(context).pop<List<String>>(_selected.toList()),
      );
    }

    // Both directory modes need somewhere to be. The mount list is not a
    // directory, so there is nothing to confirm while it is showing.
    if (here == null) return null;

    if (widget.mode == FileBrowserMode.pickDirectory) {
      return _ConfirmBar(
        label: 'Use this folder',
        onPressed: () => Navigator.of(context).pop<List<String>>([here]),
      );
    }

    return _ConfirmBar(
      label: 'Save ${widget.saveFileName ?? 'file'} here',
      onPressed: () => Navigator.of(context).pop<List<String>>([here]),
    );
  }

  static String _describeSize(File file) {
    int bytes;
    try {
      bytes = file.lengthSync();
    } catch (_) {
      return 'unreadable';
    }
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _ConfirmBar extends StatelessWidget {
  const _ConfirmBar({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 8.0),
        child: FilledButton(
          onPressed: onPressed,
          child: Text(label, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
      ),
    );
  }
}
