/*
 * The part that actually moves traffic.
 *
 * A browser extension cannot speak WireGuard: there is no raw UDP socket and no
 * TUN device behind chrome.* - so the phone's tunnel cannot simply be ported.
 * What Chromium does give an extension is chrome.proxy, i.e. the browser's own
 * network stack pointed at a gateway. So the browser build tunnels over an
 * authenticated TLS proxy (HTTPS scheme = CONNECT inside TLS) running on the
 * same German node as wg0, and the control plane stays the single source of
 * truth for identity, devices and sessions.
 *
 * Split tunnelling is compiled straight into the PAC file, so the decision is
 * made by the browser's network stack and not by JavaScript on every request.
 */

import { TUNNEL_MODES } from './store.js'

const CREDENTIALS_KEY = 'proxyCredentials'

function proxyLine(gateway) {
	const host = String(gateway.host || '').trim()
	const port = Number(gateway.port) || 8443
	if (!host) return null
	const scheme = String(gateway.scheme || 'https').toLowerCase()
	// PAC keywords: HTTPS = TLS to the proxy, PROXY = plaintext, SOCKS5 = socks.
	const keyword = scheme === 'http' ? 'PROXY' : scheme === 'socks5' ? 'SOCKS5' : 'HTTPS'
	return `${keyword} ${host}:${port}`
}

/** Users paste whole URLs; keep only the hostname pattern. */
export function cleanHostRule(value) {
	let rule = String(value ?? '').trim().toLowerCase()
	if (!rule) return ''
	rule = rule.replace(/^[a-z0-9+.-]+:\/\//, '')
	rule = rule.replace(/^[^/@]*@/, '')
	rule = rule.split('/')[0].split('?')[0].split('#')[0]
	// Strip a port, but keep IPv6 brackets intact.
	if (!rule.includes(']')) rule = rule.split(':')[0]
	return rule.trim()
}

/** Hosts that must never go through the tunnel, in any mode. */
export function alwaysDirect({ apiHosts, gatewayHost, bypass }) {
	const list = new Set()
	// The control plane stays reachable directly, so a token refresh (and the
	// disconnect call) still works when the gateway is unreachable.
	for (const host of apiHosts ?? []) {
		const clean = cleanHostRule(host)
		if (clean) list.add(clean)
	}
	const gw = cleanHostRule(gatewayHost)
	if (gw) list.add(gw)
	for (const entry of bypass ?? []) {
		const clean = cleanHostRule(entry)
		if (clean) list.add(clean)
	}
	return [...list]
}

export function buildPac({ gateway, apiHosts, bypass, siteList, tunnelMode, killSwitch }) {
	const line = proxyLine(gateway)
	if (!line) throw new Error('Gateway host is not configured')

	const mode = TUNNEL_MODES.includes(tunnelMode) ? tunnelMode : 'all'
	// In "only these sites" mode everything else is meant to go direct, so a
	// hard fail-closed fallback would block the whole browser. Kill switch then
	// only applies to the sites that are actually routed through the tunnel.
	const fallback = killSwitch && mode !== 'only' ? '' : '; DIRECT'
	const direct = alwaysDirect({ apiHosts, gatewayHost: gateway.host, bypass })
	const sites = (siteList ?? []).map(cleanHostRule).filter(Boolean)

	return `function FindProxyForURL(url, host) {
  var DIRECT_LIST = ${JSON.stringify(direct)};
  var SITE_LIST = ${JSON.stringify(sites)};
  var MODE = ${JSON.stringify(mode)};
  var TUNNEL = ${JSON.stringify(line + fallback)};
  host = ('' + host).toLowerCase();

  // Intranet single-label names and loopback never leave the machine.
  if (isPlainHostName(host)) return 'DIRECT';
  if (host === 'localhost' || host === '127.0.0.1' || host === '::1') return 'DIRECT';
  // Literal private addresses, matched textually so the PAC never calls
  // dnsResolve() - that would be a local DNS lookup for every request.
  if (/^10\\./.test(host)) return 'DIRECT';
  if (/^192\\.168\\./.test(host)) return 'DIRECT';
  if (/^169\\.254\\./.test(host)) return 'DIRECT';
  if (/^172\\.(1[6-9]|2[0-9]|3[01])\\./.test(host)) return 'DIRECT';

  function matches(list) {
    for (var i = 0; i < list.length; i++) {
      var rule = list[i];
      if (!rule) continue;
      if (host === rule) return true;
      if (rule.indexOf('*') >= 0 && shExpMatch(host, rule)) return true;
      if (rule.charAt(0) === '.' && host.length > rule.length &&
          host.slice(-rule.length) === rule) return true;
      // A bare domain also covers its subdomains: youtube.com -> m.youtube.com
      if (rule.charAt(0) !== '.' && host.length > rule.length + 1 &&
          host.slice(-(rule.length + 1)) === '.' + rule) return true;
    }
    return false;
  }

  if (matches(DIRECT_LIST)) return 'DIRECT';
  if (MODE === 'except' && matches(SITE_LIST)) return 'DIRECT';
  if (MODE === 'only' && !matches(SITE_LIST)) return 'DIRECT';

  return TUNNEL;
}`
}

/** Runs one chrome.proxy.settings call and swallows its failure. Used for the
 *  scopes Chrome refuses without "Allow in Incognito" - a missing permission
 *  there must not undo the regular-window proxy that was just set. */
async function bestEffort(operation) {
	try {
		await operation()
		return true
	} catch {
		return false
	}
}

export const ProxyEngine = {
	/** Credentials answered to the gateway's 407. Kept in storage because the
	 *  service worker is torn down between requests and the auth listener must
	 *  still be able to answer after a restart. */
	async setCredentials(username, password) {
		await chrome.storage.local.set({ [CREDENTIALS_KEY]: { username, password } })
	},
	async credentials() {
		const bag = await chrome.storage.local.get(CREDENTIALS_KEY)
		return bag[CREDENTIALS_KEY] ?? null
	},
	async clearCredentials() {
		await chrome.storage.local.remove(CREDENTIALS_KEY)
	},

	/*
	 * Which windows the PAC file applies to.
	 *
	 * Chrome layers extension preferences by scope, and the layering is what
	 * makes the incognito toggle honest:
	 *   regular              regular windows, *inherited by incognito* unless a
	 *                        more specific scope overrides it
	 *   regular_only         regular windows and nothing else
	 *   incognito_persistent incognito windows only, survives restarts
	 *
	 * So "tunnel incognito = off" cannot simply mean `regular` - with the
	 * extension allowed in incognito that scope would quietly route incognito
	 * windows too. Off therefore writes `regular_only`; on writes `regular` plus
	 * an explicit `incognito_persistent` copy. In both cases the scopes that
	 * are not in use are cleared, so a PAC from the previous state never
	 * lingers in a layer we stopped writing to.
	 *
	 * The incognito scope is only writable once the user has ticked "Allow in
	 * Incognito" on chrome://extensions. Without it Chrome rejects the call;
	 * that is not an error worth failing the connect over - regular windows are
	 * still routed, and the popup tells the user what is missing.
	 */
	async apply(config) {
		const pac = buildPac(config)
		const mandatory = Boolean(config.killSwitch) && config.tunnelMode !== 'only'
		const value = { mode: 'pac_script', pacScript: { data: pac, mandatory } }
		const incognito = Boolean(config.tunnelIncognito)

		// Regular windows are always routed by the primary 'regular' scope.
		await chrome.proxy.settings.set({ value, scope: 'regular' })
		if (incognito) {
			await bestEffort(() => chrome.proxy.settings.set({ value, scope: 'incognito_persistent' }))
		} else {
			await bestEffort(() => chrome.proxy.settings.clear({ scope: 'incognito_persistent' }))
		}
		return pac
	},

	async clear() {
		// Every layer this extension ever writes. The regular one must succeed;
		// the others are best effort (incognito access may have been revoked).
		await chrome.proxy.settings.clear({ scope: 'regular' })
		await bestEffort(() => chrome.proxy.settings.clear({ scope: 'regular_only' }))
		await bestEffort(() => chrome.proxy.settings.clear({ scope: 'incognito_persistent' }))
		await this.clearCredentials()
	},

	/** True when this extension is the one currently controlling the proxy. */
	async isControlling() {
		try {
			const current = await chrome.proxy.settings.get({ incognito: false })
			return current.levelOfControl === 'controlled_by_this_extension'
		} catch {
			return false
		}
	},
}
