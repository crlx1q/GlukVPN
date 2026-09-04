/// The device list the control plane sends with a 409 `device_limit_reached`.
///
/// Registration is refused when every slot on the account is taken. Rather than
/// showing that as an error the user can do nothing about, the server attaches
/// the devices currently holding the slots so the client can offer to sign one
/// of them out and try again.
///
/// Deliberately a separate, tolerant model rather than a reuse of `DeviceInfo`:
/// this arrives inside an error body from a server that may be older than the
/// app, so every field is optional and nothing here can throw while parsing.
library;

String _string(Object? value) => value is String ? value : '';

bool _bool(Object? value) => value is bool ? value : false;

DateTime? _date(Object? value) {
	if (value is! String || value.isEmpty) return null;
	return DateTime.tryParse(value)?.toLocal();
}

/// One device occupying a slot.
class DeviceLimitSlot {
	const DeviceLimitSlot({
		required this.id,
		required this.deviceName,
		required this.platform,
		required this.connected,
		this.lastSeen,
	});

	factory DeviceLimitSlot.fromJson(Map<String, dynamic> json) => DeviceLimitSlot(
				id: _string(json['id']),
				deviceName: _string(json['deviceName']),
				platform: _string(json['platform']),
				connected: _bool(json['connected']),
				lastSeen: _date(json['lastSeen']),
			);

	final String id;
	final String deviceName;
	final String platform;

	/// A tunnel is up on this device right now. Revoking it will drop it.
	final bool connected;
	final DateTime? lastSeen;

	bool get isUsable => id.isNotEmpty;

	/// Never empty: an unnamed device still has to be pickable from the list.
	String label(bool ru) {
		if (deviceName.isNotEmpty) return deviceName;
		if (platform.isNotEmpty) return platform;
		return ru ? 'Устройство' : 'Device';
	}
}

/// Why registration was refused, and what could be freed to allow it.
class DeviceLimitDetails {
	const DeviceLimitDetails({required this.maxDevices, required this.devices});

	factory DeviceLimitDetails.fromJson(Map<String, dynamic>? json) {
		if (json == null) return const DeviceLimitDetails(maxDevices: 0, devices: <DeviceLimitSlot>[]);
		final Object? raw = json['devices'];
		final List<DeviceLimitSlot> devices = raw is List
				? raw
						.whereType<Map<Object?, Object?>>()
						.map((Map<Object?, Object?> item) => DeviceLimitSlot.fromJson(
									item.map((Object? key, Object? value) =>
											MapEntry<String, dynamic>(key.toString(), value)),
								))
						.where((DeviceLimitSlot slot) => slot.isUsable)
						.toList()
				: <DeviceLimitSlot>[];

		// Never fall back to a hard-coded 5: the ceiling is whatever the account's
		// plan allows, and price.md gives Free 1, Basic 3 and Pro 5. Showing
		// "5 / 5" to someone on Basic would be a lie about what they bought.
		final Object? max = json['maxDevices'];
		final int maxDevices = max is int
				? max
				: max is num
						? max.toInt()
						: devices.length;

		return DeviceLimitDetails(maxDevices: maxDevices, devices: devices);
	}

	final int maxDevices;
	final List<DeviceLimitSlot> devices;

	/// Nothing to offer: without a device list the dialog would be an empty box,
	/// and the caller should fall back to showing the plain error message.
	bool get isActionable => devices.isNotEmpty;

	/// "5 / 5" — used as the dialog's subtitle.
	String get usage {
		final int total = maxDevices > 0 ? maxDevices : devices.length;
		return '${devices.length} / $total';
	}
}
