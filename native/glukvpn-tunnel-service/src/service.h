// Windows Service Control Manager plumbing.
//
// The service is installed as LocalSystem with SERVICE_AUTO_START and a
// dependency on the Base Filtering Engine, because WFP is required for the
// kill switch and split tunnelling.
//
// Installing is the only step that needs elevation. After that, the UI runs
// unelevated and talks to the service over a named pipe, so the user sees
// exactly one UAC prompt — during installation — and never again.

#pragma once

#include <windows.h>

#include <string>

namespace gluk {

constexpr wchar_t kServiceName[] = L"GlukVpnTunnel";
constexpr wchar_t kServiceDisplayName[] = L"GlukVPN Tunnel Service";
constexpr wchar_t kServiceDescription[] =
    L"Maintains the GlukVPN WireGuard tunnel, kill switch and split "
    L"tunnelling rules.";
constexpr wchar_t kPipeName[] = L"GlukVPN.tunnel";

class Service {
public:
    // Registers the service with the SCM. Requires administrator rights.
    static bool Install(std::wstring& error);

    // Stops and removes the service. Requires administrator rights.
    static bool Uninstall(std::wstring& error);

    // Asks the SCM to start the service.
    static bool Start(std::wstring& error);

    // Entry point used when the SCM launches us with --run.
    static int RunAsService();

    // Entry point used by --console for local debugging.
    static int RunInConsole(bool allowAnyClient);

    // True when the process token has the Administrators group enabled.
    static bool IsElevated();

private:
    static void WINAPI ServiceMain(DWORD argc, LPWSTR* argv);
    static DWORD WINAPI HandlerEx(DWORD control, DWORD eventType,
                                  LPVOID eventData, LPVOID context);
    static void ReportStatus(DWORD state, DWORD exitCode, DWORD waitHint);

    static bool StartWorkers(bool allowAnyClient);
    static void StopWorkers();
};

} // namespace gluk
