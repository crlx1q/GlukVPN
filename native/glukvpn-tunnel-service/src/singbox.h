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

// MTU used when the caller does not ask for one.
//
// ROUND 27. Leaving the key out of the config does not mean "let Windows
// decide", it means sing-box's own default of 9000 - and with stack "mixed"
// the Windows TCP stack believes it. It then advertises an MSS the real path
// cannot carry, the node fragments every answer, the receive window collapses
// and Windows acknowledges each out-of-order segment. That is how a link with
// 400 Mbit/s of upload ended up serving 4.5 Mbit/s of download with a send
// counter that grew 1:1 with the receive counter.
//
// 1420 is the number the control plane already hands out for the WireGuard
// engine (node.mtu, and go/glukvpn-wg falls back to the same value), so both
// engines now agree, and it is what the settings screen has always promised
// for an empty MTU field.
constexpr int kSingBoxDefaultMtu = 1420;

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
    int mtu = 0; // 0 selects kSingBoxDefaultMtu, never sing-box's own 9000

    // Resolvers queried through the tunnel. Defaults are used when empty.
    std::vector<std::string> dns;

    // Domain suffixes kept off the tunnel. Defaults to our own control plane,
    // which the app must be able to reach even while the tunnel is broken.
    std::vector<std::string> directDomains;

    // Prefixes kept off the tunnel, e.g. a LAN the user asked to bypass.
    std::vector<std::string> directRoutes;

    // ROUND 26: mirrors the "killSwitch" flag of the "up" request. When set,
    // the TUN inbound is rendered with strict_route, which makes sing-box
    // install its own WFP rules so that nothing - DNS included - can leave
    // over the physical NIC while the tunnel is up. Together with the block-all
    // filters wfp.cpp arms for the same flag this is what "kill switch" means
    // on the sing-box engine. Off by default: strict routing also refuses
    // traffic while the tunnel is being torn down, which a user who did not
    // ask for a kill switch reads as "the VPN broke my internet".
    bool strictRoute = false;

    // ROUND 28: sing-box's own Clash API, bound to loopback.
    //
    // The Windows interface counters cannot answer "how much did I download".
    // With stack "mixed" the TCP half runs on the system stack, so every
    // payload byte crosses the TUN adapter twice - once leaving the
    // application, once when sing-box re-injects it for the OS to pick up -
    // and GetIfEntry2 ends up reporting InOctets == OutOctets == total. That
    // is exactly the 855 KB / 854 KB the stats panel kept showing: not an
    // inverted mapping, a source that cannot tell the directions apart.
    // sing-box can, and its Clash API is the only place it says so. The same
    // API also measures latency *through* the proxy outbound, which is the
    // number the "ping - tunnel" cell always claimed to be showing.
    //
    // 0 leaves the block out of the configuration entirely. The controller
    // listens on 127.0.0.1 only and is closed by a per-session secret, so
    // nothing off the machine can reach it and nothing on the machine can use
    // it without the secret the service hands to the app over its pipe.
    int clashPort = 0;
    std::string clashSecret;
};

// Renders the configuration file. Never fails: an unusable gateway is
// rejected earlier by GatewayConfig::usable().
std::string BuildSingBoxConfig(const GatewayConfig& gateway,
                               const SingBoxOptions& options);

} // namespace gluk
