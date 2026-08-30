#include "split_tunnel.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <iphlpapi.h>
#include <netioapi.h>

#include <algorithm>

#include "log.h"
#include "wfp.h"

namespace gluk {
namespace {

// Splits "192.168.0.0/16" into an address and prefix length.
bool ParsePrefix(const std::string& text, IN_ADDR& address, UINT8& prefix) {
    const size_t slash = text.find('/');
    const std::string host =
        slash == std::string::npos ? text : text.substr(0, slash);

    if (InetPtonA(AF_INET, host.c_str(), &address) != 1) return false;

    if (slash == std::string::npos) {
        prefix = 32;
        return true;
    }

    const int parsed = std::atoi(text.c_str() + slash + 1);
    if (parsed < 0 || parsed > 32) return false;
    prefix = static_cast<UINT8>(parsed);
    return true;
}

// Finds the interface and next hop that currently serve the default route,
// so bypassed prefixes can be pinned to the physical link.
bool FindPhysicalDefaultRoute(NET_LUID& luid, SOCKADDR_INET& nextHop) {
    MIB_IPFORWARD_TABLE2* table = nullptr;
    if (GetIpForwardTable2(AF_INET, &table) != NO_ERROR || !table) return false;

    bool found = false;
    ULONG bestMetric = 0xFFFFFFFF;

    for (ULONG i = 0; i < table->NumEntries; ++i) {
        const MIB_IPFORWARD_ROW2& row = table->Table[i];
        if (row.DestinationPrefix.PrefixLength != 0) continue;

        MIB_IF_ROW2 iface{};
        iface.InterfaceLuid = row.InterfaceLuid;
        if (GetIfEntry2(&iface) != NO_ERROR) continue;

        // Skip our own tunnel and anything that is not really up.
        if (iface.Type == IF_TYPE_SOFTWARE_LOOPBACK) continue;
        if (iface.OperStatus != IfOperStatusUp) continue;
        if (wcsstr(iface.Alias, L"GlukVPN") != nullptr) continue;

        if (row.Metric < bestMetric) {
            bestMetric = row.Metric;
            luid = row.InterfaceLuid;
            nextHop = row.NextHop;
            found = true;
        }
    }

    FreeMibTable(table);
    return found;
}

} // namespace

const char* SplitModeName(SplitMode mode) {
    switch (mode) {
        case SplitMode::AllApps: return "all";
        case SplitMode::OnlySelected: return "only";
        case SplitMode::ExcludeSelected: return "exclude";
    }
    return "all";
}

SplitMode SplitModeFromString(const std::string& value) {
    if (value == "only") return SplitMode::OnlySelected;
    if (value == "exclude") return SplitMode::ExcludeSelected;
    return SplitMode::AllApps;
}

SplitTunnel& SplitTunnel::Instance() {
    static SplitTunnel instance;
    return instance;
}

std::string SplitTunnel::EngineName() const {
#ifdef GLUK_HAVE_WINDIVERT
    return "windivert";
#else
    // "wfp-guard" tells the UI that per-app rules are enforced by blocking,
    // not by redirection, so it can show an honest explanation.
    return "wfp-guard";
#endif
}

bool SplitTunnel::SupportsPerAppRedirect() const {
#ifdef GLUK_HAVE_WINDIVERT
    return true;
#else
    return false;
#endif
}

bool SplitTunnel::RequiresReconnect(SplitMode from, SplitMode to) {
    // Whether WireGuard installs the default route (Table = off) is decided
    // when the adapter is created, so crossing that boundary needs a rebuild.
    const bool fromFull = from == SplitMode::AllApps;
    const bool toFull = to == SplitMode::AllApps;
    return fromFull != toFull;
}

bool SplitTunnel::ApplyBypassRoutes(const SplitConfig& config) {
    ClearBypassRoutes();
    if (config.bypassRoutes.empty()) return true;

    NET_LUID physicalLuid{};
    SOCKADDR_INET nextHop{};
    if (!FindPhysicalDefaultRoute(physicalLuid, nextHop)) {
        Log::Warn("No physical default route found; skipping bypass routes");
        return true;
    }

    for (const std::string& prefixText : config.bypassRoutes) {
        IN_ADDR address{};
        UINT8 prefix = 32;
        if (!ParsePrefix(prefixText, address, prefix)) {
            Log::Warn("Ignoring malformed bypass route " + prefixText);
            continue;
        }

        MIB_IPFORWARD_ROW2 row{};
        InitializeIpForwardEntry(&row);
        row.InterfaceLuid = physicalLuid;
        row.DestinationPrefix.Prefix.si_family = AF_INET;
        row.DestinationPrefix.Prefix.Ipv4.sin_family = AF_INET;
        row.DestinationPrefix.Prefix.Ipv4.sin_addr = address;
        row.DestinationPrefix.PrefixLength = prefix;
        row.NextHop = nextHop;
        // Low metric so it beats the tunnel's own routes.
        row.Metric = 1;
        row.Protocol = MIB_IPPROTO_NETMGMT;

        const DWORD result = CreateIpForwardEntry2(&row);
        if (result == NO_ERROR || result == ERROR_OBJECT_ALREADY_EXISTS) {
            routeKeys_.push_back(
                (static_cast<unsigned long long>(address.S_un.S_addr) << 8) |
                prefix);
        } else {
            Log::LastError("CreateIpForwardEntry2 failed", result);
        }
    }
    return true;
}

void SplitTunnel::ClearBypassRoutes() {
    if (routeKeys_.empty()) return;

    for (const unsigned long long key : routeKeys_) {
        const ULONG raw = static_cast<ULONG>(key >> 8);
        const UINT8 prefix = static_cast<UINT8>(key & 0xFF);

        MIB_IPFORWARD_ROW2 row{};
        InitializeIpForwardEntry(&row);
        row.DestinationPrefix.Prefix.si_family = AF_INET;
        row.DestinationPrefix.Prefix.Ipv4.sin_family = AF_INET;
        row.DestinationPrefix.Prefix.Ipv4.sin_addr.S_un.S_addr = raw;
        row.DestinationPrefix.PrefixLength = prefix;

        // Look the row up so the LUID and next hop match exactly.
        MIB_IPFORWARD_TABLE2* table = nullptr;
        if (GetIpForwardTable2(AF_INET, &table) == NO_ERROR && table) {
            for (ULONG i = 0; i < table->NumEntries; ++i) {
                const MIB_IPFORWARD_ROW2& candidate = table->Table[i];
                if (candidate.DestinationPrefix.PrefixLength == prefix &&
                    candidate.DestinationPrefix.Prefix.Ipv4.sin_addr.S_un
                            .S_addr == raw &&
                    candidate.Protocol == MIB_IPPROTO_NETMGMT) {
                    DeleteIpForwardEntry2(&candidate);
                }
            }
            FreeMibTable(table);
        }
    }
    routeKeys_.clear();
}

bool SplitTunnel::ApplyAppFilters(const SplitConfig& config,
                                  std::string& errorCode,
                                  std::string& errorMessage) {
    Wfp& wfp = Wfp::Instance();
    wfp.ClearAppRules();

    if (config.mode == SplitMode::AllApps) return true;

    // ExcludeSelected: the listed apps are blocked from the tunnel scope, so
    // they keep using the physical route that ApplyBypassRoutes maintains.
    //
    // OnlySelected: everything except the listed apps is blocked from the
    // tunnel, which is the enforceable half of "only these apps use the VPN".
    const bool permitListed = config.mode == SplitMode::OnlySelected;

    for (const std::string& app : config.apps) {
        if (app.empty()) continue;
        if (!wfp.AddAppRule(app, permitListed, errorCode, errorMessage)) {
            return false;
        }
    }

    Log::Info(std::string("Split tunnelling applied: ") +
              SplitModeName(config.mode) + ", " +
              std::to_string(config.apps.size()) + " app(s)");
    return true;
}

bool SplitTunnel::Apply(const SplitConfig& config, std::string& errorCode,
                        std::string& errorMessage) {
    if (!ApplyAppFilters(config, errorCode, errorMessage)) {
        if (errorCode.empty()) errorCode = "split_failed";
        if (errorMessage.empty()) {
            errorMessage = "Cannot apply per-application rules";
        }
        return false;
    }

    if (!ApplyBypassRoutes(config)) {
        errorCode = "split_failed";
        errorMessage = "Cannot install bypass routes";
        return false;
    }

    // Keep the tunnel interface itself reachable no matter what.
    if (config.tunnelLuid != 0) {
        std::string code, message;
        Wfp::Instance().PermitInterface(config.tunnelLuid, code, message);
    }

    active_ = config.mode;
    return true;
}

void SplitTunnel::Clear() {
    ClearBypassRoutes();
    Wfp::Instance().ClearAppRules();
    active_ = SplitMode::AllApps;
}

} // namespace gluk
