import net from "node:net"
import { afterEach, describe, expect, it, vi } from "vitest"

// The real config reads /etc/vpn-node-agent/agent.env and demands a node
// identity; these tests only need the gateway knobs. The mock is a plain
// object the tests can rewrite instead of a literal inside the factory,
// because fromConfig() has to be watched while an operator's settings change.
const mockConfig = vi.hoisted(() => ({
  SHAPING_GATEWAY_ENABLED: true,
  SHAPING_GATEWAY_TIERS: "",
  SHAPING_GATEWAY_TARGET_HOST: "127.0.0.1",
  SHAPING_GATEWAY_TARGET_PORT: 443,
  SHAPING_GATEWAY_BURST_SECONDS: 0.25,
  LOG_LEVEL: "error",
  NODE_NAME: "unit-test-node",
}))

vi.mock("../src/config", () => ({ config: mockConfig }))

import {
  bytesPerSecond,
  GatewayShaper,
  MIN_BYTES_PER_SECOND,
  parseTiers,
  TokenBucket,
} from "../src/lib/gatewayShaper"

describe("parseTiers", () => {
  it("reads one port per plan speed, sorted by speed", () => {
    expect(parseTiers("100=2083,30=2053")).toEqual([
      { mbps: 30, port: 2053 },
      { mbps: 100, port: 2083 },
    ])
  })

  it("tolerates the spacing an operator leaves in an env file", () => {
    expect(parseTiers(" 30 = 2053 , ,100=2083 ")).toEqual([
      { mbps: 30, port: 2053 },
      { mbps: 100, port: 2083 },
    ])
  })

  it("drops a malformed pair instead of inventing a cap for it", () => {
    // A tier guessed from a typo would throttle a plan nobody sold, and the
    // control plane would hand out its port as if it were real.
    expect(parseTiers("thirty=2053")).toEqual([])
    expect(parseTiers("30")).toEqual([])
    expect(parseTiers("=2053")).toEqual([])
    expect(parseTiers("30=")).toEqual([])
    expect(parseTiers("30=2053:tls")).toEqual([])
    expect(parseTiers("0=2053")).toEqual([])
    expect(parseTiers("30=0")).toEqual([])
    expect(parseTiers("30=99999")).toEqual([])
  })

  it("keeps the first pair when a port or a speed repeats", () => {
    // Two listeners cannot bind one port, and two ports for one speed leave
    // the control plane no way to choose.
    expect(parseTiers("30=2053,100=2053")).toEqual([{ mbps: 30, port: 2053 }])
    expect(parseTiers("30=2053,30=2083")).toEqual([{ mbps: 30, port: 2053 }])
  })

  it("reads an unset variable as no shaped ports at all", () => {
    expect(parseTiers("")).toEqual([])
    expect(parseTiers("   ")).toEqual([])
  })
})

describe("bytesPerSecond", () => {
  it("converts the plan speed into a byte budget", () => {
    expect(bytesPerSecond(8)).toBe(1_000_000)
    expect(bytesPerSecond(30)).toBe(3_750_000)
    expect(bytesPerSecond(1_000)).toBe(125_000_000)
  })

  it("floors a fractional budget to whole bytes", () => {
    expect(bytesPerSecond(1 / 3)).toBe(41_666)
  })

  it("keeps a floor so a tiny cap throttles instead of hanging", () => {
    expect(MIN_BYTES_PER_SECOND).toBe(32 * 1024)
    expect(bytesPerSecond(0.1)).toBe(MIN_BYTES_PER_SECOND)
  })
})

describe("TokenBucket", () => {
  /**
   * A fake clock: sleeping moves time forward by exactly the amount asked
   * for. Wall-clock assertions would fail on a loaded CI box and would prove
   * nothing about the arithmetic.
   */
  function fakeClock() {
    let ms = 0
    const slept: number[] = []
    return {
      slept,
      now: (): number => ms,
      sleep: async (wait: number): Promise<void> => {
        ms += wait
        slept.push(wait)
      },
    }
  }

  it("lets a fresh bucket spend its burst without waiting", async () => {
    // The first quarter second is free, so a short request is not delayed at
    // all: a capped plan still has to feel responsive.
    const time = fakeClock()
    const bucket = new TokenBucket({
      bytesPerSecond: 1_000_000,
      burstSeconds: 0.25,
      now: time.now,
      sleep: time.sleep,
    })

    await bucket.take(250_000)

    expect(time.slept).toEqual([])
  })

  it("holds a long transfer to the configured rate", async () => {
    const rate = 1_000_000
    const chunk = 64 * 1024
    const chunks = 16
    const time = fakeClock()
    const bucket = new TokenBucket({
      bytesPerSecond: rate,
      burstSeconds: 0.25,
      now: time.now,
      sleep: time.sleep,
    })

    // Chunk by chunk, the way the stream gate pays for a tunnel.
    for (let i = 0; i < chunks; i++) await bucket.take(chunk)

    // Everything past the free burst is paid for at the plan rate. This is
    // the whole feature: 30 Mbit/s has to mean 30 Mbit/s on the desktop too.
    const owed = ((chunk * chunks - 0.25 * rate) / rate) * 1_000
    const waited = time.slept.reduce((total, ms) => total + ms, 0)
    expect(waited).toBeGreaterThan(owed * 0.95)
    expect(waited).toBeLessThan(owed * 1.05)
    // No single wait may outlast a rate change: an open socket has to notice
    // a new plan speed.
    expect(Math.max(...time.slept)).toBeLessThanOrEqual(1_000)
  })

  it("re-reads the rate while the socket is open", () => {
    const bucket = new TokenBucket({ bytesPerSecond: 1_000_000 })
    expect(bucket.ratePerSecond).toBe(1_000_000)

    bucket.setRate(3_750_000)
    expect(bucket.ratePerSecond).toBe(3_750_000)

    // A nonsense rate still has to leave a usable bucket rather than a
    // division by zero in the wait computation.
    bucket.setRate(0)
    expect(bucket.ratePerSecond).toBe(1)
  })
})

describe("GatewayShaper.fromConfig", () => {
  afterEach(() => {
    mockConfig.SHAPING_GATEWAY_ENABLED = true
    mockConfig.SHAPING_GATEWAY_TIERS = ""
  })

  it("stays out of the way until an operator configures a tier", () => {
    // On a node whose plans are all unlimited the relay is dead weight, and
    // a port nobody hands out is only extra surface.
    expect(GatewayShaper.fromConfig()).toBeNull()
  })

  it("stays out of the way when every tier is malformed", () => {
    mockConfig.SHAPING_GATEWAY_TIERS = "thirty=2053"
    expect(GatewayShaper.fromConfig()).toBeNull()
  })

  it("obeys the kill switch even with tiers configured", () => {
    mockConfig.SHAPING_GATEWAY_ENABLED = false
    mockConfig.SHAPING_GATEWAY_TIERS = "30=2053"
    expect(GatewayShaper.fromConfig()).toBeNull()
  })

  it("builds a relay once a tier is configured", () => {
    mockConfig.SHAPING_GATEWAY_TIERS = "30=2053"
    const shaper = GatewayShaper.fromConfig()
    expect(shaper).toBeInstanceOf(GatewayShaper)
    // Nothing is bound before start(), so this case touches no port.
    expect(shaper?.ports).toEqual([])
  })
})

describe("GatewayShaper", () => {
  it("relays a stream to sing-box byte for byte", async () => {
    // The cap here is high enough that the buckets never sleep: what is under
    // test is that the gate neither corrupts nor truncates the tunnel. A
    // shaped VLESS stream that loses a byte is a dead tunnel, not a slow one.
    const accepted: net.Socket[] = []
    const echo = net.createServer((socket) => {
      accepted.push(socket)
      socket.pipe(socket)
    })
    await new Promise<void>((resolve) => echo.listen(0, "127.0.0.1", () => resolve()))
    const echoPort = (echo.address() as net.AddressInfo).port

    const shaper = new GatewayShaper({
      // Port 0 asks the OS for a free one, so the suite never fights a real
      // node's 2053/2083 or the browser proxies on 8443/8444.
      tiers: [{ mbps: 1_000, port: 0 }],
      targetHost: "127.0.0.1",
      targetPort: echoPort,
      host: "127.0.0.1",
    })
    await shaper.start()
    const [port] = shaper.ports
    expect(port).toBeGreaterThan(0)

    const payload = Buffer.alloc(128 * 1024)
    for (let i = 0; i < payload.length; i++) payload[i] = i % 251

    const client = net.connect({ host: "127.0.0.1", port })
    const echoed = await new Promise<Buffer>((resolve, reject) => {
      const chunks: Buffer[] = []
      let received = 0
      client.on("connect", () => client.write(payload))
      client.on("data", (chunk: Buffer) => {
        chunks.push(chunk)
        received += chunk.length
        // The client hangs up once it has counted every byte back. Sending a
        // FIN instead would race the relay's own teardown and make the test
        // flaky rather than the code wrong.
        if (received >= payload.length) resolve(Buffer.concat(chunks))
      })
      client.on("error", reject)
      client.on("close", () => reject(new Error("relay closed before the payload came back")))
    })
    client.destroy()

    expect(echoed.length).toBe(payload.length)
    expect(echoed.equals(payload)).toBe(true)

    await shaper.stop()
    for (const socket of accepted) socket.destroy()
    await new Promise<void>((resolve) => echo.close(() => resolve()))
  })
})
