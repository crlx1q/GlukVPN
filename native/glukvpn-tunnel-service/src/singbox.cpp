#include "singbox.h"

#include "json.h"

namespace gluk {
namespace {

json::Array StringArray(const std::vector<std::string>& items) {
    json::Array out;
    out.reserve(items.size());
    for (const std::string& item : items) {
        if (!item.empty()) out.push_back(json::Value(item));
    }
    return out;
}

// The TUN inbound. Windows sees a real Layer 3 adapter, so games, voice chat
// and torrents behave exactly as they do on a cable - unlike an HTTP proxy,
// which can only ever carry TCP to a handful of ports.
//
// auto_route replaces every route, metric and socket-binding trick the
// WireGuard worker performed by hand over the last twenty-three rounds.
//
// strict_route adds the WFP filters that stop Windows from resolving names on
// the physical NIC while the tunnel is up - the multihomed DNS leak the old
// engine never closed. ROUND 26: it follows the kill-switch switch instead of
// being always on. Kill switch = the block-all WFP filters from wfp.cpp plus
// strict_route here; with the switch off the tunnel still carries everything
// through auto_route, but a dropped tunnel falls back to the plain internet
// instead of cutting it, which is the default users expect.
json::Object TunInbound(const SingBoxOptions& options) {
    std::vector<std::string> address;
    address.push_back(options.tunAddress.empty() ? std::string(kSingBoxTunPrefix)
                                                 : options.tunAddress);

    json::Object tun;
    tun.emplace("type", json::Value(std::string("tun")));
    tun.emplace("tag", json::Value(std::string("tun-in")));
    tun.emplace("interface_name",
                json::Value(options.adapter.empty() ? std::string("GlukVPN")
                                                    : options.adapter));
    tun.emplace("address", json::Value(StringArray(address)));
    if (options.mtu > 0) tun.emplace("mtu", json::Value(options.mtu));
    tun.emplace("auto_route", json::Value(true));
    tun.emplace("strict_route", json::Value(options.strictRoute));
    // system TCP with a gvisor UDP stack: the combination the official
    // Windows builds default to, and the only one that keeps UDP latency
    // predictable for games.
    tun.emplace("stack", json::Value(std::string("mixed")));
    return tun;
}

json::Object ProxyOutbound(const GatewayConfig& gateway) {
    json::Object tls;
    tls.emplace("enabled", json::Value(true));
    tls.emplace("server_name",
                json::Value(gateway.sni.empty() ? gateway.host : gateway.sni));
    if (gateway.insecure) tls.emplace("insecure", json::Value(true));

    json::Object out;
    out.emplace("type", json::Value(std::string("vless")));
    out.emplace("tag", json::Value(std::string("proxy")));
    out.emplace("server", json::Value(gateway.host));
    out.emplace("server_port", json::Value(gateway.port));
    out.emplace("uuid", json::Value(gateway.uuid));
    // xudp carries UDP - QUIC, DNS, game traffic, torrent DHT - inside the
    // same TLS session. It is the difference between "browsers work" and
    // "everything works", and it is exactly what the HTTP CONNECT gateway
    // used by the browser extension cannot do.
    out.emplace("packet_encoding", json::Value(std::string("xudp")));
    if (!gateway.flow.empty()) {
        out.emplace("flow", json::Value(gateway.flow));
    }
    out.emplace("tls", json::Value(std::move(tls)));
    return out;
}

json::Object DnsBlock(const SingBoxOptions& options) {
    // Resolvers are queried through the tunnel, so the provider never sees
    // which names are looked up and cannot answer them itself.
    std::vector<std::string> resolvers = options.dns;
    if (resolvers.empty()) {
        resolvers.push_back("1.1.1.1");
        resolvers.push_back("8.8.8.8");
    }

    json::Array servers;
    int index = 0;
    for (const std::string& resolver : resolvers) {
        if (resolver.empty()) continue;
        json::Object server;
        server.emplace("type", json::Value(std::string("udp")));
        server.emplace("tag",
                       json::Value("dns-proxy-" + std::to_string(++index)));
        server.emplace("server", json::Value(resolver));
        server.emplace("detour", json::Value(std::string("proxy")));
        servers.push_back(json::Value(std::move(server)));
    }

    // One resolver stays on the system stack: the gateway's own hostname has
    // to be resolved before there is a tunnel to resolve it through.
    json::Object local;
    local.emplace("type", json::Value(std::string("local")));
    local.emplace("tag", json::Value(std::string("dns-direct")));
    servers.push_back(json::Value(std::move(local)));

    json::Object dns;
    dns.emplace("servers", json::Value(std::move(servers)));
    dns.emplace("final", json::Value(std::string("dns-proxy-1")));
    // The tunnel carries IPv4 only. Without this, AAAA answers would hand
    // applications v6 addresses that have nowhere to go, and every page load
    // would start with a timeout.
    dns.emplace("strategy", json::Value(std::string("ipv4_only")));
    return dns;
}

json::Object DirectRule(const std::string& key, const json::Array& values) {
    json::Object rule;
    rule.emplace(key, json::Value(values));
    rule.emplace("action", json::Value(std::string("route")));
    rule.emplace("outbound", json::Value(std::string("direct")));
    return rule;
}

json::Object RouteBlock(const GatewayConfig& gateway,
                        const SingBoxOptions& options) {
    json::Array rules;

    // Sniffing gives the domain rules something to match on and lets the node
    // see a hostname instead of a bare IP.
    json::Object sniff;
    sniff.emplace("action", json::Value(std::string("sniff")));
    rules.push_back(json::Value(std::move(sniff)));

    // The LAN, the router and localhost must never enter the tunnel, or
    // printers, NAS shares and the router's own web page stop working the
    // moment the VPN connects.
    json::Object privateRule;
    privateRule.emplace("ip_is_private", json::Value(true));
    privateRule.emplace("action", json::Value(std::string("route")));
    privateRule.emplace("outbound", json::Value(std::string("direct")));
    rules.push_back(json::Value(std::move(privateRule)));

    // Our own control plane stays outside the tunnel: the app has to reach it
    // to fetch a session, to refresh a token and to report a broken tunnel.
    std::vector<std::string> domains = options.directDomains;
    if (domains.empty()) domains.push_back("gluk.tech");
    json::Object controlRule =
        DirectRule("domain_suffix", StringArray(domains));
    if (!gateway.host.empty()) {
        std::vector<std::string> host;
        host.push_back(gateway.host);
        controlRule.emplace("domain", json::Value(StringArray(host)));
    }
    rules.push_back(json::Value(std::move(controlRule)));

    if (!options.directRoutes.empty()) {
        rules.push_back(json::Value(
            DirectRule("ip_cidr", StringArray(options.directRoutes))));
    }

    json::Object route;
    route.emplace("rules", json::Value(std::move(rules)));
    route.emplace("final", json::Value(std::string("proxy")));
    // Binds outbound sockets to the physical NIC. This single option is what
    // stops the tunnel from carrying its own packets, and it is why
    // bindOutsideTheTunnel, keepSocketOutsideTheTunnel, bestPhysicalIndex and
    // logEndpointPathDecision are no longer needed.
    route.emplace("auto_detect_interface", json::Value(true));
    // Since 1.12 an outbound addressed by hostname must be told which
    // resolver to use, or sing-box refuses to start.
    route.emplace("default_domain_resolver",
                  json::Value(std::string("dns-direct")));
    return route;
}

} // namespace

bool GatewayConfig::usable() const {
    // vless is the only protocol the service knows how to configure: it is
    // what the node runs, it carries UDP inside TLS, and it needs exactly one
    // credential. An empty type means vless so older callers keep working.
    const std::string kind = type.empty() ? std::string("vless") : type;
    return kind == "vless" && !host.empty() && port > 0 && !uuid.empty();
}

std::string BuildSingBoxConfig(const GatewayConfig& gateway,
                               const SingBoxOptions& options) {
    // warn, not info: the worker log is read back by the service and shown to
    // the user when a tunnel fails, and round 23 established that a chatty
    // data plane buries the one line that matters.
    json::Object log;
    log.emplace("level", json::Value(std::string("warn")));
    log.emplace("timestamp", json::Value(true));

    json::Array inbounds;
    inbounds.push_back(json::Value(TunInbound(options)));

    json::Array outbounds;
    outbounds.push_back(json::Value(ProxyOutbound(gateway)));
    json::Object direct;
    direct.emplace("type", json::Value(std::string("direct")));
    direct.emplace("tag", json::Value(std::string("direct")));
    outbounds.push_back(json::Value(std::move(direct)));

    json::Object root;
    root.emplace("log", json::Value(std::move(log)));
    root.emplace("dns", json::Value(DnsBlock(options)));
    root.emplace("inbounds", json::Value(std::move(inbounds)));
    root.emplace("outbounds", json::Value(std::move(outbounds)));
    root.emplace("route", json::Value(RouteBlock(gateway, options)));
    return json::Write(json::Value(std::move(root)));
}

} // namespace gluk
