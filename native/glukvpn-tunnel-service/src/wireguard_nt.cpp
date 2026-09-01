#include "wireguard_nt.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <ifdef.h>
#include <iphlpapi.h>
#include <netioapi.h>

#include <cstdio>
#include <string>

#include "appdata.h"
#include "log.h"

namespace gluk::wg {
namespace {

using WINTUN_GET_RUNNING_DRIVER_VERSION_FUNC = DWORD(WINAPI*)(void);

// tunnel.dll publishes one UAPI pipe per adapter. wireguard-windows has used
// the "Administrators" prefix since 0.3; older embeddable builds used
// "Servers". Both are tried so a vendored DLL from either era works, and the
// unprefixed name is kept as a last resort for local test builds.
const wchar_t* const kPipePrefixes[] = {
    L"\\\\.\\pipe\\ProtectedPrefix\\Administrators\\WireGuard\\",
    L"\\\\.\\pipe\\ProtectedPrefix\\Servers\\WireGuard\\",
    L"\\\\.\\pipe\\WireGuard\\",
};

HANDLE OpenUapiPipe(const std::wstring& adapterName) {
    for (const wchar_t* prefix : kPipePrefixes) {
        const std::wstring path = std::wstring(prefix) + adapterName;

        HANDLE pipe = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                                  nullptr, OPEN_EXISTING, 0, nullptr);
        if (pipe != INVALID_HANDLE_VALUE) return pipe;

        // Another reader is mid-transaction. The service polls every couple of
        // seconds, so a short wait is always cheaper than missing a sample.
        if (GetLastError() == ERROR_PIPE_BUSY &&
            WaitNamedPipeW(path.c_str(), 200)) {
            pipe = CreateFileW(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                               nullptr, OPEN_EXISTING, 0, nullptr);
            if (pipe != INVALID_HANDLE_VALUE) return pipe;
        }
    }
    return INVALID_HANDLE_VALUE;
}

bool WriteAll(HANDLE pipe, const char* data, DWORD size) {
    DWORD offset = 0;
    while (offset < size) {
        DWORD written = 0;
        if (!WriteFile(pipe, data + offset, size - offset, &written, nullptr)) {
            return false;
        }
        if (written == 0) return false;
        offset += written;
    }
    return true;
}

// A UAPI transaction ends with a blank line after `errno=`. ERROR_BROKEN_PIPE
// is the other normal ending, because tunnel.dll closes the handle itself.
std::string ReadAll(HANDLE pipe) {
    std::string out;
    char buffer[2048];
    for (;;) {
        DWORD read = 0;
        if (!ReadFile(pipe, buffer, sizeof(buffer), &read, nullptr)) break;
        if (read == 0) break;
        out.append(buffer, read);
        if (out.size() >= 4 && out.compare(out.size() - 2, 2, "\n\n") == 0) break;
        // Never let the other side of a pipe decide how much memory we use.
        if (out.size() > (1u << 20)) break;
    }
    return out;
}

uint64_t ParseU64(const std::string& text) {
    uint64_t value = 0;
    for (const char c : text) {
        if (c < '0' || c > '9') break;
        value = value * 10 + static_cast<uint64_t>(c - '0');
    }
    return value;
}

} // namespace

Api& Api::Instance() {
    static Api instance;
    return instance;
}

bool Api::Load() {
    if (loaded_) return true;
    if (attempted_) return false;
    attempted_ = true;

    // Load strictly from the service directory. Never let the DLL search path
    // pick up an attacker-supplied wintun.dll from the working directory.
    const std::wstring path = AppData::ExecutableDir() + L"\\wintun.dll";
    module_ = LoadLibraryExW(path.c_str(), nullptr,
                             LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!module_) {
        Log::LastError("LoadLibrary(wintun.dll) failed", GetLastError());
        return false;
    }

    // A DLL that cannot create an adapter is not Wintun, whatever its name.
    if (!GetProcAddress(module_, "WintunCreateAdapter")) {
        Log::Error("wintun.dll is missing required exports");
        FreeLibrary(module_);
        module_ = nullptr;
        return false;
    }

    getRunningDriverVersion_ = reinterpret_cast<void*>(
        GetProcAddress(module_, "WintunGetRunningDriverVersion"));

    loaded_ = true;
    Log::Info("wintun.dll loaded");
    return true;
}

std::string Api::Version() {
    if (!Load()) return {};
    if (!getRunningDriverVersion_) return "wintun";

    const auto fn = reinterpret_cast<WINTUN_GET_RUNNING_DRIVER_VERSION_FUNC>(
        getRunningDriverVersion_);
    const DWORD version = fn();
    // Zero is expected before the first adapter exists: Wintun is loaded on
    // demand by tunnel.dll, not at boot. That is not an error.
    if (version == 0) return "wintun";

    char buffer[32];
    std::snprintf(buffer, sizeof(buffer), "wintun %u.%u",
                  static_cast<unsigned>((version >> 16) & 0xFFFF),
                  static_cast<unsigned>(version & 0xFFFF));
    return buffer;
}

bool Api::ReadPeerStats(const std::wstring& adapterName, PeerStats& out) {
    // The LUID comes from the interface table, so it is available as soon as
    // Wintun has created the adapter - before any handshake. The split-tunnel
    // engine needs it at that point, so it is filled even when the UAPI read
    // below fails.
    NET_LUID luid{};
    if (ConvertInterfaceAliasToLuid(adapterName.c_str(), &luid) == NO_ERROR) {
        out.adapterLuid = luid.Value;
    }

    HANDLE pipe = OpenUapiPipe(adapterName);
    if (pipe == INVALID_HANDLE_VALUE) {
        // Normal while the tunnel is down; not worth logging every poll.
        return false;
    }

    static const char kGet[] = "get=1\n\n";
    if (!WriteAll(pipe, kGet, sizeof(kGet) - 1)) {
        Log::LastError("UAPI write failed", GetLastError());
        CloseHandle(pipe);
        return false;
    }

    const std::string response = ReadAll(pipe);
    CloseHandle(pipe);
    if (response.empty()) return false;

    bool sawPeer = false;
    size_t position = 0;
    while (position < response.size()) {
        size_t lineEnd = response.find('\n', position);
        if (lineEnd == std::string::npos) lineEnd = response.size();
        std::string line = response.substr(position, lineEnd - position);
        position = lineEnd + 1;

        if (!line.empty() && line.back() == '\r') line.pop_back();
        const size_t eq = line.find('=');
        if (eq == std::string::npos) continue;

        const std::string key = line.substr(0, eq);
        const std::string value = line.substr(eq + 1);

        if (key == "public_key") {
            // The interface block reports private_key; only peers carry a
            // public one, so this is how a peer section is recognised.
            sawPeer = true;
        } else if (key == "rx_bytes") {
            out.rxBytes += ParseU64(value);
        } else if (key == "tx_bytes") {
            out.txBytes += ParseU64(value);
        } else if (key == "last_handshake_time_sec") {
            const int64_t seconds = static_cast<int64_t>(ParseU64(value));
            if (seconds > out.lastHandshakeUnix) out.lastHandshakeUnix = seconds;
        } else if (key == "errno" && value != "0") {
            Log::Error("UAPI get returned errno=" + value);
            return false;
        }
    }

    // An adapter with no peer means tunnel.dll is still configuring it. Report
    // that as "not readable yet" so the phase machine keeps waiting instead of
    // declaring a connection that cannot carry traffic.
    if (!sawPeer) return false;

    out.valid = true;
    return true;
}

bool ReadPeerStats(const std::wstring& adapterName, PeerStats& out) {
    return Api::Instance().ReadPeerStats(adapterName, out);
}

} // namespace gluk::wg
