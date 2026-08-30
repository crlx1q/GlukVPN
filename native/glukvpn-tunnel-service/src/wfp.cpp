#include "wfp.h"

#include <winsock2.h>
#include <ws2tcpip.h>

#include <fwpmu.h>
#include <initguid.h>
#include <rpc.h>

#include "appdata.h"
#include "log.h"

namespace gluk {
namespace {

// Stable identifiers for everything GlukVPN registers with WFP.
// {8F1D2C40-6B3E-4E1A-9C77-0A4C51E7B301}
constexpr GUID kProviderKey = {
    0x8f1d2c40, 0x6b3e, 0x4e1a,
    {0x9c, 0x77, 0x0a, 0x4c, 0x51, 0xe7, 0xb3, 0x01}};

// {8F1D2C41-6B3E-4E1A-9C77-0A4C51E7B301}
constexpr GUID kSublayerKey = {
    0x8f1d2c41, 0x6b3e, 0x4e1a,
    {0x9c, 0x77, 0x0a, 0x4c, 0x51, 0xe7, 0xb3, 0x01}};

constexpr wchar_t kProviderName[] = L"GlukVPN";
constexpr wchar_t kProviderDescription[] = L"GlukVPN tunnel filters";
constexpr wchar_t kSublayerName[] = L"GlukVPN sublayer";

// Weight below the built-in sublayers so we never fight Windows itself.
constexpr UINT16 kSublayerWeight = 0xFFF0;

struct LayerPair {
    const GUID* v4;
    const GUID* v6;
};

const LayerPair kAuthConnectLayers = {&FWPM_LAYER_ALE_AUTH_CONNECT_V4,
                                      &FWPM_LAYER_ALE_AUTH_CONNECT_V6};
const LayerPair kAuthRecvLayers = {&FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4,
                                   &FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6};

bool ParseIpv4(const std::string& text, UINT32& out) {
    IN_ADDR addr{};
    if (InetPtonA(AF_INET, text.c_str(), &addr) != 1) return false;
    out = ntohl(addr.S_un.S_addr);
    return true;
}

} // namespace

Wfp& Wfp::Instance() {
    static Wfp instance;
    return instance;
}

bool Wfp::Open(std::string& errorCode, std::string& errorMessage) {
    if (engine_) return true;

    FWPM_SESSION0 session{};
    // Dynamic: the kernel removes every object we created when this process
    // dies. That is what makes taskkill /F safe.
    session.flags = FWPM_SESSION_FLAG_DYNAMIC;
    session.displayData.name = const_cast<wchar_t*>(kProviderName);

    HANDLE engine = nullptr;
    DWORD result = FwpmEngineOpen0(nullptr, RPC_C_AUTHN_WINNT, nullptr,
                                   &session, &engine);
    if (result != ERROR_SUCCESS) {
        Log::LastError("FwpmEngineOpen failed", result);
        errorCode = "killswitch_unavailable";
        errorMessage = "Cannot open the Windows Filtering Platform engine";
        return false;
    }
    engine_ = engine;

    result = FwpmTransactionBegin0(engine, 0);
    if (result != ERROR_SUCCESS) {
        Log::LastError("FwpmTransactionBegin failed", result);
        errorCode = "killswitch_unavailable";
        errorMessage = "Cannot begin a filtering transaction";
        return false;
    }

    FWPM_PROVIDER0 provider{};
    provider.providerKey = kProviderKey;
    provider.displayData.name = const_cast<wchar_t*>(kProviderName);
    provider.displayData.description =
        const_cast<wchar_t*>(kProviderDescription);
    result = FwpmProviderAdd0(engine, &provider, nullptr);
    if (result != ERROR_SUCCESS && result != FWP_E_ALREADY_EXISTS) {
        Log::LastError("FwpmProviderAdd failed", result);
        FwpmTransactionAbort0(engine);
        errorCode = "killswitch_unavailable";
        errorMessage = "Cannot register the GlukVPN filtering provider";
        return false;
    }

    FWPM_SUBLAYER0 sublayer{};
    sublayer.subLayerKey = kSublayerKey;
    sublayer.displayData.name = const_cast<wchar_t*>(kSublayerName);
    sublayer.providerKey = const_cast<GUID*>(&kProviderKey);
    sublayer.weight = kSublayerWeight;
    result = FwpmSubLayerAdd0(engine, &sublayer, nullptr);
    if (result != ERROR_SUCCESS && result != FWP_E_ALREADY_EXISTS) {
        Log::LastError("FwpmSubLayerAdd failed", result);
        FwpmTransactionAbort0(engine);
        errorCode = "killswitch_unavailable";
        errorMessage = "Cannot register the GlukVPN filtering sublayer";
        return false;
    }

    result = FwpmTransactionCommit0(engine);
    if (result != ERROR_SUCCESS) {
        Log::LastError("FwpmTransactionCommit failed", result);
        errorCode = "killswitch_unavailable";
        errorMessage = "Cannot commit the filtering transaction";
        return false;
    }

    providerRegistered_ = true;
    return true;
}

bool Wfp::EnableKillSwitch(const std::vector<std::string>& endpointIps,
                           std::string& errorCode, std::string& errorMessage) {
    if (!Open(errorCode, errorMessage)) return false;
    if (killSwitchActive_) return true;

    HANDLE engine = static_cast<HANDLE>(engine_);

    DWORD result = FwpmTransactionBegin0(engine, 0);
    if (result != ERROR_SUCCESS) {
        errorCode = "killswitch_failed";
        errorMessage = "Cannot begin the kill-switch transaction";
        return false;
    }

    auto addFilter = [&](const GUID& layer, FWP_ACTION_TYPE action,
                         UINT8 weight,
                         const std::vector<FWPM_FILTER_CONDITION0>& conditions,
                         const wchar_t* name) -> bool {
        FWPM_FILTER0 filter{};
        filter.layerKey = layer;
        filter.subLayerKey = kSublayerKey;
        filter.providerKey = const_cast<GUID*>(&kProviderKey);
        filter.displayData.name = const_cast<wchar_t*>(name);
        filter.action.type = action;
        filter.weight.type = FWP_UINT8;
        filter.weight.uint8 = weight;
        filter.numFilterConditions = static_cast<UINT32>(conditions.size());
        filter.filterCondition =
            conditions.empty()
                ? nullptr
                : const_cast<FWPM_FILTER_CONDITION0*>(conditions.data());

        UINT64 id = 0;
        const DWORD status = FwpmFilterAdd0(engine, &filter, nullptr, &id);
        if (status != ERROR_SUCCESS) {
            Log::LastError("FwpmFilterAdd failed", status);
            return false;
        }
        killSwitchFilters_.push_back(id);
        return true;
    };

    bool ok = true;

    // 1. Block everything, lowest weight.
    const std::vector<FWPM_FILTER_CONDITION0> none;
    ok &= addFilter(*kAuthConnectLayers.v4, FWP_ACTION_BLOCK, kWeightBlockAll,
                    none, L"GlukVPN block all (IPv4 out)");
    ok &= addFilter(*kAuthConnectLayers.v6, FWP_ACTION_BLOCK, kWeightBlockAll,
                    none, L"GlukVPN block all (IPv6 out)");
    ok &= addFilter(*kAuthRecvLayers.v4, FWP_ACTION_BLOCK, kWeightBlockAll,
                    none, L"GlukVPN block all (IPv4 in)");
    ok &= addFilter(*kAuthRecvLayers.v6, FWP_ACTION_BLOCK, kWeightBlockAll,
                    none, L"GlukVPN block all (IPv6 in)");

    // 2. Always allow loopback, or half of Windows breaks.
    {
        FWPM_FILTER_CONDITION0 condition{};
        condition.fieldKey = FWPM_CONDITION_FLAGS;
        condition.matchType = FWP_MATCH_FLAGS_ALL_SET;
        condition.conditionValue.type = FWP_UINT32;
        condition.conditionValue.uint32 = FWP_CONDITION_FLAG_IS_LOOPBACK;

        const std::vector<FWPM_FILTER_CONDITION0> loopback{condition};
        ok &= addFilter(*kAuthConnectLayers.v4, FWP_ACTION_PERMIT,
                        kWeightPermitInfra, loopback,
                        L"GlukVPN permit loopback (IPv4)");
        ok &= addFilter(*kAuthConnectLayers.v6, FWP_ACTION_PERMIT,
                        kWeightPermitInfra, loopback,
                        L"GlukVPN permit loopback (IPv6)");
        ok &= addFilter(*kAuthRecvLayers.v4, FWP_ACTION_PERMIT,
                        kWeightPermitInfra, loopback,
                        L"GlukVPN permit loopback in (IPv4)");
        ok &= addFilter(*kAuthRecvLayers.v6, FWP_ACTION_PERMIT,
                        kWeightPermitInfra, loopback,
                        L"GlukVPN permit loopback in (IPv6)");
    }

    // 3. Allow DHCP so the physical link can keep its lease.
    {
        std::vector<FWPM_FILTER_CONDITION0> dhcp;

        FWPM_FILTER_CONDITION0 protocolCondition{};
        protocolCondition.fieldKey = FWPM_CONDITION_IP_PROTOCOL;
        protocolCondition.matchType = FWP_MATCH_EQUAL;
        protocolCondition.conditionValue.type = FWP_UINT8;
        protocolCondition.conditionValue.uint8 = IPPROTO_UDP;
        dhcp.push_back(protocolCondition);

        FWPM_FILTER_CONDITION0 portCondition{};
        portCondition.fieldKey = FWPM_CONDITION_IP_REMOTE_PORT;
        portCondition.matchType = FWP_MATCH_EQUAL;
        portCondition.conditionValue.type = FWP_UINT16;
        portCondition.conditionValue.uint16 = 67;
        dhcp.push_back(portCondition);

        ok &= addFilter(*kAuthConnectLayers.v4, FWP_ACTION_PERMIT,
                        kWeightPermitInfra, dhcp, L"GlukVPN permit DHCP");
    }

    // 4. Allow UDP to the VPN endpoints, otherwise the handshake that is
    //    supposed to lift the kill switch could never happen.
    for (const std::string& ip : endpointIps) {
        UINT32 address = 0;
        if (!ParseIpv4(ip, address)) continue;

        std::vector<FWPM_FILTER_CONDITION0> endpoint;

        FWPM_FILTER_CONDITION0 addressCondition{};
        addressCondition.fieldKey = FWPM_CONDITION_IP_REMOTE_ADDRESS;
        addressCondition.matchType = FWP_MATCH_EQUAL;
        addressCondition.conditionValue.type = FWP_UINT32;
        addressCondition.conditionValue.uint32 = address;
        endpoint.push_back(addressCondition);

        FWPM_FILTER_CONDITION0 protocolCondition{};
        protocolCondition.fieldKey = FWPM_CONDITION_IP_PROTOCOL;
        protocolCondition.matchType = FWP_MATCH_EQUAL;
        protocolCondition.conditionValue.type = FWP_UINT8;
        protocolCondition.conditionValue.uint8 = IPPROTO_UDP;
        endpoint.push_back(protocolCondition);

        ok &= addFilter(*kAuthConnectLayers.v4, FWP_ACTION_PERMIT,
                        kWeightPermitInfra, endpoint,
                        L"GlukVPN permit VPN endpoint");
    }

    // 5. Always allow GlukVPN's own binaries so the app can still reach the
    //    control API and report why traffic is blocked.
    {
        const std::wstring serviceExe = AppData::ExecutablePath();
        const std::wstring uiExe =
            AppData::ExecutableDir() + L"\\..\\glukvpn.exe";

        for (const std::wstring& exe : {serviceExe, uiExe}) {
            FWP_BYTE_BLOB* blob = nullptr;
            if (FwpmGetAppIdFromFileName0(exe.c_str(), &blob) !=
                ERROR_SUCCESS) {
                continue;
            }

            FWPM_FILTER_CONDITION0 condition{};
            condition.fieldKey = FWPM_CONDITION_ALE_APP_ID;
            condition.matchType = FWP_MATCH_EQUAL;
            condition.conditionValue.type = FWP_BYTE_BLOB_TYPE;
            condition.conditionValue.byteBlob = blob;

            const std::vector<FWPM_FILTER_CONDITION0> own{condition};
            addFilter(*kAuthConnectLayers.v4, FWP_ACTION_PERMIT,
                      kWeightPermitApp, own, L"GlukVPN permit own process");
            addFilter(*kAuthConnectLayers.v6, FWP_ACTION_PERMIT,
                      kWeightPermitApp, own, L"GlukVPN permit own process v6");

            FwpmFreeMemory0(reinterpret_cast<void**>(&blob));
        }
    }

    if (!ok) {
        FwpmTransactionAbort0(engine);
        killSwitchFilters_.clear();
        errorCode = "killswitch_failed";
        errorMessage = "One or more kill-switch filters could not be added";
        return false;
    }

    result = FwpmTransactionCommit0(engine);
    if (result != ERROR_SUCCESS) {
        Log::LastError("Kill switch commit failed", result);
        killSwitchFilters_.clear();
        errorCode = "killswitch_failed";
        errorMessage = "Cannot commit the kill-switch filters";
        return false;
    }

    killSwitchActive_ = true;
    Log::Info("Kill switch armed");
    return true;
}

bool Wfp::PermitInterface(unsigned long long luid, std::string& errorCode,
                          std::string& errorMessage) {
    if (!Open(errorCode, errorMessage)) return false;
    if (luid == 0) return true;

    HANDLE engine = static_cast<HANDLE>(engine_);

    FWPM_FILTER_CONDITION0 condition{};
    condition.fieldKey = FWPM_CONDITION_IP_LOCAL_INTERFACE;
    condition.matchType = FWP_MATCH_EQUAL;
    condition.conditionValue.type = FWP_UINT64;
    condition.conditionValue.uint64 = reinterpret_cast<UINT64*>(&luid);

    for (const GUID* layer : {kAuthConnectLayers.v4, kAuthConnectLayers.v6,
                              kAuthRecvLayers.v4, kAuthRecvLayers.v6}) {
        FWPM_FILTER0 filter{};
        filter.layerKey = *layer;
        filter.subLayerKey = kSublayerKey;
        filter.providerKey = const_cast<GUID*>(&kProviderKey);
        filter.displayData.name =
            const_cast<wchar_t*>(L"GlukVPN permit tunnel interface");
        filter.action.type = FWP_ACTION_PERMIT;
        filter.weight.type = FWP_UINT8;
        filter.weight.uint8 = kWeightPermitTunnel;
        filter.numFilterConditions = 1;
        filter.filterCondition = &condition;

        UINT64 id = 0;
        const DWORD status = FwpmFilterAdd0(engine, &filter, nullptr, &id);
        if (status == ERROR_SUCCESS) {
            killSwitchFilters_.push_back(id);
        } else {
            Log::LastError("Permit-interface filter failed", status);
        }
    }
    return true;
}

bool Wfp::AddAppRule(const std::string& exePath, bool permit,
                     std::string& errorCode, std::string& errorMessage) {
    if (!Open(errorCode, errorMessage)) return false;

    HANDLE engine = static_cast<HANDLE>(engine_);
    const std::wstring wide = AppData::ToWide(exePath);

    FWP_BYTE_BLOB* blob = nullptr;
    const DWORD status = FwpmGetAppIdFromFileName0(wide.c_str(), &blob);
    if (status != ERROR_SUCCESS || !blob) {
        // A path the user picked may no longer exist. Skip it rather than
        // failing the whole apply.
        Log::Warn("Cannot resolve app id for " + exePath);
        return true;
    }

    FWPM_FILTER_CONDITION0 condition{};
    condition.fieldKey = FWPM_CONDITION_ALE_APP_ID;
    condition.matchType = FWP_MATCH_EQUAL;
    condition.conditionValue.type = FWP_BYTE_BLOB_TYPE;
    condition.conditionValue.byteBlob = blob;

    for (const GUID* layer : {kAuthConnectLayers.v4, kAuthConnectLayers.v6}) {
        FWPM_FILTER0 filter{};
        filter.layerKey = *layer;
        filter.subLayerKey = kSublayerKey;
        filter.providerKey = const_cast<GUID*>(&kProviderKey);
        filter.displayData.name =
            const_cast<wchar_t*>(permit ? L"GlukVPN permit app"
                                        : L"GlukVPN block app");
        filter.action.type = permit ? FWP_ACTION_PERMIT : FWP_ACTION_BLOCK;
        filter.weight.type = FWP_UINT8;
        filter.weight.uint8 = permit ? kWeightPermitApp : kWeightBlockApp;
        filter.numFilterConditions = 1;
        filter.filterCondition = &condition;

        UINT64 id = 0;
        const DWORD result = FwpmFilterAdd0(engine, &filter, nullptr, &id);
        if (result == ERROR_SUCCESS) {
            appFilters_.push_back(id);
        } else {
            Log::LastError("App filter add failed", result);
        }
    }

    FwpmFreeMemory0(reinterpret_cast<void**>(&blob));
    return true;
}

void Wfp::DeleteFilters(std::vector<unsigned long long>& ids) {
    if (!engine_) {
        ids.clear();
        return;
    }
    HANDLE engine = static_cast<HANDLE>(engine_);
    for (const unsigned long long id : ids) {
        FwpmFilterDeleteById0(engine, id);
    }
    ids.clear();
}

void Wfp::ClearAppRules() { DeleteFilters(appFilters_); }

void Wfp::DisableKillSwitch() {
    DeleteFilters(killSwitchFilters_);
    killSwitchActive_ = false;
}

void Wfp::Close() {
    DeleteFilters(appFilters_);
    DeleteFilters(killSwitchFilters_);
    killSwitchActive_ = false;

    if (engine_) {
        FwpmEngineClose0(static_cast<HANDLE>(engine_));
        engine_ = nullptr;
    }
    providerRegistered_ = false;
}

} // namespace gluk
