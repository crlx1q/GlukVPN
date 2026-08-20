import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Central switch for the app's animations.
///
/// The mockup is full of infinite loops: a spinning globe, a pulsing halo,
/// marching dashes on the connection arc, morphing blobs. They look great and
/// they repaint every frame, which on a phone means the GPU never idles.
///
/// So every looping animation asks this controller first. It reports
/// [reduceMotion] when any of these is true:
///
///  * the OS is in battery-saver / low-power mode (`battery_plus`);
///  * the user enabled "Remove animations" in accessibility settings
///    (`MediaQuery.disableAnimations`);
///  * the battery is critically low (below 15%) while not charging.
///
/// In that state loops stop at a representative frame instead of running - the
/// screen still looks like the mockup, it simply stops moving. One-shot
/// transitions are shortened rather than removed, because instant screen swaps
/// feel broken rather than efficient.
class MotionController extends ChangeNotifier with WidgetsBindingObserver {
	MotionController({Battery? battery}) : _battery = battery ?? Battery() {
		WidgetsBinding.instance.addObserver(this);
		_refresh();
		_batterySubscription = _battery.onBatteryStateChanged.listen((_) => _refresh());
	}

	final Battery _battery;
	StreamSubscription<BatteryState>? _batterySubscription;

	/// Below this, animations stop even without the OS saver enabled.
	static const _lowBatteryThreshold = 15;

	bool _powerSaveMode = false;
	bool _lowBattery = false;
	bool _systemDisablesAnimations = false;
	bool _appPaused = false;

	bool get powerSaveMode => _powerSaveMode;
	bool get lowBattery => _lowBattery;

	/// True when looping animations should hold still.
	bool get reduceMotion =>
			_powerSaveMode || _lowBattery || _systemDisablesAnimations || _appPaused;

	/// Human-readable reason, shown in Settings so the user knows why the map
	/// stopped moving instead of assuming the app is broken.
	String? get reduceMotionReason {
		if (_systemDisablesAnimations) return 'System animations are turned off';
		if (_powerSaveMode) return 'Battery saver is on';
		if (_lowBattery) return 'Battery below $_lowBatteryThreshold%';
		return null;
	}

	/// Pick up the accessibility flag. Call from a widget that has a context.
	void syncWithMediaQuery(BuildContext context) {
		final disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
		if (disabled != _systemDisablesAnimations) {
			_systemDisablesAnimations = disabled;
			// Called during build; defer so we never notify mid-frame.
			scheduleMicrotask(notifyListeners);
		}
	}

	/// A looping duration: null means "do not animate".
	Duration? loop(Duration duration) => reduceMotion ? null : duration;

	/// A one-shot duration, shortened but never removed.
	Duration transition(Duration duration) => reduceMotion
			? Duration(milliseconds: (duration.inMilliseconds * 0.45).round())
			: duration;

	/// Polling intervals scale back too - the ping ticker is as expensive as a
	/// repaint when it fires every three seconds.
	Duration poll(Duration duration) =>
			reduceMotion ? duration * 2 : duration;

	Future<void> _refresh() async {
		try {
			final saveMode = await _battery.isInBatterySaveMode;
			final level = await _battery.batteryLevel;
			final state = await _battery.batteryState;
			final charging = state == BatteryState.charging || state == BatteryState.full;

			final nextLow = !charging && level <= _lowBatteryThreshold;
			if (saveMode != _powerSaveMode || nextLow != _lowBattery) {
				_powerSaveMode = saveMode;
				_lowBattery = nextLow;
				notifyListeners();
			}
		} catch (error) {
			// Emulators and some OEM ROMs do not implement the battery channel.
			// Animations stay on; that is the safe default for a demo device.
			debugPrint('MotionController: battery state unavailable ($error)');
		}
	}

	@override
	void didChangeAppLifecycleState(AppLifecycleState state) {
		// Nothing should animate while the app is not on screen.
		final paused = state != AppLifecycleState.resumed;
		if (paused != _appPaused) {
			_appPaused = paused;
			notifyListeners();
		}
		if (state == AppLifecycleState.resumed) {
			_refresh();
		}
	}

	@override
	void dispose() {
		WidgetsBinding.instance.removeObserver(this);
		_batterySubscription?.cancel();
		super.dispose();
	}
}

/// Convenience wrapper: runs [builder] against a looping ticker that is frozen
/// at [frozenValue] when motion is reduced.
///
/// Using this instead of a bare AnimationController everywhere keeps the
/// battery-saver behaviour in one place and makes it impossible to forget.
class LoopingBuilder extends StatefulWidget {
	const LoopingBuilder({
		super.key,
		required this.duration,
		required this.reduceMotion,
		required this.builder,
		this.frozenValue = 0.0,
		this.reverse = false,
	});

	final Duration duration;
	final bool reduceMotion;
	final double frozenValue;

	/// When true the loop plays forwards then backwards (CSS `alternate`).
	final bool reverse;
	final Widget Function(BuildContext context, double t) builder;

	@override
	State<LoopingBuilder> createState() => _LoopingBuilderState();
}

class _LoopingBuilderState extends State<LoopingBuilder>
		with SingleTickerProviderStateMixin {
	late final AnimationController _controller = AnimationController(
		vsync: this,
		duration: widget.duration,
	);

	@override
	void initState() {
		super.initState();
		_apply();
	}

	@override
	void didUpdateWidget(LoopingBuilder oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (oldWidget.duration != widget.duration) {
			_controller.duration = widget.duration;
		}
		if (oldWidget.reduceMotion != widget.reduceMotion) {
			_apply();
		}
	}

	void _apply() {
		if (widget.reduceMotion) {
			_controller.stop();
			_controller.value = widget.frozenValue;
		} else {
			_controller.repeat(reverse: widget.reverse);
		}
	}

	@override
	void dispose() {
		_controller.dispose();
		super.dispose();
	}

	@override
	Widget build(BuildContext context) {
		// A frozen loop needs no AnimatedBuilder at all: build once, repaint never.
		if (widget.reduceMotion) {
			return widget.builder(context, widget.frozenValue);
		}
		return AnimatedBuilder(
			animation: _controller,
			builder: (context, _) => widget.builder(context, _controller.value),
		);
	}
}
