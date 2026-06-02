import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';

void main() async {
  final password = Platform.environment['TEST_PWD'] ?? '';
  final host = Platform.arguments.isNotEmpty ? Platform.arguments[0] : '10.17.6.245';
  print('Testing connection to $host:22 with password (${password.length} chars)');
  
  try {
    print('[1] Connecting socket...');
    final socket = await SSHSocket.connect(host, 22,
        timeout: const Duration(seconds: 5));
    print('[2] Socket connected');

    final client = SSHClient(
      socket,
      username: 'lizhenguo1',
      onPasswordRequest: () {
        print('[auth] onPasswordRequest called');
        return password;
      },
      onUserInfoRequest: (req) {
        print('[auth] onUserInfoRequest called, ${req.prompts.length} prompts');
        return req.prompts.map((_) => password).toList();
      },
    );

    print('[3] Waiting for authenticated...');
    await client.authenticated.timeout(const Duration(seconds: 10));
    print('[4] Authenticated!');
    
    print('[5] Opening shell...');
    final session = await client.shell(
      pty: SSHPtyConfig(width: 80, height: 24),
    );
    print('[6] Shell opened!');

    session.stdout.listen((data) => stdout.add(data));
    session.stdin.add(Uint8List.fromList(utf8.encode('whoami\n')));
    await Future.delayed(const Duration(seconds: 2));

    session.close();
    client.close();
    print('\nSuccess!');
  } catch (e) {
    print('Failed: $e (${e.runtimeType})');
  }
  exit(0);
}
