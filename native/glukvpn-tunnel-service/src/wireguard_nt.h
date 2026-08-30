// Thin dynamic binding to wireguard.dll (WireGuardNT).
//
// tunnel.dll brings the tunnel up and owns the data plane. This wrapper is
// only used to *read* live state — most importantly the last handshake
// timestamp, which is the single fact that proves the tunnel really works.
//
// Everything is resolved at runtime with GetProcAddress so the service still
// starts (and can report driver_unavailable cleanly) when the DLL is missing.

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

// Loads wireguard.dll from the service directory. Idempotent.
class Api {
public:
    static Api& Instance();

    bool Load();
    bool loaded() const { return loaded_; }

    // Human-readable driver version, or an empty string when unavailable.
    std::string Version();

    // Opens the adapter created by tunnel.dll and reads its configuration.
    bool ReadPeerStats(const std::wstring& adapterName, PeerStats& out);

private:
    Api() = default;

    HMODULE module_ = nullptr;
    bool loaded_ = false;
    bool attempted_ = false;

    // WireGuardNT exports we care about.
    void* openAdapter_ = nullptr;
    void* closeAdapter_ = nullptr;
    void* getConfiguration_ = nullptr;
    void* getAdapterLuid_ = nullptr;
    void* getRunningDriverVersion_ = nullptr;
};

// Convenience wrapper used by Tunnel.
bool ReadPeerStats(const std::wstring& adapterName, PeerStats& out);

} // namespace gluk::wg
