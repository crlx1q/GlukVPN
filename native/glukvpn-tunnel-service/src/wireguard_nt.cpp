#include "wireguard_nt.h"

#include <winsock2.h>
#include <ifdef.h>
#include <ws2tcpip.h>

#include <vector>

#include "appdata.h"
#include "log.h"

namespace gluk::wg {
namespace {

// ---------------------------------------------------------------------------
// WireGuardNT structures, mirrored from wireguard.h in wireguard-windows.
// ---------------------------------------------------------------------------

typedef void* WIREGUARD_ADAPTER_HANDLE;

typedef enum {
    WIREGUARD_INTERFACE_HAS_PUBLIC_KEY = 1 << 0,
    WIREGUARD_INTERFACE_HAS_PRIVATE_KEY = 1 << 1,
    WIREGUARD_INTERFACE_HAS_LISTEN_PORT = 1 << 2,
    WIREGUARD_INTERFACE_REPLACE_PEERS = 1 << 3
} WIREGUARD_INTERFACE_FLAG;

typedef enum {
    WIREGUARD_PEER_HAS_PUBLIC_KEY = 1 << 0,
    WIREGUARD_PEER_HAS_PRESHARED_KEY = 1 << 1,
    WIREGUARD_PEER_HAS_PERSISTENT_KEEPALIVE = 1 << 2,
    WIREGUARD_PEER_HAS_ENDPOINT = 1 << 3,
    WIREGUARD_PEER_REPLACE_ALLOWED_IPS = 1 << 5,
    WIREGUARD_PEER_REMOVE = 1 << 6,
    WIREGUARD_PEER_UPDATE_ONLY = 1 << 7
} WIREGUARD_PEER_FLAG;

#pragma pack(push, 8)

typedef struct {
    DWORD Flags;
    DWORD ListenPort;
    BYTE PrivateKey[32];
    BYTE PublicKey[32];
    DWORD PeersCount;
} WIREGUARD_INTERFACE;

typedef union {
    SOCKADDR Addr;
    SOCKADDR_IN Ipv4;
    SOCKADDR_IN6 Ipv6;
} WIREGUARD_ALLOWED_IP_ENDPOINT;

typedef struct {
    DWORD Flags;
    DWORD Reserved;
    BYTE PublicKey[32];
    BYTE PresharedKey[32];
    WORD PersistentKeepalive;
    WIREGUARD_ALLOWED_IP_ENDPOINT Endpoint;
    DWORD64 TxBytes;
    DWORD64 RxBytes;
    DWORD64 LastHandshake; // 100ns intervals since 1601-01-01 (UTC)
    DWORD AllowedIPsCount;
} WIREGUARD_PEER;

typedef struct {
    union {
        IN_ADDR V4;
        IN6_ADDR V6;
    } Address;
    ADDRESS_FAMILY AddressFamily;
    BYTE Cidr;
} WIREGUARD_ALLOWED_IP;

#pragma pack(pop)

using WIREGUARD_OPEN_ADAPTER_FUNC =
    WIREGUARD_ADAPTER_HANDLE(WINAPI*)(LPCWSTR Name);
using WIREGUARD_CLOSE_ADAPTER_FUNC =
    void(WINAPI*)(WIREGUARD_ADAPTER_HANDLE Adapter);
using WIREGUARD_GET_CONFIGURATION_FUNC =
    BOOL(WINAPI*)(WIREGUARD_ADAPTER_HANDLE Adapter,
                  WIREGUARD_INTERFACE* Interface, DWORD* Bytes);
using WIREGUARD_GET_ADAPTER_LUID_FUNC =
    void(WINAPI*)(WIREGUARD_ADAPTER_HANDLE Adapter, NET_LUID* Luid);
using WIREGUARD_GET_RUNNING_DRIVER_VERSION_FUNC = DWORD(WINAPI*)(void);

// FILETIME epoch (1601) to Unix epoch (1970), in 100ns ticks.
constexpr uint64_t kEpochDeltaTicks = 116444736000000000ULL;

int64_t FiletimeTicksToUnix(uint64_t ticks) {
    if (ticks <= kEpochDeltaTicks) return 0;
    return static_cast<int64_t>((ticks - kEpochDeltaTicks) / 10000000ULL);
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
    // pick up an attacker-supplied wireguard.dll from the working directory.
    const std::wstring path = AppData::ExecutableDir() + L"\\wireguard.dll";
    module_ = LoadLibraryExW(path.c_str(), nullptr,
                             LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!module_) {
        Log::LastError("LoadLibrary(wireguard.dll) failed", GetLastError());
        return false;
    }

    openAdapter_ = reinterpret_cast<void*>(
        GetProcAddress(module_, "WireGuardOpenAdapter"));
    closeAdapter_ = reinterpret_cast<void*>(
        GetProcAddress(module_, "WireGuardCloseAdapter"));
    getConfiguration_ = reinterpret_cast<void*>(
        GetProcAddress(module_, "WireGuardGetConfiguration"));
    getAdapterLuid_ = reinterpret_cast<void*>(
        GetProcAddress(module_, "WireGuardGetAdapterLUID"));
    getRunningDriverVersion_ = reinterpret_cast<void*>(
        GetProcAddress(module_, "WireGuardGetRunningDriverVersion"));

    if (!openAdapter_ || !closeAdapter_ || !getConfiguration_) {
        Log::Error("wireguard.dll is missing required exports");
        FreeLibrary(module_);
        module_ = nullptr;
        return false;
    }

    loaded_ = true;
    Log::Info("wireguard.dll loaded");
    return true;
}

std::string Api::Version() {
    if (!Load() || !getRunningDriverVersion_) return {};

    const auto fn = reinterpret_cast<WIREGUARD_GET_RUNNING_DRIVER_VERSION_FUNC>(
        getRunningDriverVersion_);
    const DWORD version = fn();
    if (version == 0) return {};

    char buffer[32];
    wsprintfA(buffer, "WireGuardNT %u.%u", (version >> 16) & 0xFFFF,
              version & 0xFFFF);
    return buffer;
}

bool Api::ReadPeerStats(const std::wstring& adapterName, PeerStats& out) {
    if (!Load()) return false;

    const auto open =
        reinterpret_cast<WIREGUARD_OPEN_ADAPTER_FUNC>(openAdapter_);
    const auto close =
        reinterpret_cast<WIREGUARD_CLOSE_ADAPTER_FUNC>(closeAdapter_);
    const auto getConfig =
        reinterpret_cast<WIREGUARD_GET_CONFIGURATION_FUNC>(getConfiguration_);

    WIREGUARD_ADAPTER_HANDLE adapter = open(adapterName.c_str());
    if (!adapter) {
        // Normal while the tunnel is down; not worth logging every poll.
        return false;
    }

    if (getAdapterLuid_) {
        const auto getLuid =
            reinterpret_cast<WIREGUARD_GET_ADAPTER_LUID_FUNC>(getAdapterLuid_);
        NET_LUID luid{};
        getLuid(adapter, &luid);
        out.adapterLuid = luid.Value;
    }

    // Ask once for the size, then read into a correctly sized buffer.
    DWORD bytes = 0;
    getConfig(adapter, nullptr, &bytes);
    if (bytes == 0) {
        close(adapter);
        return false;
    }

    std::vector<BYTE> buffer(bytes);
    if (!getConfig(adapter,
                   reinterpret_cast<WIREGUARD_INTERFACE*>(buffer.data()),
                   &bytes)) {
        Log::LastError("WireGuardGetConfiguration failed", GetLastError());
        close(adapter);
        return false;
    }

    const auto* iface =
        reinterpret_cast<const WIREGUARD_INTERFACE*>(buffer.data());

    // Walk the variable-length peer/allowed-ip chain that follows the header.
    const BYTE* cursor = buffer.data() + sizeof(WIREGUARD_INTERFACE);
    const BYTE* end = buffer.data() + bytes;

    for (DWORD p = 0; p < iface->PeersCount; ++p) {
        if (cursor + sizeof(WIREGUARD_PEER) > end) break;

        const auto* peer = reinterpret_cast<const WIREGUARD_PEER*>(cursor);
        cursor += sizeof(WIREGUARD_PEER);

        // GlukVPN tunnels have exactly one peer; take the freshest handshake.
        const int64_t handshake = FiletimeTicksToUnix(peer->LastHandshake);
        if (handshake > out.lastHandshakeUnix) {
            out.lastHandshakeUnix = handshake;
        }
        out.rxBytes += peer->RxBytes;
        out.txBytes += peer->TxBytes;

        const DWORD allowedCount = peer->AllowedIPsCount;
        const size_t skip =
            static_cast<size_t>(allowedCount) * sizeof(WIREGUARD_ALLOWED_IP);
        if (cursor + skip > end) break;
        cursor += skip;
    }

    out.valid = true;
    close(adapter);
    return true;
}

bool ReadPeerStats(const std::wstring& adapterName, PeerStats& out) {
    return Api::Instance().ReadPeerStats(adapterName, out);
}

} // namespace gluk::wg
