// Tunnel lifecycle: bring a WireGuard interface up, watch it, tear it down.
//
// Implementation strategy
// -----------------------
// The tunnel is run by a separate process, glukvpn-wg.exe: a wireguard-go
// build that implements WireGuard entirely in userspace on top of the
// WHQL-signed wintun.dll. The service spawns it, watches it and stops it by
// signalling the well-known event Global\WireGuard-Stop-<adapter>, exactly
// like the official client.
//
// ROUND 7. This used to be tunnel.dll from wireguard-windows. That library is
// not a WireGuard implementation — it is a launcher for the WireGuardNT kernel
// driver, and it installs the unsigned wireguard.sys on first use. On any
// machine with Core Isolation / Memory Integrity / WDAC enabled the kernel
// refuses that driver, so the tunnel died after a second with ok=0, ran 1s.
// Wintun needs no such exception, and userspace WireGuard is what Proton,
// Mullvad and Tailscale ship on Windows for the same reason.
//
// A child process rather than a DLL is deliberate: the Go build needs no cgo
// toolchain, and a crash in the data plane cannot take the service with it.
// The adapter still shows up in Network Connections and ipconfig.
//
// ROUND 24-26. The WireGuard worker is now the *fallback*. When the control
// plane hands "up" a gateway object and sing-box.exe ships next to the
// service, the data plane is sing-box: a TUN inbound on the same wintun.dll,
// VLESS over TLS on 443 outbound. Engine selection happens once per session in
// Up(); the status reply names the engine so the UI can word itself for it.
// The kill switch is one flag with two halves on sing-box - the WFP block-all
// filters from wfp.cpp plus strict_route in the generated config - and off by
// default.

#pragma once

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "singbox.h"
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

    // ROUND 24: the sing-box outbound. When this is usable the service runs
    // sing-box over the same wintun.dll and wgConf is ignored; when it is not,
    // the WireGuard worker is used exactly as before.
    GatewayConfig gateway;
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

    // ROUND 26: "sing-box" or "wireguard", decided in Up(). Reported to the
    // UI so its status texts can stop talking about WireGuard handshakes when
    // the data plane is sing-box. Empty while no tunnel has been requested.
    std::string engine;

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

    // sing-box has no UAPI socket and no handshake, so its status comes from
    // the Windows interface table instead of the WireGuard driver.
    void RefreshFromInterface(TunnelStatus& status);

    // Whitelists the Wintun adapter in WFP the moment it appears.
    //
    // Without this the kill switch blocks the tunnel it is protecting: the
    // block-all filters match every connection, including the ones whose
    // local interface *is* the tunnel, so a full-tunnel session with the kill
    // switch armed had no internet at all. Only split_tunnel.cpp used to call
    // it, which is why the fault only ever showed in all-apps mode.
    void PermitTunnelInterface(uint64_t luid);

    // Drops the kill switch and the split routes. Takes no lock of its own,
    // so it is safe to call with or without mutex_ held, and safe to call
    // twice. "No tunnel" must always mean "working internet".
    void ReleaseNetworkLocks(const char* why);

    // Locates glukvpn-wg.exe and wintun.dll next to the service binary.
    // Returns false when either is missing, which is the one failure the user
    // can actually fix (reinstall).
    bool ResolveWorkerPaths(std::wstring& exePath,
                            std::wstring& wintunPath) const;

    // Locates sing-box.exe next to the service binary. Returns false when the
    // installer predates the engine change, which is a fallback, not a fault.
    bool ResolveSingBoxPath(std::wstring& exePath) const;

    std::wstring StopEventName() const;

    // Which data plane the current session uses. Decided once in Up(), since
    // it settles which configuration file is written, how the process is
    // started and how status is read back afterwards.
    enum class Engine { WireGuard, SingBox };
    std::atomic<Engine> engine_{Engine::WireGuard};

    mutable std::mutex mutex_;
    std::thread worker_;
    std::atomic<bool> running_{false};

    // Set by Down() before the stop event is signalled. The worker thread uses
    // it to bound its wait: a data plane that ignores the stop event is killed
    // rather than left owning the default route.
    std::atomic<bool> stopRequested_{false};

    TunnelStatus status_;
    UpRequest request_;
    std::wstring configPath_;
    std::wstring adapter_ = L"GlukVPN";
    int64_t startedUnix_ = 0;

    // Set once a handshake has been observed, so a later stale handshake is
    // reported as "lost" rather than "still starting".
    bool everHandshaked_ = false;

    // LUID already whitelisted in WFP, so the filters are installed once per
    // adapter instead of on every status poll. Atomic because the release
    // path runs on the worker thread without mutex_.
    std::atomic<uint64_t> permittedLuid_{0};
};

} // namespace gluk
