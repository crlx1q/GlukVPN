# GlukVPN Tunnel Service

The privileged half of GlukVPN for Windows. A small C++20 Windows service that
owns everything requiring administrator rights, so the Flutter UI can run
unelevated and the user sees exactly **one** UAC prompt — during installation.

```
glukvpn.exe  (Flutter, user)          GlukVpnTunnelService.exe (LocalSystem)
      |                                          |
      |  \\.\pipe\GlukVPN.tunnel  (JSON lines)   |
      |----------------------------------------->|  tunnel.dll  -> WireGuard adapter
      |<-----------------------------------------|  wireguard.dll -> handshake, bytes
                                                 |  WFP -> kill switch, per-app rules
                                                 |  iphlpapi -> bypass routes
```

## Source layout

| File | Responsibility |
| --- | --- |
| `main.cpp` | Command-line verbs, `/SUBSYSTEM:WINDOWS` entry point. |
| `service.{h,cpp}` | SCM registration, start/stop, failure actions. |
| `pipe_server.{h,cpp}` | Named pipe, DACL, JSON dispatch, client verification. |
| `tunnel.{h,cpp}` | Tunnel lifecycle, config preparation, state machine. |
| `wireguard_nt.{h,cpp}` | Dynamic binding to `wireguard.dll` for live stats. |
| `wfp.{h,cpp}` | Kill switch and per-application filters. |
| `split_tunnel.{h,cpp}` | Split-tunnelling modes, bypass routes. |
| `appdata.{h,cpp}` | `%PROGRAMDATA%` paths, ACLs, DPAPI, secret shredding. |
| `json.{h,cpp}` | Dependency-free bounded JSON reader/writer. |
| `log.{h,cpp}` | Rotating log with automatic key redaction. |

## Build

```powershell
cmake -S native\glukvpn-tunnel-service -B native\glukvpn-tunnel-service\build `
      -G "Visual Studio 17 2022" -A x64
cmake --build native\glukvpn-tunnel-service\build --config Release
```

Output: `build\Release\GlukVpnTunnelService.exe`.

Place `tunnel.dll` and `wireguard.dll` in `vendor/amd64/` first — see the README
there. CMake copies them next to the executable.

## Run it by hand

```powershell
# Register and start (elevated PowerShell)
.\GlukVpnTunnelService.exe --install

# Foreground debugging, accepts any client
.\GlukVpnTunnelService.exe --console --allow-any-client

# Remove
.\GlukVpnTunnelService.exe --uninstall
```

Logs: `%PROGRAMDATA%\GlukVPN\logs\service.log` (rotates at 2 MiB; private and
preshared keys are redacted before anything is written).

## Protocol

One JSON object per line, UTF-8, newline terminated. Every request carries
`"v": 1`; a mismatch is answered with `protocol_mismatch`.

| Op | Request fields | Reply |
| --- | --- | --- |
| `hello` | — | `serviceVersion`, `protocolVersion`, `driver`, `driverReady`, `splitEngine`, `perAppRedirect`, plus status |
| `up` | `conf`, `sessionId`, `adapter?`, `killSwitch?`, `dns?`, `mtu?`, `splitMode?`, `splitApps?`, `bypassRoutes?`, `endpointIps?` | status |
| `down` | — | status |
| `status` | — | status |
| `set-split` | `mode`, `apps`, `bypassRoutes?` | status |

Status fields: `state` (`down` \| `starting` \| `connected` \| `lost` \| `error`),
`sessionId`, `adapter`, `luid`, `vpnIp`, `rxBytes`, `txBytes`,
`lastHandshakeUnix`, `since`, `killSwitch`, `splitEngine`, and on failure
`errorCode` / `errorMessage`.

Error codes: `bad_request`, `protocol_mismatch`, `driver_unavailable`,
`tunnel_error`, `tunnel_lost`, `handshake_stale`, `reconnect_required`,
`killswitch_unavailable`, `killswitch_failed`, `split_unavailable`,
`split_failed`, `client_rejected`, `internal_error`.

## Security notes

- **Pipe DACL** — `D:P(D;;GA;;;AN)(D;;GA;;;NU)(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)`.
  Anonymous and network logons are denied; `PIPE_REJECT_REMOTE_CLIENTS` blocks
  access over SMB.
- **Client verification** — the connecting process image path must live inside
  the GlukVPN install directory. Once the binaries are Authenticode signed this
  should become a `WinVerifyTrust` publisher check; see
  `docs/desktop/RELEASE-CHECKLIST.md`.
- **WFP session is dynamic** — every filter disappears when this process exits,
  so `taskkill /F` can never leave the machine without internet.
- **Key material** — the plaintext `.conf` lives only in
  `%PROGRAMDATA%\GlukVPN\run` (SYSTEM + Administrators only) and is overwritten
  with zeros before deletion. A DPAPI machine-scope copy allows a service
  restart to resume without the UI.
- **Quoted service binary path** — avoids the classic unquoted-path escalation.
