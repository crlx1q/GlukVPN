import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// The frosted panel used throughout the mockup (`.cell`, `.traffic`,
/// `.navbar`): a translucent dark fill, a hairline stroke and a real backdrop
/// blur so the world map shows through.
class GlassPanel extends StatelessWidget {
	const GlassPanel({
		super.key,
		required this.child,
		this.padding = const EdgeInsets.fromLTRB(13, 12, 13, 12),
		this.radius = GlukSizes.cellRadius,
		this.color = GlukColors.cell,
		this.blur = 12,
		this.border = true,
		this.onTap,
	});

	final Widget child;
	final EdgeInsetsGeometry padding;
	final double radius;
	final Color color;
	final double blur;
	final bool border;
	final VoidCallback? onTap;

	@override
	Widget build(BuildContext context) {
		final shape = BorderRadius.circular(radius);
		final panel = ClipRRect(
			borderRadius: shape,
			child: BackdropFilter(
				filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
				child: DecoratedBox(
					decoration: BoxDecoration(
						color: color,
						borderRadius: shape,
						border: border
								? Border.all(color: Colors.white.withOpacity(0.07))
								: null,
					),
					child: Padding(padding: padding, child: child),
				),
			),
		);

		if (onTap == null) return panel;
		return Material(
			color: Colors.transparent,
			borderRadius: shape,
			clipBehavior: Clip.antiAlias,
			child: InkWell(
				borderRadius: shape,
				splashColor: GlukColors.violet.withOpacity(0.12),
				highlightColor: Colors.white.withOpacity(0.03),
				onTap: onTap,
				child: panel,
			),
		);
	}
}

/// `.cell` - a labelled readout. The label is uppercase 10 px, the value
/// 15 px bold with tabular figures so ticking numbers do not shift.
class StatCell extends StatelessWidget {
	const StatCell({
		super.key,
		required this.label,
		required this.value,
		this.valueColor,
		this.trailing,
	});

	final String label;
	final String value;
	final Color? valueColor;
	final Widget? trailing;

	@override
	Widget build(BuildContext context) {
		final text = Theme.of(context).textTheme;
		return GlassPanel(
			child: Column(
				crossAxisAlignment: CrossAxisAlignment.start,
				mainAxisSize: MainAxisSize.min,
				children: [
					Text(label.toUpperCase(), style: text.labelMedium),
					const SizedBox(height: 5),
					Row(
						children: [
							Flexible(
								child: Text(
									value,
									maxLines: 1,
									overflow: TextOverflow.ellipsis,
									style: text.labelLarge?.copyWith(color: valueColor),
								),
							),
							if (trailing != null) ...[const SizedBox(width: 6), trailing!],
						],
					),
				],
			),
		);
	}
}

/// `.badge` - the connection state pill. Blinks slowly while connecting, holds
/// steady otherwise (and never blinks when motion is reduced).
class StatusBadge extends StatelessWidget {
	const StatusBadge({
		super.key,
		required this.label,
		required this.tone,
		this.blinking = false,
	});

	final String label;
	final Color tone;
	final bool blinking;

	@override
	Widget build(BuildContext context) {
		final text = Theme.of(context).textTheme;
		return Container(
			padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
			decoration: BoxDecoration(
				color: tone.withOpacity(0.14),
				borderRadius: BorderRadius.circular(999),
				border: Border.all(color: tone.withOpacity(0.40)),
			),
			child: Row(
				mainAxisSize: MainAxisSize.min,
				children: [
					Container(
						width: 6,
						height: 6,
						decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
					),
					const SizedBox(width: 7),
					Text(
						label.toUpperCase(),
						style: text.labelSmall?.copyWith(color: tone),
					),
				],
			),
		);
	}
}

/// `.flag-circle` - a country flag on a dark disc.
class FlagCircle extends StatelessWidget {
	const FlagCircle({super.key, required this.flag, this.size = GlukSizes.flagCircle});

	final String flag;
	final double size;

	@override
	Widget build(BuildContext context) {
		return Container(
			width: size,
			height: size,
			alignment: Alignment.center,
			decoration: const BoxDecoration(
				color: Color(0xFF141020),
				shape: BoxShape.circle,
			),
			child: Text(flag, style: TextStyle(fontSize: size * 0.55)),
		);
	}
}

/// `.back-btn` - the circular back control used on secondary screens.
class CircleIconButton extends StatelessWidget {
	const CircleIconButton({
		super.key,
		required this.icon,
		required this.onTap,
		this.size = GlukSizes.backButton,
		this.tooltip,
	});

	final IconData icon;
	final VoidCallback onTap;
	final double size;
	final String? tooltip;

	@override
	Widget build(BuildContext context) {
		final button = Material(
			color: Colors.white.withOpacity(0.04),
			shape: const CircleBorder(),
			clipBehavior: Clip.antiAlias,
			child: InkWell(
				onTap: onTap,
				child: SizedBox(
					width: size,
					height: size,
					child: Icon(icon, size: size * 0.45, color: GlukColors.text0),
				),
			),
		);
		return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
	}
}

/// The primary call to action from onboarding (`.lets-go`): a pill with a
/// gradient arrow chip on the right.
class PrimaryPillButton extends StatelessWidget {
	const PrimaryPillButton({
		super.key,
		required this.label,
		required this.onPressed,
		this.icon = Icons.arrow_forward_rounded,
		this.busy = false,
	});

	final String label;
	final VoidCallback? onPressed;
	final IconData icon;
	final bool busy;

	@override
	Widget build(BuildContext context) {
		final text = Theme.of(context).textTheme;
		final enabled = onPressed != null && !busy;
		return Opacity(
			opacity: enabled ? 1 : 0.55,
			child: Material(
				color: Colors.white.withOpacity(0.05),
				borderRadius: BorderRadius.circular(999),
				clipBehavior: Clip.antiAlias,
				child: InkWell(
					onTap: enabled ? onPressed : null,
					child: Container(
						padding: const EdgeInsets.fromLTRB(26, 6, 6, 6),
						decoration: BoxDecoration(
							borderRadius: BorderRadius.circular(999),
							border: Border.all(color: GlukColors.stroke),
						),
						child: Row(
							children: [
								Expanded(
									child: Text(
										label,
										style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
									),
								),
								Container(
									width: 46,
									height: 46,
									alignment: Alignment.center,
									decoration: const BoxDecoration(
										gradient: GlukGradients.arrow,
										shape: BoxShape.circle,
									),
									child: busy
											? const SizedBox(
													width: 18,
													height: 18,
													child: CircularProgressIndicator(
														strokeWidth: 2,
														color: GlukColors.bg,
													),
												)
											: Icon(icon, color: GlukColors.bg, size: 20),
								),
							],
						),
					),
				),
			),
		);
	}
}

/// A short inline message, used for API errors and hints.
class InlineNotice extends StatelessWidget {
	const InlineNotice({super.key, required this.message, this.tone});

	final String message;
	final Color? tone;

	@override
	Widget build(BuildContext context) {
		final colour = tone ?? GlukColors.danger;
		return Container(
			width: double.infinity,
			padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
			decoration: BoxDecoration(
				color: colour.withOpacity(0.10),
				borderRadius: BorderRadius.circular(14),
				border: Border.all(color: colour.withOpacity(0.35)),
			),
			child: Text(
				message,
				style: Theme.of(context)
						.textTheme
						.bodyMedium
						?.copyWith(color: colour, fontWeight: FontWeight.w500),
			),
		);
	}
}
