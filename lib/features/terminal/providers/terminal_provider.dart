import 'dart:async';
import 'dart:convert';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/ssh/ssh_service.dart';
import '../../../core/mosh/mosh_service.dart';
import '../../../core/storage/secure_storage_service.dart';
import '../../../core/widgets/widget_data_service.dart';
import '../../connections/models/connection_profile.dart';

final terminalProvider = Provider.autoDispose
    .family<TerminalSession, ConnectionProfile>((ref, profile) {
  final session = TerminalSession(profile);
  ref.onDispose(session.dispose);
  return session;
});

class TerminalSession {
  final ConnectionProfile profile;
  final Terminal terminal;
  SshService ssh;
  MoshService? _mosh;
  SshService? _helperSsh;
  final ValueNotifier<bool> ctrlNotifier = ValueNotifier(false);
  final ValueNotifier<bool> altNotifier = ValueNotifier(false);
  String? _lastTmuxSession;
  final ValueNotifier<bool> inTmuxSession = ValueNotifier(false);

  final StringBuffer _outputBuffer = StringBuffer();
  Timer? _flushTimer;
  int _lastScrollBackMs = 0;
  String? _lastCapturedScreenSig;
  Timer? _widgetPreviewTimer;
  Timer? _serverStatsTimer;
  StreamSubscription? _transportStateSub;

  final _connectionStateController = StreamController<SshConnectionState>.broadcast();
  final _outputController = StreamController<void>.broadcast();

  Stream<void> get outputStream => _outputController.stream;

  final List<String> scrollBackLines = [];
  static const _maxScrollBackLines = 5000;

  bool get ctrlPressed => ctrlNotifier.value;
  bool get _isMosh => profile.transportType == TransportType.mosh;
  String? get lastTmuxSession => _lastTmuxSession;

  bool get isConnected {
    if (_isMosh) return _mosh?.state == MoshConnectionState.connected;
    return ssh.state == SshConnectionState.connected;
  }

  SshConnectionState get connectionState {
    if (_isMosh) return _mapMoshState(_mosh?.state ?? MoshConnectionState.disconnected);
    return ssh.state;
  }

  Stream<SshConnectionState> get connectionStateStream => _connectionStateController.stream;

  Future<int> ping() async {
    if (_isMosh) return await _mosh?.ping() ?? -1;
    return await ssh.ping();
  }

  ({int rxSpeed, int txSpeed}) snapshotSpeed() {
    if (_isMosh) return _mosh?.snapshotSpeed() ?? (rxSpeed: 0, txSpeed: 0);
    return ssh.snapshotSpeed();
  }

  static SshConnectionState _mapMoshState(MoshConnectionState s) {
    switch (s) {
      case MoshConnectionState.disconnected: return SshConnectionState.disconnected;
      case MoshConnectionState.connecting: return SshConnectionState.connecting;
      case MoshConnectionState.connected: return SshConnectionState.connected;
      case MoshConnectionState.error: return SshConnectionState.error;
    }
  }

  TerminalSession(this.profile)
      : terminal = Terminal(maxLines: 100000),
        ssh = SshService() {
    terminal.onOutput = _onTerminalOutput;
    terminal.onResize = (width, height, _, _) {
      if (_isMosh) {
        _mosh?.resizeTerminal(width, height);
      } else {
        ssh.resizeTerminal(width, height);
      }
    };
    if (!_isMosh) {
      _transportStateSub = ssh.stateStream.listen(
          (s) => _connectionStateController.add(s));
    }
  }

  Future<void> connect({
    void Function(String message)? onProgress,
  }) async {
    final label = _isMosh ? 'Mosh' : 'SSH';
    terminal.write('Connecting via $label to ${profile.host}:${profile.port}...\r\n');
    final password = await SecureStorageService.getPassword(profile.id);
    if (password == null || password.isEmpty) {
      terminal.write('Error: password not found. Please edit the connection and re-enter your password.\r\n');
      return;
    }

    if (_isMosh) {
      await _connectMosh(password, onProgress: onProgress);
    } else {
      await _connectSsh(password);
    }
  }

  Future<void> _connectSsh(String password) async {
    try {
      final session = await ssh.connectAndShell(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        password: password,
        width: terminal.viewWidth,
        height: terminal.viewHeight,
      );

      // Decode through a stateful streaming decoder, not per-fragment: a
      // multi-byte UTF-8 char (CJK, emoji) split across TCP packets would
      // otherwise turn both halves into  garbage. The chunked decoder holds
      // the incomplete trailing bytes until the next fragment completes them.
      // stdout/stderr get independent decoders so their partial-byte state
      // never cross-contaminates.
      session.stdout
          .cast<List<int>>()
          .map((data) {
            ssh.addBytesIn(data.length);
            return data;
          })
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_bufferOutput);
      session.stderr
          .cast<List<int>>()
          .map((data) {
            ssh.addBytesIn(data.length);
            return data;
          })
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_bufferOutput);
      // Layout's onResize may have fired before the channel was open and
      // become a no-op. Resend the current dimensions so the remote PTY
      // matches the visible viewport.
      ssh.resizeTerminal(terminal.viewWidth, terminal.viewHeight);
      _startWidgetTimers();
    } on SSHAuthFailError {
      terminal.write('Authentication failed. Please check your password.\r\n');
    } catch (e) {
      terminal.write('Connection failed: $e\r\n');
    }
  }

  Future<void> _connectMosh(String password, {
    void Function(String message)? onProgress,
  }) async {
    try {
      _mosh = MoshService();
      _transportStateSub?.cancel();
      _transportStateSub = _mosh!.stateStream.listen(
          (s) => _connectionStateController.add(_mapMoshState(s)));
      _mosh!.outputStream
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_bufferOutput);
      await _mosh!.connectAndShell(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        password: password,
        width: terminal.viewWidth,
        height: terminal.viewHeight,
        onProgress: (step, total, message) {
          final bar = '[${'=' * step}${' ' * (total - step)}]';
          terminal.write('\r\x1b[K  $bar $message\r\n');
          onProgress?.call(message);
        },
      );
      // Layout's onResize may have fired before the mosh client was created
      // and become a no-op. Resend the current dimensions so the remote PTY
      // matches the visible viewport.
      _mosh!.resizeTerminal(terminal.viewWidth, terminal.viewHeight);
      _startWidgetTimers();
    } catch (e) {
      terminal.write('\r\x1b[31mMosh connection failed: $e\x1b[0m\r\n');
    }
  }

  void _bufferOutput(String data) {
    _outputBuffer.write(data);
    // Large bursts (TUI redraws, cat, log scroll) coalesce on a ~60fps budget
    // to avoid per-fragment re-layout thrash. Small interactive echo flushes on
    // the next event-loop turn so each keystroke appears with no batching tax.
    if (_outputBuffer.length > 256) {
      _flushTimer ??= Timer(const Duration(milliseconds: 16), _flushOutput);
    } else {
      _flushTimer ??= Timer(Duration.zero, _flushOutput);
    }
  }

  void _flushOutput() {
    _flushTimer = null;
    if (_outputBuffer.isNotEmpty) {
      final text = _outputBuffer.toString();
      _outputBuffer.clear();
      terminal.write(text);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastScrollBackMs >= 200) {
        _lastScrollBackMs = now;
        _captureScrollBack();
      }
      _outputController.add(null);
    }
  }

  void _captureScrollBack() {
    final buffer = terminal.buffer;
    final viewH = terminal.viewHeight;
    final scrollBack = buffer.height - viewH;
    final screen = <String>[];
    for (var i = 0; i < viewH; i++) {
      screen.add(buffer.lines[i + scrollBack].toString().trimRight());
    }
    // Skip when the visible screen is byte-identical to the last capture —
    // a redrawing TUI (htop/vim) would otherwise flood scrollBackLines with
    // thousands of duplicate full-screen snapshots.
    final sig = screen.join('\n');
    if (sig == _lastCapturedScreenSig) return;
    _lastCapturedScreenSig = sig;
    for (final line in screen) {
      if (scrollBackLines.isEmpty || scrollBackLines.last != line || line.isEmpty) {
        scrollBackLines.add(line);
      }
    }
    if (scrollBackLines.length > _maxScrollBackLines) {
      scrollBackLines.removeRange(0, scrollBackLines.length - _maxScrollBackLines);
    }
  }

  void _startWidgetTimers() {
    _widgetPreviewTimer?.cancel();
    _widgetPreviewTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!isConnected || scrollBackLines.isEmpty) return;
      WidgetDataService().updateTerminalPreview(
        profile.id,
        profile.name,
        scrollBackLines,
      );
    });
    _serverStatsTimer?.cancel();
    _serverStatsTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!isConnected) return;
      _collectServerStats();
    });
  }

  void _stopWidgetTimers() {
    _widgetPreviewTimer?.cancel();
    _widgetPreviewTimer = null;
    _serverStatsTimer?.cancel();
    _serverStatsTimer = null;
    WidgetDataService().clearActiveSession();
  }

  Future<void> _collectServerStats() async {
    try {
      final output = await _runCommand(
        r"top -bn1 2>/dev/null | grep '%Cpu' | head -1; free -m 2>/dev/null | grep 'Mem:' | head -1",
      );
      double cpu = 0;
      double mem = 0;
      for (final line in output.split('\n')) {
        if (line.contains('%Cpu') || line.contains('Cpu(s)')) {
          final idle = RegExp(r'(\d+\.?\d*)\s*(id|idle)').firstMatch(line);
          if (idle != null) {
            cpu = 100.0 - (double.tryParse(idle.group(1)!) ?? 0);
          }
        } else if (line.contains('Mem:')) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length >= 3) {
            final total = double.tryParse(parts[1]) ?? 1;
            final used = double.tryParse(parts[2]) ?? 0;
            mem = total > 0 ? (used / total * 100) : 0;
          }
        }
      }
      WidgetDataService().updateServerStats(
        profile.id,
        profile.host,
        cpuPercent: cpu,
        memPercent: mem,
      );
    } catch (_) {}
  }

  void _write(String data) {
    final bytes = utf8.encode(data);
    if (_isMosh) {
      _mosh?.write(Uint8List.fromList(bytes));
    } else {
      ssh.write(bytes);
    }
  }

  void _onTerminalOutput(String data) {
    final ctrl = ctrlNotifier.value;
    final alt = altNotifier.value;
    if (!ctrl && !alt) {
      _write(data);
      return;
    }
    if (ctrl) ctrlNotifier.value = false;
    if (alt) altNotifier.value = false;

    // Arrows carry an xterm modifier param: 1 + alt(2) + ctrl(4).
    const arrowFinal = {'\x1b[A': 'A', '\x1b[B': 'B', '\x1b[C': 'C', '\x1b[D': 'D'};
    final arrow = arrowFinal[data];
    if (arrow != null) {
      final mod = 1 + (alt ? 2 : 0) + (ctrl ? 4 : 0);
      _write('\x1b[1;$mod$arrow');
      return;
    }

    String out = data;
    if (ctrl && data.length == 1) {
      final code = data.codeUnitAt(0);
      if (code >= 0x61 && code <= 0x7A) {
        out = String.fromCharCode(code - 0x60);
      } else if (code >= 0x41 && code <= 0x5A) {
        out = String.fromCharCode(code - 0x40);
      }
    }
    if (alt) {
      // Meta/Alt is encoded as an ESC prefix.
      out = '\x1b$out';
    }
    _write(out);
  }

  void toggleCtrl() {
    ctrlNotifier.value = !ctrlNotifier.value;
  }

  void toggleAlt() {
    altNotifier.value = !altNotifier.value;
  }

  void sendKey(String key) {
    _onTerminalOutput(key);
  }

  void resizeTerminal(int width, int height) {
    if (_isMosh) {
      _mosh?.resizeTerminal(width, height);
    } else {
      ssh.resizeTerminal(width, height);
    }
  }

  Future<void> _ensureHelperSsh() async {
    if (_helperSsh != null && _helperSsh!.state == SshConnectionState.connected) return;
    _helperSsh?.dispose();
    _helperSsh = SshService();
    final password = await SecureStorageService.getPassword(profile.id);
    if (password == null || password.isEmpty) throw Exception('No password');
    await _helperSsh!.connectAndShell(
      host: profile.host,
      port: profile.port,
      username: profile.username,
      password: password,
    );
  }

  Future<String> _runCommand(String command) async {
    if (_isMosh) {
      await _ensureHelperSsh();
      return await _helperSsh!.runCommand(command);
    }
    return await ssh.runCommand(command);
  }

  Future<List<String>> listTmuxSessions() async {
    try {
      final output = await _runCommand(
          r'''export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" && tmux ls -F '#{session_name}' 2>/dev/null''');
      return output
          .trim()
          .split('\n')
          .where((name) => name.isNotEmpty && name != 'clawmate-app')
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<String> captureTmuxScrollback({int lines = 10000}) async {
    final session = _lastTmuxSession;
    if (session == null || !isConnected) return '';
    if (!RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(session)) return '';
    try {
      return await _runCommand(
        'export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH" && '
        'tmux capture-pane -t $session -e -p -S -$lines 2>/dev/null',
      );
    } catch (_) {
      return '';
    }
  }

  void detachAndRun(String command) {
    inTmuxSession.value = false;
    resizeTerminal(terminal.viewWidth, terminal.viewHeight);
    _write('\x02d');
    Future.delayed(const Duration(milliseconds: 800), () {
      _write(command);
      inTmuxSession.value = true;
    });
  }

  Future<void> attachTmuxSession(String sessionName) async {
    _lastTmuxSession = sessionName;
    inTmuxSession.value = false;
    resizeTerminal(terminal.viewWidth, terminal.viewHeight);
    _write('\x02d');
    await Future.delayed(const Duration(milliseconds: 800));
    _write('export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; tmux set -g mouse on 2>/dev/null; tmux -u attach-session -t $sessionName\n');
    inTmuxSession.value = true;
  }

  Future<void> killTmuxSession(String sessionName) async {
    try {
      await _runCommand(
          'export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH" && tmux kill-session -t $sessionName 2>/dev/null');
    } catch (_) {}
  }

  Future<({List<String> local, List<String> remote, String current})>
      listGitBranches() async {
    try {
      final output = await _runCommand(
          'git branch -a --no-color 2>/dev/null');
      final lines = output.trim().split('\n').where((l) => l.isNotEmpty);
      final local = <String>[];
      final remote = <String>[];
      var current = '';
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.contains(' -> ')) continue;
        if (trimmed.startsWith('* ')) {
          final name = trimmed.substring(2);
          current = name;
          local.add(name);
        } else if (trimmed.startsWith('remotes/')) {
          remote.add(trimmed.replaceFirst('remotes/', ''));
        } else {
          local.add(trimmed);
        }
      }
      return (local: local, remote: remote, current: current);
    } catch (_) {
      return (local: <String>[], remote: <String>[], current: '');
    }
  }

  void checkoutBranch(String branch) {
    final branchName =
        branch.startsWith('origin/') ? branch.substring(7) : branch;
    _write('git checkout $branchName\n');
  }

  Future<List<String>> listDirectories(String path) async {
    try {
      final output = await _runCommand(
          'ls -1d ${path.replaceAll("'", "'\\''")}'
          '/*/ 2>/dev/null | head -50');
      return output
          .trim()
          .split('\n')
          .where((l) => l.isNotEmpty)
          .map((l) {
            var p = l;
            while (p.endsWith('/')) {
              p = p.substring(0, p.length - 1);
            }
            return p;
          })
          .where((l) => l.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  void resetTransport() {
    _transportStateSub?.cancel();
    if (_isMosh) {
      try { _mosh?.dispose(); } catch (_) {}
      _mosh = null;
      try { _helperSsh?.dispose(); } catch (_) {}
      _helperSsh = null;
    } else {
      try { ssh.dispose(); } catch (_) {}
      ssh = SshService();
      _transportStateSub = ssh.stateStream.listen(
          (s) => _connectionStateController.add(s));
    }
  }

  Future<void> reconnect({
    void Function(String message)? onProgress,
  }) async {
    final previousTmux = _lastTmuxSession;
    resetTransport();
    onProgress?.call('Initializing...');
    await connect(onProgress: onProgress);
    if (isConnected && previousTmux != null) {
      onProgress?.call('Re-attaching tmux: $previousTmux...');
      await Future.delayed(const Duration(milliseconds: 800));
      final sessions = await listTmuxSessions();
      if (sessions.contains(previousTmux)) {
        _lastTmuxSession = previousTmux;
        _write('export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; tmux set -g mouse on 2>/dev/null; tmux -u attach-session -t $previousTmux\n');
      }
    }
  }

  void disconnect() {
    if (_isMosh) {
      _mosh?.disconnect();
    } else {
      ssh.disconnect();
    }
  }

  void dispose() {
    _flushTimer?.cancel();
    _stopWidgetTimers();
    _transportStateSub?.cancel();
    _connectionStateController.close();
    _outputController.close();
    ctrlNotifier.dispose();
    altNotifier.dispose();
    inTmuxSession.dispose();
    ssh.dispose();
    _mosh?.dispose();
    _helperSsh?.dispose();
  }
}
