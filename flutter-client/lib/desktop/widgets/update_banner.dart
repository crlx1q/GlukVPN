import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/update_checker.dart';
import '../../theme/tokens.dart';
import '../theme/desktop_theme.dart';

/// "An update is available" strip, pinned above the content.
///
/// It owns its own [UpdateChecker] on purpose. Nothing else in the desktop app
/// needs the result, and a widget that starts and stops its own polling cannot
/// be left half-wired by a later refactor of the shell.
///
/// A failed check renders nothing at all. Not reaching the manifest is not
/// something the user can act on, and a VPN client that complains about its own
/// update server while the tunnel is up would be absurd.
class DesktopUpdateBanner extends StatefulWidget {
	const DesktopUpdateBanner({super.key, required this.russian});

	final bool russian;

	@override
	State<DesktopUpdateBanner> createState() => _DesktopUpdateBannerState();
}

class _DesktopUpdateBannerState extends State<DesktopUpdateBanner> {
	late final UpdateChecker _checker;

	@override
	void initState() {
		super.initState();
		_checker = UpdateChecker()..start();
	}

	@override
	void dispose() {
		_checker.dispose();
		super.dispose();
	}

	Future<void> _download() async {
		final String target = _checker.downloadUrl;
		if (target.isEmpty) return;
		final Uri? uri = Uri.tryParse(target);
		if (uri == null) return;
		// The browser downloads it, not us: an installer fetched and launched by
		// the very program it is about to replace is how you end up with a
		// half-written exe and a client that cannot start.
		await launchUrl(uri, mode: LaunchMode.externalApplication);
	}

	@override
	Widget build(BuildContext context) {
		return AnimatedBuilder(
			animation: _checker,
			builder: (BuildContext context, Widget? child) {
				final ReleaseInfo? release = _checker.latest;
				if (!_checker.bannerVisible || release == null) {
					return const SizedBox.shrink();
				}

				final bool required = _checker.updateRequired;
				final bool ru = widget.russian;
				final Color accent = required ? GlukColors.amber : GlukColors.violet;

				final String title = required
						? (ru
								? 'Эта версия больше не поддерживается — обновите до ${release.version}'
								: 'This version is no longer supported - update to ${release.version}')
						: (ru
								? 'Доступно обновление ${release.version}'
								: 'Update ${release.version} is available');

				return Padding(
					padding: const EdgeInsets.only(bottom: 12),
					child: DecoratedBox(
						decoration: BoxDecoration(
							color: accent.withOpacity(0.10),
							borderRadius: BorderRadius.circular(14),
							border: Border.all(color: accent.withOpacity(0.35)),
						),
						child: Padding(
							padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
							child: Row(
								children: <Widget>[
									Icon(
										required
												? Icons.priority_high_rounded
												: Icons.download_rounded,
										size: 18,
										color: accent,
									),
									const SizedBox(width: 10),
									Expanded(
										child: Column(
											crossAxisAlignment: CrossAxisAlignment.start,
											mainAxisSize: MainAxisSize.min,
											children: <Widget>[
												Text(
													title,
													style: const TextStyle(
														color: GlukColors.text0,
														fontSize: 13,
														fontWeight: FontWeight.w600,
													),
												),
												if (release.changelog.isNotEmpty) ...<Widget>[
													const SizedBox(height: 2),
													Text(
														release.changelog,
														maxLines: 2,
														overflow: TextOverflow.ellipsis,
														style: const TextStyle(
															color: GlukColors.text1,
															fontSize: 12,
														),
													),
												],
											],
										),
									),
									const SizedBox(width: 12),
									TextButton(
										onPressed: _download,
										style: TextButton.styleFrom(
											foregroundColor: accent,
											padding: const EdgeInsets.symmetric(
												horizontal: 14,
												vertical: 8,
											),
											shape: RoundedRectangleBorder(
												borderRadius: BorderRadius.circular(10),
											),
										),
										child: Text(
											ru ? 'Скачать' : 'Download',
											style: const TextStyle(
												fontSize: 13,
												fontWeight: FontWeight.w600,
											),
										),
									),
									// A required update has no dismiss: hiding it would leave the
									// user on a build the server has stopped accepting.
									if (!required)
										IconButton(
											tooltip: ru ? 'Позже' : 'Later',
											onPressed: _checker.dismiss,
											icon: const Icon(Icons.close_rounded, size: 16),
											color: GlukColors.text2,
											splashRadius: 16,
											constraints: const BoxConstraints.tightFor(
												width: 32,
												height: 32,
											),
											padding: EdgeInsets.zero,
										),
								],
							),
						),
					),
				);
			},
		);
	}
}
