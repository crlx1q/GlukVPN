/**
 * SMTP delivery for confirmation codes (Zoho Mail).
 *
 * Why this is hand-written instead of nodemailer: deployment runs `npm ci`,
 * which refuses to install anything that is in package.json but missing from
 * package-lock.json. Adding a library from here would mean regenerating a lock
 * file on a machine that is not the one deploying, and a broken `npm ci` takes
 * the entire API down - a far worse failure than the one it would solve. What
 * we actually need is narrow and completely stable: one recipient, one body,
 * AUTH LOGIN, implicit TLS on 465 (or STARTTLS on 587). That is a hundred
 * lines of a protocol that has not changed in forty years.
 *
 * Security notes:
 *   - the password is read from config and never logged, not even on failure;
 *   - the body is base64-encoded, which sidesteps dot-stuffing and line-length
 *     limits entirely - the two classic ways a hand-rolled sender corrupts mail;
 *   - the subject is RFC 2047 encoded, so Cyrillic subjects survive;
 *   - every call is bounded by a timeout, so a hung mail server cannot pin a
 *     request handler open.
 */

import { connect as netConnect, type Socket } from "node:net"
import { connect as tlsConnect, type TLSSocket } from "node:tls"
import { config } from "../config"

const TIMEOUT_MS = 15_000

type Conn = Socket | TLSSocket

type SmtpReply = { code: number; text: string }

/** True when enough of SMTP_* is filled in for a send to be attempted. */
export function mailerConfigured(): boolean {
	return (
		config.SMTP_HOST.trim().length > 0 &&
		config.SMTP_USER.trim().length > 0 &&
		config.SMTP_PASSWORD.length > 0
	)
}

/** The envelope sender. Falls back to the login user, which Zoho requires anyway. */
export function mailFrom(): string {
	const configured = config.SMTP_FROM.trim()
	return configured.length > 0 ? configured : config.SMTP_USER.trim()
}

/** Pull the bare address out of `GlukVPN <noreply@gluk.tech>`. */
function bareAddress(value: string): string {
	const match = /<([^>]+)>/.exec(value)
	return (match && match[1] ? match[1] : value).trim()
}

/**
 * One SMTP conversation. Replies are line-buffered because a single TCP read
 * can hold half a line, several lines, or the tail of a multi-line greeting -
 * assuming one read equals one reply is the bug every naive client ships with.
 */
class SmtpConnection {
	private buffer = ""
	private lines: string[] = []
	private pending: {
		resolve: (reply: SmtpReply) => void
		reject: (error: Error) => void
	} | null = null
	private failure: Error | null = null

	constructor(private socket: Conn) {
		socket.setEncoding("utf8")
		socket.setTimeout(TIMEOUT_MS)
		socket.on("data", this.onData)
		socket.on("error", this.onError)
		socket.on("close", this.onClose)
		socket.on("timeout", this.onTimeout)
	}

	private onData = (chunk: string): void => {
		this.buffer += chunk
		let index = this.buffer.indexOf("\r\n")
		while (index >= 0) {
			const line = this.buffer.slice(0, index)
			this.buffer = this.buffer.slice(index + 2)
			this.lines.push(line)
			// "250-SIZE" continues, "250 OK" ends. The fourth character is the
			// only difference, which is why substring checks are not enough.
			if (/^\d{3} /.test(line)) {
				const text = this.lines.join("\n")
				const code = Number.parseInt(line.slice(0, 3), 10)
				this.lines = []
				const waiter = this.pending
				this.pending = null
				waiter?.resolve({ code, text })
			}
			index = this.buffer.indexOf("\r\n")
		}
	}

	private onError = (error: Error): void => this.fail(error)
	private onClose = (): void => this.fail(new Error("SMTP connection closed"))
	private onTimeout = (): void => {
		this.socket.destroy()
		this.fail(new Error("SMTP timed out"))
	}

	private fail(error: Error): void {
		if (!this.failure) this.failure = error
		const waiter = this.pending
		this.pending = null
		waiter?.reject(error)
	}

	/** Detach so the socket can be handed to a TLS upgrade. */
	detach(): Conn {
		this.socket.off("data", this.onData)
		this.socket.off("error", this.onError)
		this.socket.off("close", this.onClose)
		this.socket.off("timeout", this.onTimeout)
		return this.socket
	}

	read(): Promise<SmtpReply> {
		if (this.failure) return Promise.reject(this.failure)
		return new Promise<SmtpReply>((resolve, reject) => {
			this.pending = { resolve, reject }
		})
	}

	write(line: string): void {
		this.socket.write(`${line}\r\n`)
	}

	/**
	 * Send one command and insist on an expected reply class. `secret` keeps
	 * the AUTH exchange out of the error text - a thrown SMTP error is often
	 * the one thing that does get logged.
	 */
	async command(line: string, expect: number[], secret = false): Promise<SmtpReply> {
		this.write(line)
		const reply = await this.read()
		if (!expect.includes(Math.floor(reply.code / 100))) {
			const shown = secret ? "<credentials>" : line.split(" ")[0]
			throw new Error(`SMTP ${shown} failed: ${reply.code} ${reply.text}`)
		}
		return reply
	}

	end(): void {
		try {
			this.socket.end()
		} catch {
			// Already gone; the message was accepted before this point.
		}
	}
}

function openSocket(host: string, port: number, secure: boolean): Promise<Conn> {
	return new Promise<Conn>((resolve, reject) => {
		const socket = secure
			? tlsConnect({ host, port, servername: host }, () => resolve(socket))
			: netConnect({ host, port }, () => resolve(socket))
		socket.setTimeout(TIMEOUT_MS)
		socket.once("error", reject)
		socket.once("timeout", () => {
			socket.destroy()
			reject(new Error(`SMTP connection to ${host}:${port} timed out`))
		})
	})
}

function upgradeToTls(socket: Conn, host: string): Promise<TLSSocket> {
	return new Promise<TLSSocket>((resolve, reject) => {
		const secured = tlsConnect({ socket, servername: host }, () => resolve(secured))
		secured.once("error", reject)
	})
}

/** RFC 2047, so Cyrillic subjects do not arrive as mojibake. */
function encodeHeader(value: string): string {
	// eslint-disable-next-line no-control-regex
	if (/^[\x20-\x7e]*$/.test(value)) return value
	return `=?UTF-8?B?${Buffer.from(value, "utf8").toString("base64")}?=`
}

/** Base64 body, wrapped at 76 columns as the RFC requires. */
function encodeBody(value: string): string {
	const encoded = Buffer.from(value, "utf8").toString("base64")
	const chunks: string[] = []
	for (let i = 0; i < encoded.length; i += 76) {
		chunks.push(encoded.slice(i, i + 76))
	}
	return chunks.join("\r\n")
}

export type MailMessage = {
	to: string
	subject: string
	/**
	 * Plain text, always required. It is what text-only clients show, what
	 * screen readers read, and what spam filters score - an HTML-only message
	 * looks like bulk mail to most of them.
	 */
	text: string
	/**
	 * Optional HTML alternative (ROUND 12). When present the message goes out
	 * as multipart/alternative.
	 */
	html?: string
}

/**
 * Deliver one message. Throws on any failure - the caller decides whether that
 * is fatal (registration) or merely logged (a resend nobody is waiting on).
 */
export async function sendMail(message: MailMessage): Promise<void> {
	if (!mailerConfigured()) {
		throw new Error("SMTP is not configured")
	}

	const host = config.SMTP_HOST.trim()
	const port = config.SMTP_PORT
	// 465 is implicit TLS. 587 starts in the clear and upgrades. Getting this
	// backwards produces a hang rather than an error, so it is keyed off the
	// explicit flag and the well-known port rather than guessed.
	const implicitTls = config.SMTP_SECURE || port === 465
	const from = mailFrom()
	const envelopeFrom = bareAddress(from)
	const envelopeTo = bareAddress(message.to)

	let connection = new SmtpConnection(await openSocket(host, port, implicitTls))
	try {
		await connection.read() // 220 greeting
		await connection.command(`EHLO ${envelopeFrom.split("@")[1] ?? "localhost"}`, [2])

		if (!implicitTls) {
			await connection.command("STARTTLS", [2])
			const secured = await upgradeToTls(connection.detach(), host)
			connection = new SmtpConnection(secured)
			// EHLO must be repeated after the upgrade: the server advertises a
			// different capability set once the channel is private, and AUTH is
			// usually only in the second one.
			await connection.command(`EHLO ${envelopeFrom.split("@")[1] ?? "localhost"}`, [2])
		}

		await connection.command("AUTH LOGIN", [3])
		await connection.command(
			Buffer.from(config.SMTP_USER.trim(), "utf8").toString("base64"),
			[3],
			true,
		)
		await connection.command(
			Buffer.from(config.SMTP_PASSWORD, "utf8").toString("base64"),
			[2],
			true,
		)

		await connection.command(`MAIL FROM:<${envelopeFrom}>`, [2])
		await connection.command(`RCPT TO:<${envelopeTo}>`, [2])
		await connection.command("DATA", [3])

		// A boundary that also occurred inside the body would split the message
		// in the wrong place, so it carries randomness rather than being a fixed
		// string. Base64 parts can never contain it, but the header is built once
		// and reused for both, so this stays honest if a future part is not.
		const boundary = `gluk-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`

		const headers = [
			`From: ${from.includes("<") ? from : `GlukVPN <${from}>`}`,
			`To: <${envelopeTo}>`,
			`Subject: ${encodeHeader(message.subject)}`,
			`Date: ${new Date().toUTCString()}`,
			`Message-ID: <${Date.now().toString(36)}.${Math.random().toString(36).slice(2)}@${envelopeFrom.split("@")[1] ?? "gluk.tech"}>`,
			"MIME-Version: 1.0",
			...(message.html
				? [`Content-Type: multipart/alternative; boundary="${boundary}"`]
				: [
						'Content-Type: text/plain; charset="UTF-8"',
						"Content-Transfer-Encoding: base64",
					]),
			"Auto-Submitted: auto-generated",
		].join("\r\n")

		// Plain text first, HTML second. Clients render the *last* part they
		// understand, so this order is what makes a text client show text and
		// everything else show the card.
		const body = message.html
			? [
					`--${boundary}`,
					'Content-Type: text/plain; charset="UTF-8"',
					"Content-Transfer-Encoding: base64",
					"",
					encodeBody(message.text),
					`--${boundary}`,
					'Content-Type: text/html; charset="UTF-8"',
					"Content-Transfer-Encoding: base64",
					"",
					encodeBody(message.html),
					`--${boundary}--`,
				].join("\r\n")
			: encodeBody(message.text)

		connection.write(`${headers}\r\n\r\n${body}\r\n.`)
		const accepted = await connection.read()
		if (Math.floor(accepted.code / 100) !== 2) {
			throw new Error(`SMTP refused the message: ${accepted.code} ${accepted.text}`)
		}

		try {
			await connection.command("QUIT", [2])
		} catch {
			// Some servers hang up on QUIT. The message is already accepted.
		}
	} finally {
		connection.end()
	}
}
