// GlukVpnTunnelService.exe — the privileged half of GlukVPN for Windows.
//
// Verbs:
//   --install             register the service with the SCM (needs admin)
//   --uninstall           stop and remove the service (needs admin)
//   --start               ask the SCM to start the service
//   --run                 run under the SCM (used by the service itself)
//   --console             run in the foreground for debugging
//   --allow-any-client    with --console, skip client verification
//   --version             print the service version
//
// Built with /SUBSYSTEM:WINDOWS so --install from the installer never flashes
// a console window. Diagnostics go to the service log and the debugger.

#include <windows.h>

#include <shellapi.h>

#include <string>
#include <vector>

#include "appdata.h"
#include "log.h"
#include "pipe_server.h"
#include "service.h"

namespace {

bool HasFlag(const std::vector<std::wstring>& args, const wchar_t* flag) {
    for (const std::wstring& arg : args) {
        if (_wcsicmp(arg.c_str(), flag) == 0) return true;
    }
    return false;
}

// Only used for the interactive verbs; the service itself never shows UI.
void ShowMessage(const std::wstring& text, bool error) {
    MessageBoxW(nullptr, text.c_str(), L"GlukVPN Tunnel Service",
                MB_OK | (error ? MB_ICONERROR : MB_ICONINFORMATION));
}

std::vector<std::wstring> ReadCommandLine() {
    std::vector<std::wstring> args;

    int count = 0;
    LPWSTR* raw = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!raw) return args;

    for (int i = 1; i < count; ++i) args.emplace_back(raw[i]);
    LocalFree(raw);
    return args;
}

} // namespace

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    const std::vector<std::wstring> args = ReadCommandLine();

    if (HasFlag(args, L"--version")) {
        ShowMessage(L"GlukVPN Tunnel Service " +
                        gluk::AppData::ToWide(gluk::kServiceVersion),
                    false);
        return 0;
    }

    if (HasFlag(args, L"--install")) {
        std::wstring error;
        if (!gluk::Service::Install(error)) {
            ShowMessage(error, true);
            return 1;
        }
        // Start immediately so the first Connect does not have to wait for a
        // reboot.
        std::wstring startError;
        gluk::Service::Start(startError);
        return 0;
    }

    if (HasFlag(args, L"--uninstall")) {
        std::wstring error;
        if (!gluk::Service::Uninstall(error)) {
            ShowMessage(error, true);
            return 1;
        }
        return 0;
    }

    if (HasFlag(args, L"--start")) {
        std::wstring error;
        if (!gluk::Service::Start(error)) {
            ShowMessage(error, true);
            return 1;
        }
        return 0;
    }

    if (HasFlag(args, L"--console")) {
        // Attach a console so the developer can see what is happening.
        if (!AttachConsole(ATTACH_PARENT_PROCESS)) AllocConsole();

        const bool allowAnyClient = HasFlag(args, L"--allow-any-client");
        return gluk::Service::RunInConsole(allowAnyClient);
    }

    // Default: assume the SCM launched us.
    return gluk::Service::RunAsService();
}
