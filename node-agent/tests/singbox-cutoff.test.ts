import { afterEach, describe, expect, it, vi } from "vitest"
import { closeConnection } from "../src/lib/clash"
import { renderConfig, type JsonObject } from "../src/lib/singbox"
import type { NodePolicy } from "../src/lib/api"

const base: JsonObject = {
  inbounds: [{ type: "vless", tag: "vless-in", users: [{ name: "old", uuid: "x" }] }],
  outbounds: [{ type: "direct", tag: "direct" }],
}
const policy: NodePolicy = {
  version: "maintenance-1",
  generatedAt: new Date(0).toISOString(),
  maintenance: true,
  users: [],
  legacyUser: null,
  rules: [],
  builtinRules: [],
  domainStats: false,
  flow: "xtls-rprx-vision",
}

afterEach(() => vi.unstubAllGlobals())

describe("maintenance rendering", () => {
  it("keeps VLESS empty and adds an inbound-scoped reject on modern sing-box", () => {
    const rendered = renderConfig(base, policy, {
      clashApi: "127.0.0.1:9090",
      clashSecret: "secret",
      version: { major: 1, minor: 13, raw: "1.13" },
    })
    expect((rendered.inbounds as JsonObject[])[0]?.users).toEqual([])
    expect((rendered.route as JsonObject).rules).toContainEqual({ inbound: ["vless-in"], action: "reject" })
  })

  it("uses the legacy block outbound before sing-box 1.11", () => {
    const rendered = renderConfig(base, policy, {
      clashApi: "127.0.0.1:9090",
      clashSecret: "secret",
      version: { major: 1, minor: 10, raw: "1.10" },
    })
    expect((rendered.route as JsonObject).rules).toContainEqual({ inbound: ["vless-in"], outbound: "block" })
  })
})

describe("targeted Clash cutoff", () => {
  it("DELETEs only the encoded connection id", async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 204 })
    vi.stubGlobal("fetch", fetchMock)
    await expect(closeConnection("127.0.0.1:9090", "secret", "own/id")).resolves.toBe(true)
    expect(fetchMock).toHaveBeenCalledOnce()
    expect(fetchMock.mock.calls[0]?.[0]).toBe("http://127.0.0.1:9090/connections/own%2Fid")
    expect(fetchMock.mock.calls[0]?.[1]?.method).toBe("DELETE")
  })
})
