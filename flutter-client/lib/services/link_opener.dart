import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// ROUND 11: opens an external link, and degrades honestly when it cannot.
///
/// Three places needed this at once - Telegram sign-in, the last step of
/// sign-up, and the download link in the update banner - and all three used to
/// copy a URL to the clipboard and tell the user to paste it somewhere. That is
/// not a fallback, it was the whole feature.
///
/// The clipboard is still the fallback, because it is the only one that works:
/// a phone with no browser and no Telegram installed cannot be talked into
/// having one. The difference is that it is now what happens when the launch
/// fails, not what happens always.
class LinkOpener {
	LinkOpener._();

	/// Tries to hand [url] to the system. Returns true when something took it.
	///
	/// `externalApplication` rather than the default: a `t.me` link must land in
	/// the Telegram app when it is installed, and an in-app web view would show
	/// the web preview page instead, which is exactly the wrong place to press
	/// "share contact".
	static Future<bool> open(String url) async {
		final String trimmed = url.trim();
		if (trimmed.isEmpty) return false;
		final Uri? uri = Uri.tryParse(trimmed);
		if (uri == null || !uri.hasScheme) return false;
		try {
			return await launchUrl(uri, mode: LaunchMode.externalApplication);
		} catch (_) {
			// A missing activity, a blocked intent, a malformed scheme: all of them
			// mean the same thing to the caller.
			return false;
		}
	}

	/// Opens [url], and on failure copies it and says so.
	///
	/// [failureMessage] is passed in rather than built here so the caller can use
	/// the localised string it already has.
	static Future<bool> openOrCopy(
		BuildContext context,
		String url, {
		required String failureMessage,
	}) async {
		if (await open(url)) return true;
		await Clipboard.setData(ClipboardData(text: url));
		if (!context.mounted) return false;
		ScaffoldMessenger.of(context).showSnackBar(
			SnackBar(content: Text(failureMessage), duration: const Duration(seconds: 5)),
		);
		return false;
	}
}
