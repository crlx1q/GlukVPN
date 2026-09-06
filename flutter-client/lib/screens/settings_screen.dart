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
import '../widgets/language_pill.dart';
import 'account_screen.dart';
import 'devices_screen.dart';
import 'diagnostics_screen.dart';
import 'stats_screen.dart';

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
  /// and the desktop client use: `channel.canSwitchFor(user)` - an admin or a
  /// flagged beta tester, on a build that allows beta at all. No taps, no
  /// hidden state, one rule everywhere.

  /// ROUND 11: the language picker. The dialog itself lives in
  /// `widgets/language_pill.dart` now, shared with the pill on sign-in.
  Future<void> _pickLanguage(LocaleController locale) =>
      showLanguageChooser(context, locale);

  /// Why the loops are frozen, in the interface language. Null when motion is
  /// only paused because the app is in the background.
  static String? _reduceMotionReason(MotionController motion, AppStrings s) {
    if (motion.systemDisablesAnimations) return s.reasonSystemAnimationsOff;
    if (motion.powerSaveMode) return s.reasonBatterySaver;
    if (motion.lowBattery) {
      return s.reasonLowBattery(MotionController.lowBatteryThreshold);
    }
    return null;
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
          // ПУНКТ 7: статистика теперь есть и на телефоне, а не только
          // на ПК. Сам экран рисует общий UsageStatsView.
          _ActionTile(
            icon: Icons.insights_rounded,
            title: s.isRussian ? 'Статистика' : 'Statistics',
            subtitle: s.isRussian
                ? 'Трафик по часам и дням, по устройствам и сайтам'
                : 'Traffic by hour and day, by device and site',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const StatsScreen(),
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
                ? s.reduceMotionBody(_reduceMotionReason(motion, s))
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
          // Admins, beta testers and internal builds, on every client - and
          // only when this build can switch at all. A normal account sees PROD
          // and nothing about channels, because that is all it may use.
          if (channel.canSwitchFor(user)) ...<Widget>[
            const SizedBox(height: 20),
            _SectionLabel(s.internal),
            const SizedBox(height: 8),
            _ChannelCard(channel: channel, vpn: vpn, motion: motion),
            const SizedBox(height: 12),
            _DiagnosticsPanel(channel: channel, auth: auth, vpn: vpn),
          ],
          const SizedBox(height: 20),
          _LogoutButton(auth: auth, vpn: vpn),
          const SizedBox(height: 14),
          Text(s.accountingNotice, style: text.bodySmall),
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
    final AppStrings s = context.strings;
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
              Text(s.isRussian ? 'Подписка' : 'Subscription', style: text.titleMedium),
              const Spacer(),
              _Pill(
                label: subscription?.displayPlan ?? '—',
                tone: GlukColors.violetLight,
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
                Text(s.daysLeft(daysLeft), style: text.bodySmall),
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
              active ? s.activePlan : s.noActivePlan,
              style: text.titleMedium?.copyWith(
                color: active ? GlukColors.connected : GlukColors.amber,
              ),
            ),
          const SizedBox(height: 15),
          Row(
            children: <Widget>[
              Expanded(
                child: _MiniStat(
                  label: s.devicesShort,
                  value: '${s.upTo} $maxDevices',
                ),
              ),
              Expanded(
                child: _MiniStat(
                  label: s.atOnce,
                  value: s.tunnelsCount(maxSessions),
                ),
              ),
              Expanded(
                child: _MiniStat(label: s.renews, value: s.shortDate(expires)),
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
    // Read once, up front: the strings must not be looked up through a context
    // that may be gone by the time the request returns.
    final AppStrings s = context.read<LocaleController>().strings;
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
                ? s.nicknameIsNow(result.username)
                : s.alreadyYourNickname,
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
      SnackBar(content: Text(context.read<LocaleController>().strings.accountIdCopied)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
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
                          ? s.active
                          : (user?.status.toLowerCase() ?? '\u2014'),
                      tone: active ? GlukColors.connected : GlukColors.amber,
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Row(
                  children: <Widget>[
                    Text(
                      id.isEmpty ? s.idUnavailable : 'ID $id',
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
                      ? s.nicknameChangesIdDoesNot
                      : s.memberSinceNeverChanges(s.shortDate(created)),
                  style: text.bodySmall?.copyWith(fontSize: 10.5),
                ),
              ],
            ),
          ),
          CircleIconButton(
            icon: Icons.edit_rounded,
            tooltip: s.changeNickname,
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
    final AppStrings s = context.strings;
    return AlertDialog(
      backgroundColor: GlukColors.bg,
      title: Text(s.changeNickname),
      content: Form(
        key: _form,
        child: TextFormField(
          controller: _controller,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(labelText: s.nickname),
          validator: (String? value) {
            final String text = (value ?? '').trim();
            if (text.length < AppConfig.minUsernameLength) {
              return s.atLeastChars(AppConfig.minUsernameLength);
            }
            if (text.length > AppConfig.maxUsernameLength) {
              return s.atMostChars(AppConfig.maxUsernameLength);
            }
            return null;
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(s.cancel),
        ),
        FilledButton(
          onPressed: () {
            if (!(_form.currentState?.validate() ?? false)) return;
            Navigator.of(context).pop(_controller.text.trim());
          },
          child: Text(s.save),
        ),
      ],
    );
  }
}

/// Internal builds only: the identifiers you need when something misbehaves,
/// kept in one place instead of scattered through the user-facing screens.
class _DiagnosticsPanel extends StatelessWidget {
  const _DiagnosticsPanel({required this.channel, required this.auth, required this.vpn});

  final ChannelController channel;
  final AuthController auth;
  final VpnController vpn;

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final ChannelVersion? version = channel.versionOf(channel.active);

    return _Panel(
      title: s.diagnostics,
      children: <Widget>[
        _Row(label: s.channel, value: channel.active.label),
        _Row(label: s.controlApi, value: channel.baseUrl, mono: true),
        _Row(label: s.serverVersion, value: version?.version ?? '\u2014'),
        // The release id is what actually changes when a promote copies the
        // same version number into another directory.
        _Row(
          label: s.release,
          value: version?.releaseLabel ?? '\u2014',
          mono: true,
        ),
        _Row(
          label: s.dataVersion,
          value: version?.migration ?? '\u2014',
          mono: true,
        ),
        _Row(label: s.released, value: formatDateTime(version?.releasedAt)),
        _Row(label: s.device, value: auth.deviceName ?? '\u2014'),
        _Row(label: s.deviceId, value: _short(auth.deviceId), mono: true),
        _Row(
          label: s.wireguardKey,
          value: auth.devicePublicKey == null
              ? s.notGeneratedYet
              : '${_short(auth.devicePublicKey, 12)} ${s.publicKeyMark}',
          mono: true,
        ),
        _Row(
          label: s.tunnelInterface,
          value: AppConfig.tunnelInterfaceName,
        ),
        _Row(label: s.appId, value: AppConfig.appId, mono: true),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => DiagnosticsScreen(
              russian: s.isRussian,
              runner: DiagnosticsRunner(api: vpn.api, node: vpn.selectedNode, tunnelStage: vpn.vpnService.currentStage),
            ),
          )),
          icon: const Icon(Icons.health_and_safety_outlined),
          label: Text(s.diagnostics),
        ),
      ],
    );
  }

  static String _short(String? value, [int length = 8]) {
    if (value == null || value.isEmpty) return '\u2014';
    return value.length <= length ? value : '${value.substring(0, length)}\u2026';
  }
}

/// PROD / BETA - the channel card, one design on the phone, the desktop and
/// the extension.
///
/// Two segmented pills side by side. The active one is filled (violet for
/// PROD, amber for BETA - amber is reserved for beta everywhere, so the two
/// can never be confused), the other is a ghost outline. Under each pill a
/// status dot and the version that channel reports, or "off" when it did not
/// answer. Then one line saying what is in use, and one line of hint.
///
/// The two channels are separate deployments with separate databases, so a
/// tap here is a channel switch, not a URL toggle: accounts, devices and
/// sessions do not carry over. The tap goes through
/// [ChannelController.trySwitch], which probes the target first and refuses
/// to move when it does not answer; the card only renders that outcome.
class _ChannelCard extends StatelessWidget {
  const _ChannelCard({
    required this.channel,
    required this.vpn,
    required this.motion,
  });

  final ChannelController channel;
  final VpnController vpn;
  final MotionController motion;

  /// The error line, in the interface language, or null when there is none.
  static String? _failure(ChannelController channel, AppStrings s) {
    final AppChannel? unavailable = channel.unavailableChannel;
    if (unavailable != null) {
      return s.serverUnavailable(beta: unavailable.isBeta);
    }
    if (channel.lastSwitchResult == ChannelSwitchResult.notAllowed) {
      return s.channelAdminOnly;
    }
    return channel.error;
  }

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final TextTheme text = Theme.of(context).textTheme;
    // Repointing the app at another control plane mid-tunnel would leave a
    // peer installed on a node the app can no longer talk to.
    final bool locked = vpn.isConnected || vpn.isTransitioning;
    final bool enabled = !locked && !channel.switching;
    final ChannelVersion? current = channel.versionOf(channel.active);
    final String? failure = _failure(channel, s);

    return _Panel(
      title: s.channel,
      trailing: channel.probing
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            )
          : null,
      children: <Widget>[
        Row(
          children: <Widget>[
            for (final AppChannel option in AppChannel.values) ...<Widget>[
              if (option != AppChannel.values.first) const SizedBox(width: 10),
              Expanded(
                child: _ChannelSegment(
                  option: option,
                  active: channel.active == option,
                  reachable: channel.isReachable(option),
                  version: channel.versionOf(option)?.version,
                  pending: channel.pendingTarget == option,
                  enabled: enabled,
                  motion: motion,
                  onTap: () => channel.trySwitch(option),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        // "Using: PRODUCTION · 1.2.0" / "Сейчас: BETA · 1.3.0". The channel
        // names stay Latin in both languages: they are labels, not words.
        Text(
          '${s.channelNow}: ${channel.isBeta ? 'BETA' : 'PRODUCTION'} '
          '\u00b7 ${current?.version ?? '\u2014'}',
          style: text.titleMedium?.copyWith(
            color: channel.isBeta ? GlukColors.amber : GlukColors.text0,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          locked ? s.disconnectVpnFirst : s.channelSwitchHint,
          style: text.bodySmall?.copyWith(
            color: locked ? GlukColors.amber : null,
          ),
        ),
        if (failure != null) ...<Widget>[
          const SizedBox(height: 10),
          InkWell(
            onTap: channel.clearError,
            child: InlineNotice(message: failure, tone: GlukColors.amber),
          ),
        ],
      ],
    );
  }
}

/// One half of the channel card: the pill and the status line under it.
class _ChannelSegment extends StatelessWidget {
  const _ChannelSegment({
    required this.option,
    required this.active,
    required this.reachable,
    required this.version,
    required this.pending,
    required this.enabled,
    required this.motion,
    required this.onTap,
  });

  final AppChannel option;
  final bool active;
  final bool reachable;
  final String? version;

  /// True while [ChannelController.trySwitch] is probing or moving to this
  /// channel - the pill shows a spinner next to its label.
  final bool pending;
  final bool enabled;
  final MotionController motion;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppStrings s = context.strings;
    final TextTheme text = Theme.of(context).textTheme;
    final Color tone = option.isBeta ? GlukColors.amber : GlukColors.violet;
    // Amber is light, so the active BETA pill takes dark text; violet is dark
    // enough for white.
    final Color labelColor = active
        ? (option.isBeta ? GlukColors.bg : GlukColors.text0)
        : GlukColors.text1;
    final bool tappable = enabled && !active;

    return Column(
      children: <Widget>[
        Opacity(
          opacity: enabled || active ? 1 : 0.55,
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: tappable ? onTap : null,
              splashColor: tone.withOpacity(0.18),
              child: AnimatedContainer(
                duration: motion.transition(const Duration(milliseconds: 180)),
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: active ? tone : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: active ? tone : GlukColors.stroke,
                    width: 1.2,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (pending) ...<Widget>[
                      SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          color: labelColor,
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      option.label,
                      style: text.labelLarge?.copyWith(
                        color: labelColor,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 7),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: reachable ? GlukColors.connected : GlukColors.text2,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              reachable ? (version ?? '\u2014') : s.off,
              style: text.bodySmall?.copyWith(
                color: reachable ? GlukColors.text1 : GlukColors.text2,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _LogoutButton extends StatelessWidget {
  const _LogoutButton({required this.auth, required this.vpn});

  final AuthController auth;
  final VpnController vpn;

  Future<void> _logout(BuildContext context) async {
    final AppStrings s = context.read<LocaleController>().strings;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: GlukColors.bg,
        title: Text(s.signOutQuestion),
        content: Text(s.signOutBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(s.signOut),
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
            context.strings.signOut,
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
