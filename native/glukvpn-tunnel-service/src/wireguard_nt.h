// Live tunnel telemetry for GlukVPN.
//
// ROUND 6 - Wintun migration.
//
// This file used to be a thin binding to wireguard.dll (WireGuardNT): it
// opened the adapter and read the peer table with WireGuardGetConfiguration().
// That is exactly the path Windows refuses to serve on a machine with Device
// Guard / WDAC / "Memory integrity" enabled - WireGuardNT is not WHQL signed,
// so adapter creation comes back with ERROR_ACCESS_DENIED (5) and the worker
// dies with `ok=0, ran 0s`.
//
// Wintun *is* WHQL signed, which is why every shipping VPN client uses it.
// Wintun has no configuration API of its own, so the live counters now come
// from WireGuard's own UAPI instead: tunnel.dll publishes one named pipe per
// adapter and speaks the same `get=1` protocol as wg(8) on Linux. No driver
// handle, no privileged adapter open, nothing for WDAC to object to.
//
// The namespace and the ReadPeerStats() signature are unchanged on purpose -
// Tunnel does not care where the numbers come from.

#pragma once

#include <windows.h>

#include <cstdint>
#include <string>

namespace gluk::wg {

// Live counters for the single peer of a GlukVPN tunnel.
struct PeerStats {
    bool valid = false;
    uint64_t rxBytes = 0;
    uint64_t txBytes = 0;
    // Unix seconds; 0 means "never".
    int64_t lastHandshakeUnix = 0;
    uint64_t adapterLuid = 0;
    std::string vpnIp;
};

// Wintun presence check plus the UAPI reader. Idempotent.
class Api {
public:
    static Api& Instance();

    // True when a usable wintun.dll sits next to the service binary.
    bool Load();
    bool loaded() const { return loaded_; }

    // "wintun 0.14" once the driver is actually running, "wintun" before the
    // first adapter exists. Never empty when Load() succeeded.
    std::string Version();

    // Reads rx/tx and the last handshake over the adapter's UAPI pipe. Also
    // fills adapterLuid from the interface table, which works as soon as the
    // adapter exists - the split-tunnel engine needs it before the first
    // handshake.
    bool ReadPeerStats(const std::wstring& adapterName, PeerStats& out);

private:
    Api() = default;

    HMODULE module_ = nullptr;
    bool loaded_ = false;
    bool attempted_ = false;

    void* getRunningDriverVersion_ = nullptr;
};

// Convenience wrapper used by Tunnel.
bool ReadPeerStats(const std::wstring& adapterName, PeerStats& out);

} // namespace gluk::wg
