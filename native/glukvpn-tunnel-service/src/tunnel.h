// Tunnel lifecycle: bring a WireGuard interface up, watch it, tear it down.
//
// Implementation strategy
// -----------------------
// The tunnel itself is run by tunnel.dll from wireguard-windows, which exports
//
//     BOOL WireGuardTunnelService(LPCWSTR confFile)
//
// That call blocks for the entire lifetime of the tunnel, so it runs on a
// dedicated worker thread. Stopping is done by signalling the well-known
// event  Global\WireGuard-Stop-<adapter>, exactly like the official client.
//
// This is the same code path the official WireGuard for Windows client uses,
// which is why the resulting adapter behaves identically to it — including
// showing up in Network Connections and ipconfig.

#pragma once

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "split_tunnel.h"

namespace gluk {

enum class TunnelState {
    Down,
    Starting,
    Connected,
    Lost,
    Error,
};

const char* TunnelStateName(TunnelState state);

// Everything the UI sends with "up".
struct UpRequest {
    std::string wgConf;      // full WireGuard configuration text
    std::string sessionId;   // control-plane session, echoed back in status
    std::wstring adapter = L"GlukVPN";
    bool killSwitch = false;
    std::vector<std::string> dns;
    int mtu = 0;
    SplitMode splitMode = SplitMode::AllApps;
    std::vector<std::string> splitApps;
    std::vector<std::string> bypassRoutes;
    std::vector<std::string> endpointIps; // never blocked by the kill switch
};

struct TunnelStatus {
    TunnelState state = TunnelState::Down;
    std::string sessionId;
    std::string adapter;
    uint64_t luid = 0;
    std::string vpnIp;
    uint64_t rxBytes = 0;
    uint64_t txBytes = 0;
    int64_t lastHandshakeUnix = 0;
    int64_t sinceUnix = 0;
    bool killSwitchActive = false;
    std::string splitEngine;
    std::string errorCode;
    std::string errorMessage;
};

// A handshake older than this means the tunnel is no longer usable.
constexpr int64_t kHandshakeStaleSeconds = 180;

class Tunnel {
public:
    static Tunnel& Instance();

    // Brings the tunnel up. Returns false and fills status().errorCode on
    // failure. Idempotent for the same session id.
    bool Up(const UpRequest& request, std::string& errorCode,
            std::string& errorMessage);

    // Signals the stop event, waits for the worker, removes all filters and
    // shreds the configuration file. Best effort: always leaves the machine
    // with working internet even if a step fails.
    void Down();

    // Current snapshot, refreshed from the driver on every call.
    TunnelStatus Status();

    // Applies split-tunnelling changes without restarting the tunnel where
    // possible. Returns "reconnect_required" when the change crosses the
    // all-apps boundary, which is decided at adapter-creation time.
    bool SetSplit(SplitMode mode, const std::vector<std::string>& apps,
                  const std::vector<std::string>& bypassRoutes,
                  std::string& errorCode, std::string& errorMessage);

    bool DriverReady();
    std::string DriverDescription();

    // Called from the service stop handler.
    void Shutdown();

private:
    Tunnel() = default;

    void WorkerMain(std::wstring configPath);
    void RefreshFromDriver(TunnelStatus& status);
    bool LoadTunnelDll();
    std::wstring StopEventName() const;

    mutable std::mutex mutex_;
    std::thread worker_;
    std::atomic<bool> running_{false};

    HMODULE tunnelDll_ = nullptr;
    void* tunnelServiceFn_ = nullptr;

    TunnelStatus status_;
    UpRequest request_;
    std::wstring configPath_;
    std::wstring adapter_ = L"GlukVPN";
    int64_t startedUnix_ = 0;

    // Set once a handshake has been observed, so a later stale handshake is
    // reported as "lost" rather than "still starting".
    bool everHandshaked_ = false;
};

} // namespace gluk
