import 'package:flutter/material.dart';

class WidgetDeepLinkHandler {
  static GlobalKey<NavigatorState>? navigatorKey;

  static void init(GlobalKey<NavigatorState> key) {
    navigatorKey = key;
  }

  static void handleUri(Uri? uri) {
    if (uri == null || navigatorKey?.currentContext == null) return;
    if (uri.host == 'connect' && uri.pathSegments.isNotEmpty) {
      final profileId = uri.pathSegments.first;
      _launchConnection(profileId);
    }
  }

  static void _launchConnection(String profileId) {
    _pendingConnectionId = profileId;
    _onConnectionRequested?.call(profileId);
  }

  static String? _pendingConnectionId;
  static void Function(String id)? _onConnectionRequested;

  static String? consumePendingConnection() {
    final id = _pendingConnectionId;
    _pendingConnectionId = null;
    return id;
  }

  static void setConnectionHandler(void Function(String id) handler) {
    _onConnectionRequested = handler;
  }
}
