import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../i18n/app_strings.dart';
import '../models/models.dart';
import '../services/api_client.dart';
import '../state/auth_controller.dart';
import '../state/channel_controller.dart';
import '../state/vpn_controller.dart';
import '../theme/motion.dart';
import '../theme/tokens.dart';
import '../utils/format.dart' hide countryFlag;
import '../widgets/glass.dart';
import 'account_screen.dart';
import 'devices_screen.dart';

/// Account, channel and diagnostics.
///
/// Two things here are deliberate product decisions rather than decoration:
///
///  * the nickname is editable, the account ID is not. The ID is the handle
///    support and admins search and ban by, so it is assigned by the database
///    and enforced immutable there - a renamed user is still the same account.
///  * the PROD/BETA switch is only offered while disconnected. Repointing the
///    app at another control plane mid-tunnel would leave a peer installed on a
///    node that the app can no longer talk to.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  /// ROUND 11: the five-tap "developer menu" is gone.
  ///
  /// It was the wrong shape for what it guarded. Switching control plane is an
  /// admin capability - the beta plane refuses everyone else anyway - so a
  /// secret gesture only meant a normal user could uncover a switch that would
  /// then fail on them, while an admin had to know the trick to find a control
  /// they are entitled to. The rule is now the same one the browser extension
  /// and the desktop client use: `channel.canSwitchAs(user)`, which is simply
  /// "this account is an admin". No taps, no hidden state, one rule everywhere.

  /// ROUND 11: the language picker.
  ///
  /// Three choices, not two. "System" has to exist and has to be the default,
  /// because the app should follow the phone for anyone who never opens this
  /// row. Picking a language explicitly pins it, so a Russian phone can run the
  /// app in English and the other way round.
  Future<void> _pickLanguage(LocaleController locale) async {
    final AppStrings s = context.strings;
    final AppLanguage? picked = await showDialog<AppLanguage>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text(s.language),
        children: <Widget>[
          for (final AppLanguage option in AppLanguage.values)
            RadioListTile<AppLanguage>(
              value: option,
              groupValue: locale.preference,
              title: Text(_languageLabel(option, s)),
              onChanged: (AppLanguage? value) =>
                  Navigator.of(context).pop(value),
            ),
        ],
      ),
    );
    if (picked != null) await locale.select(picked);
  }

  /// The two real languages are written in their own language - a person
  /// looking for Russian is looking for "\u0420\u0443\u0441\u0441\u043a\u0438\u0439", not for "Russian".
  static String _languageLabel(AppLanguage option, AppStrings s) {
    switch (option) {
      case AppLanguage.system:
        return s.languageAuto;
      case AppLanguage.english:
        return 'English';
      case AppLanguage.russian:
        return '\u0420\u0443\u0441\u0441\u043a\u0438\u0439';
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final LocaleController locale = context.watch<LocaleController>();
    final TextTheme text = Theme.of(context).textTheme;
    final AuthController auth = context.watch<AuthController>();
    final ChannelController channel = context.watch<ChannelController>();
    final MotionController motion = context.watch<MotionController>();
    final VpnController vpn = context.watch<VpnController>();
    final AuthUser? user = auth.user;
    final SubscriptionInfo? subscription = auth.subscription;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 108),
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(s.settings, style: text.headlineSmall),
              const Spacer(),
              CircleIconButton(
                icon: Icons.refresh_rounded,
                onTap: () {
                  auth.refreshMe();
                  channel.probeAll();
                },
                tooltip: s.refresh,
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (auth.error != null) ...<Widget>[
            InkWell(
              onTap: auth.clearError,
              child: InlineNotice(message: auth.error!),
            ),
            const SizedBox(height: 12),
          ],
          _ProfileCard(user: user),
          const SizedBox(height: 12),
          _SubscriptionCard(
            subscription: subscription,
            active: auth.subscriptionActive,
            maxDevices: user?.maxDevices ?? 3,
            maxSessions: user?.maxConcurrentSessions ?? 1,
          ),
          const SizedBox(height: 20),
          _SectionLabel(s.account),
          const SizedBox(height: 8),
          // ROUND 10 (4.2): profile, plan and the sessions that are signed in
          // right now, in one place instead of scattered across this screen.
          _ActionTile(
            icon: Icons.account_circle_outlined,
            title: s.account,
            subtitle: s.accountTileSubtitle,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const AccountScreen(),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _ActionTile(
            icon: Icons.devices_other_rounded,
            title: s.myDevices,
            subtitle: '${s.thisDevice}: '
                '${auth.deviceName ?? s.notRegisteredYet}'
                ' \u00b7 ${s.upTo} ${user?.maxDevices ?? 3} ${s.devicesShort}',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const DevicesScreen(),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _ActionTile(
            icon: motion.reduceMotion
                ? Icons.battery_saver_rounded
                : Icons.animation_rounded,
            title: s.animations,
            subtitle: motion.reduceMotion
                ? 'Paused to save power (${motion.reduceMotionReason}). '
                    'Buttons still show their progress.'
                : s.fullMotion,
            trailing: _Pill(
              label: motion.reduceMotion ? s.reduced : s.full,
              tone:
                  motion.reduceMotion ? GlukColors.amber : GlukColors.connected,
            ),
          ),
          const SizedBox(height: 8),
          // ROUND 11: language. Sits with Animations rather than under
          // "Internal", because it is a normal preference, not a build switch.
          _ActionTile(
            icon: Icons.translate_rounded,
            title: s.language,
            subtitle: locale.preferenceLabel,
            trailing: _Pill(
              label: s.code.toUpperCase(),
              tone: GlukColors.violetLight,
            ),
            onTap: () => _pickLanguage(locale),
          ),
          // Admins only, on every client. A normal account sees PROD and
          // nothing about channels, because that is all it is allowed to use.
          if (channel.canSwitchAs(user)) ...<Widget>[
            const SizedBox(height: 20),
            _SectionLabel(s.internal),
            const SizedBox(height: 8),
            _ChannelPanel(channel: channel, vpn: vpn),
            const SizedBox(height: 12),
            _DiagnosticsPanel(channel: channel, auth: auth),
          ],
          const SizedBox(height: 20),
          _LogoutButton(auth: auth, vpn: vpn),
          const SizedBox(height: 14),
          Text(
            'Traffic accounting records only byte counters and session times '
            '\u2014 never addresses, URLs or payloads.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 8),
          // The one line a release build keeps: what version answered. It is
          // plain text now - tapping it five times does nothing.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'GlukVPN ${AppConfig.appVersion} \u00b7 '
              '${channel.active.label} '
              '${channel.versionOf(channel.active)?.version ?? '\u2014'}',
              style: text.bodySmall?.copyWith(color: GlukColors.text2),
            ),
          ),
        ],
      ),
    );
  }
}

/// Short, human date for a card: "12 Sep 2026". `formatDateTime` is for rows
/// where the exact minute matters; a plan expiry does not read like a log line.
String _shortDate(DateTime? value) {
  if (value == null) return '\u2014';
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final DateTime local = value.toLocal();
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}

/// A status word, not a database enum: lower case, tinted, pill-shaped.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.tone});

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: tone.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withOpacity(0.40)),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: tone, fontSize: 10),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium,
      ),
    );
  }
}

/// One tappable settings row: icon, title, one line of plain English.
class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return GlassPanel(
      radius: GlukSizes.cellRadius,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      onTap: onTap,
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: GlukColors.violet.withOpacity(0.16),
            ),
            child: Icon(icon, size: 17, color: GlukColors.violetLight),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: text.titleMedium),
                const SizedBox(height: 2),
                Text(subtitle, style: text.bodySmall),
              ],
            ),
          ),
          if (trailing != null) trailing!,
          if (trailing == null && onTap != null)
            const Icon(Icons.chevron_right_rounded, color: GlukColors.text2),
        ],
      ),
    );
  }
}

/// Three numbers under the plan, laid out like a product page.
class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label.toUpperCase(), style: text.labelMedium),
        const SizedBox(height: 3),
        Text(
          value,
          style: text.bodyMedium?.copyWith(color: GlukColors.text0),
        ),
      ],
    );
  }
}

/// The plan, presented as a product rather than three database rows.
class _SubscriptionCard extends StatelessWidget {
  const _SubscriptionCard({
    required this.subscription,
    required this.active,
    required this.maxDevices,
    required this.maxSessions,
  });

  final SubscriptionInfo? subscription;
  final bool active;
  final int maxDevices;
  final int maxSessions;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final DateTime? expires = subscription?.expiresAt;
    final int? daysLeft = expires == null
        ? null
        : expires.difference(DateTime.now()).inMinutes ~/ (60 * 24);
    // A month is the mental unit of a subscription, so the bar is "how much of
    // a month is left" rather than a fake percentage of an unknown term.
    final double progress =
        daysLeft == null ? 0 : (daysLeft / 30).clamp(0.0, 1.0);

    return GlassPanel(
      radius: GlukSizes.trafficRadius,
      color: GlukColors.violet.withOpacity(0.10),
      padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.workspace_premium_rounded,
                size: 18,
                color: GlukColors.violetLight,
              ),
              const SizedBox(width: 8),
              Text('Premium', style: text.titleMedium),
              const Spacer(),
              _Pill(
                label: active
                    ? 'active'
                    : (subscription?.status.toLowerCase() ?? 'none'),
                tone: active ? GlukColors.connected : GlukColors.amber,
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (daysLeft != null && daysLeft >= 0) ...<Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                Text('$daysLeft', style: text.headlineSmall),
                const SizedBox(width: 6),
                Text(
                  daysLeft == 1 ? 'day left' : 'days left',
                  style: text.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: 9),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 5,
                backgroundColor: Colors.white.withOpacity(0.08),
                color: active ? GlukColors.violetLight : GlukColors.amber,
              ),
            ),
          ] else
            Text(
              active ? 'Active' : 'No active plan',
              style: text.titleMedium?.copyWith(
                color: active ? GlukColors.connected : GlukColors.amber,
              ),
            ),
          const SizedBox(height: 15),
          Row(
            children: <Widget>[
              Expanded(
                child: _MiniStat(label: 'Devices', value: 'up to $maxDevices'),
              ),
              Expanded(
                child: _MiniStat(
                  label: 'At once',
                  value: '$maxSessions tunnel${maxSessions == 1 ? '' : 's'}',
                ),
              ),
              Expanded(
                child: _MiniStat(label: 'Renews', value: _shortDate(expires)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The profile card: avatar, nickname you can change, account number you
/// cannot. Both facts are stated on the card, because that is exactly the
/// question a user asks when they see two identifiers.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.user});

  final AuthUser? user;

  Future<void> _rename(BuildContext context) async {
    final AuthController auth = context.read<AuthController>();
    final String? next = await showDialog<String>(
      context: context,
      builder: (BuildContext context) =>
          _RenameDialog(current: user?.username ?? ''),
    );
    if (next == null || next.isEmpty) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final UsernameChangeResult result = await auth.api.changeUsername(next);
      await auth.refreshMe();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.changed
                ? 'Nickname is now ${result.username}'
                : 'That is already your nickname',
          ),
        ),
      );
    } on ApiException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  void _copyId(BuildContext context) {
    final String id = user?.publicId ?? '';
    if (id.isEmpty) return;
    Clipboard.setData(ClipboardData(text: id));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Account ID copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final String name = user?.username ?? '\u2014';
    final String initial =
        name.isEmpty ? '?' : name.characters.first.toUpperCase();
    final String id = user?.publicId ?? '';
    final bool active = user?.isActive ?? false;
    final DateTime? created = user?.createdAt;

    return GlassPanel(
      radius: GlukSizes.trafficRadius,
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
      child: Row(
        children: <Widget>[
          Stack(
            alignment: Alignment.center,
            children: <Widget>[
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: GlukColors.violet.withOpacity(0.18),
                ),
              ),
              Container(
                width: 50,
                height: 50,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: GlukGradients.arrow,
                ),
                child: Text(
                  initial,
                  style: text.headlineSmall?.copyWith(color: GlukColors.bg),
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleLarge,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _Pill(
                      label: active
                          ? 'active'
                          : (user?.status.toLowerCase() ?? '\u2014'),
                      tone: active ? GlukColors.connected : GlukColors.amber,
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Row(
                  children: <Widget>[
                    Text(
                      id.isEmpty ? 'ID unavailable' : 'ID $id',
                      style: text.bodyMedium?.copyWith(
                        color: GlukColors.text1,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                    if (id.isNotEmpty) ...<Widget>[
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: () => _copyId(context),
                        borderRadius: BorderRadius.circular(999),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(
                            Icons.copy_rounded,
                            size: 13,
                            color: GlukColors.text2,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  created == null
                      ? 'Nickname can change, this number never does'
                      : 'Member since ${_shortDate(created)} \u00b7 the number '
                          'never changes',
                  style: text.bodySmall?.copyWith(fontSize: 10.5),
                ),
              ],
            ),
          ),
          CircleIconButton(
            icon: Icons.edit_rounded,
            tooltip: 'Change nickname',
            size: 34,
            onTap: () => _rename(context),
          ),
        ],
      ),
    );
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.current});

  final String current;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.current);
  final GlobalKey<FormState> _form = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: GlukColors.bg,
      title: const Text('Change nickname'),
      content: Form(
        key: _form,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Nickname'),
          validator: (String? value) {
            final String text = (value ?? '').trim();
            if (text.length < AppConfig.minUsernameLength) {
              return 'At least ${AppConfig.minUsernameLength} characters';
            }
            if (text.length > AppConfig.maxUsernameLength) {
              return 'At most ${AppConfig.maxUsernameLength} characters';
            }
            return null;
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (!(_form.currentState?.validate() ?? false)) return;
            Navigator.of(context).pop(_controller.text.trim());
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Internal builds only: the identifiers you need when something misbehaves,
/// kept in one place instead of scattered through the user-facing screens.
class _DiagnosticsPanel extends StatelessWidget {
  const _DiagnosticsPanel({required this.channel, required this.auth});

  final ChannelController channel;
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final ChannelVersion? version = channel.versionOf(channel.active);

    return _Panel(
      title: 'Diagnostics',
      children: <Widget>[
        _Row(label: 'Channel', value: channel.active.label),
        _Row(label: 'Control API', value: channel.baseUrl, mono: true),
        _Row(label: 'Server version', value: version?.version ?? '\u2014'),
        // The release id is what actually changes when a promote copies the
        // same version number into another directory.
        _Row(
          label: 'Release',
          value: version?.releaseLabel ?? '\u2014',
          mono: true,
        ),
        _Row(
          label: 'Data version',
          value: version?.migration ?? '\u2014',
          mono: true,
        ),
        _Row(label: 'Released', value: formatDateTime(version?.releasedAt)),
        _Row(label: 'Device', value: auth.deviceName ?? '\u2014'),
        _Row(label: 'Device id', value: _short(auth.deviceId), mono: true),
        _Row(
          label: 'WireGuard key',
          value: auth.devicePublicKey == null
              ? 'not generated yet'
              : '${_short(auth.devicePublicKey, 12)} (public)',
          mono: true,
        ),
        _Row(
          label: 'Tunnel interface',
          value: AppConfig.tunnelInterfaceName,
        ),
        _Row(label: 'App id', value: AppConfig.appId, mono: true),
      ],
    );
  }

  static String _short(String? value, [int length = 8]) {
    if (value == null || value.isEmpty) return '\u2014';
    return value.length <= length ? value : '${value.substring(0, length)}\u2026';
  }
}

/// PROD / BETA. The two channels are separate deployments with separate
/// databases, so this is a channel switch, not a URL toggle: accounts, devices
/// and sessions do not carry over.
class _ChannelPanel extends StatelessWidget {
  const _ChannelPanel({required this.channel, required this.vpn});

  final ChannelController channel;
  final VpnController vpn;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool locked = vpn.isConnected || vpn.isTransitioning;
    final ChannelVersion? prod = channel.versionOf(AppChannel.prod);
    final ChannelVersion? beta = channel.versionOf(AppChannel.beta);
    final String? betaProblem = channel.unreachableReason(AppChannel.beta);

    return _Panel(
      title: 'Channel',
      trailing: channel.probing
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            )
          : null,
      children: <Widget>[
        _Row(
          label: 'Production',
          value: prod?.version ?? 'unreachable',
          valueColor: prod == null ? GlukColors.amber : GlukColors.text0,
        ),
        _Row(
          label: 'Beta',
          value: beta?.version ?? 'off',
          valueColor: beta == null ? GlukColors.text2 : GlukColors.amber,
        ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                channel.isBeta ? 'Using BETA' : 'Using PRODUCTION',
                style: text.titleMedium?.copyWith(
                  color: channel.isBeta ? GlukColors.amber : GlukColors.text0,
                ),
              ),
            ),
            if (channel.switching)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Switch(
                value: channel.isBeta,
                activeColor: GlukColors.amber,
                onChanged: locked || (!channel.betaReachable && !channel.isBeta)
                    ? null
                    : (bool value) => channel.setBetaEnabled(value),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          locked
              ? 'Disconnect first: switching channel while a tunnel is up would '
                'leave a peer installed on a node this app can no longer reach.'
              : channel.betaReachable || channel.isBeta
                  ? 'BETA is a separate deployment: its own database, its own '
                    'WireGuard node (wg1 on UDP 51821) and its own accounts. '
                    'Your PROD session stays signed in.'
                  : 'BETA is not answering right now'
                    '${betaProblem == null ? '' : ': $betaProblem'}.',
          style: text.bodySmall,
        ),
        if (channel.error != null) ...<Widget>[
          const SizedBox(height: 10),
          InkWell(
            onTap: channel.clearError,
            child: InlineNotice(message: channel.error!),
          ),
        ],
      ],
    );
  }
}

class _LogoutButton extends StatelessWidget {
  const _LogoutButton({required this.auth, required this.vpn});

  final AuthController auth;
  final VpnController vpn;

  Future<void> _logout(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: GlukColors.bg,
        title: const Text('Sign out?'),
        content: const Text(
          'The tunnel is closed, this device is revoked on the server and its '
          'peer is removed from the node.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (vpn.isConnected) await vpn.disconnect();
    await auth.logout();
  }

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      radius: 999,
      padding: const EdgeInsets.symmetric(vertical: 14),
      onTap: auth.busy ? null : () => _logout(context),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(Icons.logout_rounded, size: 17, color: GlukColors.danger),
          const SizedBox(width: 8),
          Text(
            'Sign out',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: GlukColors.danger),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.children, this.trailing});

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
    this.valueColor,
  });

  final String label;
  final String value;
  final bool mono;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(child: Text(label, style: text.bodySmall)),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: (mono ? text.bodySmall : text.bodyMedium)?.copyWith(
                color: valueColor ?? GlukColors.text0,
                fontFeatures: const <FontFeature>[
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
