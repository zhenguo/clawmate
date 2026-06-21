import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with WidgetsBindingObserver {
  late TerminalSession _session;
  StreamSubscription<SshConnectionState>? _stateSub;
  Timer? _reconnectTimer;
  Timer? _healthTimer;
  static const _maxReconnectAttempts = 10;

  bool _wasConnected = false;
  bool _dialogShowing = false;
  bool _autoReconnecting = false;
  bool _initialConnectFailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session = ref.read(terminalProvider(widget.profile));
    _connectAndDetectTmux();
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted || !_wasConnected || _autoReconnecting || _dialogShowing) return;
      final cs = _session.connectionState;
      if (cs == SshConnectionState.disconnected ||
          cs == SshConnectionState.error) {
        _startAutoReconnect();
      }
    });
    _stateSub = _session.connectionStateStream.listen((state) {
      if (state == SshConnectionState.connected) {
        _wasConnected = true;
        _autoReconnecting = false;
        _reconnectTimer?.cancel();
        if (mounted) setState(() {});
      }
      if ((state == SshConnectionState.disconnected ||
              state == SshConnectionState.error) &&
          _wasConnected &&
          mounted &&
          !_dialogShowing) {
        _startAutoReconnect();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && _wasConnected) {
      final cs = _session.connectionState;
      if (cs == SshConnectionState.disconnected ||
          cs == SshConnectionState.error) {
        _startAutoReconnect();
      } else {
        // Socket error may not have propagated yet — check again shortly
        Future.delayed(const Duration(seconds: 1), () {
          if (!mounted || !_wasConnected || _autoReconnecting) return;
          final delayed = _session.connectionState;
          if (delayed == SshConnectionState.disconnected ||
              delayed == SshConnectionState.error) {
            _startAutoReconnect();
          }
        });
      }
    }
  }

  void _startAutoReconnect() {
    if (_autoReconnecting || _dialogShowing) return;
    _autoReconnecting = true;
    _dialogShowing = true;
    _showReconnectDialog();
  }

  void _showReconnectDialog() {
    if (!mounted) return;
    final isMosh = widget.profile.transportType == TransportType.mosh;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ReconnectDialog(
        isMosh: isMosh,
        maxAttempts: _maxReconnectAttempts,
        onReconnectAttempt: (attempt, setStatus) async {
          try {
            await _session.reconnect(
              onProgress: (msg) => setStatus(msg),
            );
          } catch (_) {}
          return _session.connectionState == SshConnectionState.connected;
        },
        onConnected: () {
          _wasConnected = true;
          _autoReconnecting = false;
          _dialogShowing = false;
          Navigator.pop(ctx);
        },
        onClose: () {
          _autoReconnecting = false;
          _dialogShowing = false;
          Navigator.pop(ctx);
          Navigator.pop(context);
        },
        onRetry: () {
          Navigator.pop(ctx);
          _dialogShowing = false;
          _autoReconnecting = false;
          _startAutoReconnect();
        },
      ),
    );
  }

  Future<void> _connectAndDetectTmux() async {
    setState(() => _initialConnectFailed = false);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    await _session.connect();
    if (!mounted) return;
    if (!_session.isConnected) {
      setState(() => _initialConnectFailed = true);
      return;
    }
    _wasConnected = true;
    setState(() {});
    _showTmuxSessionSheet();
  }

  void _retryConnect() {
    setState(() => _initialConnectFailed = false);
    _session.resetTransport();
    _connectAndDetectTmux();
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

  Future<void> _showGitBranchSheet() async {
    showModalBottomSheet(
      context: context,
      isDismissible: true,
      builder: (ctx) => _GitBranchSheet(
        session: _session,
        onDismiss: () => Navigator.pop(ctx),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _healthTimer?.cancel();
    _reconnectTimer?.cancel();
    _stateSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _session.connectionState == SshConnectionState.connected;
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        foregroundColor: Colors.white70,
        systemOverlayStyle: SystemUiOverlayStyle.light,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleSpacing: 0,
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(0.5),
          child: Divider(
              height: 0.5, thickness: 0.5, color: Color(0xFF2A2A2A)),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.profile.name,
                style: const TextStyle(fontSize: 14, color: Colors.white)),
            _ConnectionStatsBar(session: _session),
          ],
        ),
        actions: [
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 21,
            icon: Icon(Icons.account_tree_outlined,
                color: connected ? Colors.white70 : Colors.white24),
            tooltip: 'Git 分支',
            onPressed: connected
                ? () {
                    HapticFeedback.selectionClick();
                    _showGitBranchSheet();
                  }
                : null,
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 21,
            icon: Icon(Icons.grid_view_rounded,
                color: connected ? Colors.white70 : Colors.white24),
            tooltip: 'tmux 会话',
            onPressed: connected
                ? () {
                    HapticFeedback.selectionClick();
                    _showTmuxSessionSheet();
                  }
                : null,
          ),
          Container(
            width: 0.5,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: const Color(0xFF2A2A2A),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 21,
            icon: const Icon(Icons.logout_rounded, color: Color(0xFFFF3B30)),
            tooltip: '断开连接',
            onPressed: () async {
              HapticFeedback.lightImpact();
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  backgroundColor: const Color(0xFF2A2A2A),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  title: const Text('断开连接？',
                      style: TextStyle(color: Colors.white, fontSize: 16)),
                  content: Text('将关闭与 ${widget.profile.name} 的连接。',
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 13)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消',
                          style: TextStyle(color: Color(0xFF8E8E93))),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('断开',
                          style: TextStyle(color: Color(0xFFFF3B30))),
                    ),
                  ],
                ),
              );
              if (ok == true && mounted) {
                _session.disconnect();
                Navigator.pop(context);
              }
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Stack(
          children: [
            TerminalView(session: _session),
            if (!connected && !_initialConnectFailed)
              const Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor:
                                AlwaysStoppedAnimation(Color(0xFF5AC8FA)),
                          ),
                        ),
                        SizedBox(height: 14),
                        Text('正在连接…',
                            style: TextStyle(
                                color: Colors.white54, fontSize: 13)),
                      ],
                    ),
                  ),
                ),
              ),
            if (_initialConnectFailed)
              Positioned.fill(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_rounded,
                          color: Color(0xFFFF9F0A), size: 44),
                      const SizedBox(height: 16),
                      Text(
                        '无法连接到 ${widget.profile.name}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '请检查网络与服务器状态后重试',
                        style:
                            TextStyle(color: Colors.white38, fontSize: 13),
                      ),
                      const SizedBox(height: 24),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.selectionClick();
                          _retryConnect();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF2A2A2A),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                                color: const Color(0xFF5AC8FA), width: 1),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.refresh,
                                  color: Color(0xFF5AC8FA), size: 18),
                              SizedBox(width: 6),
                              Text('重新连接',
                                  style: TextStyle(
                                      color: Color(0xFF5AC8FA),
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionStatsBar extends StatefulWidget {
  final TerminalSession session;
  const _ConnectionStatsBar({required this.session});

  @override
  State<_ConnectionStatsBar> createState() => _ConnectionStatsBarState();
}

class _ConnectionStatsBarState extends State<_ConnectionStatsBar> {
  Timer? _speedTimer;
  Timer? _pingTimer;
  String _speedText = '';
  int _latencyMs = -1;
  double? _emaMs;

  @override
  void initState() {
    super.initState();
    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final connected =
          widget.session.connectionState == SshConnectionState.connected;
      if (!connected) {
        // Don't let the header keep advertising a stale "good" quality / speed
        // while the link is actually down — clear until reconnect repopulates.
        if (_speedText.isNotEmpty || _latencyMs != -1) {
          setState(() {
            _speedText = '';
            _latencyMs = -1;
          });
          _emaMs = null;
        }
        return;
      }
      final s = widget.session.snapshotSpeed();
      final newText = (s.rxSpeed == 0 && s.txSpeed == 0)
          ? ''
          : '${_formatSpeed(s.rxSpeed)}/s ↓  ${_formatSpeed(s.txSpeed)}/s ↑';
      if (newText != _speedText) {
        setState(() => _speedText = newText);
      }
    });
    _pingTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _measureLatency();
    });
  }

  @override
  void dispose() {
    _speedTimer?.cancel();
    _pingTimer?.cancel();
    super.dispose();
  }

  Future<void> _measureLatency() async {
    if (widget.session.connectionState != SshConnectionState.connected) return;
    final ms = await widget.session.ping();
    if (!mounted) return;
    if (ms < 0) {
      // Ping timed out on a still-"connected" link — surface 未知 rather than
      // keep advertising the last good quality, and reset smoothing.
      _emaMs = null;
      if (_latencyMs != -1) setState(() => _latencyMs = -1);
      return;
    }
    // EMA (α=0.3) smooths jittery per-sample pings so the quality label
    // reflects sustained network quality instead of flipping every 3 seconds.
    const alpha = 0.3;
    _emaMs = _emaMs == null ? ms.toDouble() : _emaMs! * (1 - alpha) + ms * alpha;
    final smoothed = _emaMs!.round();
    if (smoothed != _latencyMs) setState(() => _latencyMs = smoothed);
  }

  static ({String label, Color color}) _networkQuality(int ms) {
    if (ms < 0) return (label: '未知', color: const Color(0xFF8E8E93));
    if (ms <= 50) return (label: '极佳', color: const Color(0xFF34C759));
    if (ms <= 100) return (label: '良好', color: const Color(0xFF30D158));
    if (ms <= 200) return (label: '一般', color: const Color(0xFFFF9F0A));
    return (label: '较差', color: const Color(0xFFFF3B30));
  }

  static String _formatSpeed(int bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec}B';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)}KB';
    }
    return '${(bytesPerSec / 1024 / 1024).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (_latencyMs >= 0) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: _networkQuality(_latencyMs).color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '${_networkQuality(_latencyMs).label} ${_latencyMs}ms',
            style: TextStyle(
                fontSize: 10, color: _networkQuality(_latencyMs).color),
          ),
          const SizedBox(width: 8),
        ],
        if (_speedText.isNotEmpty)
          Flexible(
            child: Text(_speedText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 10, color: Color(0xFF8E8E93))),
          ),
      ],
    );
  }
}

enum _ReconnectPhase { reconnecting, connected, failed }

class _ReconnectDialog extends StatefulWidget {
  final bool isMosh;
  final int maxAttempts;
  final Future<bool> Function(int attempt, void Function(String) setStatus) onReconnectAttempt;
  final VoidCallback onConnected;
  final VoidCallback onClose;
  final VoidCallback onRetry;

  const _ReconnectDialog({
    required this.isMosh,
    required this.maxAttempts,
    required this.onReconnectAttempt,
    required this.onConnected,
    required this.onClose,
    required this.onRetry,
  });

  @override
  State<_ReconnectDialog> createState() => _ReconnectDialogState();
}

class _ReconnectDialogState extends State<_ReconnectDialog> {
  _ReconnectPhase _phase = _ReconnectPhase.reconnecting;
  int _currentAttempt = 0;
  String _statusMessage = '正在初始化…';
  int _countdown = 0;
  Timer? _countdownTimer;

  @override
  void initState() {
    super.initState();
    _runReconnectLoop();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  Future<void> _runReconnectLoop() async {
    for (int i = 1; i <= widget.maxAttempts; i++) {
      if (!mounted) return;
      setState(() {
        _currentAttempt = i;
        _statusMessage = '正在连接…';
      });

      final success = await widget.onReconnectAttempt(i, (msg) {
        if (mounted) setState(() => _statusMessage = msg);
      });

      if (!mounted) return;

      if (success) {
        setState(() => _phase = _ReconnectPhase.connected);
        await Future.delayed(const Duration(milliseconds: 1200));
        if (mounted) widget.onConnected();
        return;
      }

      if (i < widget.maxAttempts) {
        final delay = i <= 3 ? 2 : 5;
        _countdown = delay;
        setState(() => _statusMessage = '连接失败');
        _countdownTimer?.cancel();
        _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (!mounted) return;
          _countdown--;
          if (_countdown <= 0) {
            _countdownTimer?.cancel();
          }
          setState(() {});
        });
        await Future.delayed(Duration(seconds: delay));
      }
    }

    if (mounted) {
      setState(() => _phase = _ReconnectPhase.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1A1A1A),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: switch (_phase) {
          _ReconnectPhase.reconnecting => _buildReconnecting(),
          _ReconnectPhase.connected => _buildConnected(),
          _ReconnectPhase.failed => _buildFailed(),
        },
      ),
    );
  }

  Widget _buildReconnecting() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '重新连接中…',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 24),
        const SizedBox(
          width: 48,
          height: 48,
          child: CircularProgressIndicator(
            strokeWidth: 3,
            color: Color(0xFF5AC8FA),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          '第 $_currentAttempt / ${widget.maxAttempts} 次尝试',
          style: const TextStyle(
            fontSize: 14,
            color: Colors.white70,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _statusMessage,
          style: const TextStyle(fontSize: 13, color: Colors.white38),
          textAlign: TextAlign.center,
        ),
        if (_countdown > 0) ...[
          const SizedBox(height: 12),
          Text(
            '$_countdown 秒后重试',
            style: const TextStyle(fontSize: 12, color: Colors.white30),
          ),
        ],
      ],
    );
  }

  Widget _buildConnected() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.check_circle, color: Color(0xFF34C759), size: 56),
        const SizedBox(height: 16),
        const Text(
          '已连接',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFF34C759),
          ),
        ),
      ],
    );
  }

  Widget _buildFailed() {
    final transport = widget.isMosh ? 'Mosh' : 'SSH';
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Color(0xFFFF9F0A), size: 28),
            const SizedBox(width: 8),
            Text(
              '$transport 连接断开',
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '自动重连失败 (${widget.maxAttempts}/${widget.maxAttempts})',
          style: const TextStyle(fontSize: 13, color: Colors.white70),
        ),
        const SizedBox(height: 16),
        const Text(
          '请检查：',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Colors.white70,
          ),
        ),
        const SizedBox(height: 8),
        _checkItem('1. Wi-Fi 或蜂窝网络已开启'),
        _checkItem('2. 服务器可访问'),
        if (widget.isMosh) _checkItem('3. UDP 端口 60000-61000 已开放'),
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: widget.onClose,
              child: const Text('关闭', style: TextStyle(color: Colors.white38)),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: widget.onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5AC8FA),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                elevation: 0,
              ),
              child: const Text('重新连接', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _checkItem(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 4),
      child: Text(text, style: const TextStyle(fontSize: 13, color: Colors.white54)),
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
          widget.session.detachAndRun(cmd);
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
          widget.session.detachAndRun(cmd);
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
    final user = widget.session.profile.username;
    // Match the common home layouts: Linux (/home/<user>, /root for root),
    // and macOS (/Users/<user>). Most SSH servers are Linux, so the old
    // macOS-only assumption never shortened real paths.
    final homes = [
      if (user == 'root') '/root' else '/home/$user',
      '/Users/$user',
    ];
    for (final home in homes) {
      if (_currentPath == home) return '~';
      if (_currentPath.startsWith('$home/')) {
        return '~${_currentPath.substring(home.length)}';
      }
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
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
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
              child: Stack(
                children: [
                  // Keep the current list visible while the next directory
                  // loads (the old _dirs is retained until the new result
                  // arrives) so drilling doesn't flash a full-screen spinner.
                  if (_dirs == null)
                    const Center(
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else if (_dirs!.isEmpty)
                    const Center(
                        child: Text('No subdirectories',
                            style: TextStyle(color: Colors.grey)))
                  else
                    ListView.builder(
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
                  if (_loading && _dirs != null)
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                ],
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
  String? _taskError;

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
    final user = widget.session.profile.username;
    // Match the common home layouts: Linux (/home/<user>, /root for root),
    // and macOS (/Users/<user>). Most SSH servers are Linux, so the old
    // macOS-only assumption never shortened real paths.
    final homes = [
      if (user == 'root') '/root' else '/home/$user',
      '/Users/$user',
    ];
    for (final home in homes) {
      if (_currentPath == home) return '~';
      if (_currentPath.startsWith('$home/')) {
        return '~${_currentPath.substring(home.length)}';
      }
    }
    return _currentPath;
  }

  void _submit() {
    final task = _taskController.text.trim();
    if (task.isEmpty) {
      HapticFeedback.lightImpact();
      setState(() => _taskError = 'Please enter a session name');
      return;
    }
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
              onChanged: (_) {
                if (_taskError != null) setState(() => _taskError = null);
              },
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Session name, e.g. fix-login-bug',
                prefixIcon: const Icon(Icons.label_outline, size: 18),
                border: const OutlineInputBorder(),
                errorText: _taskError,
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
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
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
              child: Stack(
                children: [
                  if (_dirs == null)
                    const Center(
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else if (_dirs!.isEmpty)
                    const Center(
                        child: Text('No subdirectories',
                            style: TextStyle(color: Colors.grey)))
                  else
                    ListView.builder(
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
                  if (_loading && _dirs != null)
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                ],
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

class _GitBranchSheet extends StatefulWidget {
  final TerminalSession session;
  final VoidCallback onDismiss;
  const _GitBranchSheet({required this.session, required this.onDismiss});

  @override
  State<_GitBranchSheet> createState() => _GitBranchSheetState();
}

class _GitBranchSheetState extends State<_GitBranchSheet> {
  List<String> _local = [];
  List<String> _remote = [];
  String _current = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBranches();
  }

  Future<void> _loadBranches() async {
    final result = await widget.session.listGitBranches();
    if (!mounted) return;
    setState(() {
      _local = result.local;
      _remote = result.remote;
      _current = result.current;
      _loading = false;
    });
  }

  void _checkout(String branch) {
    widget.onDismiss();
    widget.session.checkoutBranch(branch);
  }

  void _runGitCommand(String cmd) {
    widget.onDismiss();
    widget.session.sendKey('$cmd\n');
  }

  void _showCommitPrDialog() {
    showDialog(
      context: context,
      builder: (ctx) => _CommitPrDialog(
        session: widget.session,
        onSubmit: (baseBranch) {
          Navigator.pop(ctx);
          widget.onDismiss();
          final script = '''
git add -A && '''
              '''DIFF=\$(git diff --cached --stat 2>/dev/null) && '''
              '''if [ -z "\$DIFF" ]; then echo "No changes to commit"; '''
              '''else '''
              '''MSG=\$(git diff --cached | head -200 | claude -p "Based on this git diff, generate a one-line commit message in conventional commits format (feat:/fix:/refactor:/chore:). Output ONLY the commit message, nothing else." 2>/dev/null) && '''
              '''if [ -z "\$MSG" ]; then MSG="chore: update \$(git diff --cached --stat | tail -1 | xargs)"; fi && '''
              '''git commit -m "\$MSG" && '''
              '''BRANCH=\$(git branch --show-current) && '''
              '''git push -u origin \$BRANCH && '''
              '''gh pr create --base $baseBranch --fill; '''
              '''fi\n''';
          widget.session.sendKey(script);
        },
      ),
    );
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
                const Icon(Icons.account_tree, size: 20),
                const SizedBox(width: 8),
                const Text(
                  'Git Branches',
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
                          _loadBranches();
                        },
                ),
                TextButton(
                  onPressed: widget.onDismiss,
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ActionChip(
                  avatar: const Icon(Icons.download, size: 16),
                  label: const Text('pull'),
                  onPressed: () => _runGitCommand('git pull'),
                ),
                ActionChip(
                  avatar: const Icon(Icons.upload, size: 16),
                  label: const Text('push'),
                  onPressed: () => _runGitCommand('git push'),
                ),
                ActionChip(
                  avatar: const Icon(Icons.info_outline, size: 16),
                  label: const Text('status'),
                  onPressed: () => _runGitCommand('git status'),
                ),
                ActionChip(
                  avatar: const Icon(Icons.history, size: 16),
                  label: const Text('log'),
                  onPressed: () =>
                      _runGitCommand('git log --oneline -20'),
                ),
                ActionChip(
                  avatar: const Icon(Icons.difference, size: 16),
                  label: const Text('diff'),
                  onPressed: () => _runGitCommand('git diff'),
                ),
                ActionChip(
                  avatar: const Icon(Icons.save, size: 16),
                  label: const Text('stash'),
                  onPressed: () => _runGitCommand('git stash'),
                ),
                ActionChip(
                  avatar: const Icon(Icons.restore, size: 16),
                  label: const Text('stash pop'),
                  onPressed: () => _runGitCommand('git stash pop'),
                ),
                ActionChip(
                  avatar: const Icon(Icons.sync, size: 16),
                  label: const Text('fetch'),
                  onPressed: () => _runGitCommand('git fetch --all'),
                ),
                ActionChip(
                  avatar: const Icon(Icons.publish, size: 16),
                  label: const Text('Commit & PR'),
                  onPressed: () => _showCommitPrDialog(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Only blank to the spinner on the first load. On manual refresh the
          // existing branch list stays put (the refresh button greys out as the
          // loading cue), so the sheet doesn't flash empty.
          if (_loading && _local.isEmpty && _remote.isEmpty)
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
                  Text('Loading branches...'),
                ],
              ),
            )
          else if (_local.isEmpty && _remote.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Not a git repository or no branches found'),
            )
          else
            Flexible(
              child: Stack(
                children: [
                  ListView(
                shrinkWrap: true,
                children: [
                  if (_local.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('Local',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ),
                    ..._local.map((branch) => ListTile(
                          dense: true,
                          leading: Icon(
                            branch == _current
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: branch == _current
                                ? Colors.green
                                : Colors.grey,
                            size: 20,
                          ),
                          title: Text(
                            branch,
                            style: TextStyle(
                              fontWeight: branch == _current
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: branch == _current
                                  ? Colors.green
                                  : null,
                            ),
                          ),
                          trailing: branch == _current
                              ? const Chip(
                                  label: Text('current',
                                      style: TextStyle(fontSize: 11)),
                                  visualDensity: VisualDensity.compact,
                                )
                              : const Icon(Icons.chevron_right),
                          onTap: branch == _current
                              ? null
                              : () => _checkout(branch),
                        )),
                  ],
                  if (_remote.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text('Remote',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ),
                    ..._remote.map((branch) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.cloud_outlined,
                              size: 20, color: Colors.grey),
                          title: Text(branch,
                              style: const TextStyle(fontSize: 14)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _checkout(branch),
                        )),
                  ],
                ],
              ),
                  if (_loading)
                    const Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _CommitPrDialog extends StatefulWidget {
  final TerminalSession session;
  final void Function(String baseBranch) onSubmit;
  const _CommitPrDialog({required this.session, required this.onSubmit});

  @override
  State<_CommitPrDialog> createState() => _CommitPrDialogState();
}

class _CommitPrDialogState extends State<_CommitPrDialog> {
  final _baseBranchController = TextEditingController(text: 'main');

  @override
  void dispose() {
    _baseBranchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Commit & Create PR'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This will:\n'
            '1. Stage all changes (git add -A)\n'
            '2. Auto-generate commit message via Claude\n'
            '3. Push to remote\n'
            '4. Create PR via gh',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _baseBranchController,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Target branch',
              hintText: 'main',
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 14),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final base = _baseBranchController.text.trim();
            widget.onSubmit(base.isEmpty ? 'main' : base);
          },
          child: const Text('Create'),
        ),
      ],
    );
  }
}
