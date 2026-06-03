import 'dart:async';
import 'dart:typed_data';

import '../ssh/ssh_service.dart';
import 'terminal_transport.dart';

class SshTransport implements TerminalTransport {
  final SshService _ssh = SshService();
  final _outputController = StreamController<Uint8List>.broadcast();

  @override
  TransportConnectionState get state {
    switch (_ssh.state) {
      case SshConnectionState.disconnected:
        return TransportConnectionState.disconnected;
      case SshConnectionState.connecting:
        return TransportConnectionState.connecting;
      case SshConnectionState.connected:
        return TransportConnectionState.connected;
      case SshConnectionState.error:
        return TransportConnectionState.error;
    }
  }

  @override
  String? get errorMessage => _ssh.errorMessage;

  @override
  Stream<TransportConnectionState> get stateStream =>
      _ssh.stateStream.map((s) {
        switch (s) {
          case SshConnectionState.disconnected:
            return TransportConnectionState.disconnected;
          case SshConnectionState.connecting:
            return TransportConnectionState.connecting;
          case SshConnectionState.connected:
            return TransportConnectionState.connected;
          case SshConnectionState.error:
            return TransportConnectionState.error;
        }
      });

  @override
  Stream<Uint8List> get outputStream => _outputController.stream;

  @override
  Future<void> connectAndShell({
    required String host,
    required int port,
    required String username,
    required String password,
    int width = 80,
    int height = 24,
  }) async {
    final session = await _ssh.connectAndShell(
      host: host,
      port: port,
      username: username,
      password: password,
      width: width,
      height: height,
    );

    session.stdout.listen((data) {
      _ssh.addBytesIn(data.length);
      _outputController.add(data);
    });
    session.stderr.listen((data) {
      _ssh.addBytesIn(data.length);
      _outputController.add(data);
    });
  }

  @override
  void write(Uint8List data) => _ssh.write(data);

  @override
  void resizeTerminal(int w, int h) => _ssh.resizeTerminal(w, h);

  @override
  Future<int> ping() => _ssh.ping();

  @override
  Future<String> runCommand(String command) => _ssh.runCommand(command);

  @override
  ({int rxSpeed, int txSpeed}) snapshotSpeed() => _ssh.snapshotSpeed();

  @override
  void disconnect() => _ssh.disconnect();

  @override
  void dispose() {
    _ssh.dispose();
    _outputController.close();
  }
}
