import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/discovery_service.dart';

export '../../../core/network/discovery_service.dart' show DiscoveredDevice;

final discoveryServiceProvider = Provider<DiscoveryService>((ref) {
  final service = DiscoveryService();
  ref.onDispose(service.dispose);
  return service;
});

final discoveryProvider =
    NotifierProvider<DiscoveryNotifier, DiscoveryState>(DiscoveryNotifier.new);

class DiscoveryState {
  final bool scanning;
  final List<DiscoveredDevice> devices;

  const DiscoveryState({this.scanning = false, this.devices = const []});

  DiscoveryState copyWith({bool? scanning, List<DiscoveredDevice>? devices}) {
    return DiscoveryState(
      scanning: scanning ?? this.scanning,
      devices: devices ?? this.devices,
    );
  }
}

class DiscoveryNotifier extends Notifier<DiscoveryState> {
  StreamSubscription<List<DiscoveredDevice>>? _sub;

  @override
  DiscoveryState build() => const DiscoveryState();

  Future<void> scan() async {
    final service = ref.read(discoveryServiceProvider);
    state = state.copyWith(scanning: true, devices: []);
    _sub?.cancel();
    _sub = service.devicesStream.listen((devices) {
      state = state.copyWith(devices: devices);
    });
    await service.startScan();
    await Future.delayed(const Duration(seconds: 10));
    state = state.copyWith(scanning: false);
  }

  Future<void> stop() async {
    final service = ref.read(discoveryServiceProvider);
    await service.stopScan();
    _sub?.cancel();
    _sub = null;
    state = state.copyWith(scanning: false);
  }
}
