import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/tailscale_checker.dart';
import '../providers/connections_provider.dart';
import '../providers/discovery_provider.dart';
import '../models/connection_profile.dart';
import 'connection_form_screen.dart';
import '../../terminal/screens/terminal_screen.dart';

class ConnectionsListScreen extends ConsumerStatefulWidget {
  const ConnectionsListScreen({super.key});

  @override
  ConsumerState<ConnectionsListScreen> createState() =>
      _ConnectionsListScreenState();
}

class _ConnectionsListScreenState extends ConsumerState<ConnectionsListScreen>
    with WidgetsBindingObserver {
  bool? _tailscaleConnected;
  bool _tailscaleInstalled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkTailscale();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkTailscale();
    }
  }

  Future<void> _checkTailscale() async {
    final connected = await TailscaleChecker.isConnected();
    final installed = await TailscaleChecker.canOpenTailscale();
    if (mounted) {
      setState(() {
        _tailscaleConnected = connected;
        _tailscaleInstalled = installed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final connectionsAsync = ref.watch(connectionsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ClawMate'),
        actions: [
          IconButton(
            icon: const Icon(Icons.radar),
            tooltip: 'Scan LAN',
            onPressed: () => _showScanSheet(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: () => _openForm(context),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_tailscaleConnected != null) _TailscaleBanner(
            connected: _tailscaleConnected!,
            installed: _tailscaleInstalled,
            onRefresh: _checkTailscale,
          ),
          Expanded(
            child: connectionsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (connections) {
                if (connections.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.terminal, size: 64, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text(
                          'No connections yet',
                          style:
                              TextStyle(fontSize: 18, color: Colors.grey[600]),
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () => _openForm(context),
                          icon: const Icon(Icons.add),
                          label: const Text('Add Connection'),
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () => _showScanSheet(context, ref),
                          icon: const Icon(Icons.radar),
                          label: const Text('Scan Network'),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  itemCount: connections.length,
                  itemBuilder: (context, index) {
                    final conn = connections[index];
                    return _ConnectionTile(profile: conn);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _openForm(BuildContext context,
      {String? name, String? host, int? port}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConnectionFormScreen(
          prefillName: name,
          prefillHost: host,
          prefillPort: port,
        ),
      ),
    );
  }

  void _showScanSheet(BuildContext context, WidgetRef ref) {
    ref.read(discoveryProvider.notifier).scan();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ScanSheet(
        onDeviceSelected: (device, reachableHost) {
          Navigator.pop(ctx);
          _openForm(context,
              name: device.name, host: reachableHost, port: device.port);
        },
      ),
    );
  }
}

class _TailscaleBanner extends StatelessWidget {
  final bool connected;
  final bool installed;
  final VoidCallback onRefresh;

  const _TailscaleBanner({
    required this.connected,
    required this.installed,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      color: connected ? Colors.green.withValues(alpha: 0.1) : Colors.orange.withValues(alpha: 0.1),
      child: Row(
        children: [
          Icon(
            connected ? Icons.vpn_lock : Icons.vpn_lock_outlined,
            size: 18,
            color: connected ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              connected ? 'Tailscale Connected' : 'Tailscale Not Connected',
              style: TextStyle(
                fontSize: 13,
                color: connected ? Colors.green : Colors.orange,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (!connected && installed)
            TextButton.icon(
              onPressed: () async {
                await TailscaleChecker.openTailscale();
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.orange,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            )
          else if (!connected && !installed)
            Text(
              'Not Installed',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          IconButton(
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            color: Colors.grey[500],
          ),
        ],
      ),
    );
  }
}

class _ScanSheet extends ConsumerStatefulWidget {
  final void Function(DiscoveredDevice device, String reachableHost) onDeviceSelected;
  const _ScanSheet({required this.onDeviceSelected});

  @override
  ConsumerState<_ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends ConsumerState<_ScanSheet> {
  String? _probingDevice;
  final List<String> _logs = [];
  StreamSubscription<String>? _logSub;
  final _logScrollController = ScrollController();
  bool _showLogs = true;

  @override
  void initState() {
    super.initState();
    final service = ref.read(discoveryServiceProvider);
    _logSub = service.logStream.listen((log) {
      if (!mounted) return;
      setState(() => _logs.add(log));
      Future.microtask(() {
        if (_logScrollController.hasClients) {
          _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
        }
      });
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _logScrollController.dispose();
    super.dispose();
  }

  Future<void> _probeAndSelect(DiscoveredDevice device) async {
    setState(() => _probingDevice = device.name);
    _logs.add('[${DateTime.now().toString().substring(11, 19)}] Probing ${device.allAddresses.length} address(es) for ${device.name}...');
    for (final addr in device.allAddresses) {
      _logs.add('[${DateTime.now().toString().substring(11, 19)}]   trying $addr:${device.port}');
    }
    setState(() {});

    final reachable = await device.findReachableHost();
    if (!mounted) return;

    if (reachable != null) {
      _logs.add('[${DateTime.now().toString().substring(11, 19)}]   => REACHABLE: $reachable');
      setState(() => _probingDevice = null);
      widget.onDeviceSelected(device, reachable);
    } else {
      _logs.add('[${DateTime.now().toString().substring(11, 19)}]   => ALL UNREACHABLE');
      setState(() => _probingDevice = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot reach ${device.name} on any address: ${device.allAddresses.join(", ")}'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(discoveryProvider);
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  const Text('Discovered Devices',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  if (state.scanning)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: () {
                        _logs.clear();
                        ref.read(discoveryProvider.notifier).scan();
                      },
                    ),
                ],
              ),
            ),
            if (state.devices.isEmpty && state.scanning)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Scanning...', style: TextStyle(color: Colors.grey)),
              )
            else if (state.devices.isEmpty && !state.scanning)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('No devices found',
                    style: TextStyle(color: Colors.grey)),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: state.devices.length,
                itemBuilder: (_, index) {
                  final device = state.devices[index];
                  final isProbing = _probingDevice == device.name;
                  final addrInfo = device.allAddresses.length > 1
                      ? '${device.host}:${device.port} (+${device.allAddresses.length - 1} IPs)'
                      : '${device.host}:${device.port}';
                  return ListTile(
                    leading: const Icon(Icons.computer),
                    title: Text(device.name),
                    subtitle: Text(addrInfo),
                    trailing: isProbing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_circle_outline),
                    onTap: isProbing ? null : () => _probeAndSelect(device),
                  );
                },
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Icon(Icons.terminal, size: 14, color: Colors.grey[500]),
                  const SizedBox(width: 6),
                  Text('Scan Log',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500])),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _showLogs = !_showLogs),
                    child: Icon(
                      _showLogs ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),
            ),
            if (_showLogs)
              Expanded(
                child: Container(
                  color: Colors.black,
                  padding: const EdgeInsets.all(8),
                  child: ListView.builder(
                    controller: _logScrollController,
                    itemCount: _logs.length,
                    itemBuilder: (_, index) {
                      final log = _logs[index];
                      Color color = Colors.grey[400]!;
                      if (log.contains('ERROR')) {
                        color = Colors.red;
                      } else if (log.contains('FOUND')) {
                        color = Colors.green;
                      } else if (log.contains('REACHABLE')) {
                        color = Colors.cyan;
                      } else if (log.contains('UNREACHABLE') || log.contains('LOST')) {
                        color = Colors.orange;
                      }
                      return Text(
                        log,
                        style: TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 10,
                          color: color,
                          height: 1.4,
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionTile extends ConsumerWidget {
  final ConnectionProfile profile;
  const _ConnectionTile({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: ValueKey(profile.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        color: const Color(0xFFFF3B30),
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (_) => _confirmDeleteChoice(context),
      onDismissed: (_) =>
          ref.read(connectionsProvider.notifier).remove(profile.id),
      child: ListTile(
        leading: const Icon(Icons.computer),
        title: Text(profile.name),
        subtitle: Text(
          '${profile.username}@${profile.host}:${profile.port}'
          '${profile.transportType == TransportType.mosh ? ' (Mosh)' : ''}',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TerminalScreen(profile: profile),
            ),
          );
        },
        onLongPress: () => _showActions(context, ref),
      ),
    );
  }

  Future<bool> _confirmDeleteChoice(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Connection'),
        content: Text('Delete "${profile.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ConnectionFormScreen(profile: profile),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title:
                  const Text('Delete', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(context, ref);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Connection'),
        content: Text('Delete "${profile.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              ref.read(connectionsProvider.notifier).remove(profile.id);
              Navigator.pop(ctx);
            },
            child:
                const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}
