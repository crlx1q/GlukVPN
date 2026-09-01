# Data plane binaries (x64)

Two files live here. Neither is committed: one is a Microsoft-signed driver
with its own release cadence, the other is built from source in this very
repository.

| File | Where it comes from | What it does |
| --- | --- | --- |
| `glukvpn-wg.exe` | Built from `../../go/glukvpn-wg` (Go 1.22+, plain `go build`) | The whole WireGuard data plane, in userspace. |
| `wintun.dll` | <https://www.wintun.net/> (official, Microsoft-WHQL signed) | The virtual network adapter. |

## Why there is no kernel driver here

This is the fix for the bug that survived two rounds.

Round 6 replaced WireGuard-NT with Wintun and kept `tunnel.dll` from
`wireguard-windows/embeddable-dll-service`. That did not help, and the reason
is worth writing down: **`tunnel.dll` is not a WireGuard implementation.** It
is a launcher for the WireGuard-NT *kernel* driver, and it installs
`wireguard.sys` on first use. `wireguard.sys` carries no Microsoft WHQL
signature, so on any machine with Core Isolation / Memory Integrity / WDAC
enabled the kernel refuses to load it and the tunnel dies immediately:

```
Tunnel worker exited, ok=0, ran 1s
```

Shipping `wintun.dll` beside it changed nothing, because `tunnel.dll` never
asked for Wintun.

Round 7 removes the kernel driver from the picture entirely. `glukvpn-wg.exe`
is [wireguard-go](https://git.zx2c4.com/wireguard-go/): the protocol runs in
userspace and the only thing it needs from the system is a virtual adapter,
which is exactly what Wintun is - and Wintun **is** WHQL signed. Proton,
Mullvad and Tailscale all ship this same architecture on Windows.

There is no driver to install, no signing exception to request, and nothing
for WDAC to object to.

## How to produce them

`desktop\packaging\build-all.ps1` does all of this automatically. Manually:

1. **`wintun.dll`** - download
   <https://www.wintun.net/builds/wintun-0.14.1.zip> and take
   `wintun/bin/amd64/wintun.dll`.

2. **`glukvpn-wg.exe`** - build it from this repository:

   ```powershell
   cd native\glukvpn-tunnel-service\go\glukvpn-wg
   $env:CGO_ENABLED = "0"
   $env:GOOS = "windows"
   $env:GOARCH = "amd64"
   go mod tidy
   go build -ldflags="-w -s" -trimpath -o ..\..\vendor\amd64\glukvpn-wg.exe .
   ```

   `CGO_ENABLED=0` matters: it keeps the build to pure Go, so no mingw-w64 /
   gcc toolchain is needed. (The old `-buildmode=c-shared` route did need one.)

Drop both into this directory:

```
native/glukvpn-tunnel-service/vendor/amd64/
  glukvpn-wg.exe
  wintun.dll
```

CMake copies them next to `GlukVpnTunnelService.exe` automatically, and the
installer picks them up from there. If they are missing you still get a
successful build, but the service answers every `up` request with
`driver_unavailable` and the client can never connect.

## How the two halves talk

- The service writes the `.conf` and spawns
  `glukvpn-wg.exe <conf> --parent <service pid>`.
- Stopping is the standard named event `Global\WireGuard-Stop-GlukVPN`.
- Live statistics come from the standard WireGuard UAPI pipe,
  `\\.\pipe\ProtectedPrefix\Administrators\WireGuard\GlukVPN`, which
  `src/wireguard_nt.cpp` reads with a plain `get=1` transaction - the same
  protocol `wg(8)` speaks on Linux.
- `--parent` makes the worker exit if the service ever dies without calling
  `Down()`, so an orphaned adapter can never keep the default route and leave
  the machine without internet.

## Licensing

Wintun is distributed by WireGuard LLC under the GPLv2; it is redistributed
here unmodified. wireguard-go is MIT licensed. "WireGuard" and "Wintun" are
registered trademarks of Jason A. Donenfeld.
