/**
 * BETA lifecycle scripts.
 *
 * The bug these tests exist for: beta-stop.sh / beta-restart.sh printed
 *
 *   vpn-node-agent-beta is not installed, skipping
 *   vpn-control-beta is not installed, skipping
 *
 * exited 0, and :8082 kept answering. "I could not find the unit" was treated
 * as "there is nothing to stop".
 *
 * Two kinds of test below:
 *
 *   1. static - the scripts are read as text and checked for the properties
 *      that must never regress (no prod unit is ever started/stopped here, the
 *      stop verifies the port, restart delegates to stop+start). These run
 *      everywhere, including on Windows.
 *
 *   2. behavioural - the real scripts are executed under bash with stub
 *      systemctl / ss / ip / wg-quick / curl on PATH and a real child process
 *      standing in for "something is listening on the beta port". Skipped when
 *      there is no bash (Windows), because there is nothing to exercise.
 *
 * Nothing here touches the machine's own services: the stubs are the only
 * systemctl on PATH, and the port is a throwaway high port.
 */
import { spawn, spawnSync } from "node:child_process"
import type { ChildProcess } from "node:child_process"
import {
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	writeFileSync,
} from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import { afterEach, describe, expect, it } from "vitest"

const BIN_DIR = path.join(__dirname, "..", "deploy", "bin")
const LIFECYCLE_SCRIPTS = [
	"beta-lib.sh",
	"beta-start.sh",
	"beta-stop.sh",
	"beta-restart.sh",
] as const

/** A throwaway high port, so a stray run cannot disturb 8081/8082. */
const TEST_PORT = "8199"

const read = (name: string): string =>
	readFileSync(path.join(BIN_DIR, name), "utf8")

// ---------------------------------------------------------------- static ----

describe("beta lifecycle scripts: shape", () => {
	it("all four scripts exist and run under bash", () => {
		for (const name of LIFECYCLE_SCRIPTS) {
			expect(existsSync(path.join(BIN_DIR, name))).toBe(true)
			expect(read(name).startsWith("#!/usr/bin/env bash")).toBe(true)
		}
		for (const name of ["beta-start.sh", "beta-stop.sh", "beta-restart.sh"]) {
			expect(read(name)).toContain("set -euo pipefail")
		}
	})

	it("never starts, stops or restarts a PROD unit", () => {
		for (const name of LIFECYCLE_SCRIPTS) {
			const actions = read(name)
				.split("\n")
				.filter((line) =>
					/systemctl\s+(start|stop|restart|enable|disable)/.test(line),
				)
			for (const line of actions) {
				// The prod units and the prod port must not appear on any line that
				// changes state. Beta units come from variables, never literals.
				expect(line).not.toMatch(/vpn-control\.service/)
				expect(line).not.toMatch(/vpn-node-agent\.service/)
				expect(line).not.toMatch(/wg0/)
				expect(line).not.toMatch(/8081/)
			}
		}
	})

	it("treats the listening port as the proof that beta stopped", () => {
		const stop = read("beta-stop.sh")
		expect(stop).toContain('port_open "$BETA_PORT"')
		expect(stop).toContain('clear_beta_port "$BETA_PORT"')
		expect(stop).toContain('die "beta still answers on :${BETA_PORT}')
		// The old behaviour: a missing unit ended the stop early and exited 0.
		expect(stop).not.toContain("is not installed, skipping")
	})

	it("keeps looking when systemd does not know the unit name", () => {
		const lib = read("beta-lib.sh")
		// Four independent ways to find a unit, then a pattern search.
		expect(lib).toContain("systemctl cat")
		expect(lib).toContain("list-unit-files")
		expect(lib).toContain("list-units --all")
		expect(lib).toContain("list_beta_units")
		expect(lib).toContain("resolve_unit")
		// A unit systemd has never heard of must not end the stop.
		expect(lib).toContain("the port check below is authoritative")
	})

	it("refuses to touch anything that is not beta", () => {
		const lib = read("beta-lib.sh")
		expect(lib).toContain("assert_beta_unit")
		expect(lib).toContain("assert_beta_interface")
		expect(lib).toContain("pid_is_prod")
		expect(lib).toContain("refusing to touch")
		expect(lib).toContain("BETA owns wg1 only")
		expect(lib).toContain("looks like PROD")
	})

	it("restart delegates to the verified stop and start", () => {
		const restart = read("beta-restart.sh")
		expect(restart).toContain('"$HERE/beta-stop.sh"')
		expect(restart).toContain('"$HERE/beta-start.sh"')
		// No second, subtly different implementation of the stop.
		expect(restart).not.toMatch(/systemctl\s+(stop|start)/)
	})

	it("start refuses to run without a beta release and waits for the port", () => {
		const start = read("beta-start.sh")
		expect(start).toContain("no beta release is active")
		expect(start).toContain('wait_port_open "$BETA_PORT"')
		// Beta is opt-in: nothing here may enable a unit at boot.
		expect(start).not.toContain("systemctl enable")
	})
})

// ----------------------------------------------------------- behavioural ----

type Harness = {
	dir: string
	state: string
	env: NodeJS.ProcessEnv
	run: (script: string) => { status: number; output: string }
	holdPort: (ignoreTerm?: boolean) => void
	systemctlLog: () => string
}

const children: ChildProcess[] = []

afterEach(() => {
	while (children.length > 0) {
		const child = children.pop()
		try {
			if (child?.pid) process.kill(child.pid, "SIGKILL")
		} catch {
			// already gone
		}
	}
})

function stub(dir: string, name: string, body: string): void {
	const file = path.join(dir, name)
	writeFileSync(file, body, { mode: 0o755 })
}

function harness(options: {
	knownUnits?: string[]
	activeUnits?: string[]
	/** Stopping a unit also releases the port, as it would on the real host. */
	stopClosesPort?: boolean
	/** The port never closes, whatever we do. */
	forceOpen?: boolean
}): Harness {
	const dir = mkdtempSync(path.join(tmpdir(), "glukvpn-beta-"))
	const state = path.join(dir, "state")
	const stubs = path.join(dir, "stubs")
	mkdirSync(state)
	mkdirSync(stubs)

	writeFileSync(
		path.join(state, "known_units"),
		`${(options.knownUnits ?? []).join("\n")}\n`,
	)
	writeFileSync(
		path.join(state, "active_units"),
		`${(options.activeUnits ?? []).join("\n")}\n`,
	)
	if (options.stopClosesPort) {
		writeFileSync(path.join(state, "stop_closes_port"), "1")
	}
	if (options.forceOpen) writeFileSync(path.join(state, "force_open"), "1")

	// A systemd that only knows what the test told it.
	stub(
		stubs,
		"systemctl",
		`#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$STATE/systemctl.log"
cmd="\${1:-}"; shift || true
args=()
for a in "$@"; do
  case "$a" in
    --*) ;;
    *) args+=("$a") ;;
  esac
done
known="$STATE/known_units"
active="$STATE/active_units"
touch "$known" "$active"
case "$cmd" in
  cat)
    for u in "\${args[@]}"; do grep -qx -- "$u" "$known" || exit 1; done
    exit 0 ;;
  list-unit-files|list-units)
    pattern="\${args[0]:-*}"
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      case "$u" in
        $pattern) printf '%s loaded active running\\n' "$u" ;;
      esac
    done < "$known"
    exit 0 ;;
  is-active)
    u="\${args[0]:-}"
    grep -qx -- "$u" "$active" && exit 0
    exit 3 ;;
  stop)
    u="\${args[0]:-}"
    grep -vx -- "$u" "$active" > "$active.tmp" || true
    mv "$active.tmp" "$active"
    if [ -f "$STATE/stop_closes_port" ] && [ -f "$STATE/port_pid" ]; then
      kill -KILL "$(cat "$STATE/port_pid")" 2>/dev/null || true
      rm -f "$STATE/port_pid"
    fi
    exit 0 ;;
  start)
    printf '%s\\n' "\${args[0]:-}" >> "$active"
    exit 0 ;;
  *) exit 0 ;;
esac
`,
	)

	// "Something is listening" == the child process we started is still alive.
	stub(
		stubs,
		"ss",
		`#!/usr/bin/env bash
port="\${BETA_PORT:-8082}"
if [ -f "$STATE/force_open" ]; then
  printf 'LISTEN 0 511 127.0.0.1:%s 0.0.0.0:* users:(("node",pid=%s,fd=20))\\n' "$port" 4194303
  exit 0
fi
f="$STATE/port_pid"
[ -f "$f" ] || exit 0
pid="$(cat "$f")"
[ -n "$pid" ] || exit 0
if kill -0 "$pid" 2>/dev/null; then
  printf 'LISTEN 0 511 127.0.0.1:%s 0.0.0.0:* users:(("node",pid=%s,fd=20))\\n' "$port" "$pid"
fi
exit 0
`,
	)

	// No wg1 in a sandbox, and nothing may be created.
	stub(stubs, "ip", "#!/usr/bin/env bash\nexit 1\n")
	stub(stubs, "wg-quick", "#!/usr/bin/env bash\nexit 0\n")
	stub(stubs, "journalctl", "#!/usr/bin/env bash\nexit 0\n")
	// Offline on purpose: the port stubs are the only source of truth.
	stub(stubs, "curl", "#!/usr/bin/env bash\nexit 1\n")

	const env: NodeJS.ProcessEnv = {
		...process.env,
		PATH: `${stubs}${path.delimiter}${process.env.PATH ?? ""}`,
		STATE: state,
		BETA_PORT: TEST_PORT,
		BETA_WG_IF: "wg1",
		BETA_ROOT: path.join(dir, "beta-root"),
		BETA_ENV_FILE: path.join(dir, "beta.env"),
		BETA_WG_CONF: path.join(dir, "wg1.conf"),
	}

	return {
		dir,
		state,
		env,
		run: (script: string) => {
			const result = spawnSync("bash", [path.join(BIN_DIR, script)], {
				env,
				encoding: "utf8",
				timeout: 90_000,
			})
			return {
				status: result.status ?? -1,
				output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
			}
		},
		holdPort: (ignoreTerm = false) => {
			const child = ignoreTerm
				? spawn("bash", ["-c", "trap '' TERM; sleep 45"], { stdio: "ignore" })
				: spawn("sleep", ["45"], { stdio: "ignore" })
			children.push(child)
			writeFileSync(path.join(state, "port_pid"), String(child.pid))
		},
		systemctlLog: () => {
			try {
				return readFileSync(path.join(state, "systemctl.log"), "utf8")
			} catch {
				return ""
			}
		},
	}
}

const canRunShell = process.platform !== "win32" && existsSync("/bin/bash")
const describeShell = canRunShell ? describe : describe.skip

describeShell("beta-stop.sh: behaviour", () => {
	it(
		"closes the port even when systemd knows no beta unit (the reported bug)",
		() => {
			// Exactly the reported situation: systemd reports nothing, yet the port
			// is still being served.
			const h = harness({ knownUnits: [], activeUnits: [] })
			h.holdPort()

			const { status, output } = h.run("beta-stop.sh")

			expect(output).toContain("no matching systemd unit found")
			expect(output).toContain(`still holds :${TEST_PORT}`)
			expect(output).toContain("sending TERM")
			expect(output).toContain(`tcp/${TEST_PORT} is closed`)
			expect(output).toContain("=== BETA STOPPED ===")
			expect(output).not.toContain("FATAL")
			expect(status).toBe(0)
		},
		90_000,
	)

	it(
		"escalates to KILL when the listener ignores TERM",
		() => {
			const h = harness({ knownUnits: [], activeUnits: [] })
			h.holdPort(true)

			const { status, output } = h.run("beta-stop.sh")

			expect(output).toContain("sending TERM")
			expect(output).toContain("ignored TERM, sending KILL")
			expect(output).toContain(`tcp/${TEST_PORT} is closed`)
			expect(status).toBe(0)
		},
		90_000,
	)

	it(
		"fails loudly when the port refuses to close",
		() => {
			const h = harness({ forceOpen: true })

			const { status, output } = h.run("beta-stop.sh")

			expect(output).toContain(
				`FATAL: beta still answers on :${TEST_PORT} - the stop did not take effect`,
			)
			expect(status).toBe(1)
		},
		90_000,
	)

	it(
		"finds and stops a beta unit that was renamed",
		() => {
			// Neither of the expected names exists; the unit is discovered by the
			// '*beta*' pattern instead of being reported as "not installed".
			const h = harness({
				knownUnits: ["glukvpn-api-beta.service"],
				activeUnits: ["glukvpn-api-beta.service"],
				stopClosesPort: true,
			})
			h.holdPort()

			const { status, output } = h.run("beta-stop.sh")

			expect(output).toContain("stopping glukvpn-api-beta.service")
			expect(h.systemctlLog()).toContain("stop -- glukvpn-api-beta.service")
			expect(output).toContain(`tcp/${TEST_PORT} is closed`)
			expect(status).toBe(0)
		},
		90_000,
	)

	it(
		"never asks systemd to touch a prod unit",
		() => {
			const h = harness({
				knownUnits: [
					"vpn-control-beta.service",
					"vpn-node-agent-beta.service",
					// Prod is installed on the same host and must be ignored.
					"vpn-control.service",
					"vpn-node-agent.service",
				],
				activeUnits: [
					"vpn-control-beta.service",
					"vpn-node-agent-beta.service",
					"vpn-control.service",
					"vpn-node-agent.service",
				],
				stopClosesPort: true,
			})
			h.holdPort()

			const { status } = h.run("beta-stop.sh")
			const log = h.systemctlLog()

			expect(status).toBe(0)
			expect(log).toContain("stop -- vpn-node-agent-beta.service")
			expect(log).toContain("stop -- vpn-control-beta.service")
			// The prod units appear nowhere in a state-changing call.
			for (const line of log.split("\n")) {
				if (!/^(stop|start|restart|enable|disable)\b/.test(line)) continue
				expect(line).not.toMatch(/(^|\s)vpn-control\.service$/)
				expect(line).not.toMatch(/(^|\s)vpn-node-agent\.service$/)
			}
		},
		90_000,
	)
})

describeShell("beta lifecycle guards", () => {
	const probe = (lines: string): { status: number; output: string } => {
		const dir = mkdtempSync(path.join(tmpdir(), "glukvpn-guard-"))
		const file = path.join(dir, "probe.sh")
		writeFileSync(
			file,
			`#!/usr/bin/env bash\nset -euo pipefail\n. ${JSON.stringify(
				path.join(BIN_DIR, "beta-lib.sh"),
			)}\n${lines}\n`,
			{ mode: 0o755 },
		)
		const result = spawnSync("bash", [file], {
			encoding: "utf8",
			timeout: 30_000,
		})
		return {
			status: result.status ?? -1,
			output: `${result.stdout ?? ""}${result.stderr ?? ""}`,
		}
	}

	it("accepts beta units", () => {
		const ok = probe(
			'assert_beta_unit "vpn-control-beta.service"\n' +
				'assert_beta_unit "vpn-node-agent-beta.service"\n' +
				'assert_beta_unit "wg-quick@wg1.service"\n' +
				'echo "guards-ok"',
		)
		expect(ok.output).toContain("guards-ok")
		expect(ok.status).toBe(0)
	})

	it("refuses prod units and wg0", () => {
		const control = probe('assert_beta_unit "vpn-control.service"')
		expect(control.output).toContain("refusing to touch")
		expect(control.status).toBe(1)

		const agent = probe('assert_beta_unit "vpn-node-agent.service"')
		expect(agent.status).toBe(1)

		const wg = probe('assert_beta_unit "wg-quick@wg0.service"')
		expect(wg.status).toBe(1)

		const iface = probe('BETA_WG_IF="wg0"\nassert_beta_interface')
		expect(iface.output).toContain("BETA owns wg1 only")
		expect(iface.status).toBe(1)
	})
})

describeShell("beta-restart.sh: behaviour", () => {
	it(
		"does not start beta when the stop could not close the port",
		() => {
			const h = harness({ forceOpen: true })

			const { status, output } = h.run("beta-restart.sh")

			expect(output).toContain("=== RESTART BETA ===")
			expect(output).toContain("beta still answers")
			expect(output).not.toContain("=== START BETA ===")
			expect(status).not.toBe(0)
		},
		90_000,
	)
})
