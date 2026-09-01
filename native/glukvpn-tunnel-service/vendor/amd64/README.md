# Vendored tunnel binaries (x64)

Two DLLs must be placed in this folder before building. They are **not**
committed to the repository because they are large signed binaries with their
own release cadence, and shipping stale copies of a network driver is a bad
idea.

| File | Where it comes from | What it does |
| --- | --- | --- |
| `tunnel.dll` | wireguard-windows, `embeddable-dll-service`, built against the **wintun** backend | Exports `WireGuardTunnelService(LPCWSTR confFile)`. Runs the whole tunnel. |
| `wintun.dll` | <https://www.wintun.net/> (official, Microsoft-WHQL signed) | The TUN adapter driver. Creates the virtual network interface. |

## Why Wintun and not WireGuard-NT

Round 6 replaced WireGuard-NT with Wintun, and this is the whole reason the
desktop tunnel works at all on a modern machine.

WireGuard-NT is a kernel driver **without** a Microsoft WHQL signature. On
Windows 10/11 with Core Isolation / Memory Integrity / WDAC enabled — which is
the default on a lot of hardware — the kernel refuses to load it, and
`WireGuardCreateAdapter` fails with `ERROR_ACCESS_DENIED (5)`. The service could
only report `driver_unavailable`; no client-side setting could fix it.

`wintun.dll` is WHQL-signed, so it loads under those policies. Every shipping
consumer VPN (Proton, Mullvad, and others) uses it for exactly this reason.

**The pair must match.** `tunnel.dll` speaks to one specific driver backend, so
it has to be built against Wintun. A `tunnel.dll` built for WireGuard-NT will
not work next to `wintun.dll`, and the failure looks like a worker that starts
and dies in under a second.

## How to fetch them

`desktop\packaging\build-all.ps1` does all of this automatically. Manually:

1. **`wintun.dll`** — download
   <https://www.wintun.net/builds/wintun-0.14.1.zip> and take
   `wintun/bin/amd64/wintun.dll`.
2. **`tunnel.dll`** — build it from source with the wintun backend (Go 1.22+):

   ```
   go build -buildmode=c-shared -o tunnel.dll golang.zx2c4.com/wireguard/windows/embeddable-dll-service
   ```

Drop both into this directory:

```
native/glukvpn-tunnel-service/vendor/amd64/
  tunnel.dll
  wintun.dll
```

CMake copies them next to `GlukVpnTunnelService.exe` automatically. If they are
missing you still get a successful build, but the service will answer every `up`
request with `driver_unavailable`.

## Why they are loaded dynamically

`wireguard_nt.cpp` and `tunnel.cpp` resolve everything with
`LoadLibraryEx(..., LOAD_WITH_ALTERED_SEARCH_PATH)` against an absolute path in
the service directory. That means:

- the service starts and reports a clean error when the DLLs are absent,
  instead of failing to load at process start;
- the DLL search path cannot be hijacked by dropping a rogue `wintun.dll`
  into the working directory.

Live statistics no longer come from a driver API. `wireguard_nt.cpp` talks to
the standard WireGuard UAPI named pipe (`get=1`) and parses `rx_bytes`,
`tx_bytes` and `last_handshake_time_sec` from the reply.

## Licensing

Both components are MIT licensed by Jason A. Donenfeld / WireGuard LLC. Keep
their license text in the installer's third-party notices. "WireGuard" and
"Wintun" are registered trademarks — do not imply endorsement.

## Do not check these in

The repository `.gitignore` should keep `*.dll` out of this folder. If you need
reproducible builds, pin the upstream version in
`docs/desktop/BUILD-WINDOWS.md` and verify the SHA-256 in CI instead of
committing the binaries.
