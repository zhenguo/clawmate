import 'dart:async';
import 'dart:io';

import 'package:nsd/nsd.dart' as nsd;

class DiscoveredDevice {
  final String name;
  final String host;
  final int port;
  final List<String> allAddresses;

  const DiscoveredDevice({
    required this.name,
    required this.host,
    required this.port,
    this.allAddresses = const [],
  });

  @override
  bool operator ==(Object other) =>
      other is DiscoveredDevice && other.name == name && other.port == port;

  @override
  int get hashCode => Object.hash(name, port);

  Future<String?> findReachableHost({Duration timeout = const Duration(seconds: 3)}) async {
    if (allAddresses.isEmpty) return host;
    final futures = allAddresses.map((addr) async {
      try {
        final socket = await Socket.connect(addr, port, timeout: timeout);
        socket.destroy();
        return addr;
      } catch (_) {
        return null;
      }
    });
    final results = await Future.wait(futures);
    for (final r in results) {
      if (r != null) return r;
    }
    return null;
  }
}

class DiscoveryService {
  nsd.Discovery? _discovery;
  final _controller = StreamController<List<DiscoveredDevice>>.broadcast();
  final _logController = StreamController<String>.broadcast();
  final List<DiscoveredDevice> _devices = [];
  Timer? _timeoutTimer;

  Stream<List<DiscoveredDevice>> get devicesStream => _controller.stream;
  Stream<String> get logStream => _logController.stream;
  List<DiscoveredDevice> get devices => List.unmodifiable(_devices);

  void _log(String message) {
    final ts = DateTime.now().toString().substring(11, 19);
    _logController.add('[$ts] $message');
  }

  Future<void> startScan({Duration timeout = const Duration(seconds: 10)}) async {
    await stopScan();
    _devices.clear();
    _controller.add([]);

    _log('Starting NSD scan for _ssh._tcp ...');
    _log('Timeout: ${timeout.inSeconds}s, IP lookup: IPv4');

    try {
      _discovery = await nsd.startDiscovery('_ssh._tcp',
          autoResolve: true, ipLookupType: nsd.IpLookupType.v4);
      _log('NSD discovery started successfully');
    } catch (e) {
      _log('ERROR: Failed to start discovery: $e');
      return;
    }

    _discovery!.addServiceListener((service, status) {
      if (status == nsd.ServiceStatus.found) {
        _log('Service FOUND: "${service.name}"');
        _log('  host: ${service.host}');
        _log('  port: ${service.port}');
        _log('  type: ${service.type}');

        final addresses = service.addresses;
        if (addresses != null && addresses.isNotEmpty) {
          _log('  addresses (${addresses.length}):');
          for (final addr in addresses) {
            _log('    - ${addr.address} (${addr.address.contains(':') ? 'IPv6' : 'IPv4'})');
          }
        } else {
          _log('  addresses: NONE (resolution failed)');
        }

        final ipv4List = <String>[];
        String? primaryHost;
        if (addresses != null && addresses.isNotEmpty) {
          for (final addr in addresses) {
            if (!addr.address.contains(':')) {
              ipv4List.add(addr.address);
            }
          }
          primaryHost = ipv4List.isNotEmpty ? ipv4List.first : addresses.first.address;
        }
        primaryHost ??= service.host;
        final port = service.port;
        final name = service.name ?? 'Unknown';

        if (primaryHost != null && port != null) {
          final device = DiscoveredDevice(
            name: name,
            host: primaryHost,
            port: port,
            allAddresses: ipv4List,
          );
          if (!_devices.contains(device)) {
            _devices.add(device);
            _controller.add(List.of(_devices));
            _log('  => Added device: $name @ $primaryHost:$port (${ipv4List.length} IPv4 addrs)');
          } else {
            _log('  => Duplicate, skipped');
          }
        } else {
          _log('  => Skipped: host=$primaryHost, port=$port');
        }
      } else if (status == nsd.ServiceStatus.lost) {
        _log('Service LOST: "${service.name}"');
      }
    });

    _timeoutTimer = Timer(timeout, () {
      _log('Scan timeout reached (${timeout.inSeconds}s), stopping...');
      stopScan();
    });
  }

  Future<void> stopScan() async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    if (_discovery != null) {
      _log('Stopping NSD discovery...');
      await nsd.stopDiscovery(_discovery!);
      _discovery = null;
      _log('Discovery stopped. Found ${_devices.length} device(s).');
    }
  }

  void dispose() {
    stopScan();
    _controller.close();
    _logController.close();
  }
}
