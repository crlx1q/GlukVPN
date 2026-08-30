#include "service.h"

#include <windows.h>

#include <shlwapi.h>

#include "appdata.h"
#include "log.h"
#include "pipe_server.h"
#include "tunnel.h"
#include "wfp.h"

namespace gluk {
namespace {

SERVICE_STATUS_HANDLE g_statusHandle = nullptr;
SERVICE_STATUS g_status{};
HANDLE g_stopEvent = nullptr;

std::wstring FormatError(DWORD code) {
    LPWSTR buffer = nullptr;
    FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                       FORMAT_MESSAGE_IGNORE_INSERTS,
                   nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                   reinterpret_cast<LPWSTR>(&buffer), 0, nullptr);
    std::wstring text = buffer ? buffer : L"unknown error";
    if (buffer) LocalFree(buffer);
    while (!text.empty() && (text.back() == L'\r' || text.back() == L'\n')) {
        text.pop_back();
    }
    return text;
}

} // namespace

bool Service::IsElevated() {
    BOOL isAdmin = FALSE;
    PSID adminGroup = nullptr;
    SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY;

    if (AllocateAndInitializeSid(&authority, 2, SECURITY_BUILTIN_DOMAIN_RID,
                                 DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0,
                                 &adminGroup)) {
        CheckTokenMembership(nullptr, adminGroup, &isAdmin);
        FreeSid(adminGroup);
    }
    return isAdmin == TRUE;
}

bool Service::Install(std::wstring& error) {
    if (!IsElevated()) {
        error = L"Administrator rights are required to install the service.";
        return false;
    }

    SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_ALL_ACCESS);
    if (!manager) {
        error = L"Cannot open the service manager: " +
                FormatError(GetLastError());
        return false;
    }

    // Quote the path: Program Files contains a space, and an unquoted binary
    // path is a classic privilege-escalation bug.
    const std::wstring command =
        L"\"" + AppData::ExecutablePath() + L"\" --run";

    SC_HANDLE service = CreateServiceW(
        manager, kServiceName, kServiceDisplayName, SERVICE_ALL_ACCESS,
        SERVICE_WIN32_OWN_PROCESS, SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
        command.c_str(), nullptr, nullptr,
        // BFE hosts the Windows Filtering Platform; without it the kill
        // switch cannot be armed.
        L"BFE\0", nullptr, nullptr);

    if (!service) {
        const DWORD code = GetLastError();
        if (code == ERROR_SERVICE_EXISTS) {
            // Reinstall over an existing copy: just refresh the binary path.
            service = OpenServiceW(manager, kServiceName, SERVICE_ALL_ACCESS);
            if (service) {
                ChangeServiceConfigW(service, SERVICE_WIN32_OWN_PROCESS,
                                     SERVICE_AUTO_START, SERVICE_ERROR_NORMAL,
                                     command.c_str(), nullptr, nullptr,
                                     L"BFE\0", nullptr, nullptr,
                                     kServiceDisplayName);
            }
        } else {
            CloseServiceHandle(manager);
            error = L"Cannot create the service: " + FormatError(code);
            return false;
        }
    }

    if (service) {
        SERVICE_DESCRIPTIONW description{};
        description.lpDescription = const_cast<LPWSTR>(kServiceDescription);
        ChangeServiceConfig2W(service, SERVICE_CONFIG_DESCRIPTION,
                              &description);

        // Restart automatically if the service ever crashes, so an active
        // tunnel comes back without the user noticing.
        SC_ACTION actions[3] = {};
        actions[0].Type = SC_ACTION_RESTART;
        actions[0].Delay = 5000;
        actions[1].Type = SC_ACTION_RESTART;
        actions[1].Delay = 10000;
        actions[2].Type = SC_ACTION_RESTART;
        actions[2].Delay = 30000;

        SERVICE_FAILURE_ACTIONSW failure{};
        failure.dwResetPeriod = 86400;
        failure.cActions = 3;
        failure.lpsaActions = actions;
        ChangeServiceConfig2W(service, SERVICE_CONFIG_FAILURE_ACTIONS,
                              &failure);

        CloseServiceHandle(service);
    }

    CloseServiceHandle(manager);
    AppData::EnsureDirectories();
    return true;
}

bool Service::Uninstall(std::wstring& error) {
    if (!IsElevated()) {
        error = L"Administrator rights are required to remove the service.";
        return false;
    }

    SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_ALL_ACCESS);
    if (!manager) {
        error = L"Cannot open the service manager: " +
                FormatError(GetLastError());
        return false;
    }

    SC_HANDLE service = OpenServiceW(manager, kServiceName, SERVICE_ALL_ACCESS);
    if (!service) {
        CloseServiceHandle(manager);
        // Already gone is a success for an uninstaller.
        return true;
    }

    SERVICE_STATUS status{};
    ControlService(service, SERVICE_CONTROL_STOP, &status);

    // Give the tunnel a moment to unwind before deleting the registration.
    for (int i = 0; i < 20; ++i) {
        if (!QueryServiceStatus(service, &status)) break;
        if (status.dwCurrentState == SERVICE_STOPPED) break;
        Sleep(250);
    }

    const BOOL deleted = DeleteService(service);
    CloseServiceHandle(service);
    CloseServiceHandle(manager);

    if (!deleted) {
        const DWORD code = GetLastError();
        if (code != ERROR_SERVICE_MARKED_FOR_DELETE) {
            error = L"Cannot remove the service: " + FormatError(code);
            return false;
        }
    }
    return true;
}

bool Service::Start(std::wstring& error) {
    SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!manager) {
        error = L"Cannot open the service manager: " +
                FormatError(GetLastError());
        return false;
    }

    SC_HANDLE service =
        OpenServiceW(manager, kServiceName, SERVICE_START | SERVICE_QUERY_STATUS);
    if (!service) {
        CloseServiceHandle(manager);
        error = L"The GlukVPN service is not installed.";
        return false;
    }

    bool ok = StartServiceW(service, 0, nullptr) == TRUE;
    if (!ok && GetLastError() == ERROR_SERVICE_ALREADY_RUNNING) ok = true;
    if (!ok) error = L"Cannot start the service: " + FormatError(GetLastError());

    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    return ok;
}

void Service::ReportStatus(DWORD state, DWORD exitCode, DWORD waitHint) {
    static DWORD checkPoint = 1;

    g_status.dwCurrentState = state;
    g_status.dwWin32ExitCode = exitCode;
    g_status.dwWaitHint = waitHint;
    g_status.dwServiceType = SERVICE_WIN32_OWN_PROCESS;

    g_status.dwControlsAccepted =
        state == SERVICE_START_PENDING
            ? 0
            : SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN |
                  SERVICE_ACCEPT_SESSIONCHANGE;

    g_status.dwCheckPoint =
        (state == SERVICE_RUNNING || state == SERVICE_STOPPED) ? 0
                                                               : checkPoint++;

    if (g_statusHandle) SetServiceStatus(g_statusHandle, &g_status);
}

DWORD WINAPI Service::HandlerEx(DWORD control, DWORD eventType,
                                LPVOID eventData, LPVOID context) {
    switch (control) {
        case SERVICE_CONTROL_STOP:
        case SERVICE_CONTROL_SHUTDOWN:
            ReportStatus(SERVICE_STOP_PENDING, NO_ERROR, 8000);
            if (g_stopEvent) SetEvent(g_stopEvent);
            return NO_ERROR;

        case SERVICE_CONTROL_INTERROGATE:
            ReportStatus(g_status.dwCurrentState, NO_ERROR, 0);
            return NO_ERROR;

        default:
            return ERROR_CALL_NOT_IMPLEMENTED;
    }
}

bool Service::StartWorkers(bool allowAnyClient) {
    AppData::EnsureDirectories();
    Log::Init(AppData::ServiceLogPath());
    Log::Info(std::string("GlukVPN tunnel service ") + kServiceVersion +
              " starting");

    PipeServer::Instance().SetAllowAnyClient(allowAnyClient);
    if (!PipeServer::Instance().Start(kPipeName)) {
        Log::Error("Cannot start the control pipe");
        return false;
    }

    // The driver may legitimately be absent right after installation; the
    // service still runs so it can report driver_unavailable to the UI.
    if (!Tunnel::Instance().DriverReady()) {
        Log::Warn("WireGuard driver files are not available yet");
    }
    return true;
}

void Service::StopWorkers() {
    Log::Info("Service stopping");
    PipeServer::Instance().Stop();
    Tunnel::Instance().Shutdown();
    Wfp::Instance().Close();
    Log::Info("Service stopped");
    Log::Shutdown();
}

void WINAPI Service::ServiceMain(DWORD argc, LPWSTR* argv) {
    g_statusHandle =
        RegisterServiceCtrlHandlerExW(kServiceName, HandlerEx, nullptr);
    if (!g_statusHandle) return;

    ReportStatus(SERVICE_START_PENDING, NO_ERROR, 5000);

    g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_stopEvent) {
        ReportStatus(SERVICE_STOPPED, GetLastError(), 0);
        return;
    }

    if (!StartWorkers(false)) {
        ReportStatus(SERVICE_STOPPED, ERROR_SERVICE_SPECIFIC_ERROR, 0);
        return;
    }

    ReportStatus(SERVICE_RUNNING, NO_ERROR, 0);
    WaitForSingleObject(g_stopEvent, INFINITE);

    StopWorkers();
    CloseHandle(g_stopEvent);
    g_stopEvent = nullptr;

    ReportStatus(SERVICE_STOPPED, NO_ERROR, 0);
}

int Service::RunAsService() {
    SERVICE_TABLE_ENTRYW table[] = {
        {const_cast<LPWSTR>(kServiceName), ServiceMain},
        {nullptr, nullptr}};

    if (!StartServiceCtrlDispatcherW(table)) {
        // Started outside the SCM; nothing useful to do.
        return static_cast<int>(GetLastError());
    }
    return 0;
}

int Service::RunInConsole(bool allowAnyClient) {
    g_stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);

    SetConsoleCtrlHandler(
        [](DWORD) -> BOOL {
            if (g_stopEvent) SetEvent(g_stopEvent);
            return TRUE;
        },
        TRUE);

    if (!StartWorkers(allowAnyClient)) return 1;

    WaitForSingleObject(g_stopEvent, INFINITE);
    StopWorkers();

    CloseHandle(g_stopEvent);
    g_stopEvent = nullptr;
    return 0;
}

} // namespace gluk
