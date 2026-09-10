import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../i18n/app_strings.dart';
import '../services/link_opener.dart';
import '../services/update_checker.dart';
import '../theme/tokens.dart';

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
/// ROUND 27 fixes the two things that were wrong with it on a phone.
///
/// The action copied the link, because there was no `url_launcher` in the
/// project when this was written. There has been one since round 11
/// ([LinkOpener]), and the desktop banner has opened the download page
/// directly the whole time. The phone does the same now; the clipboard is
/// what happens when nothing on the device will take an https link, which
/// makes it a fallback instead of the feature.
///
/// The strip was also built out of `GlassPanel` - a translucent film over a
/// backdrop blur. That is the right surface for a card lying on the dotted
/// world map and the wrong one for a notice: the map and the screen behind it
/// read straight through the text. The accent tint is composited onto
/// [GlukColors.bg] now rather than laid over it, so the fill is genuinely
/// opaque, and it casts a shadow because it floats above the page instead of
/// belonging to it.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final UpdateChecker updates = context.watch<UpdateChecker>();
    if (!updates.bannerVisible) return const SizedBox.shrink();

    final AppStrings s = context.strings;
    final TextTheme text = Theme.of(context).textTheme;
    final ReleaseInfo? release = updates.latest;
    final bool required = updates.updateRequired;
    final Color tone = required ? GlukColors.amber : GlukColors.violetLight;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: DecoratedBox(
          decoration: BoxDecoration(
            // alphaBlend, not withOpacity: this is one solid colour with the
            // same tint, so nothing behind the banner shows through it.
            color: Color.alphaBlend(tone.withOpacity(0.14), GlukColors.bg),
            borderRadius: BorderRadius.circular(GlukSizes.cellRadius),
            border: Border.all(color: tone.withOpacity(0.38)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Colors.black.withOpacity(0.45),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
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
                            ? '${s.updateRequired} \u00b7 ${release?.version ?? ''}'
                            : s.newVersion(release?.version ?? ''),
                        style: text.titleMedium?.copyWith(color: tone),
                      ),
                    ),
                    if (!required)
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        color: GlukColors.text2,
                        tooltip: s.hideUntilNextLaunch,
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
                  Text(s.buildTooOld, style: text.bodySmall),
                ],
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    // The address stays on screen: it is what somebody reads
                    // out or retypes when the phone has no browser to open.
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
                      onPressed: () => LinkOpener.openOrCopy(
                        context,
                        updates.downloadUrl,
                        failureMessage: s.downloadLinkCopied,
                      ),
                      icon: const Icon(Icons.download_rounded, size: 15),
                      label: Text(s.download),
                      style: TextButton.styleFrom(foregroundColor: tone),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
