/**
 * Oracle Cloud API access: request signing, plus the two queries the egress
 * budget needs.
 *
 * Two things make this worth its own file. First, OCI does not accept a bearer
 * token: every request carries an RFC-draft HTTP signature over a fixed set of
 * headers, signed with the API key whose fingerprint is registered on the user.
 * Second, the whole module is optional - with no credentials in the environment
 * `ociConfigured()` is false, nothing here is ever called, and a dev checkout or
 * a self-hosted deploy starts with no Oracle account at all.
 *
 * Region endpoints are built by hand rather than pulled from an SDK: the two
 * hostnames below are the entire surface we use, and oci-sdk would be a very
 * large dependency for two POSTs.
 */
import { createHash, createPrivateKey, createSign, type KeyObject } from "crypto"
import { readFileSync } from "fs"

import { config } from "../config"

type Credentials = {
	tenancyOcid: string
	region: string
	key: KeyObject
	/** tenancy/user/fingerprint - what OCI looks the public key up by. */
	keyId: string
}

// Parsing a PEM is not free and the key never changes while the process runs.
// A failure is cached too: a malformed key is a deploy mistake, and retrying it
// every poll would only fill the log with the same stack trace.
let cached: Credentials | null = null
let cachedFailure: string | null = null

/** True once every value needed to sign a request is present. */
export function ociConfigured(): boolean {
	return (
		config.OCI_TENANCY_OCID.trim().length > 0 &&
		config.OCI_USER_OCID.trim().length > 0 &&
		config.OCI_FINGERPRINT.trim().length > 0 &&
		config.OCI_REGION.trim().length > 0 &&
		(config.OCI_PRIVATE_KEY.trim().length > 0 ||
			config.OCI_PRIVATE_KEY_PATH.trim().length > 0)
	)
}

function privateKeyPem(): string {
	const file = config.OCI_PRIVATE_KEY_PATH.trim()
	if (file) return readFileSync(file, "utf8")
	// A PEM pasted into an env var arrives with escaped newlines more often than
	// not, and createPrivateKey rejects it silently-looking if they stay escaped.
	return config.OCI_PRIVATE_KEY.replace(/\\n/g, "\n").trim()
}

function credentials(): Credentials {
	if (cached) return cached
	if (cachedFailure) throw new Error(cachedFailure)

	try {
		const passphrase = config.OCI_PRIVATE_KEY_PASSPHRASE
		const pem = privateKeyPem()
		if (!pem) throw new Error("private key is empty")
		const key = passphrase
			? createPrivateKey({ key: pem, passphrase })
			: createPrivateKey(pem)

		const tenancyOcid = config.OCI_TENANCY_OCID.trim()
		cached = {
			tenancyOcid,
			region: config.OCI_REGION.trim(),
			key,
			keyId:
				tenancyOcid +
				"/" +
				config.OCI_USER_OCID.trim() +
				"/" +
				config.OCI_FINGERPRINT.trim(),
		}
		return cached
	} catch (error) {
		cachedFailure =
			"OCI private key could not be read: " +
			(error instanceof Error ? error.message : String(error))
		throw new Error(cachedFailure)
	}
}

type SignedRequest = {
	host: string
	method: "GET" | "POST"
	/** Path plus query string, exactly as it goes on the wire. */
	path: string
	body?: unknown
}

export async function signedRequest<T>(request: SignedRequest): Promise<T> {
	const creds = credentials()
	const date = new Date().toUTCString()
	const payload = request.body === undefined ? "" : JSON.stringify(request.body)

	// Order matters: the "headers" parameter of the Authorization header must
	// list the same names in the same order they were concatenated.
	const signed: Array<[string, string]> = [
		["(request-target)", request.method.toLowerCase() + " " + request.path],
		["host", request.host],
		["date", date],
	]
	const headers: Record<string, string> = { date, accept: "application/json" }

	if (request.method === "POST") {
		const digest = createHash("sha256").update(payload, "utf8").digest("base64")
		const length = String(Buffer.byteLength(payload, "utf8"))
		signed.push(
			["x-content-sha256", digest],
			["content-type", "application/json"],
			["content-length", length],
		)
		// host and content-length are deliberately not set here: undici derives
		// both from the URL and the body, and setting them again risks a duplicate
		// header. The values it sends are the ones signed above.
		headers["x-content-sha256"] = digest
		headers["content-type"] = "application/json"
	}

	const signingString = signed
		.map(([name, value]) => name + ": " + value)
		.join("\n")
	const signature = createSign("RSA-SHA256")
		.update(signingString, "utf8")
		.sign(creds.key, "base64")

	headers.authorization =
		'Signature version="1",keyId="' +
		creds.keyId +
		'",algorithm="rsa-sha256",headers="' +
		signed.map(([name]) => name).join(" ") +
		'",signature="' +
		signature +
		'"'

	const response = await fetch("https://" + request.host + request.path, {
		method: request.method,
		headers,
		body: request.method === "POST" ? payload : undefined,
		signal: AbortSignal.timeout(config.OCI_TIMEOUT_MS),
	})

	if (!response.ok) {
		// OCI puts a readable reason in the body; the status alone rarely says
		// which of the five OCIDs is the wrong one.
		const detail = (await response.text().catch(() => "")).slice(0, 400)
		throw new Error(
			"OCI " + request.host + " returned " + response.status + ": " + detail,
		)
	}

	return (await response.json()) as T
}

export type TimeWindow = { start: Date; end: Date }

type MetricSeries = {
	aggregatedDatapoints?: Array<{ value?: number | null }>
}

/**
 * Outbound bytes on the node's VNIC over `window`, summed.
 *
 * The metric name is configurable because the two namespaces that can answer
 * this disagree on it: `oci_vcn` exposes VnicBytesOut and needs nothing
 * installed on the instance, while `oci_computeagent` exposes NetworksBytesOut
 * and needs the monitoring plugin enabled. We default to the former.
 *
 * Note this counts *all* egress on the VNIC, including traffic that never
 * leaves the VCN, whereas Oracle's free allowance only counts internet egress.
 * The difference makes our figure an over-count, which is the safe direction
 * for a budget alarm.
 */
export async function summarizeEgressBytes(window: TimeWindow): Promise<number> {
	const creds = credentials()
	const compartment = config.OCI_COMPARTMENT_OCID.trim() || creds.tenancyOcid
	const vnic = config.OCI_VNIC_OCID.trim()
	const filter = vnic ? '{resourceId = "' + vnic + '"}' : ""

	const series = await signedRequest<MetricSeries[]>({
		host: "telemetry." + creds.region + ".oraclecloud.com",
		method: "POST",
		path:
			"/20180401/metrics/actions/summarizeMetricsData?compartmentId=" +
			encodeURIComponent(compartment),
		body: {
			namespace: config.OCI_EGRESS_NAMESPACE.trim(),
			// One datapoint per hour, summed per hour: adding those up gives total
			// bytes for the window without pulling minute-resolution data, which
			// OCI only retains for fifteen days anyway.
			query: config.OCI_EGRESS_METRIC.trim() + "[1h]" + filter + ".sum()",
			startTime: window.start.toISOString(),
			endTime: window.end.toISOString(),
			resolution: "1h",
		},
	})

	let total = 0
	for (const entry of series ?? []) {
		for (const point of entry.aggregatedDatapoints ?? []) {
			if (typeof point.value === "number" && Number.isFinite(point.value)) {
				total += point.value
			}
		}
	}
	return total
}

export type ChargeTotal = { amount: number; currency: string }

type UsageResponse = {
	items?: Array<{ computedAmount?: number | null; currency?: string | null }>
}

/** Midnight UTC on the day containing `at`. The Usage API insists on it. */
function utcMidnight(at: Date): Date {
	return new Date(
		Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), at.getUTCDate()),
	)
}

/**
 * What Oracle says the tenancy has been charged over `window`.
 *
 * The point is not accounting, it is a tripwire: the whole deployment is meant
 * to sit inside the always-free allowance, so anything other than zero means an
 * assumption broke - a second instance, a paid shape, a volume nobody deleted -
 * and it should be visible before the invoice arrives.
 */
export async function summarizeCharges(
	window: TimeWindow,
): Promise<ChargeTotal> {
	const creds = credentials()
	const response = await signedRequest<UsageResponse>({
		host: "usageapi." + creds.region + ".oci.oraclecloud.com",
		method: "POST",
		path: "/20200107/usage",
		body: {
			tenantId: creds.tenancyOcid,
			timeUsageStarted: utcMidnight(window.start).toISOString(),
			// The end is exclusive and must also land on midnight, so round up.
			timeUsageEnded: new Date(
				utcMidnight(window.end).getTime() + 24 * 60 * 60 * 1000,
			).toISOString(),
			granularity: "DAILY",
			queryType: "COST",
		},
	})

	let amount = 0
	let currency = "USD"
	for (const item of response.items ?? []) {
		if (typeof item.computedAmount === "number" && Number.isFinite(item.computedAmount)) {
			amount += item.computedAmount
		}
		if (item.currency) currency = item.currency
	}
	// Two decimals: this is money, and floating point addition of many daily
	// rows otherwise reports things like 0.30000000000000004 as "not zero".
	return { amount: Math.round(amount * 100) / 100, currency }
}

/** Test seam: forget the parsed key so a new environment can be picked up. */
export function resetOciClientForTests(): void {
	cached = null
	cachedFailure = null
}
