import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:ffi/ffi.dart';

import 'mosh_ffi_bindings.dart';

enum MoshConnectionState { disconnected, connecting, connected, error }

class MoshService {
  Pointer<Void>? _client;
  MoshConnectionState _state = MoshConnectionState.disconnected;
  String? _errorMessage;
  Timer? _pollTimer;
  SSHClient? _bootstrapSshClient;

  int _bytesIn = 0;
  int _bytesOut = 0;
  int _lastBytesIn = 0;
  int _lastBytesOut = 0;

  final Pointer<Uint8> _recvBuf = calloc<Uint8>(65536);

  MoshConnectionState get state => _state;
  String? get errorMessage => _errorMessage;
  int get bytesIn => _bytesIn;
  int get bytesOut => _bytesOut;

  ({int rxSpeed, int txSpeed}) snapshotSpeed() {
    final rx = _bytesIn - _lastBytesIn;
    final tx = _bytesOut - _lastBytesOut;
    _lastBytesIn = _bytesIn;
    _lastBytesOut = _bytesOut;
    return (rxSpeed: rx, txSpeed: tx);
  }

  final _stateController = StreamController<MoshConnectionState>.broadcast();
  Stream<MoshConnectionState> get stateStream => _stateController.stream;

  final _outputController = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get outputStream => _outputController.stream;

  Future<void> connectAndShell({
    required String host,
    required int port,
    required String username,
    required String password,
    int width = 80,
    int height = 24,
    void Function(int step, int total, String message)? onProgress,
  }) async {
    _setState(MoshConnectionState.connecting);

    void progress(int step, int total, String msg) {
      onProgress?.call(step, total, msg);
    }

    try {
      // Step 1: SSH bootstrap — start mosh-server on remote
      progress(1, 6, 'Establishing SSH tunnel to $host:$port...');
      final rawSocket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 10));
      rawSocket.setOption(SocketOption.tcpNoDelay, true);
      final socket = _NoDelaySSHSocket(rawSocket);

      _bootstrapSshClient = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => password,
        onUserInfoRequest: (request) =>
            request.prompts.map((_) => password).toList(),
      );

      progress(2, 6, 'Authenticating as $username...');
      await _bootstrapSshClient!.authenticated
          .timeout(const Duration(seconds: 15));

      // Step 2: Run mosh-server
      progress(3, 6, 'Starting mosh-server on remote host...');
      final result = await _bootstrapSshClient!
          .run('export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH" && mosh-server new -s -c 256 -l LANG=en_US.UTF-8')
          .timeout(const Duration(seconds: 10));
      final output = utf8.decode(result);

      // Parse: MOSH CONNECT <port> <key>
      final match =
          RegExp(r'MOSH CONNECT (\d+) (\S+)').firstMatch(output);
      if (match == null) {
        if (output.contains('command not found') ||
            output.contains('not found') ||
            output.contains('No such file')) {
          throw Exception(
              'mosh-server is not installed on the remote host.\n'
              'Please install it:\n'
              '  Ubuntu/Debian: sudo apt install mosh\n'
              '  CentOS/RHEL:   sudo yum install mosh\n'
              '  macOS:         brew install mosh');
        }
        throw Exception(
            'Failed to start mosh-server: $output');
      }
      final udpPort = int.parse(match.group(1)!);
      final aesKey = match.group(2)!;

      // Step 3: Close SSH bootstrap connection
      progress(4, 6, 'Got mosh key, closing SSH tunnel...');
      _bootstrapSshClient!.close();
      _bootstrapSshClient = null;

      // Step 4: Create mosh client via FFI
      progress(5, 6, 'Connecting UDP to $host:$udpPort...');
      final hostPtr = host.toNativeUtf8();
      final keyPtr = aesKey.toNativeUtf8();
      _client = MoshFfiBindings.moshClientCreate(
          hostPtr, udpPort, keyPtr, width, height);
      calloc.free(hostPtr);
      calloc.free(keyPtr);

      if (_client == null || _client == nullptr) {
        throw Exception('Failed to create mosh client');
      }

      // Step 5: Start network thread
      final ret = MoshFfiBindings.moshClientStart(_client!);
      if (ret != 0) {
        throw Exception('Failed to start mosh client');
      }

      _setState(MoshConnectionState.connected);
      progress(6, 6, 'Connected via Mosh (UDP)');

      // Step 6: Start polling for output
      _pollTimer = Timer.periodic(
          const Duration(milliseconds: 32), _pollOutput);
    } catch (e) {
      _errorMessage = '$e';
      _setState(MoshConnectionState.error);
      _cleanup();
      rethrow;
    }
  }

  void _pollOutput(Timer timer) {
    if (_client == null) return;

    final n = MoshFfiBindings.moshClientReceiveOutput(
        _client!, _recvBuf, 65536);

    if (n > 0) {
      final data = Uint8List(n);
      for (int i = 0; i < n; i++) {
        data[i] = _recvBuf[i];
      }
      _bytesIn += n;
      _outputController.add(data);
    } else if (n < 0) {
      _setState(MoshConnectionState.disconnected);
      _pollTimer?.cancel();
    }

    // Update connection state from native
    final nativeState =
        MoshFfiBindings.moshClientGetState(_client!);
    if (nativeState == 2) {
      _setState(MoshConnectionState.disconnected);
      _pollTimer?.cancel();
    } else if (nativeState == 3) {
      _setState(MoshConnectionState.error);
      _pollTimer?.cancel();
    }
  }

  void write(Uint8List data) {
    if (_client == null) return;
    _bytesOut += data.length;
    final buf = calloc<Uint8>(data.length);
    for (int i = 0; i < data.length; i++) {
      buf[i] = data[i];
    }
    MoshFfiBindings.moshClientSendInput(_client!, buf, data.length);
    calloc.free(buf);
  }

  void resizeTerminal(int width, int height) {
    if (_client == null) return;
    MoshFfiBindings.moshClientResize(_client!, width, height);
  }

  Future<int> ping() async {
    if (_client == null) return -1;
    return MoshFfiBindings.moshClientGetRtt(_client!);
  }

  void disconnect() {
    if (_client != null) {
      MoshFfiBindings.moshClientStop(_client!);
    }
    _cleanup();
    _setState(MoshConnectionState.disconnected);
  }

  void _cleanup() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _bootstrapSshClient?.close();
    _bootstrapSshClient = null;
    if (_client != null && _client != nullptr) {
      MoshFfiBindings.moshClientDestroy(_client!);
      _client = null;
    }
  }

  void _setState(MoshConnectionState s) {
    _state = s;
    if (!_stateController.isClosed) {
      _stateController.add(s);
    }
  }

  void dispose() {
    _cleanup();
    calloc.free(_recvBuf);
    _stateController.close();
    _outputController.close();
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
