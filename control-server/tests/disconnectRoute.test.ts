import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import path from "node:path"

describe("VPN disconnect route contracts", () => {
	it("uses requireUser rather than requireDeviceScope so the web dashboard can disconnect devices", () => {
		const vpnSource = readFileSync(path.join(__dirname, "../src/routes/vpn.ts"), "utf8")
		const disconnectSection = vpnSource.slice(vpnSource.indexOf('"/api/vpn/disconnect"'))
		const preHandlerMatch = disconnectSection.match(/preHandler:\s*([A-Za-z0-9_]+)/)
		expect(preHandlerMatch?.[1]).toBe("requireUser")
	})

	it("accepts deviceId in addition to sessionId in DisconnectBody schema", () => {
		const vpnSource = readFileSync(path.join(__dirname, "../src/routes/vpn.ts"), "utf8")
		expect(vpnSource).toMatch(/deviceId:\s*z\.string\(\)\.uuid\(/)
	})
})
