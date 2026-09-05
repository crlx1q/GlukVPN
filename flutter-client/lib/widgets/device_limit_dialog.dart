import 'package:flutter/material.dart';

import '../i18n/app_strings.dart';
import '../models/device_limit.dart';
import '../theme/tokens.dart';

/// "Device limit (5 / 5)" — offered instead of an error the user cannot act on.
///
/// The account has no free slot, so registration was refused. Showing that as
/// a bare message leaves someone with a paid plan unable to use the app on the
/// phone in their hand; showing the devices that hold the slots lets them sign
/// one out and carry on.
///
/// Returns the id of the device the user chose to sign out, or null if they
/// dismissed the dialog.
Future<String?> showDeviceLimitDialog({
  required BuildContext context,
  required DeviceLimitDetails details,
  required AppStrings strings,
}) {
  return showDialog<String>(
    context: context,
    // Deliberately dismissible: being trapped in a modal is worse than being
    // at the device limit.
    builder: (BuildContext ctx) => _DeviceLimitDialog(details: details, strings: strings),
  );
}

class _DeviceLimitDialog extends StatelessWidget {
  const _DeviceLimitDialog({required this.details, required this.strings});

  final DeviceLimitDetails details;
  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final bool ru = strings.isRussian;
    return AlertDialog(
      backgroundColor: GlukColors.bg,
      title: Text(
        ru ? 'Лимит устройств (${details.usage})' : 'Device limit (${details.usage})',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            ru
                ? 'Все слоты заняты. Выберите устройство, которое нужно отключить, '
                    'чтобы войти на этом.'
                : 'Every slot is taken. Pick a device to sign out so this one can '
                    'sign in.',
            style: const TextStyle(color: GlukColors.text1, fontSize: 13),
          ),
          const SizedBox(height: 14),
          // The list can be as long as the plan ceiling, so it scrolls rather
          // than pushing the buttons off a short screen.
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: details.devices
                    .map((DeviceLimitSlot slot) => _SlotRow(slot: slot, ru: ru))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(ru ? 'Отмена' : 'Cancel'),
        ),
      ],
    );
  }
}

class _SlotRow extends StatelessWidget {
  const _SlotRow({required this.slot, required this.ru});

  final DeviceLimitSlot slot;
  final bool ru;

  String get _subtitle {
    final List<String> parts = <String>[];
    if (slot.platform.isNotEmpty) parts.add(slot.platform);
    final String node = slot.connectedNode?.label ?? '';
    if (node.isNotEmpty) parts.add(node);
    if (slot.connected) {
      parts.add(ru ? 'подключено сейчас' : 'connected now');
    } else if (slot.lastSeen != null) {
      final DateTime seen = slot.lastSeen!;
      final String stamp = '${seen.day.toString().padLeft(2, '0')}.'
          '${seen.month.toString().padLeft(2, '0')} '
          '${seen.hour.toString().padLeft(2, '0')}:'
          '${seen.minute.toString().padLeft(2, '0')}';
      parts.add(ru ? 'было в сети $stamp' : 'last seen $stamp');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: GlukColors.cell,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).pop(slot.id),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(
                  slot.connected ? Icons.lan_rounded : Icons.devices_other_rounded,
                  size: 18,
                  color: slot.connected ? GlukColors.connected : GlukColors.text1,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        slot.label(ru),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      if (_subtitle.isNotEmpty)
                        Text(
                          _subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: GlukColors.text1, fontSize: 11),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  ru ? 'Выйти' : 'Sign out',
                  style: const TextStyle(
                    color: GlukColors.violetLight,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
