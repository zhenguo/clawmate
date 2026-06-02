import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../../core/ssh/ssh_service.dart';
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
  bool _ctrlPressed = false;

  bool get ctrlPressed => _ctrlPressed;

  TerminalSession(this.profile)
      : terminal = Terminal(maxLines: 10000),
        ssh = SshService() {
    terminal.onOutput = _onTerminalOutput;
    terminal.onResize = (width, height, _, _) {
      ssh.resizeTerminal(width, height);
    };
  }

  Future<void> connect() async {
    terminal.write('Connecting to ${profile.host}:${profile.port}...\r\n');
    final password = await SecureStorageService.getPassword(profile.id);
    if (password == null || password.isEmpty) {
      terminal.write('Error: password not found. Please edit the connection and re-enter your password.\r\n');
      return;
    }
    try {
      final session = await ssh.connectAndShell(
        host: profile.host,
        port: profile.port,
        username: profile.username,
        password: password,
        width: terminal.viewWidth,
        height: terminal.viewHeight,
      );

      session.stdout.cast<List<int>>().transform(utf8.decoder).listen((data) {
        terminal.write(data);
      });
      session.stderr.cast<List<int>>().transform(utf8.decoder).listen((data) {
        terminal.write(data);
      });
    } on SSHAuthFailError {
      terminal.write('Authentication failed. Please check your password.\r\n');
    } catch (e) {
      terminal.write('Connection failed: $e\r\n');
    }
  }

  void _onTerminalOutput(String data) {
    if (_ctrlPressed && data.length == 1) {
      final code = data.codeUnitAt(0);
      if (code >= 0x61 && code <= 0x7A) {
        ssh.write(utf8.encode(String.fromCharCode(code - 0x60)));
      } else if (code >= 0x41 && code <= 0x5A) {
        ssh.write(utf8.encode(String.fromCharCode(code - 0x40)));
      } else {
        ssh.write(utf8.encode(data));
      }
      _ctrlPressed = false;
      return;
    }
    ssh.write(utf8.encode(data));
  }

  void toggleCtrl() {
    _ctrlPressed = !_ctrlPressed;
  }

  void sendKey(String key) {
    _onTerminalOutput(key);
  }

  void resizeTerminal(int width, int height) {
    ssh.resizeTerminal(width, height);
  }

  Future<List<String>> listTmuxSessions() async {
    try {
      final output = await ssh.runCommand(
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
    ssh.resizeTerminal(terminal.viewWidth, terminal.viewHeight);
    ssh.write(utf8.encode('\x02d'));
    Future.delayed(const Duration(milliseconds: 500), () {
      terminal.write('\x1b[2J\x1b[H');
      ssh.write(utf8.encode(command));
      Future.delayed(const Duration(milliseconds: 800), () {
        ssh.write(utf8.encode('\x0c'));
      });
    });
  }

  void attachTmuxSession(String sessionName) {
    detachAndRun(
        'export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8; tmux set -g mouse on 2>/dev/null; tmux -u attach-session -t $sessionName\n');
  }

  Future<void> killTmuxSession(String sessionName) async {
    try {
      // Kill all sessions in the group
      await ssh.runCommand(
          'export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH" && tmux kill-session -t $sessionName 2>/dev/null');
    } catch (_) {}
  }

  Future<({List<String> local, List<String> remote, String current})>
      listGitBranches() async {
    try {
      final output = await ssh.runCommand(
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
    ssh.write(utf8.encode('git checkout $branchName\n'));
  }

  Future<List<String>> listDirectories(String path) async {
    try {
      final output = await ssh.runCommand(
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

  Future<void> reconnect() async {
    ssh.dispose();
    ssh = SshService();
    terminal.write('\r\nReconnecting...\r\n');
    await connect();
  }

  void dispose() {
    ssh.dispose();
  }
}
