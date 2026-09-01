import 'package:flutter/material.dart';

import '../../config.dart';
import '../../theme/tokens.dart';

/// The version line at the bottom of Settings, and the channel switch under it.
///
/// Ordinary users must never see a channel switch. Pointing a normal install at
/// beta hands them a control plane full of test data and half-finished nodes,
/// and nothing on screen would explain why their VPN suddenly behaves oddly.
///
/// ROUND 11: it used to hide behind five clicks on the version number. That was
/// the wrong control. A secret gesture is not a permission - it let a normal
/// user uncover a switch the beta plane would then refuse them, while an admin
/// had to know the trick to reach something they are entitled to. The rule is
/// now the same one the phone and the browser extension use: admins see it,
/// nobody else does.
///
/// The switch is deliberately symmetric: it stays reachable while beta is
/// active. A one-way door would mean the only way back to prod is a reinstall.
class DevChannelFooter extends StatefulWidget {
	const DevChannelFooter({
		super.key,
		required this.russian,
		required this.onChannelChanged,
		this.isAdmin = false,
		this.alwaysVisible = false,
	});

	final bool russian;

	/// The signed-in account is an admin. This is the only thing that reveals
	/// the switch in a shipped build.
	final bool isAdmin;

	/// Escape hatch for internal builds and tests; not used in production.
	final bool alwaysVisible;

	/// Called right after the channel changed, with the channel that was picked.
	///
	/// The session belongs to exactly one control plane - a prod refresh token is
	/// meaningless on beta - so the caller signs out. Leaving the old session in
	/// place produces 401s that look like a broken account.
	///
	/// ROUND 9 (1.3): the channel is passed out rather than read back from
	/// AppConfig, because the caller also has to write it to settings.json. An
	/// in-memory override alone was lost on restart, which is how a tester ended
	/// up back on production without noticing.
	final Future<void> Function(AppChannel channel) onChannelChanged;

	@override
	State<DevChannelFooter> createState() => _DevChannelFooterState();
}

class _DevChannelFooterState extends State<DevChannelFooter> {
	bool _busy = false;

	bool get _visible =>
			widget.isAdmin || widget.alwaysVisible || AppConfig.internalBuild;

	Future<void> _select(AppChannel channel) async {
		if (_busy || channel == AppConfig.activeChannel) return;
		// A build compiled without beta refuses the override outright.
		if (!AppConfig.setChannelOverride(channel)) return;
		setState(() => _busy = true);
		try {
			await widget.onChannelChanged(channel);
		} finally {
			if (mounted) setState(() => _busy = false);
		}
	}

	@override
	Widget build(BuildContext context) {
		final bool ru = widget.russian;
		return Column(
			mainAxisSize: MainAxisSize.min,
			children: <Widget>[
				Text(
					'GlukVPN Desktop ${AppConfig.appVersion} · '
					'${AppConfig.activeChannel.label}',
					style: const TextStyle(color: GlukColors.text2, fontSize: 11),
				),
				if (_visible) ...<Widget>[
					const SizedBox(height: 10),
					DecoratedBox(
						decoration: BoxDecoration(
							color: GlukColors.violet.withOpacity(0.06),
							borderRadius: BorderRadius.circular(12),
							border: Border.all(color: GlukColors.violet.withOpacity(0.24)),
						),
						child: Padding(
							padding: const EdgeInsets.symmetric(
								horizontal: 12,
								vertical: 9,
							),
							child: Row(
								mainAxisSize: MainAxisSize.min,
								children: <Widget>[
									Text(
										ru ? 'Канал' : 'Channel',
										style: const TextStyle(
											color: GlukColors.text1,
											fontSize: 11,
											fontWeight: FontWeight.w600,
										),
									),
									const SizedBox(width: 10),
									_pill(AppChannel.prod, 'Prod'),
									if (AppConfig.betaChannelAvailable) ...<Widget>[
										const SizedBox(width: 6),
										_pill(AppChannel.beta, 'Beta'),
									],
									if (_busy) ...<Widget>[
										const SizedBox(width: 10),
										const SizedBox(
											width: 12,
											height: 12,
											child: CircularProgressIndicator(strokeWidth: 1.6),
										),
									],
								],
							),
						),
					),
					const SizedBox(height: 6),
					Text(
						ru
								? 'Смена канала выйдет из аккаунта — войдите заново'
								: 'Changing the channel signs you out - sign in again',
						textAlign: TextAlign.center,
						style: const TextStyle(color: GlukColors.text2, fontSize: 10),
					),
				],
			],
		);
	}

	Widget _pill(AppChannel channel, String label) {
		final bool active = AppConfig.activeChannel == channel;
		return InkWell(
			borderRadius: BorderRadius.circular(9),
			onTap: _busy ? null : () => _select(channel),
			child: DecoratedBox(
				decoration: BoxDecoration(
					color: active
							? GlukColors.violet.withOpacity(0.28)
							: Colors.white.withOpacity(0.04),
					borderRadius: BorderRadius.circular(9),
				),
				child: Padding(
					padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
					child: Text(
						label,
						style: TextStyle(
							color: active ? GlukColors.text0 : GlukColors.text1,
							fontSize: 11,
							fontWeight: active ? FontWeight.w700 : FontWeight.w500,
						),
					),
				),
			),
		);
	}
}
