import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/connection_profile.dart';
import '../providers/connections_provider.dart';
import '../../../core/storage/secure_storage_service.dart';

class ConnectionFormScreen extends ConsumerStatefulWidget {
  final ConnectionProfile? profile;
  final String? prefillName;
  final String? prefillHost;
  final int? prefillPort;
  const ConnectionFormScreen({
    super.key,
    this.profile,
    this.prefillName,
    this.prefillHost,
    this.prefillPort,
  });

  @override
  ConsumerState<ConnectionFormScreen> createState() =>
      _ConnectionFormScreenState();
}

class _ConnectionFormScreenState extends ConsumerState<ConnectionFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _usernameCtrl;
  late final TextEditingController _passwordCtrl;
  late TransportType _transportType;
  bool _saving = false;
  bool _obscurePassword = true;

  bool get _isEditing => widget.profile != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(
        text: widget.profile?.name ?? widget.prefillName ?? 'My Mac');
    _hostCtrl = TextEditingController(
        text: widget.profile?.host ?? widget.prefillHost ?? '10.17.6.245');
    _portCtrl = TextEditingController(
        text: (widget.profile?.port ?? widget.prefillPort ?? 22).toString());
    _usernameCtrl = TextEditingController(
        text: widget.profile?.username ?? 'lizhenguo1');
    _passwordCtrl = TextEditingController();
    _transportType = widget.profile?.transportType ?? TransportType.ssh;
    if (_isEditing) _loadPassword();
  }

  Future<void> _loadPassword() async {
    final pw = await SecureStorageService.getPassword(widget.profile!.id);
    if (pw != null && mounted) _passwordCtrl.text = pw;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? 'Edit Connection' : 'New Connection'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. MacBook Pro',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _hostCtrl,
              decoration: const InputDecoration(
                labelText: 'Host',
                hintText: 'e.g. 192.168.1.100',
              ),
              keyboardType: TextInputType.url,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Host required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _portCtrl,
              decoration: const InputDecoration(labelText: 'Port'),
              keyboardType: TextInputType.number,
              validator: (v) {
                final port = int.tryParse(v ?? '');
                if (port == null || port < 1 || port > 65535) {
                  return 'Port must be 1-65535';
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Transport: '),
                const SizedBox(width: 8),
                SegmentedButton<TransportType>(
                  segments: const [
                    ButtonSegment(
                      value: TransportType.ssh,
                      label: Text('SSH'),
                    ),
                    ButtonSegment(
                      value: TransportType.mosh,
                      label: Text('Mosh'),
                    ),
                  ],
                  selected: {_transportType},
                  onSelectionChanged: (v) =>
                      setState(() => _transportType = v.first),
                ),
              ],
            ),
            if (_transportType == TransportType.mosh)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'Requires mosh-server installed on the remote host',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _usernameCtrl,
              decoration: const InputDecoration(
                labelText: 'Username',
                hintText: 'e.g. user',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Username required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _passwordCtrl,
              decoration: InputDecoration(
                labelText: 'Password',
                hintText: _isEditing ? '(unchanged if empty)' : '',
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_off
                        : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              obscureText: _obscurePassword,
              validator: (v) {
                if (!_isEditing && (v == null || v.isEmpty)) {
                  return 'Password required';
                }
                return null;
              },
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_isEditing ? 'Save' : 'Add'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final notifier = ref.read(connectionsProvider.notifier);
    if (_isEditing) {
      await notifier.updateProfile(
        id: widget.profile!.id,
        name: _nameCtrl.text.trim(),
        host: _hostCtrl.text.trim(),
        port: int.parse(_portCtrl.text),
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text.isNotEmpty ? _passwordCtrl.text : null,
        transportType: _transportType,
      );
    } else {
      await notifier.add(
        name: _nameCtrl.text.trim(),
        host: _hostCtrl.text.trim(),
        port: int.parse(_portCtrl.text),
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text,
        transportType: _transportType,
      );
    }

    if (mounted) Navigator.pop(context);
  }
}
