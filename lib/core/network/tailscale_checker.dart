import 'dart:io';

import 'package:flutter/services.dart';

class TailscaleChecker {
  static Future<bool> isConnected() async {
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        if (!iface.name.startsWith('utun')) continue;
        for (final addr in iface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              addr.address.startsWith('100.')) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  static Future<bool> canOpenTailscale() async {
    try {
      return await canLaunchUrl('tailscale://');
    } catch (_) {
      return false;
    }
  }

  static Future<void> openTailscale() async {
    const channel = MethodChannel('com.clawmate.launcher');
    try {
      await channel.invokeMethod('openURL', 'tailscale://');
    } catch (_) {
      // Fallback: try via ProcessResult on macOS, no-op on iOS failure
    }
  }

  static Future<bool> canLaunchUrl(String urlString) async {
    const channel = MethodChannel('com.clawmate.launcher');
    try {
      return await channel.invokeMethod<bool>('canOpenURL', urlString) ?? false;
    } catch (_) {
      return false;
    }
  }
}
