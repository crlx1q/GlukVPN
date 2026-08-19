import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/api_client.dart';
import '../state/auth_controller.dart';
import '../state/vpn_controller.dart';
import '../utils/format.dart';
import '../widgets/common.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  bool _loading = true;
  String? _error;
  DevicesResult? _result;
  String? _revokingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final AuthController auth = context.read<AuthController>();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final DevicesResult result = await auth.loadDevices();
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    }
  }

  Future<void> _revoke(DeviceInfo device) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Revoke ${device.deviceName}?'),
        content: Text(
          device.isCurrent
              ? 'This is the phone you are using. Its session is closed, the '
                'WireGuard peer is removed from the node and a new key pair is '
                'registered on the next connect.'
              : 'Any active session for this device is closed and its WireGuard '
                'peer is removed from the node.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final AuthController auth = context.read<AuthController>();
    final VpnController vpn = context.read<VpnController>();
    setState(() => _revokingId = device.id);
    try {
      // Bring the local tunnel down first so the phone does not keep a dead
      // interface up after the peer disappears on the node.
      if (device.isCurrent && vpn.isConnected) {
        await vpn.disconnect();
      }
      await auth.revokeDevice(device.id);
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      if (device.isCurrent) {
        await auth.ensureDeviceRegistered();
        if (!mounted) return;
        await _load();
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _revokingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<DeviceInfo> devices = _result?.devices ?? const <DeviceInfo>[];
    final int active = devices.where((DeviceInfo d) => d.isActive).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: <Widget>[
            if (_error != null)
              MessageBanner(
                message: _error!,
                isError: true,
                onDismiss: () => setState(() => _error = null),
              ),
            if (_loading && devices.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_result != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '$active of ${_result!.maxDevices} device slots in use',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
            for (final DeviceInfo device in devices)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _DeviceCard(
                  device: device,
                  revoking: _revokingId == device.id,
                  onRevoke: _revokingId == null ? () => _revoke(device) : null,
                ),
              ),
            if (!_loading && devices.isEmpty && _error == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Text(
                  'No devices registered.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device, required this.revoking, this.onRevoke});

  final DeviceInfo device;
  final bool revoking;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.smartphone_outlined,
                  color: device.isActive ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    device.deviceName,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ),
                if (device.connected) ...<Widget>[
                  const StatusDot(online: true),
                  const SizedBox(width: 6),
                ],
                Text(
                  device.isActive ? device.status.toLowerCase() : 'revoked',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: device.isActive ? scheme.primary : scheme.error,
                  ),
                ),
              ],
            ),
            if (device.isCurrent)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'this device',
                  style: TextStyle(fontSize: 11, color: scheme.primary),
                ),
              ),
            const SizedBox(height: 10),
            KeyValueRow(label: 'Platform', value: device.platform ?? '--'),
            KeyValueRow(label: 'Registered', value: formatDateTime(device.createdAt)),
            KeyValueRow(label: 'Last seen', value: formatRelative(device.lastSeen)),
            KeyValueRow(
              label: 'Session',
              value: device.connected
                  ? 'connected via ${device.connectedNodeName ?? 'node'}'
                  : 'not connected',
            ),
            if (device.isActive)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: revoking ? null : onRevoke,
                  icon: revoking
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.block, size: 18),
                  label: Text(revoking ? 'Revoking...' : 'Revoke'),
                  style: TextButton.styleFrom(foregroundColor: scheme.error),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
