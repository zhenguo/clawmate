import 'dart:async';
import 'dart:typed_data';

import '../mosh/mosh_service.dart';
import '../ssh/ssh_service.dart';
import 'terminal_transport.dart';

class MoshTransport implements TerminalTransport {
  final MoshService _mosh = MoshService();
  SshService? _helperSsh;
  String? _host;
  int? _port;
  String? _username;
  String? _password;

  @override
  TransportConnectionState get state {
    switch (_mosh.state) {
      case MoshConnectionState.disconnected:
        return TransportConnectionState.disconnected;
      case MoshConnectionState.connecting:
        return TransportConnectionState.connecting;
      case MoshConnectionState.connected:
        return TransportConnectionState.connected;
      case MoshConnectionState.error:
        return TransportConnectionState.error;
    }
  }

  @override
  String? get errorMessage => _mosh.errorMessage;

  @override
  Stream<TransportConnectionState> get stateStream =>
      _mosh.stateStream.map((s) {
        switch (s) {
          case MoshConnectionState.disconnected:
            return TransportConnectionState.disconnected;
          case MoshConnectionState.connecting:
            return TransportConnectionState.connecting;
          case MoshConnectionState.connected:
            return TransportConnectionState.connected;
          case MoshConnectionState.error:
            return TransportConnectionState.error;
        }
      });

  @override
  Stream<Uint8List> get outputStream => _mosh.outputStream;

  @override
  Future<void> connectAndShell({
    required String host,
    required int port,
    required String username,
    required String password,
    int width = 80,
    int height = 24,
  }) async {
    _host = host;
    _port = port;
    _username = username;
    _password = password;

    await _mosh.connectAndShell(
      host: host,
      port: port,
      username: username,
      password: password,
      width: width,
      height: height,
    );
  }

  @override
  void write(Uint8List data) => _mosh.write(data);

  @override
  void resizeTerminal(int w, int h) => _mosh.resizeTerminal(w, h);

  @override
  Future<int> ping() => _mosh.ping();

  @override
  Future<String> runCommand(String command) async {
    _helperSsh ??= SshService();
    if (_helperSsh!.state != SshConnectionState.connected) {
      await _helperSsh!.connectAndShell(
        host: _host!,
        port: _port!,
        username: _username!,
        password: _password!,
      );
    }
    return _helperSsh!.runCommand(command);
  }

  @override
  ({int rxSpeed, int txSpeed}) snapshotSpeed() => _mosh.snapshotSpeed();

  @override
  void disconnect() {
    _mosh.disconnect();
    _helperSsh?.disconnect();
  }

  @override
  void dispose() {
    _mosh.dispose();
    _helperSsh?.dispose();
  }
}
