import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/ssh/ssh_service.dart';
import '../../../core/mosh/mosh_service.dart';
import '../../../core/storage/secure_storage_service.dart';
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
  bool _ctrlPressed = false;

  final StringBuffer _outputBuffer = StringBuffer();
  Timer? _flushTimer;
  StreamSubscription? _transportStateSub;

  final _connectionStateController = StreamController<SshConnectionState>.broadcast();

  final List<String> scrollBackLines = [];
  static const _maxScrollBackLines = 5000;

  bool get ctrlPressed => _ctrlPressed;
  bool get _isMosh => profile.transportType == TransportType.mosh;

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
      : terminal = Terminal(maxLines: 10000),
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

  Future<void> connect() async {
    final label = _isMosh ? 'Mosh' : 'SSH';
    terminal.write('Connecting via $label to ${profile.host}:${profile.port}...\r\n');
    final password = await SecureStorageService.getPassword(profile.id);
    if (password == null || password.isEmpty) {
      terminal.write('Error: password not found. Please edit the connection and re-enter your password.\r\n');
      return;
    }

    if (_isMosh) {
      await _connectMosh(password);
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

      session.stdout.cast<List<int>>().listen((data) {
        ssh.addBytesIn(data.length);
        _bufferOutput(utf8.decode(data, allowMalformed: true));
      });
      session.stderr.cast<List<int>>().listen((data) {
        ssh.addBytesIn(data.length);
        _bufferOutput(utf8.decode(data, allowMalformed: true));
      });
    } on SSHAuthFailError {
      terminal.write('Authentication failed. Please check your password.\r\n');
    } catch (e) {
      terminal.write('Connection failed: $e\r\n');
    }
  }

  Future<void> _connectMosh(String password) async {
    try {
      _mosh = MoshService();
      _transportStateSub?.cancel();
      _transportStateSub = _mosh!.stateStream.listen(
          (s) => _connectionStateController.add(_mapMoshState(s)));
      _mosh!.outputStream.listen((data) {
        _bufferOutput(utf8.decode(data, allowMalformed: true));
      });
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
        },
      );
    } catch (e) {
      terminal.write('\r\x1b[31mMosh connection failed: $e\x1b[0m\r\n');
    }
  }

  void _bufferOutput(String data) {
    _outputBuffer.write(data);
    _flushTimer ??= Timer(const Duration(milliseconds: 32), _flushOutput);
  }

  void _flushOutput() {
    _flushTimer = null;
    if (_outputBuffer.isNotEmpty) {
      final text = _outputBuffer.toString();
      _outputBuffer.clear();
      terminal.write(text);
      _captureScrollBack();
    }
  }

  void _captureScrollBack() {
    final buffer = terminal.buffer;
    final viewH = terminal.viewHeight;
    final scrollBack = buffer.height - viewH;
    for (var i = 0; i < viewH; i++) {
      final line = buffer.lines[i + scrollBack].toString().trimRight();
      if (scrollBackLines.isEmpty || scrollBackLines.last != line || line.isEmpty) {
        scrollBackLines.add(line);
      }
    }
    if (scrollBackLines.length > _maxScrollBackLines) {
      scrollBackLines.removeRange(0, scrollBackLines.length - _maxScrollBackLines);
    }
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
    if (_ctrlPressed && data.length == 1) {
      final code = data.codeUnitAt(0);
      if (code >= 0x61 && code <= 0x7A) {
        _write(String.fromCharCode(code - 0x60));
      } else if (code >= 0x41 && code <= 0x5A) {
        _write(String.fromCharCode(code - 0x40));
      } else {
        _write(data);
      }
      _ctrlPressed = false;
      return;
    }
    _write(data);
  }

  void toggleCtrl() {
    _ctrlPressed = !_ctrlPressed;
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

  void detachAndRun(String command) {
    resizeTerminal(terminal.viewWidth, terminal.viewHeight);
    _write('\x02d');
    Future.delayed(const Duration(milliseconds: 500), () {
      terminal.write('\x1b[2J\x1b[H');
      _write(command);
      Future.delayed(const Duration(milliseconds: 800), () {
        _write('\x0c');
      });
    });
  }

  void attachTmuxSession(String sessionName) {
    detachAndRun(
        'export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; tmux set -g mouse on 2>/dev/null; tmux -u attach-session -t $sessionName\n');
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
      _mosh?.dispose();
      _mosh = null;
      _helperSsh?.dispose();
      _helperSsh = null;
    } else {
      ssh.dispose();
      ssh = SshService();
      _transportStateSub = ssh.stateStream.listen(
          (s) => _connectionStateController.add(s));
    }
  }

  Future<void> reconnect() async {
    resetTransport();
    terminal.write('\r\nReconnecting...\r\n');
    await connect();
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
    _transportStateSub?.cancel();
    _connectionStateController.close();
    ssh.dispose();
    _mosh?.dispose();
    _helperSsh?.dispose();
  }
}
