#include "tunnel.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <chrono>
#include <sstream>

#include "appdata.h"
#include "log.h"
#include "wfp.h"
#include "wireguard_nt.h"

namespace gluk {
namespace {

// tunnel.dll from wireguard-windows (embeddable-dll-service).
// Blocks until the tunnel stops.
using WIREGUARD_TUNNEL_SERVICE_FUNC = BOOL(WINAPI*)(LPCWSTR confFile);

int64_t NowUnix() {
    return std::chrono::duration_cast<std::chrono::seconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

// Extracts "Address = 10.9.0.10/32" so the UI can show the VPN IP without
// asking the driver for the interface table.
std::string ParseAddress(const std::string& conf) {
    std::istringstream stream(conf);
    std::string line;
    while (std::getline(stream, line)) {
        // Trim.
        size_t begin = line.find_first_not_of(" \t\r\n");
        if (begin == std::string::npos) continue;
        size_t end = line.find_last_not_of(" \t\r\n");
        line = line.substr(begin, end - begin + 1);

        if (line.size() < 8) continue;
        if (_strnicmp(line.c_str(), "Address", 7) != 0) continue;

        const size_t eq = line.find('=');
        if (eq == std::string::npos) continue;

        std::string value = line.substr(eq + 1);
        begin = value.find_first_not_of(" \t");
        if (begin == std::string::npos) continue;
        value = value.substr(begin);

        // Take only the first address and drop the prefix length.
        const size_t comma = value.find(',');
        if (comma != std::string::npos) value = value.substr(0, comma);
        const size_t slash = value.find('/');
        if (slash != std::string::npos) value = value.substr(0, slash);

        end = value.find_last_not_of(" \t\r\n");
        if (end != std::string::npos) value = value.substr(0, end + 1);
        return value;
    }
    return {};
}

// Rewrites/injects the keys we control, so the caller cannot smuggle in
// arbitrary interface directives and so Table=off is applied for split modes.
std::string PrepareConfig(const UpRequest& request) {
    std::istringstream stream(request.wgConf);
    std::string line;

    std::string interfaceSection;
    std::string rest;
    bool inInterface = false;
    bool seenInterface = false;

    const bool needsManualRoutes = request.splitMode != SplitMode::AllApps ||
                                   !request.bypassRoutes.empty();

    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();

        std::string trimmed = line;
        const size_t begin = trimmed.find_first_not_of(" \t");
        if (begin != std::string::npos) trimmed = trimmed.substr(begin);

        if (!trimmed.empty() && trimmed[0] == '[') {
            inInterface = _strnicmp(trimmed.c_str(), "[Interface]", 11) == 0;
            if (inInterface) seenInterface = true;
        }

        // Drop keys we are about to set ourselves.
        if (inInterface && !trimmed.empty() && trimmed[0] != '[') {
            if (_strnicmp(trimmed.c_str(), "DNS", 3) == 0 &&
                !request.dns.empty()) {
                continue;
            }
            if (_strnicmp(trimmed.c_str(), "MTU", 3) == 0 && request.mtu > 0) {
                continue;
            }
            if (_strnicmp(trimmed.c_str(), "Table", 5) == 0) {
                continue;
            }
        }

        if (inInterface) {
            interfaceSection += line;
            interfaceSection += "\r\n";
        } else {
            rest += line;
            rest += "\r\n";
        }
    }

    if (!seenInterface) {
        // Nothing sensible to do with a config that has no [Interface].
        return request.wgConf;
    }

    std::string extras;
    if (!request.dns.empty()) {
        extras += "DNS = ";
        for (size_t i = 0; i < request.dns.size(); ++i) {
            if (i) extras += ", ";
            extras += request.dns[i];
        }
        extras += "\r\n";
    }
    if (request.mtu > 0) {
        extras += "MTU = " + std::to_string(request.mtu) + "\r\n";
    }
    if (needsManualRoutes) {
        // Table = off stops WireGuard installing 0.0.0.0/0, letting the split
        // engine own the routing table instead.
        extras += "Table = off\r\n";
    }

    return interfaceSection + extras + "\r\n" + rest;
}

} // namespace

const char* TunnelStateName(TunnelState state) {
    switch (state) {
        case TunnelState::Down: return "down";
        case TunnelState::Starting: return "starting";
        case TunnelState::Connected: return "connected";
        case TunnelState::Lost: return "lost";
        case TunnelState::Error: return "error";
    }
    return "down";
}

Tunnel& Tunnel::Instance() {
    static Tunnel instance;
    return instance;
}

bool Tunnel::LoadTunnelDll() {
    if (tunnelServiceFn_) return true;

    const std::wstring path = AppData::ExecutableDir() + L"\\tunnel.dll";
    tunnelDll_ = LoadLibraryExW(path.c_str(), nullptr,
                                LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!tunnelDll_) {
        Log::LastError("LoadLibrary(tunnel.dll) failed", GetLastError());
        return false;
    }

    tunnelServiceFn_ = reinterpret_cast<void*>(
        GetProcAddress(tunnelDll_, "WireGuardTunnelService"));
    if (!tunnelServiceFn_) {
        Log::Error("tunnel.dll does not export WireGuardTunnelService");
        FreeLibrary(tunnelDll_);
        tunnelDll_ = nullptr;
        return false;
    }
    return true;
}

std::wstring Tunnel::StopEventName() const {
    // Same convention as the official client, so `wg-quick`-style tooling and
    // our own service agree on how to stop a tunnel.
    return L"Global\\WireGuard-Stop-" + adapter_;
}

bool Tunnel::DriverReady() {
    return wg::Api::Instance().Load() && LoadTunnelDll();
}

std::string Tunnel::DriverDescription() {
    const std::string version = wg::Api::Instance().Version();
    return version.empty() ? std::string("unavailable") : version;
}

void Tunnel::WorkerMain(std::wstring configPath) {
    const auto fn =
        reinterpret_cast<WIREGUARD_TUNNEL_SERVICE_FUNC>(tunnelServiceFn_);

    Log::Info("Tunnel worker starting");
    // Blocks for the whole lifetime of the tunnel.
    const BOOL ok = fn(configPath.c_str());
    Log::Info(std::string("Tunnel worker exited, ok=") + (ok ? "1" : "0"));

    std::lock_guard<std::mutex> lock(mutex_);
    running_ = false;
    if (status_.state != TunnelState::Down) {
        if (!ok) {
            status_.state = TunnelState::Error;
            status_.errorCode = "tunnel_error";
            status_.errorMessage = "WireGuard tunnel terminated unexpectedly";
        } else {
            status_.state = TunnelState::Down;
        }
    }
}

bool Tunnel::Up(const UpRequest& request, std::string& errorCode,
                std::string& errorMessage) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (running_ && status_.sessionId == request.sessionId &&
        !request.sessionId.empty()) {
        // Same session asked twice; treat as success rather than churning the
        // adapter, which would drop the user's connections.
        return true;
    }

    if (!DriverReady()) {
        errorCode = "driver_unavailable";
        errorMessage =
            "WireGuard driver files are missing. Reinstall GlukVPN.";
        status_.state = TunnelState::Error;
        status_.errorCode = errorCode;
        status_.errorMessage = errorMessage;
        return false;
    }

    if (!AppData::EnsureDirectories()) {
        errorCode = "internal_error";
        errorMessage = "Cannot prepare the tunnel working directory";
        return false;
    }

    adapter_ = request.adapter.empty() ? L"GlukVPN" : request.adapter;
    request_ = request;

    const std::string prepared = PrepareConfig(request);
    configPath_ = AppData::TunnelConfigPath(adapter_);

    if (!AppData::WriteConfig(configPath_, prepared)) {
        errorCode = "internal_error";
        errorMessage = "Cannot write the tunnel configuration";
        return false;
    }

    // Keep an encrypted copy so a service restart can resume without the UI.
    AppData::ProtectToFile(AppData::RunDir() + L"\\gluk.conf.dpapi", prepared);

    status_ = TunnelStatus{};
    status_.state = TunnelState::Starting;
    status_.sessionId = request.sessionId;
    status_.adapter = AppData::ToUtf8(adapter_);
    status_.vpnIp = ParseAddress(prepared);
    status_.splitEngine = SplitTunnel::Instance().EngineName();
    startedUnix_ = NowUnix();
    status_.sinceUnix = startedUnix_;
    everHandshaked_ = false;

    running_ = true;
    if (worker_.joinable()) worker_.join();
    worker_ = std::thread(&Tunnel::WorkerMain, this, configPath_);

    // The kill switch must be armed while the tunnel comes up, not after, so
    // there is no window where traffic escapes on the physical interface.
    if (request.killSwitch) {
        std::string wfpCode, wfpMessage;
        if (Wfp::Instance().EnableKillSwitch(request.endpointIps, wfpCode,
                                             wfpMessage)) {
            status_.killSwitchActive = true;
        } else {
            Log::Warn("Kill switch could not be armed: " + wfpMessage);
            status_.killSwitchActive = false;
        }
    }

    Log::Info("Tunnel up requested for adapter " + status_.adapter);
    return true;
}

void Tunnel::Down() {
    std::thread worker;
    std::wstring configPath;

    {
        std::lock_guard<std::mutex> lock(mutex_);

        // Order matters: drop the filters first so the machine is never left
        // without internet if a later step throws.
        Wfp::Instance().DisableKillSwitch();
        SplitTunnel::Instance().Clear();

        if (running_) {
            HANDLE stop = CreateEventW(nullptr, TRUE, FALSE,
                                       StopEventName().c_str());
            if (stop) {
                SetEvent(stop);
                CloseHandle(stop);
            } else {
                Log::LastError("CreateEvent(stop) failed", GetLastError());
            }
        }

        worker = std::move(worker_);
        worker_ = std::thread();
        configPath = configPath_;

        status_.state = TunnelState::Down;
        status_.killSwitchActive = false;
        status_.rxBytes = 0;
        status_.txBytes = 0;
        status_.lastHandshakeUnix = 0;
        status_.sessionId.clear();
        running_ = false;
    }

    if (worker.joinable()) {
        // tunnel.dll unwinds quickly; do not hold the lock while waiting.
        worker.join();
    }

    if (!configPath.empty()) {
        AppData::ShredFile(configPath);
    }
    AppData::ShredFile(AppData::RunDir() + L"\\gluk.conf.dpapi");

    Log::Info("Tunnel down complete");
}

void Tunnel::RefreshFromDriver(TunnelStatus& status) {
    if (status.state == TunnelState::Down) return;

    wg::PeerStats stats;
    if (!wg::ReadPeerStats(adapter_, stats) || !stats.valid) {
        // The adapter is gone while we believe we are up.
        if (status.state == TunnelState::Connected) {
            status.state = TunnelState::Lost;
            status.errorCode = "tunnel_lost";
            status.errorMessage = "The VPN adapter disappeared";
        }
        return;
    }

    status.rxBytes = stats.rxBytes;
    status.txBytes = stats.txBytes;
    status.lastHandshakeUnix = stats.lastHandshakeUnix;
    if (stats.adapterLuid) status.luid = stats.adapterLuid;

    const int64_t now = NowUnix();

    if (stats.lastHandshakeUnix > 0) {
        const int64_t age = now - stats.lastHandshakeUnix;
        if (age <= kHandshakeStaleSeconds) {
            everHandshaked_ = true;
            status.state = TunnelState::Connected;
            status.errorCode.clear();
            status.errorMessage.clear();
            return;
        }

        // Handshake exists but is stale.
        status.state = TunnelState::Lost;
        status.errorCode = "handshake_stale";
        status.errorMessage = "No handshake for over three minutes";
        return;
    }

    // No handshake yet. That is normal for the first few seconds.
    if (everHandshaked_) {
        status.state = TunnelState::Lost;
        status.errorCode = "tunnel_lost";
        status.errorMessage = "Handshake lost";
    } else {
        status.state = TunnelState::Starting;
    }
}

TunnelStatus Tunnel::Status() {
    std::lock_guard<std::mutex> lock(mutex_);
    RefreshFromDriver(status_);
    status_.splitEngine = SplitTunnel::Instance().EngineName();
    return status_;
}

bool Tunnel::SetSplit(SplitMode mode, const std::vector<std::string>& apps,
                      const std::vector<std::string>& bypassRoutes,
                      std::string& errorCode, std::string& errorMessage) {
    std::lock_guard<std::mutex> lock(mutex_);

    if (running_ && SplitTunnel::RequiresReconnect(request_.splitMode, mode)) {
        errorCode = "reconnect_required";
        errorMessage =
            "Switching between full-tunnel and split mode needs a reconnect";
        // Still remember the choice so the next Up() uses it.
        request_.splitMode = mode;
        request_.splitApps = apps;
        request_.bypassRoutes = bypassRoutes;
        return false;
    }

    request_.splitMode = mode;
    request_.splitApps = apps;
    request_.bypassRoutes = bypassRoutes;

    if (!running_) {
        // Nothing to enforce yet; the settings are applied on the next Up().
        return true;
    }

    SplitConfig config;
    config.mode = mode;
    config.apps = apps;
    config.bypassRoutes = bypassRoutes;
    config.tunnelLuid = status_.luid;

    if (!SplitTunnel::Instance().Apply(config, errorCode, errorMessage)) {
        return false;
    }

    status_.splitEngine = SplitTunnel::Instance().EngineName();
    return true;
}

void Tunnel::Shutdown() {
    Down();

    std::lock_guard<std::mutex> lock(mutex_);
    if (tunnelDll_) {
        FreeLibrary(tunnelDll_);
        tunnelDll_ = nullptr;
        tunnelServiceFn_ = nullptr;
    }
}

} // namespace gluk
