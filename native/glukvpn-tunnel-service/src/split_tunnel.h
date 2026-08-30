// Split tunnelling engine.
//
// Three modes are supported (requirement 14):
//
//   AllApps        every packet goes through the tunnel
//   OnlySelected   only the listed executables use the tunnel
//   ExcludeSelected  the listed executables bypass the tunnel
//
// How it actually works on Windows
// --------------------------------
// Destination-based splitting is exact: the adapter is created with
// Table = off so WireGuard does not install its own default route, and this
// class installs the routes itself, leaving the excluded prefixes on the
// physical interface.
//
// Application-based splitting is enforced with WFP filters keyed on the
// application id (FWPM_CONDITION_ALE_APP_ID) at the ALE_AUTH_CONNECT layers.
// That reliably *blocks* traffic, which is what "these apps must not use the
// VPN" and "only these apps may use the VPN" require, and it cannot be
// bypassed from user mode.
//
// What it deliberately does not claim
// -----------------------------------
// Without a signed WFP callout driver (or WinDivert) Windows cannot *force*
// an arbitrary process onto a different interface; it can only permit or deny.
// The engine name is reported to the UI as "wfp-guard" so the client can be
// honest about that instead of pretending. See docs/desktop/ARCHITECTURE.md.

#pragma once

#include <string>
#include <vector>

namespace gluk {

enum class SplitMode {
    AllApps,
    OnlySelected,
    ExcludeSelected,
};

const char* SplitModeName(SplitMode mode);
SplitMode SplitModeFromString(const std::string& value);

struct SplitConfig {
    SplitMode mode = SplitMode::AllApps;
    // Full paths to executables, as reported by the UI.
    std::vector<std::string> apps;
    // Destination prefixes that must never enter the tunnel, e.g. the LAN.
    std::vector<std::string> bypassRoutes;
    // Tunnel adapter LUID, used to scope the filters.
    unsigned long long tunnelLuid = 0;
};

class SplitTunnel {
public:
    static SplitTunnel& Instance();

    // Installs the filters and routes for the requested configuration.
    bool Apply(const SplitConfig& config, std::string& errorCode,
               std::string& errorMessage);

    // Removes everything this class installed. Safe to call when nothing is
    // active; never leaves the machine without internet.
    void Clear();

    // Reported to the client in the hello/status payloads.
    std::string EngineName() const;

    // True when a real per-application redirection engine is compiled in.
    bool SupportsPerAppRedirect() const;

    // True when switching from `from` to `to` requires the tunnel to be
    // rebuilt, because Table=off is decided when the adapter is created.
    static bool RequiresReconnect(SplitMode from, SplitMode to);

private:
    SplitTunnel() = default;

    bool ApplyAppFilters(const SplitConfig& config, std::string& errorCode,
                         std::string& errorMessage);
    bool ApplyBypassRoutes(const SplitConfig& config);
    void ClearBypassRoutes();

    SplitMode active_ = SplitMode::AllApps;
    std::vector<unsigned long long> routeKeys_;
};

} // namespace gluk
