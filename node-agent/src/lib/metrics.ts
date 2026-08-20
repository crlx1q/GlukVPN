/**
 * Host metrics for heartbeats.
 *
 * Only aggregate numbers are collected: CPU load, memory usage, uptime and
 * interface byte counters. No process list, no connection contents, no URLs.
 */
import fs from "node:fs/promises"
import os from "node:os"

type CpuSample = { total: number; idle: number }

let previousCpuSample: CpuSample | null = null

async function readCpuSample(): Promise<CpuSample | null> {
	try {
		const content = await fs.readFile("/proc/stat", "utf8")
		const line = content.split("\n").find((entry) => entry.startsWith("cpu "))
		if (!line) return null
		const values = line
			.trim()
			.split(/\s+/)
			.slice(1)
			.map((value) => Number(value) || 0)
		if (values.length < 5) return null
		const total = values.reduce((sum, value) => sum + value, 0)
		// idle + iowait
		const idle = (values[3] ?? 0) + (values[4] ?? 0)
		return { total, idle }
	} catch {
		return null
	}
}

/**
 * CPU utilisation since the previous call. The first call after start returns a
 * load-average based estimate, because a delta is not available yet.
 */
export async function cpuPercent(): Promise<number> {
	const sample = await readCpuSample()
	if (!sample) {
		const cores = os.cpus().length || 1
		return Math.min(100, Math.round((os.loadavg()[0] / cores) * 100))
	}

	const previous = previousCpuSample
	previousCpuSample = sample

	if (!previous) {
		const cores = os.cpus().length || 1
		return Math.min(100, Math.round((os.loadavg()[0] / cores) * 100))
	}

	const totalDelta = sample.total - previous.total
	const idleDelta = sample.idle - previous.idle
	if (totalDelta <= 0) return 0
	const used = 1 - idleDelta / totalDelta
	return Math.min(100, Math.max(0, Math.round(used * 1000) / 10))
}

/** Memory usage in percent, based on MemAvailable when the kernel exposes it. */
export async function ramPercent(): Promise<number> {
	try {
		const content = await fs.readFile("/proc/meminfo", "utf8")
		const read = (key: string): number | null => {
			const match = new RegExp(`^${key}:\\s+(\\d+) kB$`, "m").exec(content)
			return match ? Number(match[1]) : null
		}
		const total = read("MemTotal")
		const available = read("MemAvailable")
		if (total && available && total > 0) {
			return Math.round(((total - available) / total) * 1000) / 10
		}
	} catch {
		/* fall through to the os module */
	}
	const total = os.totalmem()
	if (total <= 0) return 0
	return Math.round(((total - os.freemem()) / total) * 1000) / 10
}

/** Host uptime in whole seconds. */
export function uptimeSeconds(): number {
	return Math.floor(os.uptime())
}

export type InterfaceCounters = { bytesRx: number; bytesTx: number }

/**
 * Byte counters of one interface from /proc/net/dev. Used for a coarse
 * node-level traffic figure; per-session accounting comes from `wg` itself.
 */
export async function interfaceCounters(iface: string): Promise<InterfaceCounters | null> {
	try {
		const content = await fs.readFile("/proc/net/dev", "utf8")
		for (const line of content.split("\n")) {
			const [name, rest] = line.split(":")
			if (!rest || name.trim() !== iface) continue
			const columns = rest.trim().split(/\s+/).map((value) => Number(value) || 0)
			return { bytesRx: columns[0] ?? 0, bytesTx: columns[8] ?? 0 }
		}
		return null
	} catch {
		return null
	}
}

export type HostMetrics = {
	cpuPercent: number
	ramPercent: number
	uptimeSeconds: number
	interfaceBytesRx: number | null
	interfaceBytesTx: number | null
}

export async function collectHostMetrics(iface: string): Promise<HostMetrics> {
	const [cpu, ram, counters] = await Promise.all([
		cpuPercent(),
		ramPercent(),
		interfaceCounters(iface),
	])
	return {
		cpuPercent: cpu,
		ramPercent: ram,
		uptimeSeconds: uptimeSeconds(),
		interfaceBytesRx: counters?.bytesRx ?? null,
		interfaceBytesTx: counters?.bytesTx ?? null,
	}
}
