#include "tunnel.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <iphlpapi.h>

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

// ROUND 24: the data plane the service prefers. sing-box drives the same
// wintun.dll, installs its own routes through auto_route and wraps the
// traffic in TLS, so a provider that fingerprints the WireGuard header sees
// an ordinary HTTPS session. The worker above stays in the payload and is
// still used whenever the control plane hands us no gateway.
constexpr wchar_t kSingBoxExe[] = L"sing-box.exe";

bool FileExists(const std::wstring& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
           !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

// ROUND 12: sweep leftover GlukVPN adapters before a new one is created.
//
// Wintun deletes its adapter when the worker closes it cleanly, but a crash, a
// kill or a power cut leaves the network device registered. Windows will not
// reuse a friendly name that still exists, so the next start becomes
// "GlukVPN 2", then "GlukVPN 3", and eventually the "GlukVPN 11" the user is
// staring at.
//
// The leftovers are not only cosmetic. Each ghost keeps its own routes and DNS
// registration, and the resolver can still hand traffic to an interface that
// no longer forwards anything - a plausible reason the PC has no internet
// while the tunnel reports itself up.
//
// Two deliberate choices: only devices whose status is not OK are removed, so
// the adapter of a live session can never be swept away; and the sweep runs
// synchronously *before* the worker starts, because a sweep racing with
// adapter creation could delete the new device while it is still coming up.
// True when the expensive sweep below is worth paying for.
//
// ROUND 17: the round-12 sweep ran PowerShell on every connect and cost about
// eight seconds before the tunnel could start at all - 16:34:30.531 to
// 16:34:38.090 in the production service log. A clean machine has nothing to
// sweep, so the cost is now only paid when it can achieve something: either
// Windows still knows an interface by one of our names, or this is the first
// connect since the service started, which is the right moment to clear stale
// NetworkList profiles once.
bool GhostSweepWorthRunning() {
    static std::atomic<bool> sweptOnce{false};
    if (!sweptOnce.exchange(true)) return true;

    static const wchar_t* const kAliases[] = {
        L"GlukVPN", L"GlukVPN 2", L"GlukVPN 3", L"GlukVPN 4", L"GlukVPN 5"};
    for (const wchar_t* alias : kAliases) {
        NET_LUID luid{};
        if (ConvertInterfaceAliasToLuid(alias, &luid) == NO_ERROR) return true;
    }
    return false;
}

void PurgeGhostAdapters() {
    if (!GhostSweepWorthRunning()) return;

    // pnputil needs an instance id, and enumerating the Net class from C++
    // means pulling in SetupAPI for a job that runs once per connect.
    // PowerShell is the documented route and keeps the service dependency-free.
    //
    // ROUND 17 fixes two things the production log exposed.
    //
    //  1. "Ghost adapter sweep finished, exit 1". Get-PnpDevice raises a
    //     terminating error when its filter matches nothing, which is the
    //     normal case, so the script failed on every healthy machine. Errors
    //     are suppressed and the script ends in exit 0 - no outcome here is a
    //     failure worth reporting.
    //
    //  2. The adapter alias was never what the user was reading. The worker
    //     log says name="GlukVPN", yet Windows shows the network as
    //     "GlukVPN 11": that number belongs to a *NetworkList profile*, not to
    //     the adapter, and no amount of pnputil will ever touch it. Once the
    //     adapter behind a profile is gone the profile and its unmanaged
    //     signature are dead registry entries, so ours are removed by name and
    //     Windows mints a clean "GlukVPN" profile on the next connect.
    std::wstring command =
        L"powershell.exe -NoProfile -NonInteractive -Command \""
        L"$ErrorActionPreference='SilentlyContinue'; "
        L"Get-PnpDevice -Class Net -FriendlyName 'GlukVPN*' "
        L"-ErrorAction SilentlyContinue "
        L"| Where-Object { $_.Status -ne 'OK' } "
        L"| ForEach-Object { pnputil /remove-device $_.InstanceId }; "
        L"$nl='HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion"
        L"\\NetworkList'; "
        L"Get-ChildItem ($nl + '\\Profiles') -ErrorAction SilentlyContinue "
        L"| Where-Object { (Get-ItemProperty $_.PSPath "
        L"-ErrorAction SilentlyContinue).ProfileName -like 'GlukVPN*' } "
        L"| Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; "
        L"Get-ChildItem ($nl + '\\Signatures\\Unmanaged') "
        L"-ErrorAction SilentlyContinue "
        L"| Where-Object { (Get-ItemProperty $_.PSPath "
        L"-ErrorAction SilentlyContinue).Description -like 'GlukVPN*' } "
        L"| Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; "
        L"exit 0\"";

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;

    PROCESS_INFORMATION pi{};
    const BOOL spawned =
        CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi);
    if (!spawned) {
        Log::Warn("Ghost adapter sweep could not start, error " +
                  std::to_string(GetLastError()));
        return;
    }

    // Bounded on purpose: a stuck sweep must not become a tunnel that never
    // connects. Twenty seconds is far more than a handful of device removals
    // needs, and the tunnel comes up regardless of the outcome.
    if (WaitForSingleObject(pi.hProcess, 20000) == WAIT_TIMEOUT) {
        Log::Warn("Ghost adapter sweep timed out after 20s, continuing");
        TerminateProcess(pi.hProcess, 1);
    } else {
        DWORD exitCode = 0;
        GetExitCodeProcess(pi.hProcess, &exitCode);
        Log::Info("Ghost adapter sweep finished, exit " +
                  std::to_string(exitCode));
    }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
}

// A Windows service owns no console, and CTRL+BREAK - the only polite way to
// stop sing-box, which has no stop event of its own - can only be sent from
// inside one. So one console is allocated for the lifetime of the service and
// the data plane is started in it as its own process group. Without this the
// only way to stop sing-box is TerminateProcess, which risks leaving its
// routes and WFP filters behind: a dead tunnel and no internet, the one
// outcome this service must never produce.
bool EnsureConsole() {
    static std::atomic<int> state{0}; // 0 unknown, 1 ready, 2 unavailable
    const int known = state.load();
    if (known != 0) return known == 1;

    bool ready = GetConsoleWindow() != nullptr;
    if (!ready) {
        if (AllocConsole()) {
            ready = true;
        } else if (GetLastError() == ERROR_ACCESS_DENIED) {
            // A console is already attached, which is all that is needed.
            ready = true;
        } else {
            Log::Warn("No console could be allocated; sing-box will have to "
                      "be stopped by force");
        }
    }

    state.store(ready ? 1 : 2);
    return ready;
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
// arbitrary interface directives. Any Table key in the incoming config is
// dropped below and never re-added, so WireGuard always owns the routes.
std::string PrepareConfig(const UpRequest& request) {
    std::istringstream stream(request.wgConf);
    std::string line;

    std::string interfaceSection;
    std::string rest;
    bool inInterface = false;
    bool seenInterface = false;

    // Table = off used to be injected here for every split mode and for any
    // bypass route, on the assumption that the split engine would install the
    // tunnel's routes instead. It never did. ApplyBypassRoutes only adds the
    // bypass prefixes, and it adds them to the *physical* interface;
    // ApplyAppFilters returns immediately for AllApps and otherwise only adds
    // WFP filters. So with Table = off nothing installed 0.0.0.0/1 and
    // 128.0.0.0/1 on the adapter, and the result was a tunnel that finished
    // its handshake and then carried no traffic at all.
    //
    // Bypass routes never needed the tunnel routes gone: a LAN prefix such as
    // 192.168.0.0/24 on the physical interface already beats a /1 from the
    // tunnel under longest-prefix match. WireGuard therefore always installs
    // its own routes now, and no mode can silently end up with none.

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

bool Tunnel::ResolveSingBoxPath(std::wstring& exePath) const {
    std::wstring dir = AppData::ExecutableDir();
    if (!dir.empty() && dir.back() != L'\\') dir.push_back(L'\\');
    exePath = dir + kSingBoxExe;
    return FileExists(exePath);
}

std::wstring Tunnel::StopEventName() const {
    // Same convention as the official client, so `wg-quick`-style tooling and
    // our own service agree on how to stop a tunnel.
    return L"Global\\WireGuard-Stop-" + adapter_;
}

bool Tunnel::DriverReady() {
    // ROUND 24: wintun.dll plus at least one data plane. sing-box is the
    // engine the service prefers, the WireGuard worker is the fallback, and
    // neither of them needs a kernel driver.
    std::wstring exePath;
    std::wstring wintunPath;
    const bool haveWireGuard = ResolveWorkerPaths(exePath, wintunPath);

    std::wstring singBoxPath;
    const bool haveSingBox = ResolveSingBoxPath(singBoxPath);

    if (!FileExists(wintunPath) || (!haveWireGuard && !haveSingBox)) {
        Log::Error(
            "no usable data plane next to the service: wintun.dll plus "
            "sing-box.exe or glukvpn-wg.exe is required");
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
    const bool singBox = engine_.load() == Engine::SingBox;

    std::wstring exePath;
    std::wstring wintunPath;
    bool haveBinaries = ResolveWorkerPaths(exePath, wintunPath);
    if (singBox) {
        // The same wintun.dll, a different process on top of it.
        haveBinaries = ResolveSingBoxPath(exePath) && FileExists(wintunPath);
    }

    const std::wstring logPath = AppData::RunDir() + L"\\tunnel-worker.log";
    const int64_t startedAt = NowUnix();

    bool ok = false;
    DWORD exitCode = 0;
    std::string detail;

    if (!haveBinaries) {
        detail = singBox
                     ? "sing-box.exe or wintun.dll is missing next to the "
                       "service"
                     : "glukvpn-wg.exe or wintun.dll is missing next to the "
                       "service";
        Log::Error("Tunnel worker cannot start: " + detail);
    } else {
        Log::Info("Tunnel worker starting (" + DriverDescription() + ")");

        // Before the worker creates its adapter, never after - see the comment
        // on PurgeGhostAdapters. This is what stops the adapter name creeping
        // towards "GlukVPN 11".
        PurgeGhostAdapters();

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

        // --parent lets the WireGuard worker tear the adapter down if this
        // service ever dies without calling Down(). An orphaned tunnel owning
        // the default route is exactly how a machine ends up with no internet
        // at all. sing-box has no such flag, so it goes into a job object that
        // Windows tears down together with the service.
        const std::wstring quote = L"\"";
        std::wstring command = quote + exePath + quote + L" ";
        if (singBox) {
            command += L"run -c " + quote + configPath + quote;
        } else {
            command += quote + configPath + quote + L" --parent " +
                       std::to_wstring(GetCurrentProcessId());
        }
        const std::wstring workingDir = AppData::ExecutableDir();

        HANDLE job = nullptr;
        if (singBox) {
            job = CreateJobObjectW(nullptr, nullptr);
            if (job) {
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
                limits.BasicLimitInformation.LimitFlags =
                    JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                SetInformationJobObject(job, JobObjectExtendedLimitInformation,
                                        &limits, sizeof(limits));
            }
        }

        // The console has to exist before the child starts, because the child
        // inherits it. Its output still goes to the log file through the
        // standard handles set above.
        DWORD flags = CREATE_NO_WINDOW;
        if (singBox && EnsureConsole()) flags = CREATE_NEW_PROCESS_GROUP;
        if (job) flags |= CREATE_SUSPENDED;

        PROCESS_INFORMATION pi{};
        const BOOL spawned = CreateProcessW(
            exePath.c_str(), command.data(), nullptr, nullptr,
            logFile != INVALID_HANDLE_VALUE ? TRUE : FALSE, flags,
            nullptr, workingDir.c_str(), &si, &pi);

        if (!spawned) {
            const DWORD error = GetLastError();
            Log::LastError("CreateProcess(data plane) failed", error);
            detail = "the tunnel worker could not be started (Windows error " +
                     std::to_string(error) + ")";
        } else {
            if (job) {
                AssignProcessToJobObject(job, pi.hProcess);
                ResumeThread(pi.hThread);
            }
            CloseHandle(pi.hThread);

            // Wait, but never for ever. If a stop was asked for and the worker
            // ignores it, the adapter is taken down by force instead of being
            // left behind holding the default route.
            int graceTicks = 0;
            bool askedPolitely = false;
            for (;;) {
                const DWORD waited = WaitForSingleObject(pi.hProcess, 500);
                if (waited != WAIT_TIMEOUT) break;
                if (!stopRequested_.load()) continue;
                if (singBox && !askedPolitely) {
                    // sing-box removes its routes and its WFP filters on the
                    // way out, so a graceful stop is what leaves the machine
                    // with working internet after a disconnect.
                    askedPolitely = true;
                    if (!GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT,
                                                  pi.dwProcessId)) {
                        Log::Warn("sing-box could not be asked to stop, error " +
                                  std::to_string(GetLastError()));
                    }
                }
                if (++graceTicks < 16) continue;
                Log::Warn("Tunnel worker ignored the stop request, "
                          "terminating");
                TerminateProcess(pi.hProcess, 1);
                WaitForSingleObject(pi.hProcess, 3000);
                break;
            }

            if (!GetExitCodeProcess(pi.hProcess, &exitCode)) exitCode = 1;
            CloseHandle(pi.hProcess);
            // An interrupted sing-box reports a non-zero code, which is the
            // normal path through Down() rather than a failure to report.
            ok = exitCode == 0 || (singBox && stopRequested_.load());
        }

        if (job) CloseHandle(job);
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
                // ROUND 26: name the engine that actually died. This text
                // reaches the user, and "WireGuard tunnel stopped" on a
                // sing-box session sent people looking for the wrong thing.
                const std::string engineName =
                    singBox ? "sing-box" : "WireGuard";
                status_.errorCode = "tunnel_error";
                status_.errorMessage =
                    detail.empty()
                        ? engineName + " tunnel terminated unexpectedly"
                        : engineName + " tunnel stopped: " + detail;
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
    // DisableKillSwitch() deletes the permit filters together with the block
    // filters, so the next adapter has to be whitelisted again from scratch.
    permittedLuid_.store(0);
    Log::Info(std::string("Network locks released (") + why + ")");
}

void Tunnel::PermitTunnelInterface(uint64_t luid) {
    if (luid == 0 || luid == permittedLuid_.load()) return;

    // A permit filter only means anything while something is blocking, and
    // opening a WFP session for nothing would leave a provider registered on
    // machines that never use the kill switch.
    if (!Wfp::Instance().killSwitchActive()) return;

    std::string code, message;
    if (Wfp::Instance().PermitInterface(luid, code, message)) {
        permittedLuid_.store(luid);
    } else {
        // Leave permittedLuid_ at 0 so the next poll retries. If this keeps
        // failing the user has a tunnel with no traffic, and the log is the
        // only place that says why.
        Log::Warn("WFP: the tunnel adapter could not be permitted: " + message);
    }
}

// Blocks until no interface answers to `adapter`, or the timeout expires.
//
// Only ever called on the connect path, where a few hundred milliseconds are
// invisible next to the tunnel handshake itself.
static void WaitForAdapterToVanish(const std::wstring& adapter,
                                   ULONGLONG timeoutMs) {
    if (adapter.empty()) return;

    NET_LUID luid{};
    const ULONGLONG deadline = GetTickCount64() + timeoutMs;
    while (ConvertInterfaceAliasToLuid(adapter.c_str(), &luid) == NO_ERROR) {
        if (GetTickCount64() >= deadline) {
            Log::Warn("The previous VPN adapter is still present; starting the "
                      "new tunnel anyway");
            return;
        }
        Sleep(100);
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
            "The tunnel data plane (sing-box.exe or glukvpn-wg.exe) or "
            "wintun.dll is missing. Reinstall GlukVPN.";
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

    // ROUND 24: sing-box whenever the control plane handed us a gateway and
    // the binary is in the payload; the WireGuard worker otherwise. Deciding
    // it here, once per session, keeps the rest of the class free of engine
    // checks - it only has to know which file to write and how to read status.
    std::wstring singBoxPath;
    engine_.store(Engine::WireGuard);
    if (request.gateway.usable()) {
        if (ResolveSingBoxPath(singBoxPath)) {
            engine_.store(Engine::SingBox);
        } else {
            Log::Warn("A gateway was supplied but sing-box.exe is missing; "
                      "falling back to the WireGuard worker");
        }
    }

    const bool singBox = engine_.load() == Engine::SingBox;

    std::string prepared;
    if (singBox) {
        SingBoxOptions options;
        options.adapter = AppData::ToUtf8(adapter_);
        options.mtu = request.mtu;
        options.dns = request.dns;
        options.directRoutes = request.bypassRoutes;
        // ROUND 26: the kill switch is one user-facing switch with two halves
        // on this engine - the WFP block-all filters armed below and sing-box's
        // own strict_route. Both follow the same flag from the "up" request.
        options.strictRoute = request.killSwitch;
        prepared = BuildSingBoxConfig(request.gateway, options);
        configPath_ = AppData::RunDir() + L"\\singbox.json";
    } else {
        prepared = PrepareConfig(request);
        configPath_ = AppData::TunnelConfigPath(adapter_);
    }

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
    status_.engine = singBox ? "sing-box" : "wireguard";
    // In sing-box mode the interface address is ours rather than the node's,
    // so it is a constant; the address the outside world sees is measured
    // separately by the app and shown as the external IP.
    status_.vpnIp =
        singBox ? std::string(kSingBoxTunAddress) : ParseAddress(prepared);
    status_.splitEngine = SplitTunnel::Instance().EngineName();
    startedUnix_ = NowUnix();
    status_.sinceUnix = startedUnix_;
    everHandshaked_ = false;

    // ROUND 25: Disconnect immediately followed by Connect.
    //
    // Down() signals the stop event and joins the worker thread *outside* the
    // lock, so a connect that arrives right after it can start the next data
    // plane while the previous process is still tearing its adapter down. Two
    // instances then race for the same interface name and the same DNS
    // listeners, and the newcomer dies with an error the user reads as "it just
    // does not connect". Waiting for the old adapter to vanish costs nothing
    // on a normal connect and makes the fast reconnect boring.
    WaitForAdapterToVanish(adapter_, 3000);

    running_ = true;
    stopRequested_ = false;
    if (worker_.joinable()) worker_.join();
    worker_ = std::thread(&Tunnel::WorkerMain, this, configPath_);

    // The kill switch must be armed while the tunnel comes up, not after, so
    // there is no window where traffic escapes on the physical interface.
    //
    // ROUND 26: on the sing-box engine these block-all filters are one half of
    // the kill switch; the other half is strict_route in the generated config
    // (see SingBoxOptions::strictRoute), which follows the same flag. Neither
    // is armed when the user left the switch off, which is the default.
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

    Log::Info(std::string("Tunnel up requested for adapter ") +
              status_.adapter + " using " +
              (singBox ? "sing-box" : "the WireGuard worker"));
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
        permittedLuid_.store(0);

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
        // ROUND 26: the address belonged to the tunnel that is going away.
        // Left in the status it was read back by the UI and shown next to
        // "Disconnected" as if a tunnel still existed.
        status_.vpnIp.clear();
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

// sing-box publishes no UAPI socket and performs no handshake, so liveness is
// the adapter plus the process, and the counters come from the same interface
// table that Task Manager reads for the same adapter.
void Tunnel::RefreshFromInterface(TunnelStatus& status) {
    if (!running_.load()) return;

    NET_LUID luid{};
    if (ConvertInterfaceAliasToLuid(adapter_.c_str(), &luid) != NO_ERROR) {
        if (status.state == TunnelState::Connected) {
            status.state = TunnelState::Lost;
            status.errorCode = "tunnel_lost";
            status.errorMessage = "The VPN adapter disappeared";
        }
        return;
    }

    status.luid = luid.Value;
    PermitTunnelInterface(status.luid);

    MIB_IF_ROW2 row{};
    row.InterfaceLuid = luid;
    if (GetIfEntry2(&row) == NO_ERROR) {
        status.rxBytes = row.InOctets;
        status.txBytes = row.OutOctets;
    }

    // There is no handshake to report, so this field carries the moment the
    // data plane was last seen alive. The UI only uses it to decide whether a
    // tunnel has gone stale, and a dead sing-box stops refreshing it.
    everHandshaked_ = true;
    status.lastHandshakeUnix = NowUnix();
    status.state = TunnelState::Connected;
    status.errorCode.clear();
    status.errorMessage.clear();
}

void Tunnel::RefreshFromDriver(TunnelStatus& status) {
    if (status.state == TunnelState::Down) return;

    if (engine_.load() == Engine::SingBox) {
        RefreshFromInterface(status);
        return;
    }

    wg::PeerStats stats;
    const bool read = wg::ReadPeerStats(adapter_, stats);
    // Wintun publishes the adapter before the first handshake, and the split
    // engine needs its LUID from that moment on, so the LUID is taken even
    // when the UAPI read itself has not succeeded yet.
    if (stats.adapterLuid) status.luid = stats.adapterLuid;

    // The adapter exists from this moment on, so this is the earliest point
    // where the kill switch can be told to let it through. Up() cannot do it:
    // the worker process has not created the adapter yet when Up() returns,
    // so there is no LUID to permit.
    PermitTunnelInterface(status.luid);

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
