import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../../utils/format.dart';
import '../../widgets/glass.dart';
import '../i18n/desktop_strings.dart';
import '../state/usage_store.dart';
import '../widgets/metric_cell.dart';

/// Traffic statistics (requirement 18).
///
/// Data comes from the local usage store, which is keyed by account rather
/// than device, so removing this PC from the Devices list does not erase the
/// history.
class DesktopStatsScreen extends StatelessWidget {
  const DesktopStatsScreen({
    super.key,
    required this.usage,
    required this.strings,
  });

  final UsageSnapshot usage;
  final DesktopStrings strings;

  @override
  Widget build(BuildContext context) {
    final s = strings;

    return ListView(
      padding: const EdgeInsets.all(GlukSizes.pagePadding),
      children: <Widget>[
        Text(
          s.statistics,
          style: const TextStyle(
            color: GlukColors.text0,
            fontSize: 20,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 18),

        MetricRow(
          children: <Widget>[
            MetricCell(
              label: s.today,
              value: formatBytes(usage.today.totalBytes),
              monospace: true,
              icon: Icons.today_rounded,
            ),
            MetricCell(
              label: s.thisMonth,
              value: formatBytes(usage.thisMonth.totalBytes),
              monospace: true,
              icon: Icons.calendar_month_rounded,
            ),
            MetricCell(
              label: s.allTime,
              value: formatBytes(usage.allTime.totalBytes),
              monospace: true,
              icon: Icons.all_inclusive_rounded,
            ),
          ],
        ),

        const SizedBox(height: 12),

        MetricRow(
          children: <Widget>[
            MetricCell(
              label: '${s.downloaded} · ${s.allTime}',
              value: formatBytes(usage.allTime.rxBytes),
              monospace: true,
              valueColor: GlukColors.connected,
            ),
            MetricCell(
              label: '${s.uploaded} · ${s.allTime}',
              value: formatBytes(usage.allTime.txBytes),
              monospace: true,
              valueColor: GlukColors.violetLight,
            ),
            MetricCell(
              label: s.vpnTime,
              value: formatDuration(usage.allTime.duration),
              monospace: true,
            ),
          ],
        ),

        const SizedBox(height: 22),

        Text(
          s.lastDays.toUpperCase(),
          style: const TextStyle(
            color: GlukColors.text2,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.3,
          ),
        ),
        const SizedBox(height: 10),

        if (usage.recentDays.isEmpty)
          GlassPanel(
            radius: 18,
            padding: const EdgeInsets.symmetric(vertical: 34),
            child: Center(
              child: Text(
                s.noStats,
                style: const TextStyle(
                  color: GlukColors.text2,
                  fontSize: 13,
                ),
              ),
            ),
          )
        else
          GlassPanel(
            radius: 18,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                _DayChart(days: usage.recentDays),
                const SizedBox(height: 16),
                for (final day in usage.recentDays)
                  _DayRow(day: day, strings: s),
              ],
            ),
          ),

        const SizedBox(height: 16),
      ],
    );
  }
}

/// Simple bar chart. Rendered with plain widgets so the desktop build does
/// not pull in a charting dependency for one screen.
class _DayChart extends StatelessWidget {
  const _DayChart({required this.days});

  final List<UsageBucket> days;

  @override
  Widget build(BuildContext context) {
    final ordered = days.reversed.toList();
    final peak = ordered.fold<int>(
      1,
      (int max, UsageBucket b) => b.totalBytes > max ? b.totalBytes : max,
    );

    return SizedBox(
      height: 96,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          for (final day in ordered)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Tooltip(
                  message: '${day.key}\n${formatBytes(day.totalBytes)}',
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      Container(
                        height: (day.totalBytes / peak * 78).clamp(2.0, 78.0),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          gradient: const LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: <Color>[
                              GlukColors.violet2,
                              GlukColors.violetLight,
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        day.key.substring(day.key.length - 2),
                        style: const TextStyle(
                          color: GlukColors.text2,
                          fontSize: 9,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.day, required this.strings});

  final UsageBucket day;
  final DesktopStrings strings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(
              day.key,
              style: const TextStyle(
                color: GlukColors.text1,
                fontSize: 12,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Text(
              '↓ ${formatBytes(day.rxBytes)}',
              style: const TextStyle(
                color: GlukColors.connected,
                fontSize: 12,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Text(
              '↑ ${formatBytes(day.txBytes)}',
              style: const TextStyle(
                color: GlukColors.violetLight,
                fontSize: 12,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(
            width: 78,
            child: Text(
              formatDuration(day.duration),
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: GlukColors.text2,
                fontSize: 12,
                fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
