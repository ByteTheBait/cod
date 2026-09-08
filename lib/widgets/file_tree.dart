import 'dart:io';
import 'package:flutter/material.dart';

class FileTree extends StatefulWidget {
  final String workingDir;
  final String? selectedPath;
  final void Function(String path) onFileTap;

  const FileTree({
    super.key,
    required this.workingDir,
    required this.onFileTap,
    this.selectedPath,
  });

  @override
  State<FileTree> createState() => _FileTreeState();
}

class _FlatNode {
  final String name;
  final String path;
  final bool isDir;
  final int depth;
  bool expanded = false;

  _FlatNode({
    required this.name,
    required this.path,
    required this.isDir,
    required this.depth,
  });
}

class _FileTreeState extends State<FileTree> {
  final List<_FlatNode> _nodes = [];
  bool _loading = true;
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    _loadRoot();
  }

  @override
  void didUpdateWidget(FileTree old) {
    super.didUpdateWidget(old);
    if (old.workingDir != widget.workingDir) _loadRoot();
  }

  Future<List<_FlatNode>> _readDir(String dirPath, int depth) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return [];
    final entries = await dir.list().toList()
      ..sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return a.path.split('/').last.toLowerCase().compareTo(
              b.path.split('/').last.toLowerCase());
      });
    return entries
        .where((e) {
          final name = e.path.split('/').last;
          return _showHidden || !name.startsWith('.');
        })
        .map((e) => _FlatNode(
              name: e.path.split('/').last,
              path: e.path,
              isDir: e is Directory,
              depth: depth,
            ))
        .toList();
  }

  Future<void> _loadRoot() async {
    setState(() {
      _loading = true;
      _nodes.clear();
    });
    if (widget.workingDir.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final children = await _readDir(widget.workingDir, 0);
    if (mounted) setState(() {
      _loading = false;
      _nodes.addAll(children);
    });
  }

  Future<void> _toggleDir(int index) async {
    final node = _nodes[index];
    if (!node.isDir) return;

    if (node.expanded) {
      // Collapse: remove all descendants
      int end = index + 1;
      while (end < _nodes.length && _nodes[end].depth > node.depth) end++;
      setState(() {
        _nodes.removeRange(index + 1, end);
        node.expanded = false;
      });
    } else {
      // Expand: load and insert children
      final children = await _readDir(node.path, node.depth + 1);
      if (!mounted) return;
      setState(() {
        node.expanded = true;
        _nodes.insertAll(index + 1, children);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (widget.workingDir.isEmpty) {
      return Center(
        child: Text('No folder open',
            style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.35))),
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    if (_nodes.isEmpty) {
      return Center(
        child: Text('Empty folder',
            style: TextStyle(fontSize: 12, color: cs.onSurface.withValues(alpha: 0.35))),
      );
    }

    return Column(
      children: [
        // Show/hide dotfiles toggle
        InkWell(
          onTap: () {
            setState(() => _showHidden = !_showHidden);
            _loadRoot();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              children: [
                Icon(
                  _showHidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                  size: 12,
                  color: cs.onSurface.withValues(alpha: 0.3),
                ),
                const SizedBox(width: 5),
                Text(
                  _showHidden ? 'hide dotfiles' : 'show dotfiles',
                  style: TextStyle(fontSize: 10, color: cs.onSurface.withValues(alpha: 0.3)),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _nodes.length,
            itemExtent: 26,
            itemBuilder: (ctx, i) {
              final node = _nodes[i];
              final isSelected = node.path == widget.selectedPath;
              return _NodeTile(
                node: node,
                isSelected: isSelected,
                onTap: () {
                  if (node.isDir) {
                    _toggleDir(i);
                  } else {
                    widget.onFileTap(node.path);
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NodeTile extends StatelessWidget {
  final _FlatNode node;
  final bool isSelected;
  final VoidCallback onTap;

  const _NodeTile({
    required this.node,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final indent = 6.0 + node.depth * 14.0;

    return InkWell(
      onTap: onTap,
      child: Container(
        color: isSelected ? cs.primary.withValues(alpha: 0.18) : Colors.transparent,
        padding: EdgeInsets.only(left: indent, right: 8),
        alignment: Alignment.centerLeft,
        child: Row(
          children: [
            // Expand arrow (dirs) or spacer (files)
            if (node.isDir)
              Icon(
                node.expanded ? Icons.arrow_drop_down : Icons.arrow_right,
                size: 16,
                color: cs.onSurface.withValues(alpha: 0.5),
              )
            else
              const SizedBox(width: 16),
            const SizedBox(width: 2),
            // Icon
            _FileIcon(name: node.name, isDir: node.isDir, expanded: node.expanded),
            const SizedBox(width: 5),
            // Name
            Expanded(
              child: Text(
                node.name,
                style: TextStyle(
                  fontSize: 12.5,
                  color: isSelected
                      ? cs.primary
                      : cs.onSurface.withValues(alpha: node.isDir ? 0.9 : 0.8),
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileIcon extends StatelessWidget {
  final String name;
  final bool isDir;
  final bool expanded;

  const _FileIcon({required this.name, required this.isDir, required this.expanded});

  @override
  Widget build(BuildContext context) {
    if (isDir) {
      return Icon(
        expanded ? Icons.folder_open : Icons.folder,
        size: 14,
        color: Colors.amber.shade600,
      );
    }

    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final (icon, color) = switch (ext) {
      'dart' => (Icons.code, const Color(0xFF54C5F8)),
      'py' => (Icons.code, const Color(0xFF3B7EAA)),
      'js' || 'mjs' || 'cjs' => (Icons.code, const Color(0xFFF0DB4F)),
      'ts' || 'tsx' => (Icons.code, const Color(0xFF2D79C7)),
      'jsx' => (Icons.code, const Color(0xFF61DAFB)),
      'go' => (Icons.code, const Color(0xFF00ADD8)),
      'rs' => (Icons.code, const Color(0xFFDEA584)),
      'c' || 'h' || 'cpp' || 'cc' || 'cxx' => (Icons.code, const Color(0xFF00549D)),
      'swift' => (Icons.code, const Color(0xFFF05138)),
      'kt' || 'kts' => (Icons.code, const Color(0xFF7F52FF)),
      'java' => (Icons.code, const Color(0xFFED8B00)),
      'rb' => (Icons.code, const Color(0xFFCC342D)),
      'php' => (Icons.code, const Color(0xFF8892BE)),
      'sh' || 'bash' || 'zsh' => (Icons.terminal, Colors.green.shade400),
      'json' || 'jsonc' => (Icons.data_object, const Color(0xFFCBCB41)),
      'yaml' || 'yml' => (Icons.settings_outlined, const Color(0xFFCBCB41)),
      'toml' => (Icons.settings_outlined, const Color(0xFFCBCB41)),
      'xml' || 'html' || 'htm' => (Icons.html, Colors.orange.shade400),
      'css' || 'scss' || 'sass' || 'less' => (Icons.format_paint, Colors.blue.shade300),
      'md' || 'mdx' => (Icons.article_outlined, Colors.blueGrey.shade300),
      'txt' => (Icons.text_snippet_outlined, Colors.grey.shade400),
      'pdf' => (Icons.picture_as_pdf, Colors.red.shade400),
      'png' || 'jpg' || 'jpeg' || 'gif' || 'svg' || 'webp' || 'ico' =>
        (Icons.image_outlined, Colors.purple.shade300),
      'zip' || 'tar' || 'gz' || 'bz2' || 'xz' => (Icons.folder_zip_outlined, Colors.brown.shade400),
      'lock' => (Icons.lock_outline, Colors.grey.shade500),
      _ => (Icons.insert_drive_file_outlined, Colors.grey.shade500),
    };

    return Icon(icon, size: 14, color: color);
  }
}
