import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../connections/models/connection_profile.dart';
import '../providers/terminal_provider.dart';
import '../widgets/terminal_view.dart';
import '../../../core/ssh/ssh_service.dart';

class TerminalScreen extends ConsumerStatefulWidget {
  final ConnectionProfile profile;
  const TerminalScreen({super.key, required this.profile});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  late TerminalSession _session;
  StreamSubscription<SshConnectionState>? _stateSub;

  bool _wasConnected = false;
  bool _dialogShowing = false;

  @override
  void initState() {
    super.initState();
    _session = ref.read(terminalProvider(widget.profile));
    _connectAndDetectTmux();
    _stateSub = _session.ssh.stateStream.listen((state) {
      if (state == SshConnectionState.connected) {
        _wasConnected = true;
      }
      if (state == SshConnectionState.disconnected &&
          _wasConnected &&
          mounted &&
          !_dialogShowing) {
        _showDisconnectedDialog();
      }
    });
  }

  Future<void> _connectAndDetectTmux() async {
    await _session.connect();
    if (!mounted || _session.ssh.state != SshConnectionState.connected) return;
    _showTmuxSessionSheet();
  }

  Future<void> _showTmuxSessionSheet() async {
    showModalBottomSheet(
      context: context,
      isDismissible: true,
      builder: (ctx) => _TmuxSessionSheet(
        session: _session,
        onDismiss: () => Navigator.pop(ctx),
      ),
    );
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    super.dispose();
  }

  void _showDisconnectedDialog() {
    if (!mounted || _dialogShowing) return;
    _dialogShowing = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnected'),
        content: const Text('SSH connection lost.'),
        actions: [
          TextButton(
            onPressed: () {
              _dialogShowing = false;
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              _dialogShowing = false;
              _wasConnected = false;
              Navigator.pop(ctx);
              _connectAndDetectTmux();
            },
            child: const Text('Reconnect'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        foregroundColor: Colors.white,
        title: Text(widget.profile.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.layers),
            tooltip: 'tmux sessions',
            onPressed: () {
              if (_session.ssh.state == SshConnectionState.connected) {
                _showTmuxSessionSheet();
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              _session.ssh.disconnect();
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: TerminalView(session: _session),
      ),
    );
  }
}

class _TmuxSessionSheet extends StatefulWidget {
  final TerminalSession session;
  final VoidCallback onDismiss;
  const _TmuxSessionSheet({required this.session, required this.onDismiss});

  @override
  State<_TmuxSessionSheet> createState() => _TmuxSessionSheetState();
}

class _TmuxSessionSheetState extends State<_TmuxSessionSheet> {
  List<String>? _sessions;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final sessions = await widget.session.listTmuxSessions();
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _loading = false;
    });
  }

  void _showClaudeCodeDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _DirectoryPickerDialog(
        session: widget.session,
        onSelected: (dir) {
          Navigator.pop(ctx);
          widget.onDismiss();
          final cdPart = dir.isNotEmpty ? 'cd $dir && ' : '';
          final cmd = '${cdPart}tmux new-session -d -s claude-code '
              "'claude --dangerously-skip-permissions' 2>/dev/null; "
              'tmux set -g mouse on 2>/dev/null; '
              'export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; '
              'tmux -u attach-session -t claude-code\n';
          widget.session.sendKey(cmd);
        },
      ),
    );
  }

  void _showClaudeTaskDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _ClaudeTaskDialog(
        session: widget.session,
        onStart: (taskName, dir) {
          Navigator.pop(ctx);
          widget.onDismiss();
          final sanitized = taskName
              .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '-')
              .replaceAll(RegExp(r'-+'), '-')
              .replaceAll(RegExp(r'^-|-$'), '');
          final sessionName =
              sanitized.isEmpty ? 'claude-task' : 'claude-$sanitized';
          final cdPart = dir.isNotEmpty ? 'cd $dir && ' : '';
          final cmd = "${cdPart}tmux new-session -d -s $sessionName "
              "'claude --dangerously-skip-permissions' 2>/dev/null; "
              'tmux set -g mouse on 2>/dev/null; '
              'export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; '
              'tmux -u attach-session -t $sessionName\n';
          widget.session.sendKey(cmd);
        },
      ),
    );
  }

  Future<void> _confirmKill(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kill session'),
        content: Text('Kill tmux session "$name"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Kill', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.session.killTmuxSession(name);
      setState(() => _loading = true);
      await _loadSessions();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.terminal, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'tmux sessions',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: _loading
                      ? null
                      : () {
                          setState(() => _loading = true);
                          _loadSessions();
                        },
                ),
                TextButton(
                  onPressed: widget.onDismiss,
                  child: const Text('Skip'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.smart_toy, color: Colors.blue),
            title: const Text('Start Claude Code'),
            subtitle: const Text('claude --dangerously-skip-permissions'),
            onTap: () => _showClaudeCodeDialog(),
          ),
          ListTile(
            leading: const Icon(Icons.assignment, color: Colors.orange),
            title: const Text('Start Claude Code with Task'),
            subtitle: const Text('Start with a task prompt'),
            onTap: () => _showClaudeTaskDialog(),
          ),
          const Divider(height: 1),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 12),
                  Text('Detecting...'),
                ],
              ),
            )
          else if (_sessions == null || _sessions!.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Icon(Icons.info_outline, size: 40, color: Colors.grey[500]),
                  const SizedBox(height: 12),
                  const Text('No active tmux sessions'),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _showClaudeCodeDialog(),
                    icon: const Icon(Icons.add),
                    label: const Text('Create new session'),
                  ),
                ],
              ),
            )
          else
            ...(_sessions!.map((name) => ListTile(
                  leading: const Icon(Icons.terminal),
                  title: Text(name),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.red, size: 20),
                        tooltip: 'Kill session',
                        onPressed: () => _confirmKill(name),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                  onTap: () {
                    widget.onDismiss();
                    widget.session.attachTmuxSession(name);
                  },
                ))),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _DirectoryPickerDialog extends StatefulWidget {
  final TerminalSession session;
  final ValueChanged<String> onSelected;
  const _DirectoryPickerDialog({
    required this.session,
    required this.onSelected,
  });

  @override
  State<_DirectoryPickerDialog> createState() => _DirectoryPickerDialogState();
}

class _DirectoryPickerDialogState extends State<_DirectoryPickerDialog> {
  static const _recentKey = 'recent_dirs';
  String _currentPath = '~';
  List<String>? _dirs;
  List<String> _recentDirs = [];
  bool _loading = true;
  final _manualController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadRecent();
    _loadDirs();
  }

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_recentKey) ?? [];
    if (mounted) setState(() => _recentDirs = list);
  }

  Future<void> _saveRecent(String dir) async {
    final prefs = await SharedPreferences.getInstance();
    _recentDirs.remove(dir);
    _recentDirs.insert(0, dir);
    if (_recentDirs.length > 10) _recentDirs = _recentDirs.sublist(0, 10);
    await prefs.setStringList(_recentKey, _recentDirs);
  }

  void _selectDir(String dir) {
    _saveRecent(dir);
    widget.onSelected(dir);
  }

  Future<void> _loadDirs() async {
    setState(() => _loading = true);
    final dirs = await widget.session.listDirectories(_currentPath);
    if (!mounted) return;
    setState(() {
      _dirs = dirs;
      _loading = false;
    });
  }

  void _navigateTo(String path) {
    _currentPath = path;
    _loadDirs();
  }

  String get _displayPath {
    final home = '/Users/${widget.session.profile.username}';
    if (_currentPath.startsWith(home)) {
      return '~${_currentPath.substring(home.length)}';
    }
    return _currentPath;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Directory'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_recentDirs.isNotEmpty) ...[
              const Text('Recent', style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              SizedBox(
                height: 32,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _recentDirs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) {
                    final dir = _recentDirs[i];
                    final label = dir.contains('/')
                        ? dir.substring(dir.lastIndexOf('/') + 1)
                        : dir;
                    return ActionChip(
                      label: Text(label, style: const TextStyle(fontSize: 12)),
                      avatar: const Icon(Icons.history, size: 16),
                      onPressed: () => _selectDir(dir),
                    );
                  },
                ),
              ),
              const Divider(),
            ],
            Row(
              children: [
                const Icon(Icons.folder_open, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _displayPath,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_currentPath != '~')
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, size: 20),
                    tooltip: 'Parent directory',
                    onPressed: () {
                      final parent = _currentPath.contains('/')
                          ? _currentPath.substring(
                              0, _currentPath.lastIndexOf('/'))
                          : '~';
                      _navigateTo(parent.isEmpty ? '/' : parent);
                    },
                  ),
              ],
            ),
            const Divider(),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : (_dirs == null || _dirs!.isEmpty)
                      ? const Center(
                          child: Text('No subdirectories',
                              style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          itemCount: _dirs!.length,
                          itemBuilder: (_, i) {
                            final dir = _dirs![i];
                            final name = dir.contains('/')
                                ? dir.substring(dir.lastIndexOf('/') + 1)
                                : dir;
                            return ListTile(
                              dense: true,
                              leading:
                                  const Icon(Icons.folder, color: Colors.amber),
                              title: Text(name),
                              onTap: () => _navigateTo(dir),
                            );
                          },
                        ),
            ),
            const Divider(),
            TextField(
              controller: _manualController,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Or type path manually',
                prefixIcon: Icon(Icons.edit, size: 18),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final manual = _manualController.text.trim();
            _selectDir(manual.isNotEmpty ? manual : _currentPath);
          },
          child: const Text('Start Here'),
        ),
      ],
    );
  }
}

class _ClaudeTaskDialog extends StatefulWidget {
  final TerminalSession session;
  final void Function(String taskName, String dir) onStart;
  const _ClaudeTaskDialog({required this.session, required this.onStart});

  @override
  State<_ClaudeTaskDialog> createState() => _ClaudeTaskDialogState();
}

class _ClaudeTaskDialogState extends State<_ClaudeTaskDialog> {
  static const _recentKey = 'recent_dirs';
  final _taskController = TextEditingController();
  final _manualController = TextEditingController();
  String _currentPath = '~';
  List<String>? _dirs;
  List<String> _recentDirs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    _loadDirs();
  }

  @override
  void dispose() {
    _taskController.dispose();
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_recentKey) ?? [];
    if (mounted) setState(() => _recentDirs = list);
  }

  Future<void> _saveRecent(String dir) async {
    final prefs = await SharedPreferences.getInstance();
    _recentDirs.remove(dir);
    _recentDirs.insert(0, dir);
    if (_recentDirs.length > 10) _recentDirs = _recentDirs.sublist(0, 10);
    await prefs.setStringList(_recentKey, _recentDirs);
  }

  Future<void> _loadDirs() async {
    setState(() => _loading = true);
    final dirs = await widget.session.listDirectories(_currentPath);
    if (!mounted) return;
    setState(() {
      _dirs = dirs;
      _loading = false;
    });
  }

  void _navigateTo(String path) {
    _currentPath = path;
    _loadDirs();
  }

  String get _displayPath {
    final home = '/Users/${widget.session.profile.username}';
    if (_currentPath.startsWith(home)) {
      return '~${_currentPath.substring(home.length)}';
    }
    return _currentPath;
  }

  void _submit() {
    final task = _taskController.text.trim();
    if (task.isEmpty) return;
    final manual = _manualController.text.trim();
    final dir = manual.isNotEmpty ? manual : _currentPath;
    _saveRecent(dir);
    widget.onStart(task, dir);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Claude Code Task'),
      content: SizedBox(
        width: double.maxFinite,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _taskController,
              autofocus: true,
              maxLines: 1,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Session name, e.g. fix-login-bug',
                prefixIcon: Icon(Icons.label_outline, size: 18),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            const Text('Working Directory',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 4),
            if (_recentDirs.isNotEmpty) ...[
              SizedBox(
                height: 32,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _recentDirs.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 6),
                  itemBuilder: (_, i) {
                    final dir = _recentDirs[i];
                    final label = dir.contains('/')
                        ? dir.substring(dir.lastIndexOf('/') + 1)
                        : dir;
                    return ActionChip(
                      label: Text(label, style: const TextStyle(fontSize: 12)),
                      avatar: const Icon(Icons.history, size: 16),
                      onPressed: () {
                        _manualController.text = dir;
                        _currentPath = dir;
                        _loadDirs();
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 4),
            ],
            Row(
              children: [
                const Icon(Icons.folder_open, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _displayPath,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.bold),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_currentPath != '~')
                  IconButton(
                    icon: const Icon(Icons.arrow_upward, size: 20),
                    tooltip: 'Parent directory',
                    onPressed: () {
                      final parent = _currentPath.contains('/')
                          ? _currentPath.substring(
                              0, _currentPath.lastIndexOf('/'))
                          : '~';
                      _navigateTo(parent.isEmpty ? '/' : parent);
                    },
                  ),
              ],
            ),
            const Divider(height: 8),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : (_dirs == null || _dirs!.isEmpty)
                      ? const Center(
                          child: Text('No subdirectories',
                              style: TextStyle(color: Colors.grey)))
                      : ListView.builder(
                          itemCount: _dirs!.length,
                          itemBuilder: (_, i) {
                            final dir = _dirs![i];
                            final name = dir.contains('/')
                                ? dir.substring(dir.lastIndexOf('/') + 1)
                                : dir;
                            return ListTile(
                              dense: true,
                              leading: const Icon(Icons.folder,
                                  color: Colors.amber),
                              title: Text(name),
                              onTap: () => _navigateTo(dir),
                            );
                          },
                        ),
            ),
            const Divider(height: 8),
            TextField(
              controller: _manualController,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Or type path manually',
                prefixIcon: Icon(Icons.edit, size: 18),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Start Task'),
        ),
      ],
    );
  }
}
