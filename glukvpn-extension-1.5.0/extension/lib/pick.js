/*
 * Automatic server choice, shared by the popup and the service worker.
 *
 * This is a deliberate port of
 * `flutter-client/lib/desktop/logic/node_selector.dart`, so Windows, Android
 * and the browser answer the same question the same way:
 *
 *   score = 0.55 * latency + 0.30 * free load + 0.15 * spare capacity
 *
 * plus a small bonus for the user's own country, so Auto does not bounce
 * between two nodes that score almost identically. A node with 50 ms of ping
 * therefore wins over one with 95 ms, and loses to it once it fills up - which
 * is exactly the behaviour asked for.
 *
 * If you change a weight here, change it in the Dart file too.
 */

const PING_BEST_MS = 20
const PING_WORST_MS = 300
const HOME_COUNTRY_BONUS = 0.06
// Paid plans prefer premium hardware when it exists. The control plane does
// not send `tier` yet, so today every node reads as `free` and this line is
// inert; it starts working the moment the field appears, with no client
// update.
const PREMIUM_BONUS = 0.05

function asNumber(value) {
	const n = Number(value)
	return Number.isFinite(n) ? n : null
}

function nodeId(node) {
	return String(node?.id ?? node?.nodeId ?? '')
}

/* Load is reported as `loadPercent` by the control plane and as `load` by the
 * older node rows still cached in storage. Both are accepted. */
function loadPercentOf(node) {
	const direct = asNumber(node?.loadPercent ?? node?.load)
	if (direct !== null) return Math.min(100, Math.max(0, direct))

	const capacity = asNumber(node?.capacity)
	const peers = asNumber(node?.activePeers)
	if (capacity !== null && capacity > 0 && peers !== null) {
		return Math.min(100, Math.max(0, (peers / capacity) * 100))
	}
	return null
}

function headroomOf(node) {
	const capacity = asNumber(node?.capacity)
	const peers = asNumber(node?.activePeers)
	if (capacity === null || capacity <= 0 || peers === null) return 0.6
	const free = (capacity - peers) / capacity
	return Math.min(1, Math.max(0, free))
}

function isPremium(node) {
	const tier = String(node?.tier ?? node?.plan ?? '').toLowerCase()
	return tier === 'premium' || tier === 'pro'
}

/* Offline is reported in three different shapes depending on how old the
 * cached row is, so all three are honoured. */
export function isNodeOnline(node) {
	if (!node) return false
	if (node.online === false) return false
	if (String(node.status ?? '').toLowerCase() === 'offline') return false
	return true
}

export function isNodeUsable(node, { paid = false } = {}) {
	if (!isNodeOnline(node)) return false
	if (node.connectable === false) return false
	// Premium hardware is not offered to a free plan: connecting would only
	// earn a 403 from the control plane.
	if (isPremium(node) && !paid) return false
	return true
}

export function pingOf(node, pings = {}) {
	return asNumber(pings[nodeId(node)] ?? node?.ping ?? node?.pingMs)
}

/* Quality in [0..1]; higher is better. */
export function nodeScore(node, { pingMs = null, paid = false } = {}) {
	let pingGrade
	if (pingMs === null) {
		pingGrade = 0.55 // unknown: mediocre rather than great
	} else if (pingMs <= PING_BEST_MS) {
		pingGrade = 1
	} else if (pingMs >= PING_WORST_MS) {
		pingGrade = 0
	} else {
		pingGrade = 1 - (pingMs - PING_BEST_MS) / (PING_WORST_MS - PING_BEST_MS)
	}

	const load = loadPercentOf(node)
	const loadGrade = load === null ? 0.6 : 1 - load / 100

	let score = 0.55 * pingGrade + 0.3 * loadGrade + 0.15 * headroomOf(node)
	if (paid && isPremium(node)) score += PREMIUM_BONUS
	return score
}

/*
 * Best node for Auto.
 *
 * Always returns a `reason` string: it goes into the log and, for the popup,
 * explains why Auto landed where it did.
 */
export function bestNode(nodes, { pings = {}, preferCountryCode = '', paid = false } = {}) {
	const list = Array.isArray(nodes) ? nodes : []
	const candidates = list.filter((node) => isNodeUsable(node, { paid }))
	if (!candidates.length) return { node: null, reason: 'no_available_nodes' }

	const prefer = String(preferCountryCode ?? '').toUpperCase()
	let best = null
	let bestScore = -1
	let bestPing = null

	for (const node of candidates) {
		const ping = pingOf(node, pings)
		let score = nodeScore(node, { pingMs: ping, paid })
		if (prefer && String(node?.countryCode ?? '').toUpperCase() === prefer) {
			score += HOME_COUNTRY_BONUS
		}
		if (score > bestScore) {
			bestScore = score
			best = node
			bestPing = ping
		}
	}

	const load = loadPercentOf(best)
	const reason =
		'score=' + bestScore.toFixed(2) +
		' ping=' + (bestPing === null ? 'n/a' : bestPing + 'ms') +
		' load=' + (load === null ? 'n/a' : Math.round(load) + '%')
	return { node: best, reason }
}

/*
 * Resolve the node to connect to.
 *
 * A manual choice wins whenever it is still usable. When it is not - the node
 * went offline, or a paid-only node is left over from an expired plan - Auto
 * takes over instead of failing, and the caller learns which happened from
 * `reason`.
 */
export function pickNode(nodes, wantedId, options = {}) {
	const list = Array.isArray(nodes) ? nodes : []
	const wanted = String(wantedId ?? '')
	if (wanted) {
		const exact = list.find((node) => nodeId(node) === wanted)
		if (exact && isNodeUsable(exact, options)) {
			return { node: exact, reason: 'manual', auto: false }
		}
	}
	const auto = bestNode(list, options)
	return {
		node: auto.node,
		reason: wanted && auto.node ? 'auto_after_unusable_choice' : auto.reason,
		auto: true,
	}
}
