import 'package:flutter/material.dart';

import '../../config.dart';
import '../../theme/tokens.dart';

/// The version line at the bottom of Settings, and the developer menu hidden
/// behind it.
///
/// Ordinary users must never see a channel switch. Pointing a normal install at
/// beta hands them a control plane full of test data and half-finished nodes,
/// and nothing on screen would explain why their VPN suddenly behaves oddly. So
/// the switch sits behind five clicks on the version number, and is open from
/// the start only in internal builds.
///
/// The switch is deliberately symmetric: it stays reachable while beta is
/// active. A one-way door would mean the only way back to prod is a reinstall.
class DevChannelFooter extends StatefulWidget {
	const DevChannelFooter({
		super.key,
		required this.russian,
		required this.onChannelChanged,
		this.alwaysVisible = false,
	});

	final bool russian;

	/// For admins and testers: skip the five clicks.
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
	static const int _tapsToOpen = 5;
	/// Long enough to be deliberate, short enough that idle clicking on the
	/// version number never opens it by accident.
	static const Duration _tapWindow = Duration(seconds: 3);

	int _taps = 0;
	DateTime? _firstTap;
	bool _open = false;
	bool _busy = false;

	bool get _visible =>
			_open || widget.alwaysVisible || AppConfig.internalBuild;

	void _countTap() {
		if (_visible) return;
		final DateTime now = DateTime.now();
		if (_firstTap == null || now.difference(_firstTap!) > _tapWindow) {
			_firstTap = now;
			_taps = 0;
		}
		_taps++;
		if (_taps >= _tapsToOpen) setState(() => _open = true);
	}

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
				GestureDetector(
					behavior: HitTestBehavior.opaque,
					onTap: _countTap,
					child: Text(
						'GlukVPN Desktop ${AppConfig.appVersion} · '
						'${AppConfig.activeChannel.label}',
						style: const TextStyle(color: GlukColors.text2, fontSize: 11),
					),
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
