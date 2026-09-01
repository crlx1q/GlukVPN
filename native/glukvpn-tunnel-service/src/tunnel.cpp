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

// The data plane is a separate process: glukvpn-wg.exe, a wireguard-go build
// that speaks WireGuard in userspace on top of the WHQL-signed wintun.dll.
//
// It replaces tunnel.dll from wireguard-windows, which was never a WireGuard
// implementation at all - it is a launcher for the WireGuardNT kernel driver,
// and it installs the unsigned wireguard.sys on first use. With Core Isolation
// on, the kernel refuses that driver and the worker died after one second
// (ok=0, ran 1s). Nothing in the new worker touches a kernel driver.
constexpr wchar_t kWorkerExe[] = L"glukvpn-wg.exe";
constexpr wchar_t kWintunDll[] = L"wintun.dll";

bool FileExists(const std::wstring& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
           !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

// Last few hundred bytes of the worker log, flattened to one line. Without
// this a failure reaches the UI as "the tunnel stopped"; with it the user gets
// the actual sentence, e.g. "cannot resolve the server address".
std::string ReadTail(const std::wstring& path, DWORD maxBytes) {
    HANDLE file = CreateFileW(
        path.c_str(), GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return {};

    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size)) {
        CloseHandle(file);
        return {};
    }

    DWORD want = maxBytes;
    if (size.QuadPart < static_cast<LONGLONG>(want)) {
        want = static_cast<DWORD>(size.QuadPart);
    }

    LARGE_INTEGER offset{};
    offset.QuadPart = size.QuadPart - static_cast<LONGLONG>(want);
    SetFilePointerEx(file, offset, nullptr, FILE_BEGIN);

    std::string buffer(static_cast<size_t>(want), '\0');
    DWORD read = 0;
    if (want == 0 || !ReadFile(file, buffer.data(), want, &read, nullptr)) {
        read = 0;
    }
    CloseHandle(file);
    buffer.resize(read);

    for (char& c : buffer) {
        if (c == '\r' || c == '\n' || c == '\t') c = ' ';
    }
    const size_t begin = buffer.find_first_not_of(' ');
    if (begin == std::string::npos) return {};
    const size_t end = buffer.find_last_not_of(' ');
    return buffer.substr(begin, end - begin + 1);
}

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

bool Tunnel::ResolveWorkerPaths(std::wstring& exePath,
                                std::wstring& wintunPath) const {
    const std::wstring dir = AppData::ExecutableDir();
    exePath = dir + L"\\" + kWorkerExe;
    wintunPath = dir + L"\\" + kWintunDll;
    return FileExists(exePath) && FileExists(wintunPath);
}

std::wstring Tunnel::StopEventName() const {
    // Same convention as the official client, so `wg-quick`-style tooling and
    // our own service agree on how to stop a tunnel.
    return L"Global\\WireGuard-Stop-" + adapter_;
}

bool Tunnel::DriverReady() {
    // ROUND 7: the pair is glukvpn-wg.exe + wintun.dll, and there is no kernel
    // driver in the picture at all. Both files must sit next to the service.
    std::wstring exePath;
    std::wstring wintunPath;
    if (!ResolveWorkerPaths(exePath, wintunPath)) {
        Log::Error(
            "glukvpn-wg.exe or wintun.dll is missing next to the service");
        return false;
    }

    // Loading wintun here is only for the version string and to catch a
    // truncated or wrong-architecture download early. It is not required for
    // the tunnel: the worker process loads its own copy.
    if (!wg::Api::Instance().Load()) {
        Log::Warn("wintun.dll could not be loaded by the service; the worker "
                  "will try on its own");
    }
    return true;
}

std::string Tunnel::DriverDescription() {
    const std::string version = wg::Api::Instance().Version();
    return version.empty() ? std::string("wintun (userspace)")
                           : version + " (userspace)";
}

void Tunnel::WorkerMain(std::wstring configPath) {
    std::wstring exePath;
    std::wstring wintunPath;
    const bool haveBinaries = ResolveWorkerPaths(exePath, wintunPath);

    const std::wstring logPath = AppData::RunDir() + L"\\tunnel-worker.log";
    const int64_t startedAt = NowUnix();

    bool ok = false;
    DWORD exitCode = 0;
    std::string detail;

    if (!haveBinaries) {
        detail = "glukvpn-wg.exe or wintun.dll is missing next to the service";
        Log::Error("Tunnel worker cannot start: " + detail);
    } else {
        Log::Info("Tunnel worker starting (" + DriverDescription() + ")");

        // The worker inherits exactly one handle: the log file. Its stdout and
        // stderr go straight into it, which cannot deadlock the way an unread
        // pipe can when the child is chatty.
        SECURITY_ATTRIBUTES sa{};
        sa.nLength = sizeof(sa);
        sa.bInheritHandle = TRUE;

        HANDLE logFile = CreateFileW(
            logPath.c_str(), FILE_APPEND_DATA,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, &sa,
            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);

        STARTUPINFOW si{};
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;
        if (logFile != INVALID_HANDLE_VALUE) {
            si.dwFlags |= STARTF_USESTDHANDLES;
            si.hStdInput = nullptr;
            si.hStdOutput = logFile;
            si.hStdError = logFile;
        }

        // --parent lets the worker tear the adapter down if this service ever
        // dies without calling Down(). An orphaned tunnel owning the default
        // route is exactly how a machine ends up with no internet at all.
        std::wstring command = L"\"" + exePath + L"\" \"" + configPath +
                               L"\" --parent " +
                               std::to_wstring(GetCurrentProcessId());
        const std::wstring workingDir = AppData::ExecutableDir();

        PROCESS_INFORMATION pi{};
        const BOOL spawned = CreateProcessW(
            exePath.c_str(), command.data(), nullptr, nullptr,
            logFile != INVALID_HANDLE_VALUE ? TRUE : FALSE, CREATE_NO_WINDOW,
            nullptr, workingDir.c_str(), &si, &pi);

        if (!spawned) {
            const DWORD error = GetLastError();
            Log::LastError("CreateProcess(glukvpn-wg.exe) failed", error);
            detail = "the tunnel worker could not be started (Windows error " +
                     std::to_string(error) + ")";
        } else {
            CloseHandle(pi.hThread);

            // Wait, but never for ever. If a stop was asked for and the worker
            // ignores it, the adapter is taken down by force instead of being
            // left behind holding the default route.
            int graceTicks = 0;
            for (;;) {
                const DWORD waited = WaitForSingleObject(pi.hProcess, 500);
                if (waited != WAIT_TIMEOUT) break;
                if (!stopRequested_.load()) continue;
                if (++graceTicks < 16) continue;
                Log::Warn("Tunnel worker ignored the stop event, terminating");
                TerminateProcess(pi.hProcess, 1);
                WaitForSingleObject(pi.hProcess, 3000);
                break;
            }

            if (!GetExitCodeProcess(pi.hProcess, &exitCode)) exitCode = 1;
            CloseHandle(pi.hProcess);
            ok = exitCode == 0;
        }

        if (logFile != INVALID_HANDLE_VALUE) CloseHandle(logFile);
    }

    const int64_t ranFor = NowUnix() - startedAt;
    Log::Info(std::string("Tunnel worker exited, ok=") + (ok ? "1" : "0") +
              ", code=" + std::to_string(exitCode) + ", ran " +
              std::to_string(ranFor) + "s");

    if (!ok && detail.empty()) detail = ReadTail(logPath, 512);
    if (!ok && !detail.empty()) Log::Error("Tunnel worker: " + detail);

    // No worker means no tunnel, and no tunnel must never mean "no internet".
    // The locks are dropped here and not only in Down(), because a tunnel that
    // dies on its own never reaches Down() - which is exactly how a failed
    // connect used to leave the whole machine firewalled off until the service
    // was restarted.
    ReleaseNetworkLocks("worker exited");

    std::lock_guard<std::mutex> lock(mutex_);
    running_ = false;
    if (status_.state != TunnelState::Down) {
        if (!ok) {
            status_.state = TunnelState::Error;
            if (ranFor <= 5) {
                // The worker never got as far as a working adapter. The
                // message now carries the worker's own last line, which is the
                // difference between "it broke" and "wintun.dll is missing".
                status_.errorCode = "tunnel_start_failed";
                status_.errorMessage =
                    detail.empty()
                        ? std::string("The tunnel could not be started.")
                        : "The tunnel could not be started: " + detail;
            } else {
                status_.errorCode = "tunnel_error";
                status_.errorMessage =
                    detail.empty()
                        ? std::string(
                              "WireGuard tunnel terminated unexpectedly")
                        : "WireGuard tunnel stopped: " + detail;
            }
        } else {
            status_.state = TunnelState::Down;
        }
    }
    status_.killSwitchActive = false;
    stopRequested_ = false;
}

void Tunnel::ReleaseNetworkLocks(const char* why) {
    // Neither call takes mutex_, so this is safe with or without the lock
    // held, and both are idempotent.
    Wfp::Instance().DisableKillSwitch();
    SplitTunnel::Instance().Clear();
    Log::Info(std::string("Network locks released (") + why + ")");
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
            "The tunnel worker (glukvpn-wg.exe) or wintun.dll is missing. "
            "Reinstall GlukVPN.";
        status_.state = TunnelState::Error;
        status_.errorCode = errorCode;
        status_.errorMessage = errorMessage;
        return false;
    }

    // A previous attempt that died on its own may have left filters behind.
    if (!running_ && status_.killSwitchActive) {
        ReleaseNetworkLocks("stale locks from a previous attempt");
        status_.killSwitchActive = false;
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
    stopRequested_ = false;
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

        // Read by the worker thread, which stops waiting politely once it is
        // set and kills the data plane if it has not exited within 8 seconds.
        stopRequested_ = true;

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
        // The worker thread returns as soon as the data plane process does,
        // and it is bounded by the grace timer. Do not hold the lock here.
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
    const bool read = wg::ReadPeerStats(adapter_, stats);
    // Wintun publishes the adapter before the first handshake, and the split
    // engine needs its LUID from that moment on, so the LUID is taken even
    // when the UAPI read itself has not succeeded yet.
    if (stats.adapterLuid) status.luid = stats.adapterLuid;
    if (!read || !stats.valid) {
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

    // Safety net. Filters may exist only while a tunnel does; every other
    // combination is a bug that takes the machine's internet with it, so it is
    // repaired here rather than merely reported.
    const bool alive = running_ && (status_.state == TunnelState::Starting ||
                                    status_.state == TunnelState::Connected ||
                                    status_.state == TunnelState::Lost);
    if (!alive && status_.killSwitchActive) {
        ReleaseNetworkLocks("status: no live tunnel");
        status_.killSwitchActive = false;
    }

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
    // Down() already stops the data plane process and drops every filter.
    // Nothing else is held open: the worker is a child process, not a DLL
    // loaded into this one.
    Down();
}

} // namespace gluk
