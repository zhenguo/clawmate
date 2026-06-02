import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dartssh2/dartssh2.dart';

void main() async {
  final password = Platform.environment['TEST_PWD'] ?? '';
  print('Connecting to 127.0.0.1:22...');
  try {
    final socket = await SSHSocket.connect('127.0.0.1', 22,
        timeout: const Duration(seconds: 5));
    print('Socket OK');

    final client = SSHClient(
      socket,
      username: 'lizhenguo1',
      onPasswordRequest: () {
        print('[auth] password requested');
        return password;
      },
      onUserInfoRequest: (req) {
        print('[auth] keyboard-interactive: ${req.prompts.length} prompts');
        return req.prompts.map((_) => password).toList();
      },
    );

    print('Waiting for shell...');
    final session = await client.shell(
      pty: SSHPtyConfig(width: 80, height: 24),
    );
    print('Shell opened!');

    session.stdout.listen((data) => stdout.add(data));
    session.stdin.add(Uint8List.fromList(utf8.encode('whoami\n')));
    await Future.delayed(const Duration(seconds: 2));

    session.close();
    client.close();
    print('\nSuccess!');
  } catch (e) {
    print('Failed: $e');
  }
  exit(0);
}
