# Vendored WireGuard binaries (x64)

Two DLLs must be placed in this folder before building. They are **not**
committed to the repository because they are large signed binaries with their
own release cadence, and shipping stale copies of a network driver is a bad
idea.

| File | Where it comes from | What it does |
| --- | --- | --- |
| `tunnel.dll` | wireguard-windows, `embeddable-dll-service` | Exports `WireGuardTunnelService(LPCWSTR confFile)`. Runs the whole tunnel. |
| `wireguard.dll` | WireGuardNT (`wireguard-nt`) | Kernel driver loader plus the API used to read handshakes and byte counters. |

## How to fetch them

1. **`tunnel.dll`** — download `wireguard-windows` from
   <https://download.wireguard.com/windows-client/> and take
   `embeddable-dll-service/amd64/tunnel.dll`.
2. **`wireguard.dll`** — download `wireguard-nt` from
   <https://download.wireguard.com/wireguard-nt/> and take `bin/amd64/wireguard.dll`.

Drop both into this directory:

```
native/glukvpn-tunnel-service/vendor/amd64/
  tunnel.dll
  wireguard.dll
```

CMake copies them next to `GlukVpnTunnelService.exe` automatically. If they are
missing you still get a successful build, but with a `message(WARNING)` and the
service will answer every `up` request with `driver_unavailable`.

## Why they are loaded dynamically

`wireguard_nt.cpp` and `tunnel.cpp` resolve everything with
`LoadLibraryEx(..., LOAD_WITH_ALTERED_SEARCH_PATH)` against an absolute path in
the service directory. That means:

- the service starts and reports a clean error when the DLLs are absent,
  instead of failing to load at process start;
- the DLL search path cannot be hijacked by dropping a rogue `wireguard.dll`
  into the working directory.

## Licensing

Both components are MIT licensed by Jason A. Donenfeld / WireGuard LLC. Keep
their license text in the installer's third-party notices. "WireGuard" is a
registered trademark — do not imply endorsement.

## Do not check these in

The repository `.gitignore` should keep `*.dll` out of this folder. If you need
reproducible builds, pin the upstream version in
`docs/desktop/BUILD-WINDOWS.md` and verify the SHA-256 in CI instead of
committing the binaries.
