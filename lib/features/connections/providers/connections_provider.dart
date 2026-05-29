import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/connection_profile.dart';
import '../../../core/storage/secure_storage_service.dart';

const _storageKey = 'connections';
const _uuid = Uuid();

final connectionsProvider =
    AsyncNotifierProvider<ConnectionsNotifier, List<ConnectionProfile>>(
        ConnectionsNotifier.new);

class ConnectionsNotifier extends AsyncNotifier<List<ConnectionProfile>> {
  @override
  Future<List<ConnectionProfile>> build() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_storageKey) ?? [];
    return raw.map(ConnectionProfile.decode).toList();
  }

  Future<void> _persist(List<ConnectionProfile> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _storageKey,
      list.map((c) => c.encode()).toList(),
    );
  }

  Future<ConnectionProfile> add({
    required String name,
    required String host,
    required int port,
    required String username,
    required String password,
  }) async {
    final profile = ConnectionProfile(
      id: _uuid.v4(),
      name: name,
      host: host,
      port: port,
      username: username,
    );
    await SecureStorageService.savePassword(profile.id, password);
    final updated = [...state.requireValue, profile];
    await _persist(updated);
    state = AsyncData(updated);
    return profile;
  }

  Future<void> updateProfile({
    required String id,
    required String name,
    required String host,
    required int port,
    required String username,
    String? password,
  }) async {
    final list = [...state.requireValue];
    final idx = list.indexWhere((c) => c.id == id);
    if (idx == -1) return;
    list[idx] = list[idx].copyWith(
      name: name,
      host: host,
      port: port,
      username: username,
    );
    if (password != null && password.isNotEmpty) {
      await SecureStorageService.savePassword(id, password);
    }
    await _persist(list);
    state = AsyncData(list);
  }

  Future<void> remove(String id) async {
    await SecureStorageService.deletePassword(id);
    final updated = state.requireValue.where((c) => c.id != id).toList();
    await _persist(updated);
    state = AsyncData(updated);
  }
}
