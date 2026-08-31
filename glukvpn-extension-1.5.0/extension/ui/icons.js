/*
 * Line icons for the popup.
 *
 * Rules that keep the set looking drawn by one hand instead of generated:
 *  - one 24x24 grid, one stroke width, round caps and joins everywhere
 *  - geometry snaps to whole or half pixels; nothing is eyeballed
 *  - the gear outline is generated from polar maths (8 teeth, tip r=9.4,
 *    root r=7.3), so it is symmetric to two decimals instead of lopsided
 *  - every shape is currentColor, so a CSS colour change themes the icon
 */

const NS = 'http://www.w3.org/2000/svg'

// 8 teeth, perfectly symmetric - generated, not traced.
const GEAR_OUTLINE =
	'M10.37 2.74A9.4 9.4 0 0 1 13.63 2.74L13.67 4.89A7.3 7.3 0 0 1 15.85 5.80' +
	'L17.39 4.30A9.4 9.4 0 0 1 19.70 6.61L18.20 8.15A7.3 7.3 0 0 1 19.11 10.33' +
	'L21.26 10.37A9.4 9.4 0 0 1 21.26 13.63L19.11 13.67A7.3 7.3 0 0 1 18.20 15.85' +
	'L19.70 17.39A9.4 9.4 0 0 1 17.39 19.70L15.85 18.20A7.3 7.3 0 0 1 13.67 19.11' +
	'L13.63 21.26A9.4 9.4 0 0 1 10.37 21.26L10.33 19.11A7.3 7.3 0 0 1 8.15 18.20' +
	'L6.61 19.70A9.4 9.4 0 0 1 4.30 17.39L5.80 15.85A7.3 7.3 0 0 1 4.89 13.67' +
	'L2.74 13.63A9.4 9.4 0 0 1 2.74 10.37L4.89 10.33A7.3 7.3 0 0 1 5.80 8.15' +
	'L4.30 6.61A9.4 9.4 0 0 1 6.61 4.30L8.15 5.80A7.3 7.3 0 0 1 10.33 4.89Z'

export const ICONS = {
	/* navigation */
	shield: '<path d="M12 2.75 4.75 5.6v5.15c0 4.6 3.02 8.4 7.25 9.9 4.23-1.5 7.25-5.3 7.25-9.9V5.6L12 2.75Z"/>',
	shieldCheck:
		'<path d="M12 2.75 4.75 5.6v5.15c0 4.6 3.02 8.4 7.25 9.9 4.23-1.5 7.25-5.3 7.25-9.9V5.6L12 2.75Z"/><path d="M9 11.9 11.2 14.1 15.3 10"/>',
	shieldFill:
		'<path d="M12 2.75 4.75 5.6v5.15c0 4.6 3.02 8.4 7.25 9.9 4.23-1.5 7.25-5.3 7.25-9.9V5.6L12 2.75Z" fill="currentColor" stroke="none"/>',
	globe:
		'<circle cx="12" cy="12" r="9"/><path d="M3 12h18"/><path d="M12 3c2.4 2.45 3.6 5.45 3.6 9s-1.2 6.55-3.6 9c-2.4-2.45-3.6-5.45-3.6-9S9.6 5.45 12 3Z"/>',
	gear: `<path d="${GEAR_OUTLINE}"/><circle cx="12" cy="12" r="3.2"/>`,
	user: '<circle cx="12" cy="8" r="3.6"/><path d="M4.8 20.2a7.2 7.2 0 0 1 14.4 0"/>',

	/* stats */
	clock: '<circle cx="12" cy="12" r="9"/><path d="M12 6.8V12l3.4 2"/>',
	pulse: '<path d="M3 12h3.4l2.2-5.4 3.6 11L14.6 12H21"/>',
	down: '<path d="M12 4.5v12"/><path d="M7.2 11.8 12 16.6l4.8-4.8"/><path d="M5 19.5h14"/>',
	up: '<path d="M12 19.5v-12"/><path d="M7.2 12.2 12 7.4l4.8 4.8"/><path d="M5 4.5h14"/>',

	/* affordances */
	chevron: '<path d="M9.5 5.5 16 12l-6.5 6.5"/>',
	back: '<path d="M14.5 5.5 8 12l6.5 6.5"/>',
	refresh:
		'<path d="M20.2 12a8.2 8.2 0 0 1-13.9 5.9L3.8 15.6"/><path d="M3.8 12a8.2 8.2 0 0 1 13.9-5.9l2.5 2.3"/><path d="M20.2 4v4.4h-4.4"/><path d="M3.8 20v-4.4h4.4"/>',
	check: '<path d="M5.2 12.6 9.6 17 18.8 7.4"/>',
	close: '<path d="M6.4 6.4 17.6 17.6"/><path d="M17.6 6.4 6.4 17.6"/>',
	pin: '<path d="M12 21c4.3-4.2 6.5-7.6 6.5-10.4a6.5 6.5 0 1 0-13 0C5.5 13.4 7.7 16.8 12 21Z"/><circle cx="12" cy="10.4" r="2.5"/>',
	speed: '<path d="M4.6 17.4a9 9 0 1 1 14.8 0"/><path d="m14.6 9.6-3 4.4"/><circle cx="12" cy="15" r="1.3"/>',
	trash: '<path d="M4.5 6.8h15"/><path d="M9.6 6.8V4.6h4.8v2.2"/><path d="M6.6 6.8 7.5 19.4h9L17.4 6.8"/><path d="M10.4 10.4v5.4"/><path d="M13.6 10.4v5.4"/>',
	sliders: '<path d="M4 8h9"/><path d="M17 8h3"/><path d="M4 16h3"/><path d="M11 16h9"/><circle cx="15" cy="8" r="2.2"/><circle cx="9" cy="16" r="2.2"/>',
	code: '<path d="M8.6 8 4.6 12l4 4"/><path d="M15.4 8l4 4-4 4"/><path d="m13.4 5.4-2.8 13.2"/>',
	key: '<circle cx="8" cy="12" r="3.6"/><path d="M11.6 12H20"/><path d="M17.2 12v3.2"/><path d="M20 12v2.4"/>',
	link: '<path d="M10.4 13.6a3.6 3.6 0 0 0 5.1 0l2.9-2.9a3.6 3.6 0 0 0-5.1-5.1l-1.1 1.1"/><path d="M13.6 10.4a3.6 3.6 0 0 0-5.1 0l-2.9 2.9a3.6 3.6 0 0 0 5.1 5.1l1.1-1.1"/>',
	external: '<path d="M13.4 4.6H19.4v6"/><path d="M19.4 4.6 11 13"/><path d="M18 14.4v3.6a1.6 1.6 0 0 1-1.6 1.6H6a1.6 1.6 0 0 1-1.6-1.6V7.6A1.6 1.6 0 0 1 6 6h3.6"/>',
	logout: '<path d="M9.6 19.4H6.2A1.7 1.7 0 0 1 4.5 17.7V6.3a1.7 1.7 0 0 1 1.7-1.7h3.4"/><path d="M14.8 15.6 18.4 12l-3.6-3.6"/><path d="M18.4 12H9.2"/>',

	/* devices */
	laptop: '<rect x="3.6" y="5" width="16.8" height="11" rx="1.8"/><path d="M2 19h20"/>',
	phone: '<rect x="7.4" y="2.6" width="9.2" height="18.8" rx="2.2"/><path d="M10.8 18.4h2.4"/>',

	/* states - these three were referenced by the code but never existed, so
	 * every error frame silently rendered without its icon */
	alert: '<path d="M12 3.6 2.9 19.4h18.2L12 3.6Z"/><path d="M12 10v4.2"/><path d="M12 17.1v.1"/>',
	warn: '<path d="M12 3.6 2.9 19.4h18.2L12 3.6Z"/><path d="M12 10v4.2"/><path d="M12 17.1v.1"/>',
	info: '<circle cx="12" cy="12" r="9"/><path d="M12 11.2v5"/><path d="M12 7.9v.1"/>',
	noSignal:
		'<path d="M4 4l16 16"/><path d="M8.6 15.4a4.8 4.8 0 0 1 6.6-.3"/><path d="M5.2 12a9.6 9.6 0 0 1 3.1-2.1"/><path d="M15.6 9.8a9.6 9.6 0 0 1 3.2 2.2"/><path d="M12 18.9v.1"/>',
	plug: '<path d="M9 3.6v4.2"/><path d="M15 3.6v4.2"/><path d="M6.6 7.8h10.8v3a5.4 5.4 0 0 1-10.8 0v-3Z"/><path d="M12 16.2v4.2"/>',
}

/** Builds an <svg> element for one of the ICONS keys. Unknown names fall back
 *  to a neutral dot instead of the globe, so a typo is visible but harmless. */
export function iconSvg(name, size) {
	const body = ICONS[name] ?? '<circle cx="12" cy="12" r="7.5"/>'
	const svg = document.createElementNS(NS, 'svg')
	svg.setAttribute('viewBox', '0 0 24 24')
	svg.setAttribute('fill', 'none')
	svg.setAttribute('stroke', 'currentColor')
	svg.setAttribute('stroke-width', '1.6')
	svg.setAttribute('stroke-linecap', 'round')
	svg.setAttribute('stroke-linejoin', 'round')
	svg.setAttribute('aria-hidden', 'true')
	svg.setAttribute('focusable', 'false')
	if (size) {
		svg.setAttribute('width', String(size))
		svg.setAttribute('height', String(size))
	}
	svg.innerHTML = body
	return svg
}

/**
 * Replaces every [data-icon] placeholder with its SVG. Safe to call again after
 * re-rendering a list: nodes that already hold the right icon are skipped.
 */
export function paintIcons(root = document) {
	const nodes = root.querySelectorAll('[data-icon]')
	for (const node of nodes) {
		const name = node.getAttribute('data-icon')
		if (!name) continue
		if (node.dataset.iconPainted === name) continue
		node.replaceChildren(iconSvg(name))
		node.dataset.iconPainted = name
	}
}
