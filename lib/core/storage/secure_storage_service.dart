import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static const _instance = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static Future<void> savePassword(String connectionId, String password) =>
      _instance.write(key: 'pwd_$connectionId', value: password);

  static Future<String?> getPassword(String connectionId) =>
      _instance.read(key: 'pwd_$connectionId');

  static Future<void> deletePassword(String connectionId) =>
      _instance.delete(key: 'pwd_$connectionId');
}
