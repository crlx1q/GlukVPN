/**
 * Branded HTML for transactional mail.
 *
 * Codes used to leave as four lines of plain text. That delivers, but it reads
 * like a system notice from 2003 - and a code that looks unofficial is a code
 * people hesitate to trust, which is exactly the wrong instinct to train in
 * users who will later have to spot a lookalike phishing mail.
 *
 * Constraints that shape every decision below:
 *   - tables, not flexbox or grid: Outlook renders through Word, which knows
 *     neither;
 *   - inline styles only, no <style> block: Gmail drops it when mail is
 *     forwarded, so anything that matters has to sit on the element;
 *   - a plain-text alternative always ships alongside - plenty of clients
 *     refuse HTML, and the code has to survive that untouched;
 *   - every dark cell carries its own bgcolor *and* background: a client that
 *     ignores the outer table must not end up with dark text on dark paper;
 *   - no remote images at all. A logo fetched from our domain would turn every
 *     open into a tracking ping and would show as a broken box in the many
 *     clients that block images by default, so the mark is a rounded table
 *     cell with a letter in it.
 */

const INK = {
	page: "#05040A",
	card: "#120E1E",
	well: "#0A0714",
	edge: "#241A3A",
	text: "#F5F3FB",
	muted: "#9994AB",
	faint: "#5C5770",
	accent: "#8B5CF6",
	accentSoft: "#C4B5FD",
}

const FONT =
	"-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"
const MONO = "'SFMono-Regular',Consolas,'Liberation Mono',Menlo,monospace"

export type CodeMailKind =
	| "register"
	| "emailChange"
	| "passwordReset"
	| "deviceConfirm"

type Copy = {
	/** Kicker above the heading. Short, uppercase, tells the flow at a glance. */
	action: string
	heading: string
	lead: string
}

/**
 * One entry per flow. The code is identical in all of them; what changes is
 * the sentence that tells the reader *why* they got it - which is the part
 * that makes an unexpected code obviously wrong rather than merely confusing.
 */
const COPY: Record<CodeMailKind, Copy> = {
	register: {
		action: "Регистрация",
		heading: "Подтвердите адрес",
		lead: "Вы создаёте аккаунт GlukVPN. Введите код в приложении или на сайте, чтобы закончить регистрацию.",
	},
	emailChange: {
		action: "Смена почты",
		heading: "Подтвердите новый адрес",
		lead: "Этот адрес хотят привязать к аккаунту GlukVPN. Пока код не введён, почта в аккаунте остаётся прежней.",
	},
	passwordReset: {
		action: "Восстановление доступа",
		heading: "Код для нового пароля",
		lead: "Кто-то запросил смену пароля в GlukVPN. Введите код, чтобы задать новый пароль.",
	},
	deviceConfirm: {
		action: "Новое устройство",
		heading: "Подтвердите вход",
		lead: "В аккаунт GlukVPN входят с нового устройства. Введите код, чтобы разрешить вход.",
	},
}

/** The code is digits, but the copy is not - and templates are not escaping. */
function escapeHtml(value: string): string {
	return value
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;")
}

/** "5 минут", "1 минуту", "22 минуты" - a wrong ending reads like a bug. */
function minutesWord(minutes: number): string {
	const teen = minutes % 100
	const tail = minutes % 10
	if (teen >= 11 && teen <= 14) return "минут"
	if (tail === 1) return "минуту"
	if (tail >= 2 && tail <= 4) return "минуты"
	return "минут"
}

export type RenderedMail = {
	subject: string
	text: string
	html: string
}

/**
 * Render one confirmation-code message.
 *
 * The subject leads with the code on purpose: it is what the notification
 * shade shows, and being able to read the code without opening the mail is a
 * real convenience on a phone.
 */
export function codeMail(params: {
	code: string
	ttlMinutes: number
	kind?: CodeMailKind
}): RenderedMail {
	const copy = COPY[params.kind ?? "register"]
	const ttl = `${params.ttlMinutes} ${minutesWord(params.ttlMinutes)}`
	const code = escapeHtml(params.code)
	const guard =
		"Код вводится только в приложении GlukVPN или на vpn.gluk.tech. Мы никогда не спрашиваем его в переписке, по телефону или в ответном письме."
	const ignore =
		"Если код запрашивали не вы — просто удалите письмо, без него ничего не произойдёт."

	const html = `<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<meta name="color-scheme" content="dark light" />
<title>${escapeHtml(copy.heading)}</title>
</head>
<body style="margin:0;padding:0;background:${INK.page};">
<div style="display:none;font-size:1px;line-height:1px;max-height:0;max-width:0;opacity:0;overflow:hidden;color:${INK.page};">Код ${code}, действует ${ttl}.</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${INK.page}" style="background:${INK.page};">
<tr><td align="center" style="padding:32px 16px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:520px;">

<tr><td align="left" style="padding:0 4px 18px;">
<table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
<td width="34" height="34" align="center" valign="middle" bgcolor="${INK.accent}" style="width:34px;height:34px;border-radius:11px;background:${INK.accent};font-family:${FONT};font-size:18px;font-weight:700;color:#FFFFFF;">G</td>
<td style="padding-left:10px;font-family:${FONT};font-size:17px;font-weight:600;letter-spacing:.2px;color:${INK.text};">GlukVPN</td>
</tr></table>
</td></tr>

<tr><td bgcolor="${INK.card}" style="background:${INK.card};border:1px solid ${INK.edge};border-radius:18px;padding:26px 26px 22px;">
<div style="font-family:${FONT};font-size:11px;font-weight:700;letter-spacing:1.4px;text-transform:uppercase;color:${INK.accentSoft};">${escapeHtml(copy.action)}</div>
<h1 style="margin:10px 0 0;font-family:${FONT};font-size:23px;line-height:1.25;font-weight:700;color:${INK.text};">${escapeHtml(copy.heading)}</h1>
<p style="margin:12px 0 0;font-family:${FONT};font-size:15px;line-height:1.6;color:${INK.muted};">${escapeHtml(copy.lead)}</p>

<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:22px 0 0;">
<tr><td align="center" bgcolor="${INK.well}" style="background:${INK.well};border:1px dashed ${INK.accent};border-radius:14px;padding:18px 12px 14px;">
<div style="font-family:${MONO};font-size:32px;line-height:1.1;font-weight:700;letter-spacing:9px;color:${INK.text};">${code}</div>
<div style="margin-top:8px;font-family:${FONT};font-size:13px;color:${INK.faint};">действует ${ttl}</div>
</td></tr>
</table>

<p style="margin:20px 0 0;font-family:${FONT};font-size:13px;line-height:1.6;color:${INK.faint};">${escapeHtml(guard)}</p>
</td></tr>

<tr><td style="padding:18px 6px 0;font-family:${FONT};font-size:12px;line-height:1.6;color:${INK.faint};">
${escapeHtml(ignore)}<br />
<a href="https://vpn.gluk.tech" style="color:${INK.accentSoft};text-decoration:none;">vpn.gluk.tech</a> &middot; письмо отправлено автоматически, отвечать на него не нужно
</td></tr>

</table>
</td></tr>
</table>
</body>
</html>`

	const text = [
		copy.heading,
		"",
		copy.lead,
		"",
		`Код: ${params.code}`,
		`Действует ${ttl}.`,
		"",
		guard,
		"",
		ignore,
		"",
		"— GlukVPN, vpn.gluk.tech",
	].join("\n")

	return {
		subject: `${params.code} — код подтверждения GlukVPN`,
		text,
		html,
	}
}
