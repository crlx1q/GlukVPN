import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../i18n/app_strings.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../state/auth_controller.dart';
import '../state/vpn_controller.dart';
import '../theme/tokens.dart';
import '../utils/format.dart' hide countryFlag;
import '../widgets/glass.dart';
import 'devices_screen.dart' show TonePill;

/// ROUND 10 (4.2): the "Account" screen the desktop client and the website
/// already had - profile, plan, and the live sessions with a way to end them.
///
/// One deliberate naming decision. The server has no separate "session" object
/// a user could act on: a session belongs to a registered device, and revoking
/// the device is what closes the tunnel and removes the WireGuard peer from the
/// node. So the list is built from `GET /api/devices` and each row says what it
/// is really doing. Inventing a session list that cannot be revoked, next to a
/// device list that can, would only teach people to distrust the buttons.
///
/// Settings keeps the plain device manager for the case where somebody just
/// wants to free a slot; this screen is the account overview.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _loading = true;
  String? _error;
  DevicesResult? _devices;

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
    // Both, in one pull-to-refresh: a stale plan next to a fresh session list
    // is how "my subscription is active" arguments start.
    await auth.refreshMe();
    try {
      final DevicesResult result = await auth.loadDevices();
      if (!mounted) return;
      setState(() {
        _devices = result;
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

  void _copy(String value, String said) {
    if (value.isEmpty) return;
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(said)));
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final TextTheme text = Theme.of(context).textTheme;
    final AuthController auth = context.watch<AuthController>();
    final AuthUser? user = auth.user;
    final SubscriptionInfo? plan = auth.subscription;

    final List<DeviceInfo> all = _devices?.devices ?? const <DeviceInfo>[];
    final List<DeviceInfo> active =
        all.where((DeviceInfo d) => d.isActive).toList();

    return Scaffold(
      backgroundColor: GlukColors.pageBg,
      appBar: AppBar(
        title: Text(s.account),
        backgroundColor: Colors.transparent,
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: s.reload,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: <Widget>[
            if (_error != null) ...<Widget>[
              InkWell(
                onTap: () => setState(() => _error = null),
                child: InlineNotice(message: _error!),
              ),
              const SizedBox(height: 14),
            ],
            if (auth.sessionUnconfirmed) ...<Widget>[
              InlineNotice(message: s.showingLastKnownState),
              const SizedBox(height: 14),
            ],

            // --- profile ---------------------------------------------------
            _Card(
              title: s.profile,
              children: <Widget>[
                _Row(label: s.username, value: user?.username ?? '\u2014'),
                _Row(
                  label: s.email,
                  value: user?.email ?? s.notSet,
                  trailing: user?.email == null
                      ? null
                      : TonePill(
                          label: (user?.emailVerified ?? false)
                              ? s.verified
                              : s.unverified,
                          tone: (user?.emailVerified ?? false)
                              ? GlukColors.connected
                              : GlukColors.amber,
                        ),
                ),
                _Row(
                  label: s.accountNumber,
                  value: (user?.publicId ?? '').isEmpty
                      ? '\u2014'
                      : user!.publicId,
                  mono: true,
                  onTapValue: (user?.publicId ?? '').isEmpty
                      ? null
                      : () => _copy(user!.publicId, s.accountIdCopied),
                ),
                _Row(
                  label: s.status,
                  value: user?.status.toLowerCase() ?? '\u2014',
                ),
                if ((user?.originLabel ?? '').isNotEmpty)
                  _Row(label: s.signedUpFrom, value: user!.originLabel!),
                _Row(
                  label: s.memberSince,
                  value: formatDateTime(user?.createdAt),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // --- subscription ----------------------------------------------
            _Card(
              title: s.subscription,
              trailing: TonePill(
                label: auth.subscriptionActive
                    ? s.active
                    : (plan?.status.toLowerCase() ?? s.none),
                tone: auth.subscriptionActive
                    ? GlukColors.connected
                    : GlukColors.amber,
              ),
              children: <Widget>[
                _Row(
                  label: s.validUntil,
                  value: plan?.expiresAt == null
                      ? '\u2014'
                      : formatDateTime(plan!.expiresAt),
                ),
                _Row(
                  label: s.deviceSlots,
                  value: s.usedOfTotal(
                    active.length,
                    _devices?.maxDevices ?? user?.maxDevices ?? 3,
                  ),
                ),
                _Row(
                  label: s.tunnelsAtOnce,
                  value: '${user?.maxConcurrentSessions ?? 1}',
                ),
                if (!auth.subscriptionActive) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(s.noActivePlanBody, style: text.bodySmall),
                ],
              ],
            ),
            const SizedBox(height: 20),

            // ПУНКТ 12: список устройств отсюда убран. Экран
            // «Аккаунт» и экран «Мои устройства» показывали ровно одно и
            // то же, а две копии кнопки «Выйти» в разных местах — это
            // способ случайно отозвать не то устройство. Теперь
            // устройства живут в двух синхронных местах: чип на
            // карте и экран «Мои устройства». Здесь остался только
            // счётчик занятых слотов в карточке тарифа.
          ],
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.children, this.trailing});

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return GlassPanel(
      radius: GlukSizes.trafficRadius,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(title.toUpperCase(), style: text.labelMedium),
              const Spacer(),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.mono = false,
    this.trailing,
    this.onTapValue,
  });

  final String label;
  final String value;
  final bool mono;
  final Widget? trailing;
  final VoidCallback? onTapValue;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final Widget shown = Text(
      value,
      textAlign: TextAlign.right,
      style: (mono ? text.bodySmall : text.bodyMedium)?.copyWith(
        color: GlukColors.text0,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label, style: text.bodySmall)),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: onTapValue == null
                ? shown
                : InkWell(onTap: onTapValue, child: shown),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      ),
    );
  }
}
