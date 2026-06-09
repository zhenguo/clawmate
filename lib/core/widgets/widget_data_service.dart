import 'dart:convert';

import 'package:flutter/services.dart';

import '../../features/connections/models/connection_profile.dart';

const _channel = MethodChannel('com.clawmate.widget_bridge');

class WidgetDataService {
  static final WidgetDataService _instance = WidgetDataService._();
  factory WidgetDataService() => _instance;
  WidgetDataService._();

  Future<void> _save(String key, String value) async {
    try {
      await _channel.invokeMethod('saveWidgetData', {'key': key, 'value': value});
    } catch (_) {}
  }

  Future<void> updateConnections(List<ConnectionProfile> connections) async {
    final data = connections.map((c) => {
      'id': c.id,
      'name': c.name,
      'host': c.host,
      'username': c.username,
      'transport': c.transportType.name,
    }).toList();
    await _save('connections', jsonEncode(data));
  }

  Future<void> updateTerminalPreview(
    String connectionId,
    String connectionName,
    List<String> lines,
  ) async {
    final data = {
      'name': connectionName,
      'lines': lines.length > 10 ? lines.sublist(lines.length - 10) : lines,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    await _save('terminal_preview_$connectionId', jsonEncode(data));
    await _save('active_session_id', connectionId);
  }

  Future<void> updateServerStats(
    String connectionId,
    String host, {
    required double cpuPercent,
    required double memPercent,
    double? diskPercent,
  }) async {
    final data = <String, dynamic>{
      'host': host,
      'cpu': cpuPercent,
      'mem': memPercent,
      if (diskPercent != null) 'disk': diskPercent,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    await _save('server_stats_$connectionId', jsonEncode(data));
  }

  Future<void> clearActiveSession() async {
    await _save('active_session_id', '');
  }
}
