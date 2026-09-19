import { createReadStream } from "node:fs"
import { readdir, readFile, stat } from "node:fs/promises"
import path from "node:path"
import { spawn } from "node:child_process"

const BACKUP_NAME = /^glukvpn-backup-(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})\.tar\.gz$/
const DEFAULT_BACKUP_DIR = "/opt/glukvpn/backups/daily"
const DEFAULT_STATUS_FILE = "/opt/glukvpn/backups/status.json"

export type BackupItem = {
	filename: string
	createdAt: string
	sizeBytes: number
	sizeMb: number
	googleDrive: "uploaded" | "failed" | "pending" | "disabled" | "unknown"
}

type BackupStatusFile = {
	lastAttemptAt?: string
	lastSuccessAt?: string
	lastFilename?: string
	lastError?: string | null
	googleDriveConfigured?: boolean
	googleDriveStatus?: string
	running?: boolean
}

function backupDir(): string {
	return process.env.GLUKVPN_BACKUP_DIR?.trim() || DEFAULT_BACKUP_DIR
}

function statusFile(): string {
	return process.env.GLUKVPN_BACKUP_STATUS_FILE?.trim() || DEFAULT_STATUS_FILE
}

export function parseBackupCreatedAt(filename: string): Date | null {
	const match = BACKUP_NAME.exec(filename)
	if (!match) return null
	const [, year, month, day, hour, minute, second] = match
	const value = new Date(`${year}-${month}-${day}T${hour}:${minute}:${second}Z`)
	return Number.isNaN(value.getTime()) ? null : value
}

export function safeBackupFilename(filename: string): string | null {
	if (!BACKUP_NAME.test(filename) || path.basename(filename) !== filename) return null
	return filename
}

async function readJson<T>(filename: string): Promise<T | null> {
	try {
		return JSON.parse(await readFile(filename, "utf8")) as T
	} catch {
		return null
	}
}

async function cloudStatus(filename: string): Promise<BackupItem["googleDrive"]> {
	const sidecar = await readJson<{ googleDrive?: BackupItem["googleDrive"] }>(
		path.join(backupDir(), `${filename}.json`),
	)
	return sidecar?.googleDrive ?? "unknown"
}

export async function listBackups(): Promise<BackupItem[]> {
	let names: string[]
	try {
		names = await readdir(backupDir())
	} catch (error: any) {
		if (error?.code === "ENOENT") return []
		throw error
	}
	const items = await Promise.all(
		names.filter((name) => BACKUP_NAME.test(name)).map(async (filename) => {
			const info = await stat(path.join(backupDir(), filename))
			const parsed = parseBackupCreatedAt(filename)
			return {
				filename,
				createdAt: (parsed ?? info.mtime).toISOString(),
				sizeBytes: info.size,
				sizeMb: Math.round((info.size / 1024 / 1024) * 100) / 100,
				googleDrive: await cloudStatus(filename),
			} satisfies BackupItem
		}),
	)
	return items.sort((left, right) => right.createdAt.localeCompare(left.createdAt)).slice(0, 5)
}

function nextDailyRun(now = new Date()): Date {
	const next = new Date(now)
	next.setUTCHours(3, 0, 0, 0)
	if (next.getTime() <= now.getTime()) next.setUTCDate(next.getUTCDate() + 1)
	return next
}

export async function backupStatus(now = new Date()) {
	const [items, state] = await Promise.all([listBackups(), readJson<BackupStatusFile>(statusFile())])
	return {
		schedule: "03:00 UTC",
		retention: 5,
		lastBackupAt: state?.lastSuccessAt ?? items[0]?.createdAt ?? null,
		lastAttemptAt: state?.lastAttemptAt ?? null,
		lastFilename: state?.lastFilename ?? items[0]?.filename ?? null,
		lastError: state?.lastError ?? null,
		running: state?.running === true,
		googleDriveConfigured: state?.googleDriveConfigured === true,
		googleDriveStatus: state?.googleDriveStatus ?? "unknown",
		nextBackupAt: nextDailyRun(now).toISOString(),
	}
}

export function startBackup(): Promise<void> {
	return new Promise((resolve, reject) => {
		const command = process.env.GLUKVPN_BACKUP_START_COMMAND?.trim() || "sudo"
		const args = command === "sudo" ? ["-n", "/bin/systemctl", "start", "glukvpn-backup.service"] : []
		const child = spawn(command, args, { stdio: "ignore", detached: false })
		child.once("error", reject)
		child.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`backup start failed (${code ?? "signal"})`))))
	})
}

export async function backupDownload(filename: string) {
	const safe = safeBackupFilename(filename)
	if (!safe) return null
	const fullPath = path.join(backupDir(), safe)
	try {
		const info = await stat(fullPath)
		if (!info.isFile()) return null
		return { fullPath, sizeBytes: info.size, stream: createReadStream(fullPath) }
	} catch (error: any) {
		if (error?.code === "ENOENT") return null
		throw error
	}
}
