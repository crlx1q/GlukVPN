import { afterEach, describe, expect, it, vi } from "vitest"

// The real config reads /etc/vpn-node-agent/agent.env and demands a node
// identity; these cases only need the gateway knobs. A plain object (rather
// than a literal inside the factory) lets each case rewrite an operator's
// settings before asking fromConfig() what it would bind.
const mockConfig = vi.hoisted(() => ({
  SHAPING_GATEWAY_ENABLED: true,
  SHAPING_GATEWAY_TIERS: "",
  SHAPING_GATEWAY_SPEEDS: "",
  SHAPING_GATEWAY_BASE_PORT: 8460,
  SHAPING_GATEWAY_BIND_HOST: "127.0.0.1",
  SHAPING_GATEWAY_TARGET_HOST: "127.0.0.1",
  SHAPING_GATEWAY_TARGET_PORT: 8445,
  SHAPING_GATEWAY_BURST_SECONDS: 0.25,
  LOG_LEVEL: "error",
  NODE_NAME: "unit-test-node",
}))

vi.mock("../src/config", () => ({ config: mockConfig }))

import {
  DEFAULT_SPEED_BASE_PORT,
  GatewayShaper,
  parseSpeedTiers,
} from "../src/lib/gatewayShaper"

// ROUND 27 gave every sold speed its own *external* port (30 -> 2053,
// 100 -> 2083). The Oracle VCN closes everything but 443, so a capped desktop
// client got connect_timeout instead of a slow tunnel. The speeds list is the
// fix: nginx `stream` splits the single open port by SNI and these listeners
// bind loopback, so their ports are an internal detail. What has to hold is
// that the agent derives the same port for a speed that the generated nginx
// map does - otherwise one tier answers with connection refused.
describe("parseSpeedTiers", () => {
  it("assigns a loopback port per sold speed, in speed order", () => {
    // The five buttons in the admin panel, in the order the map generator
    // walks them.
    expect(parseSpeedTiers("30,50,100,250,500")).toEqual([
      { mbps: 30, port: 8460 },
      { mbps: 50, port: 8461 },
      { mbps: 100, port: 8462 },
      { mbps: 250, port: 8463 },
      { mbps: 500, port: 8464 },
    ])
  })

  it("sorts by speed so the port of a tier does not depend on typing order", () => {
    // An operator who appends a new speed to the end of the variable must not
    // silently renumber the tiers nginx already points at... but a *sorted*
    // list at least makes the numbering reproducible from the speeds alone.
    expect(parseSpeedTiers("100,30")).toEqual([
      { mbps: 30, port: 8460 },
      { mbps: 100, port: 8461 },
    ])
  })

  it("starts from the documented default base port", () => {
    expect(DEFAULT_SPEED_BASE_PORT).toBe(8460)
    expect(parseSpeedTiers("30")[0]?.port).toBe(DEFAULT_SPEED_BASE_PORT)
  })

  it("honours a base port moved off a range the node already uses", () => {
    expect(parseSpeedTiers("30,50", 9100)).toEqual([
      { mbps: 30, port: 9100 },
      { mbps: 50, port: 9101 },
    ])
  })

  it("tolerates the spacing an env file actually has", () => {
    expect(parseSpeedTiers(" 30 , ,100 , ")).toEqual([
      { mbps: 30, port: 8460 },
      { mbps: 100, port: 8461 },
    ])
  })

  it("lets a tier pin its own port", () => {
    // Escape hatch for a node where 8460+ is taken by something else.
    expect(parseSpeedTiers("30=9000,50")).toEqual([
      { mbps: 30, port: 9000 },
      { mbps: 50, port: 8460 },
    ])
  })

  it("routes assigned ports around a pinned one", () => {
    // Two listeners cannot bind one port: the second tier would fail to start
    // and its subscribers would see connection refused.
    expect(parseSpeedTiers("30=8460,50,100")).toEqual([
      { mbps: 30, port: 8460 },
      { mbps: 50, port: 8461 },
      { mbps: 100, port: 8462 },
    ])
  })

  it("keeps the first entry when a speed is listed twice", () => {
    expect(parseSpeedTiers("30,30")).toEqual([{ mbps: 30, port: 8460 }])
    expect(parseSpeedTiers("30=9000,30")).toEqual([{ mbps: 30, port: 9000 }])
  })

  it("drops a malformed entry instead of inventing a cap", () => {
    // A tier guessed from a typo throttles a plan nobody sold, and the control
    // plane hands out its subdomain as if it were real.
    expect(parseSpeedTiers("thirty")).toEqual([])
    expect(parseSpeedTiers("30mbit")).toEqual([])
    expect(parseSpeedTiers("0")).toEqual([])
    expect(parseSpeedTiers("-30")).toEqual([])
    expect(parseSpeedTiers("30=")).toEqual([])
    expect(parseSpeedTiers("=8460")).toEqual([])
    expect(parseSpeedTiers("30=0")).toEqual([])
    expect(parseSpeedTiers("30=99999")).toEqual([])
  })

  it("keeps the good tiers when one entry is junk", () => {
    // Numbering follows the surviving speeds, which is what the map generator
    // sees too.
    expect(parseSpeedTiers("30,oops,100")).toEqual([
      { mbps: 30, port: 8460 },
      { mbps: 100, port: 8461 },
    ])
  })

  it("reads an unset variable as no shaped tiers at all", () => {
    expect(parseSpeedTiers("")).toEqual([])
    expect(parseSpeedTiers("   ")).toEqual([])
    expect(parseSpeedTiers(",,")).toEqual([])
  })
})

describe("GatewayShaper.fromConfig with SHAPING_GATEWAY_SPEEDS", () => {
  afterEach(() => {
    mockConfig.SHAPING_GATEWAY_ENABLED = true
    mockConfig.SHAPING_GATEWAY_TIERS = ""
    mockConfig.SHAPING_GATEWAY_SPEEDS = ""
    mockConfig.SHAPING_GATEWAY_BASE_PORT = 8460
    mockConfig.SHAPING_GATEWAY_TARGET_PORT = 8445
  })

  it("builds a loopback relay per sold speed", () => {
    mockConfig.SHAPING_GATEWAY_SPEEDS = "30,50"
    const shaper = GatewayShaper.fromConfig()
    expect(shaper).toBeInstanceOf(GatewayShaper)
    // The map nginx has to point at. Nothing is bound before start(), so this
    // case touches no port.
    expect(shaper?.tierMap).toBe("30=8460,50=8461")
    expect(shaper?.ports).toEqual([])
  })

  it("keeps a node that still has the legacy pairs on them", () => {
    // An operator who has not installed the nginx SNI map yet must not have
    // their working ports pulled out from under them by an upgrade.
    mockConfig.SHAPING_GATEWAY_TIERS = "30=2053,100=2083"
    mockConfig.SHAPING_GATEWAY_SPEEDS = "30,50,100"
    expect(GatewayShaper.fromConfig()?.tierMap).toBe("30=2053,100=2083")
  })

  it("ignores the speeds list when it is all junk", () => {
    mockConfig.SHAPING_GATEWAY_SPEEDS = "thirty,fifty"
    expect(GatewayShaper.fromConfig()).toBeNull()
  })

  it("obeys the kill switch with speeds configured", () => {
    mockConfig.SHAPING_GATEWAY_ENABLED = false
    mockConfig.SHAPING_GATEWAY_SPEEDS = "30,50"
    expect(GatewayShaper.fromConfig()).toBeNull()
  })

  it("never binds the port it forwards to", () => {
    // A relay listening on sing-box's own port would forward the stream into
    // itself until the node ran out of sockets.
    mockConfig.SHAPING_GATEWAY_BASE_PORT = 8445
    mockConfig.SHAPING_GATEWAY_TARGET_PORT = 8445
    mockConfig.SHAPING_GATEWAY_SPEEDS = "30,50"
    expect(GatewayShaper.fromConfig()?.tierMap).toBe("50=8446")
  })

  it("stays out of the way when every tier collides with sing-box", () => {
    mockConfig.SHAPING_GATEWAY_BASE_PORT = 8445
    mockConfig.SHAPING_GATEWAY_TARGET_PORT = 8445
    mockConfig.SHAPING_GATEWAY_SPEEDS = "30"
    expect(GatewayShaper.fromConfig()).toBeNull()
  })
})
