import 'dart:async';
import 'dart:typed_data';

enum TransportConnectionState { disconnected, connecting, connected, error }

abstract class TerminalTransport {
  TransportConnectionState get state;
  String? get errorMessage;
  Stream<TransportConnectionState> get stateStream;

  Future<void> connectAndShell({
    required String host,
    required int port,
    required String username,
    required String password,
    int width = 80,
    int height = 24,
  });

  void write(Uint8List data);
  Stream<Uint8List> get outputStream;
  void resizeTerminal(int w, int h);
  Future<int> ping();
  Future<String> runCommand(String command);
  ({int rxSpeed, int txSpeed}) snapshotSpeed();
  void disconnect();
  void dispose();
}
