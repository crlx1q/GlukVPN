import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/update_checker.dart';
import '../theme/tokens.dart';
import 'glass.dart';

/// "A new version is out" strip, shown above whatever is on screen.
///
/// ROUND 10 (4.3). The desktop client has had this since round 4; the phone
/// had the [UpdateChecker] service wired to nothing at all, so a stale APK
/// stayed stale in silence.
///
/// Rules kept from the desktop behaviour, because they are the honest ones:
///  * a failed check shows nothing - an older build still works,
///  * a normal update can be dismissed and comes back next launch,
///  * a build older than `minSupportedVersion` cannot be dismissed, because it
///    genuinely cannot talk to the control plane any more.
///
/// There is no `url_launcher` in this project, and adding a plugin for one
/// button is not worth a native dependency, so Download copies the link and
/// says so. The address is also printed, which is what somebody types when the
/// clipboard is the thing that failed.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final UpdateChecker updates = context.watch<UpdateChecker>();
    if (!updates.bannerVisible) return const SizedBox.shrink();

    final TextTheme text = Theme.of(context).textTheme;
    final ReleaseInfo? release = updates.latest;
    final bool required = updates.updateRequired;
    final Color tone = required ? GlukColors.amber : GlukColors.violetLight;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: GlassPanel(
          radius: GlukSizes.cellRadius,
          color: tone.withOpacity(0.10),
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    required
                        ? Icons.priority_high_rounded
                        : Icons.system_update_alt_rounded,
                    size: 18,
                    color: tone,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      required
                          ? 'Update required \u00b7 ${release?.version ?? ''}'
                          : 'Version ${release?.version ?? ''} is available',
                      style: text.titleMedium?.copyWith(color: tone),
                    ),
                  ),
                  if (!required)
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 18),
                      color: GlukColors.text2,
                      tooltip: 'Hide until next launch',
                      onPressed: updates.dismiss,
                    ),
                ],
              ),
              if ((release?.changelog ?? '').isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  release!.changelog,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall,
                ),
              ],
              if (required) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  'This build is older than the oldest version the servers '
                  'still accept.',
                  style: text.bodySmall,
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      updates.downloadUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall?.copyWith(color: GlukColors.text2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => _copy(context, updates.downloadUrl),
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: const Text('Copy link'),
                    style: TextButton.styleFrom(foregroundColor: tone),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _copy(BuildContext context, String url) {
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Download link copied')),
    );
  }
}
