import type { VpnNode } from "@prisma/client"
import { describe, expect, it } from "vitest"
import {
	effectiveNodeStatus,
	isHeartbeatFresh,
	isNodeConnectable,
	nodeEndpoint,
	nodeHost,
	nodeLoadPercent,
	toPublicNode,
} from "../src/services/nodes"

// NODE_OFFLINE_AFTER_SEC is pinned to 30 in tests/setup.ts.
const secondsAgo = (seconds: number): Date => new Date(Date.now() - seconds * 1000)

const NODE_KEY = Buffer.from(new Uint8Array(32).fill(5)).toString("base64")

function makeNode(overrides: Partial<VpnNode> = {}): VpnNode {
	return {
		id: "11111111-1111-4111-8111-111111111111",
		name: "de-01",
		country: "Germany",
		countryCode: "DE",
		hostname: "de-01.example.com",
		publicIp: "203.0.113.10",
		wireguardPublicKey: NODE_KEY,
		wireguardPort: 51820,
		subnetCidr: "10.8.0.0/24",
		dns: "1.1.1.1,1.0.0.1",
		mtu: 1420,
		status: "ONLINE",
		capacity: 50,
		activePeers: 2,
		cpuPercent: 12.5,
		ramPercent: 41.25,
		uptimeSeconds: 3600,
		agentVersion: "0.1.0",
		lastHeartbeat: secondsAgo(5),
		createdAt: secondsAgo(86400),
		updatedAt: secondsAgo(5),
		...overrides,
	} as VpnNode
}

describe("isHeartbeatFresh", () => {
	it("is true inside the offline window and false outside it", () => {
		expect(isHeartbeatFresh(secondsAgo(1))).toBe(true)
		expect(isHeartbeatFresh(secondsAgo(29))).toBe(true)
		expect(isHeartbeatFresh(secondsAgo(45))).toBe(false)
		expect(isHeartbeatFresh(null)).toBe(false)
	})
})

describe("effectiveNodeStatus", () => {
	it("reports ONLINE for a node with a key and a fresh heartbeat", () => {
		expect(effectiveNodeStatus(makeNode())).toBe("ONLINE")
	})

	it("reports OFFLINE as soon as the heartbeat goes stale", () => {
		// Stored status is still ONLINE: the live check must win.
		const node = makeNode({ status: "ONLINE", lastHeartbeat: secondsAgo(120) })
		expect(effectiveNodeStatus(node)).toBe("OFFLINE")
		expect(effectiveNodeStatus(makeNode({ lastHeartbeat: null }))).toBe("OFFLINE")
	})

	it("reports PENDING until the node publishes its WireGuard key", () => {
		expect(effectiveNodeStatus(makeNode({ wireguardPublicKey: null }))).toBe("PENDING")
	})

	it("keeps DISABLED sticky, even with a fresh heartbeat", () => {
		const node = makeNode({ status: "DISABLED", lastHeartbeat: secondsAgo(1) })
		expect(effectiveNodeStatus(node)).toBe("DISABLED")
	})
})

describe("nodeLoadPercent", () => {
	it("is the peer-to-capacity ratio, clamped to 100", () => {
		expect(nodeLoadPercent(makeNode({ activePeers: 0, capacity: 50 }))).toBe(0)
		expect(nodeLoadPercent(makeNode({ activePeers: 2, capacity: 50 }))).toBe(4)
		expect(nodeLoadPercent(makeNode({ activePeers: 25, capacity: 50 }))).toBe(50)
		expect(nodeLoadPercent(makeNode({ activePeers: 50, capacity: 50 }))).toBe(100)
		expect(nodeLoadPercent(makeNode({ activePeers: 80, capacity: 50 }))).toBe(100)
	})

	it("treats a zero capacity as full", () => {
		expect(nodeLoadPercent(makeNode({ activePeers: 0, capacity: 0 }))).toBe(100)
	})
})

describe("nodeHost / nodeEndpoint", () => {
	it("prefers the hostname and falls back to the public IP", () => {
		expect(nodeHost(makeNode())).toBe("de-01.example.com")
		expect(nodeHost(makeNode({ hostname: "" }))).toBe("203.0.113.10")
		expect(nodeHost(makeNode({ hostname: "   " }))).toBe("203.0.113.10")
	})

	it("builds the WireGuard endpoint", () => {
		expect(nodeEndpoint(makeNode())).toBe("de-01.example.com:51820")
		expect(nodeEndpoint(makeNode({ hostname: "", wireguardPort: 51821 }))).toBe(
			"203.0.113.10:51821",
		)
	})
})

describe("isNodeConnectable", () => {
	it("allows new peers only on an online node below capacity", () => {
		expect(isNodeConnectable(makeNode())).toBe(true)
		expect(isNodeConnectable(makeNode({ activePeers: 50, capacity: 50 }))).toBe(false)
		expect(isNodeConnectable(makeNode({ lastHeartbeat: secondsAgo(120) }))).toBe(false)
		expect(isNodeConnectable(makeNode({ status: "DISABLED" }))).toBe(false)
		expect(isNodeConnectable(makeNode({ wireguardPublicKey: null }))).toBe(false)
	})
})

describe("toPublicNode", () => {
	it("exposes only client-safe fields", () => {
		const node = makeNode()
		const view = toPublicNode(node)

		expect(view).toMatchObject({
			id: node.id,
			name: "de-01",
			country: "Germany",
			countryCode: "DE",
			host: "de-01.example.com",
			port: 51820,
			status: "ONLINE",
			online: true,
			connectable: true,
			loadPercent: 4,
			activePeers: 2,
			capacity: 50,
			cpuPercent: 12.5,
			ramPercent: 41.25,
			uptimeSeconds: 3600,
			agentVersion: "0.1.0",
		})
		expect(view.lastHeartbeat).toBe(node.lastHeartbeat?.toISOString())
	})

	it("never leaks the node key, subnet, DNS or MTU", () => {
		const view = toPublicNode(makeNode())
		expect(view).not.toHaveProperty("wireguardPublicKey")
		expect(view).not.toHaveProperty("subnetCidr")
		expect(view).not.toHaveProperty("dns")
		expect(view).not.toHaveProperty("mtu")
		expect(JSON.stringify(view)).not.toContain(NODE_KEY)
	})

	it("nulls out metrics that were never reported", () => {
		const view = toPublicNode(
			makeNode({
				status: "PENDING",
				wireguardPublicKey: null,
				cpuPercent: null,
				ramPercent: null,
				uptimeSeconds: null,
				agentVersion: null,
				lastHeartbeat: null,
			}),
		)
		expect(view).toMatchObject({
			status: "PENDING",
			online: false,
			connectable: false,
			cpuPercent: null,
			ramPercent: null,
			uptimeSeconds: null,
			agentVersion: null,
			lastHeartbeat: null,
		})
	})
})
