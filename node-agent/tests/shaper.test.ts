import { describe, expect, it, vi } from "vitest"

// The real config reads /etc/vpn-node-agent/agent.env and demands node
// identity; these tests only exercise the pure half of the shaper, so the
// module is handed the three knobs it actually reads.
vi.mock("../src/config", () => ({
  config: {
    SHAPING_ENABLED: true,
    SHAPING_UPLINK_MBIT: 1000,
    SHAPING_GUARANTEE_PERCENT: 25,
    LOG_LEVEL: "error",
    NODE_NAME: "unit-test-node",
  },
}))

import {
  burstKb,
  classKey,
  downloadClassArgs,
  downloadFilterArgs,
  guaranteedMbps,
  parseShaping,
  uploadPolicerArgs,
} from "../src/lib/shaper"

describe("parseShaping", () => {
  it("leaves a peer unshaped when the control plane sent no shaping block", () => {
    // An older control plane still speaks this payload; guessing a cap for it
    // would throttle paying customers.
    expect(parseShaping({ sessionId: "s1", publicKey: "k" })).toBeNull()
    expect(parseShaping({ shaping: null })).toBeNull()
    expect(parseShaping({ shaping: "100mbit" })).toBeNull()
  })

  it("reads the plan speed and priority as sent", () => {
    expect(parseShaping({ shaping: { speedMbps: 100, priority: 3 } })).toEqual({
      speedMbps: 100,
      priority: 3,
    })
  })

  it("keeps an uncapped plan uncapped", () => {
    expect(parseShaping({ shaping: { speedMbps: null, priority: 2 } })).toEqual({
      speedMbps: null,
      priority: 2,
    })
  })

  it("refuses a nonsense speed instead of shaping to it", () => {
    for (const speedMbps of [0, -100, Number.NaN, Number.POSITIVE_INFINITY, "100"]) {
      expect(parseShaping({ shaping: { speedMbps, priority: 2 } })?.speedMbps).toBeNull()
    }
  })

  it("floors a fractional speed to whole Mbit/s", () => {
    expect(parseShaping({ shaping: { speedMbps: 99.9 } })?.speedMbps).toBe(99)
  })

  it("clamps the priority into the range tc accepts", () => {
    expect(parseShaping({ shaping: { speedMbps: 100, priority: 99 } })?.priority).toBe(7)
    expect(parseShaping({ shaping: { speedMbps: 100, priority: -3 } })?.priority).toBe(0)
  })

  it("falls back to the Free priority when none was sent", () => {
    expect(parseShaping({ shaping: { speedMbps: 100 } })?.priority).toBe(4)
    expect(parseShaping({ shaping: { speedMbps: 100, priority: "high" } })?.priority).toBe(4)
  })
})

// The class id comes from the leased address so the same device always lands in
// the same class: a repeated ADD_PEER replaces it instead of leaking a second.
describe("classKey", () => {
  it("derives the class from the last two octets", () => {
    expect(classKey("10.8.0.5")).toBe(5)
    expect(classKey("10.8.1.5")).toBe((1 << 8) | 5)
    expect(classKey("10.8.0.254")).toBe(254)
  })

  it("is stable for one address", () => {
    expect(classKey("10.8.3.77")).toBe(classKey("10.8.3.77"))
  })

  it("refuses the network and gateway addresses reserved for the root class", () => {
    expect(classKey("10.8.0.0")).toBeNull()
    expect(classKey("10.8.0.1")).toBeNull()
  })

  it("refuses an address that cannot be a filter handle", () => {
    // 12-bit u32 handles: anything past a /20 pool has no id to live in.
    expect(classKey("10.8.16.0")).toBeNull()
    expect(classKey("10.8.255.255")).toBeNull()
  })

  it("refuses malformed input rather than shaping the wrong peer", () => {
    expect(classKey("")).toBeNull()
    expect(classKey("10.8.0")).toBeNull()
    expect(classKey("10.8.0.300")).toBeNull()
    expect(classKey("10.8.0.5/32")).toBeNull()
    expect(classKey("not-an-ip")).toBeNull()
  })
})

describe("guaranteedMbps", () => {
  it("gives a device the configured share of its own cap", () => {
    expect(guaranteedMbps(100, 25)).toBe(25)
    expect(guaranteedMbps(250, 25)).toBe(62)
  })

  it("never guarantees more than the cap itself", () => {
    expect(guaranteedMbps(30, 100)).toBe(30)
    expect(guaranteedMbps(1, 100)).toBe(1)
  })

  it("keeps a floor of 1 Mbit/s so HTB gets a usable rate", () => {
    expect(guaranteedMbps(2, 25)).toBe(1)
    expect(guaranteedMbps(1, 1)).toBe(1)
  })
})

describe("burstKb", () => {
  it("scales the policer burst with the cap", () => {
    expect(burstKb(100)).toBe(1600)
    expect(burstKb(250)).toBe(4000)
  })

  it("keeps a minimum burst so a slow cap can still pass a packet", () => {
    expect(burstKb(1)).toBe(32)
  })
})

// tc argv is assembled by hand, so the order and the units are the contract.
describe("tc arguments", () => {
  const iface = "wg0"
  const ip = "10.8.0.5"
  const hex = (classKey(ip) as number).toString(16)

  it("hangs the download class under the root class with rate, ceil and prio", () => {
    expect(
      downloadClassArgs({ iface, hex, capMbps: 100, guaranteeMbps: 25, priority: 3 }),
    ).toEqual([
      "class", "replace", "dev", "wg0",
      "parent", "1:1",
      "classid", `1:${hex}`,
      "htb",
      "rate", "25mbit",
      "ceil", "100mbit",
      "prio", "3",
    ])
  })

  it("matches download traffic on the destination address", () => {
    expect(downloadFilterArgs({ iface, hex, ip })).toEqual([
      "filter", "replace", "dev", "wg0",
      "parent", "1:",
      "protocol", "ip",
      "prio", "1",
      // The handle is what makes a second ADD_PEER replace this filter.
      "handle", `800::${hex}`,
      "u32", "match", "ip", "dst", "10.8.0.5/32",
      "flowid", `1:${hex}`,
    ])
  })

  it("polices upload traffic on the source address and drops the excess", () => {
    expect(uploadPolicerArgs({ iface, hex, ip, capMbps: 100 })).toEqual([
      "filter", "replace", "dev", "wg0",
      "parent", "ffff:",
      "protocol", "ip",
      "prio", "1",
      "handle", `800::${hex}`,
      "u32", "match", "ip", "src", "10.8.0.5/32",
      "police", "rate", "100mbit", "burst", "1600k", "drop",
      "flowid", ":1",
    ])
  })

  it("never lets a peer claim the root class id", () => {
    const args = downloadClassArgs({
      iface,
      hex,
      capMbps: 100,
      guaranteeMbps: 25,
      priority: 4,
    })
    expect(args).toContain("1:1")
    expect(args.at(-2)).toBe("prio")
    expect(hex).not.toBe("1")
  })
})
