// sing-box configuration for the Windows data plane.
//
// ROUND 24. The WireGuard worker stays in the payload, but the engine the
// service prefers is now sing-box: it owns the Wintun adapter, installs the
// routes itself and wraps the traffic in TLS, so the DPI equipment used by
// Kazakhtelecom and Beeline KZ sees an ordinary HTTPS session instead of a
// WireGuard header it can fingerprint and throttle.
//
// Everything here targets the schema of sing-box 1.14, the release pinned by
// the build scripts. Two keys that circulate in older guides do not exist any
// more and make the process abort on startup:
//
//   * inet4_address was merged into address in 1.10 and removed in 1.12
//   * inbound.sniff became a route rule with "action": "sniff" in 1.11
//
// That is the reason the configuration is generated in C++ instead of being
// shipped as a template: the adapter name, the MTU, the resolvers and the
// credentials are all per-session, and a hand-edited file drifts out of date
// the moment sing-box is upgraded.

#pragma once

#include <string>
#include <vector>

namespace gluk {

// Address of the TUN interface. A /30 is all sing-box needs: the peer side is
// synthetic, nothing else lives on that subnet, and 172.19.0.0/16 is far
// enough from the ranges home routers hand out.
constexpr char kSingBoxTunPrefix[] = "172.19.0.1/30";
constexpr char kSingBoxTunAddress[] = "172.19.0.1";

// The outbound side of the tunnel, handed over by the UI with "up".
struct GatewayConfig {
    std::string type;      // "vless", the only protocol the service configures
    std::string host;      // node hostname; also the TLS server name
    int port = 0;
    std::string uuid;      // per-device credential from the control plane
    std::string sni;       // overrides the TLS server name when set
    std::string flow;      // vless sub-protocol, e.g. xtls-rprx-vision
    bool insecure = false; // staging certificates only, never in production

    // False means "there is nothing to connect to", and the service falls
    // back to the WireGuard worker instead of writing a config sing-box would
    // refuse.
    bool usable() const;
};

struct SingBoxOptions {
    std::string adapter = "GlukVPN";
    std::string tunAddress = kSingBoxTunPrefix;
    int mtu = 0; // 0 leaves sing-box's own default in place

    // Resolvers queried through the tunnel. Defaults are used when empty.
    std::vector<std::string> dns;

    // Domain suffixes kept off the tunnel. Defaults to our own control plane,
    // which the app must be able to reach even while the tunnel is broken.
    std::vector<std::string> directDomains;

    // Prefixes kept off the tunnel, e.g. a LAN the user asked to bypass.
    std::vector<std::string> directRoutes;
};

// Renders the configuration file. Never fails: an unusable gateway is
// rejected earlier by GatewayConfig::usable().
std::string BuildSingBoxConfig(const GatewayConfig& gateway,
                               const SingBoxOptions& options);

} // namespace gluk
