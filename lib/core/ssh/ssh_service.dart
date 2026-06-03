import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

enum SshConnectionState { disconnected, connecting, connected, error }

class SshService {
  SSHClient? _client;
  SSHSession? _session;
  SshConnectionState _state = SshConnectionState.disconnected;
  String? _errorMessage;

  int _bytesIn = 0;
  int _bytesOut = 0;
  int _lastBytesIn = 0;
  int _lastBytesOut = 0;

  SshConnectionState get state => _state;
  String? get errorMessage => _errorMessage;
  SSHSession? get session => _session;
  int get bytesIn => _bytesIn;
  int get bytesOut => _bytesOut;

  ({int rxSpeed, int txSpeed}) snapshotSpeed() {
    final rx = _bytesIn - _lastBytesIn;
    final tx = _bytesOut - _lastBytesOut;
    _lastBytesIn = _bytesIn;
    _lastBytesOut = _bytesOut;
    return (rxSpeed: rx, txSpeed: tx);
  }

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
      final rawSocket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 10));
      rawSocket.setOption(SocketOption.tcpNoDelay, true);
      final socket = _NoDelaySSHSocket(rawSocket);

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

  Future<int> ping() async {
    if (_client == null) return -1;
    try {
      final sw = Stopwatch()..start();
      await _client!.ping();
      sw.stop();
      return sw.elapsedMilliseconds;
    } catch (_) {
      return -1;
    }
  }

  void addBytesIn(int count) {
    _bytesIn += count;
  }

  void write(Uint8List data) {
    _bytesOut += data.length;
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

class _NoDelaySSHSocket implements SSHSocket {
  final Socket _socket;

  _NoDelaySSHSocket(this._socket);

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> close() async {
    await _socket.close();
  }

  @override
  Future<void> get done => _socket.done;

  @override
  void destroy() {
    _socket.destroy();
  }
}
