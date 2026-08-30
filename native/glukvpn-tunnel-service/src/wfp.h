// Windows Filtering Platform wrapper: kill switch and per-application rules.
//
// All filters are registered under a single non-persistent provider and
// sublayer. That is a deliberate safety property: if the service is killed
// with taskkill /F, or crashes, the WFP session is torn down by the kernel and
// every filter disappears with it. The machine can never be left without
// internet because of a dead GlukVPN process.

#pragma once

#include <string>
#include <vector>

namespace gluk {

class Wfp {
public:
    static Wfp& Instance();

    // Opens the engine and registers the provider/sublayer. Idempotent.
    bool Open(std::string& errorCode, std::string& errorMessage);

    // Blocks all IPv4/IPv6 traffic except:
    //   - anything on the tunnel adapter
    //   - UDP to the VPN endpoints (so the handshake can happen)
    //   - loopback, DHCP and IPv6 neighbour discovery
    //   - GlukVPN's own executables
    bool EnableKillSwitch(const std::vector<std::string>& endpointIps,
                          std::string& errorCode, std::string& errorMessage);

    void DisableKillSwitch();

    // Permits or blocks a specific executable at the ALE connect layers.
    // `permit == false` installs a block filter with a higher weight, which
    // wins over the permit filters.
    bool AddAppRule(const std::string& exePath, bool permit,
                    std::string& errorCode, std::string& errorMessage);

    // Allows every packet on the given adapter, used to keep the tunnel itself
    // reachable while the kill switch is armed.
    bool PermitInterface(unsigned long long luid, std::string& errorCode,
                         std::string& errorMessage);

    // Removes only the application rules, leaving the kill switch in place.
    void ClearAppRules();

    // Removes everything and closes the engine.
    void Close();

    bool killSwitchActive() const { return killSwitchActive_; }

    // Filter weights. Higher wins inside our sublayer.
    static constexpr unsigned char kWeightBlockAll = 1;
    static constexpr unsigned char kWeightPermitTunnel = 10;
    static constexpr unsigned char kWeightPermitInfra = 12;
    static constexpr unsigned char kWeightPermitApp = 14;
    static constexpr unsigned char kWeightBlockApp = 16;

private:
    Wfp() = default;

    void* engine_ = nullptr;
    bool providerRegistered_ = false;
    bool killSwitchActive_ = false;

    std::vector<unsigned long long> killSwitchFilters_;
    std::vector<unsigned long long> appFilters_;

    void DeleteFilters(std::vector<unsigned long long>& ids);
};

} // namespace gluk
