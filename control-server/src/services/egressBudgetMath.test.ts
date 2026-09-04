import { describe, expect, it } from "vitest"

import {
	BYTES_PER_TB,
	cycleEnd,
	cycleStart,
	formatBytes,
	parseThresholds,
} from "./egressBudgetMath"

const utc = (iso: string): Date => new Date(iso + "T00:00:00.000Z")

describe("cycleStart", () => {
	// The whole point of the feature: a PAYG subscription that began on the 17th
	// resets on the 17th. Anchoring to the 1st of the month would put the reset
	// up to thirty days early and every alert would arrive after the fact.
	it("anchors to the subscription day, not the first of the month", () => {
		const start = cycleStart(utc("2026-03-17"), utc("2026-09-04"))
		expect(start.toISOString()).toBe("2026-08-17T00:00:00.000Z")
	})

	it("treats the anniversary itself as the start of the new cycle", () => {
		const start = cycleStart(utc("2026-03-17"), utc("2026-09-17"))
		expect(start.toISOString()).toBe("2026-09-17T00:00:00.000Z")
	})

	it("steps back across a year boundary", () => {
		const start = cycleStart(utc("2025-06-20"), utc("2026-01-05"))
		expect(start.toISOString()).toBe("2025-12-20T00:00:00.000Z")
	})

	// A subscription that began on the 31st has no anniversary in February.
	it("clamps a day that the month does not have", () => {
		const start = cycleStart(utc("2025-01-31"), utc("2026-02-27"))
		expect(start.toISOString()).toBe("2026-02-28T00:00:00.000Z")
	})

	it("never reports a cycle that begins before the subscription", () => {
		const start = cycleStart(utc("2026-03-17"), utc("2026-03-20"))
		expect(start.toISOString()).toBe("2026-03-17T00:00:00.000Z")
	})
})

describe("cycleEnd", () => {
	it("is the next anniversary", () => {
		const end = cycleEnd(utc("2026-08-17"), utc("2026-03-17"))
		expect(end.toISOString()).toBe("2026-09-17T00:00:00.000Z")
	})

	it("rolls over the year", () => {
		const end = cycleEnd(utc("2026-12-20"), utc("2025-06-20"))
		expect(end.toISOString()).toBe("2027-01-20T00:00:00.000Z")
	})

	it("clamps into a shorter month", () => {
		const end = cycleEnd(utc("2026-01-31"), utc("2025-01-31"))
		expect(end.toISOString()).toBe("2026-02-28T00:00:00.000Z")
	})
})

describe("parseThresholds", () => {
	it("reads the configured defaults", () => {
		expect(parseThresholds("7,8,9,9.5")).toEqual([7, 8, 9, 9.5])
	})

	it("sorts, de-duplicates and ignores junk", () => {
		expect(parseThresholds(" 9 , 7,7, ,x,-1,0,8 ")).toEqual([7, 8, 9])
	})

	it("returns nothing for an empty setting", () => {
		expect(parseThresholds("")).toEqual([])
	})
})

describe("formatBytes", () => {
	it("uses decimal units, as Oracle bills them", () => {
		expect(formatBytes(0)).toBe("0 B")
		expect(formatBytes(1500)).toBe("1.5 KB")
		expect(formatBytes(BYTES_PER_TB)).toBe("1 TB")
		expect(formatBytes(9.5 * BYTES_PER_TB)).toBe("9.5 TB")
	})

	it("survives nonsense instead of printing NaN", () => {
		expect(formatBytes(Number.NaN)).toBe("0 B")
		expect(formatBytes(-1)).toBe("0 B")
	})

	// Ten decimal TB, not ten binary TB: 2^40 would quietly hand us a 10%
	// larger budget than Oracle actually gives away.
	it("keeps the budget in decimal terabytes", () => {
		expect(BYTES_PER_TB).toBe(1_000_000_000_000)
		expect(formatBytes(10 * BYTES_PER_TB)).toBe("10 TB")
	})
})
