import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

enum SshConnectionState { disconnected, connecting, connected, error }

class SshService {
  SSHClient? _client;
  SSHSession? _session;
  SshConnectionState _state = SshConnectionState.disconnected;
  String? _errorMessage;

  SshConnectionState get state => _state;
  String? get errorMessage => _errorMessage;
  SSHSession? get session => _session;

  final _stateController = StreamController<SshConnectionState>.broadcast();
  Stream<SshConnectionState> get stateStream => _stateController.stream;

  Future<SSHSession> connectAndShell({
    required String host,
    required int port,
    required String username,
    required String password,
    int width = 80,
    int height = 24,
  }) async {
    _setState(SshConnectionState.connecting);
    try {
      final socket = await SSHSocket.connect(host, port,
          timeout: const Duration(seconds: 10));

      _client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => password,
        onUserInfoRequest: (request) =>
            request.prompts.map((_) => password).toList(),
      );

      await _client!.authenticated.timeout(const Duration(seconds: 15));

      _session = await _client!.shell(
        pty: SSHPtyConfig(width: width, height: height),
      ).timeout(const Duration(seconds: 10));

      _setState(SshConnectionState.connected);

      _session!.done.then((_) {
        _setState(SshConnectionState.disconnected);
      });

      return _session!;
    } on SSHAuthFailError {
      _errorMessage = 'Authentication failed. Please check your password.';
      _setState(SshConnectionState.error);
      _client?.close();
      _client = null;
      rethrow;
    } on TimeoutException {
      _errorMessage = 'Connection timed out to $host:$port';
      _setState(SshConnectionState.error);
      _client?.close();
      _client = null;
      rethrow;
    } catch (e) {
      _errorMessage = '$e (host: $host:$port)';
      _setState(SshConnectionState.error);
      _client?.close();
      _client = null;
      rethrow;
    }
  }

  void resizeTerminal(int width, int height) {
    _session?.resizeTerminal(width, height);
  }

  Future<String> runCommand(String command) async {
    final result = await _client!.run(command);
    return utf8.decode(result);
  }

  void write(Uint8List data) {
    _session?.stdin.add(data);
  }

  void disconnect() {
    _session?.close();
    _client?.close();
    _session = null;
    _client = null;
    _setState(SshConnectionState.disconnected);
  }

  void _setState(SshConnectionState s) {
    _state = s;
    if (!_stateController.isClosed) {
      _stateController.add(s);
    }
  }

  void dispose() {
    _session?.close();
    _client?.close();
    _session = null;
    _client = null;
    _stateController.close();
  }
}
