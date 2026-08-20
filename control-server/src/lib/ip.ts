import { badRequest } from "./errors"

export function ipToInt(ip: string): number {
	const parts = ip.trim().split(".")
	if (parts.length !== 4) throw badRequest(`Invalid IPv4 address: ${ip}`)
	let value = 0
	for (const part of parts) {
		if (!/^\d{1,3}$/.test(part)) throw badRequest(`Invalid IPv4 address: ${ip}`)
		const octet = Number(part)
		if (octet > 255) throw badRequest(`Invalid IPv4 address: ${ip}`)
		value = (value << 8) | octet
	}
	return value >>> 0
}

export function intToIp(value: number): string {
	const unsigned = value >>> 0
	return [
		(unsigned >>> 24) & 255,
		(unsigned >>> 16) & 255,
		(unsigned >>> 8) & 255,
		unsigned & 255,
	].join(".")
}

export function parseCidr(cidr: string): {
	network: number
	prefix: number
	size: number
} {
	const [ipPart, prefixPart] = cidr.trim().split("/")
	if (!ipPart || !prefixPart) throw badRequest(`Invalid CIDR: ${cidr}`)
	const prefix = Number(prefixPart)
	// /16 keeps the generated pool bounded; /30 is the smallest useful subnet.
	if (!Number.isInteger(prefix) || prefix < 16 || prefix > 30) {
		throw badRequest(`Subnet prefix must be between /16 and /30: ${cidr}`)
	}
	const mask = (0xffffffff << (32 - prefix)) >>> 0
	const network = (ipToInt(ipPart) & mask) >>> 0
	return { network, prefix, size: 2 ** (32 - prefix) }
}

/** Gateway address of the tunnel subnet (the node itself), e.g. 10.8.0.1. */
export function gatewayIp(cidr: string): string {
	const { network } = parseCidr(cidr)
	return intToIp(network + 1)
}

/**
 * Usable client addresses: excludes the network address, the gateway
 * (reservedHosts) and the broadcast address.
 */
export function usableHostIps(cidr: string, reservedHosts = 1): string[] {
	const { network, size } = parseCidr(cidr)
	const ips: string[] = []
	for (let offset = 1 + reservedHosts; offset < size - 1; offset += 1) {
		ips.push(intToIp(network + offset))
	}
	return ips
}

/** True when `ip` belongs to `cidr`. */
export function isIpInCidr(ip: string, cidr: string): boolean {
	const { network, prefix } = parseCidr(cidr)
	const mask = (0xffffffff << (32 - prefix)) >>> 0
	return ((ipToInt(ip) & mask) >>> 0) === network
}
