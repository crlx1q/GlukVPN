#include "pipe_server.h"

#include <windows.h>

#include <sddl.h>
#include <psapi.h>

#include <algorithm>
#include <vector>

#include "appdata.h"
#include "json.h"
#include "log.h"
#include "split_tunnel.h"
#include "tunnel.h"

namespace gluk {
namespace {

// Deny anonymous and network logons outright, allow SYSTEM and Administrators
// full control, and give interactive users read/write so an unelevated UI can
// talk to the service without another UAC prompt.
constexpr wchar_t kPipeSddl[] =
    L"D:P(D;;GA;;;AN)(D;;GA;;;NU)(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;IU)";

std::string ErrorReply(const std::string& code, const std::string& message) {
    json::Object error;
    error.emplace("code", json::Value(code));
    error.emplace("message", json::Value(message));

    json::Object root;
    root.emplace("ok", json::Value(false));
    root.emplace("error", json::Value(std::move(error)));
    return json::Write(json::Value(std::move(root)));
}

void FillStatus(json::Object& root, const TunnelStatus& status) {
    root.emplace("state", json::Value(std::string(TunnelStateName(status.state))));
    root.emplace("sessionId", json::Value(status.sessionId));
    root.emplace("adapter", json::Value(status.adapter));
    root.emplace("luid",
                 json::Value(static_cast<double>(status.luid)));
    root.emplace("vpnIp", json::Value(status.vpnIp));
    root.emplace("rxBytes", json::Value(static_cast<double>(status.rxBytes)));
    root.emplace("txBytes", json::Value(static_cast<double>(status.txBytes)));
    root.emplace("lastHandshakeUnix",
                 json::Value(static_cast<double>(status.lastHandshakeUnix)));
    root.emplace("since", json::Value(static_cast<double>(status.sinceUnix)));
    root.emplace("killSwitch", json::Value(status.killSwitchActive));
    root.emplace("splitEngine", json::Value(status.splitEngine));

    if (!status.errorCode.empty()) {
        root.emplace("errorCode", json::Value(status.errorCode));
        root.emplace("errorMessage", json::Value(status.errorMessage));
    }
}

std::string LowerCopy(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c) { return static_cast<char>(::tolower(c)); });
    return value;
}

} // namespace

PipeServer& PipeServer::Instance() {
    static PipeServer instance;
    return instance;
}

HANDLE PipeServer::CreatePipeInstance() {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            kPipeSddl, SDDL_REVISION_1, &descriptor, nullptr)) {
        Log::LastError("Pipe SDDL conversion failed", GetLastError());
        return INVALID_HANDLE_VALUE;
    }

    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    attributes.lpSecurityDescriptor = descriptor;
    attributes.bInheritHandle = FALSE;

    const std::wstring full = L"\\\\.\\pipe\\" + pipeName_;

    HANDLE pipe = CreateNamedPipeW(
        full.c_str(),
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_BYTE | PIPE_WAIT |
            PIPE_REJECT_REMOTE_CLIENTS,
        kMaxConcurrentClients, kBufferSize, kBufferSize, kClientTimeoutMs,
        &attributes);

    if (pipe == INVALID_HANDLE_VALUE) {
        Log::LastError("CreateNamedPipe failed", GetLastError());
    }

    LocalFree(descriptor);
    return pipe;
}

bool PipeServer::VerifyClient(HANDLE pipe) {
    if (allowAnyClient_) return true;

    ULONG processId = 0;
    if (!GetNamedPipeClientProcessId(pipe, &processId)) {
        Log::LastError("GetNamedPipeClientProcessId failed", GetLastError());
        return false;
    }

    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                 processId);
    if (!process) {
        Log::LastError("OpenProcess(client) failed", GetLastError());
        return false;
    }

    wchar_t path[MAX_PATH * 2] = {};
    DWORD size = static_cast<DWORD>(std::size(path));
    const BOOL ok = QueryFullProcessImageNameW(process, 0, path, &size);
    CloseHandle(process);

    if (!ok) {
        Log::LastError("QueryFullProcessImageName failed", GetLastError());
        return false;
    }

    // Path-based check for now. Once the binaries are Authenticode signed,
    // replace this with WinVerifyTrust plus a publisher-name comparison; see
    // docs/desktop/RELEASE-CHECKLIST.md.
    const std::string client = LowerCopy(AppData::ToUtf8(path));
    const std::string installRoot =
        LowerCopy(AppData::ToUtf8(AppData::ExecutableDir()));

    // The UI lives one directory above the service (\GlukVPN\glukvpn.exe vs
    // \GlukVPN\service\GlukVpnTunnelService.exe).
    std::string parent = installRoot;
    const size_t slash = parent.find_last_of('\\');
    if (slash != std::string::npos) parent = parent.substr(0, slash);

    const bool insideInstall =
        client.rfind(installRoot, 0) == 0 || client.rfind(parent, 0) == 0;

    if (!insideInstall) {
        Log::Warn("Rejected pipe client outside the install directory: " +
                  client);
        return false;
    }
    return true;
}

std::string PipeServer::Dispatch(const std::string& line) {
    json::Value request;
    if (!json::Parse(line, request) || request.type() != json::Type::Object) {
        return ErrorReply("bad_request", "Malformed request");
    }

    const std::string op = request["op"].asString();
    if (op.empty()) {
        return ErrorReply("bad_request", "Missing operation");
    }

    // Every request must carry the protocol version so a stale UI cannot
    // silently misinterpret a newer service.
    const int version = static_cast<int>(request["v"].asNumber());
    if (version != kProtocolVersion) {
        return ErrorReply("protocol_mismatch",
                          "The GlukVPN service and app versions do not match");
    }

    Tunnel& tunnel = Tunnel::Instance();

    if (op == "hello") {
        json::Object root;
        root.emplace("ok", json::Value(true));
        root.emplace("serviceVersion", json::Value(std::string(kServiceVersion)));
        root.emplace("protocolVersion",
                     json::Value(static_cast<double>(kProtocolVersion)));
        root.emplace("driver", json::Value(tunnel.DriverDescription()));
        root.emplace("driverReady", json::Value(tunnel.DriverReady()));
        root.emplace("splitEngine",
                     json::Value(SplitTunnel::Instance().EngineName()));
        root.emplace("perAppRedirect",
                     json::Value(SplitTunnel::Instance().SupportsPerAppRedirect()));
        FillStatus(root, tunnel.Status());
        return json::Write(json::Value(std::move(root)));
    }

    if (op == "status") {
        json::Object root;
        root.emplace("ok", json::Value(true));
        FillStatus(root, tunnel.Status());
        return json::Write(json::Value(std::move(root)));
    }

    if (op == "up") {
        UpRequest up;
        up.wgConf = request["conf"].asString();
        up.sessionId = request["sessionId"].asString();
        up.killSwitch = request["killSwitch"].asBool();
        up.dns = request["dns"].stringList();
        up.mtu = static_cast<int>(request["mtu"].asNumber());
        up.splitMode = SplitModeFromString(request["splitMode"].asString());
        up.splitApps = request["splitApps"].stringList();
        up.bypassRoutes = request["bypassRoutes"].stringList();
        up.endpointIps = request["endpointIps"].stringList();

        // ROUND 24: the sing-box outbound. Present means "run sing-box";
        // absent means the WireGuard worker, so a client that predates the
        // engine change keeps working against a newer service.
        const json::Value& gateway = request["gateway"];
        if (gateway.isObject()) {
            up.gateway.type = gateway["type"].asString();
            up.gateway.host = gateway["host"].asString();
            up.gateway.port = static_cast<int>(gateway["port"].asNumber());
            up.gateway.uuid = gateway["uuid"].asString();
            up.gateway.sni = gateway["sni"].asString();
            up.gateway.flow = gateway["flow"].asString();
            up.gateway.insecure = gateway["insecure"].asBool();
        }

        const std::string adapter = request["adapter"].asString();
        if (!adapter.empty()) up.adapter = AppData::ToWide(adapter);

        // A sing-box session needs no WireGuard configuration at all, so the
        // request is complete as soon as either of the two is present.
        if (up.wgConf.empty() && !up.gateway.usable()) {
            return ErrorReply("bad_request", "Missing tunnel configuration");
        }

        std::string code, message;
        if (!tunnel.Up(up, code, message)) {
            return ErrorReply(code.empty() ? "tunnel_error" : code, message);
        }

        json::Object root;
        root.emplace("ok", json::Value(true));
        FillStatus(root, tunnel.Status());
        return json::Write(json::Value(std::move(root)));
    }

    if (op == "down") {
        tunnel.Down();

        json::Object root;
        root.emplace("ok", json::Value(true));
        FillStatus(root, tunnel.Status());
        return json::Write(json::Value(std::move(root)));
    }

    if (op == "set-split") {
        const SplitMode mode =
            SplitModeFromString(request["mode"].asString());
        const std::vector<std::string> apps = request["apps"].stringList();
        const std::vector<std::string> routes =
            request["bypassRoutes"].stringList();

        std::string code, message;
        if (!tunnel.SetSplit(mode, apps, routes, code, message)) {
            return ErrorReply(code.empty() ? "split_failed" : code, message);
        }

        json::Object root;
        root.emplace("ok", json::Value(true));
        FillStatus(root, tunnel.Status());
        return json::Write(json::Value(std::move(root)));
    }

    return ErrorReply("bad_request", "Unknown operation: " + op);
}

void PipeServer::HandleClient(HANDLE pipe) {
    if (!VerifyClient(pipe)) {
        const std::string reply =
            ErrorReply("client_rejected",
                       "This process is not allowed to control GlukVPN") +
            "\n";
        DWORD written = 0;
        WriteFile(pipe, reply.data(), static_cast<DWORD>(reply.size()),
                  &written, nullptr);
        FlushFileBuffers(pipe);
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
        return;
    }

    std::string buffer;
    std::vector<char> chunk(kBufferSize);

    while (running_) {
        DWORD read = 0;
        if (!ReadFile(pipe, chunk.data(), static_cast<DWORD>(chunk.size()),
                      &read, nullptr) ||
            read == 0) {
            break;
        }

        buffer.append(chunk.data(), read);

        if (buffer.size() > kMaxMessageBytes) {
            const std::string reply =
                ErrorReply("bad_request", "Request too large") + "\n";
            DWORD written = 0;
            WriteFile(pipe, reply.data(), static_cast<DWORD>(reply.size()),
                      &written, nullptr);
            break;
        }

        // Process every complete newline-terminated message in the buffer.
        size_t newline = buffer.find('\n');
        while (newline != std::string::npos) {
            std::string line = buffer.substr(0, newline);
            buffer.erase(0, newline + 1);

            if (!line.empty() && line.back() == '\r') line.pop_back();

            if (!line.empty()) {
                std::string reply;
                try {
                    reply = Dispatch(line);
                } catch (const std::exception& e) {
                    Log::Error(std::string("Unhandled dispatch error: ") +
                               e.what());
                    reply = ErrorReply("internal_error",
                                       "The service hit an internal error");
                } catch (...) {
                    reply = ErrorReply("internal_error",
                                       "The service hit an internal error");
                }

                reply += "\n";
                DWORD written = 0;
                if (!WriteFile(pipe, reply.data(),
                               static_cast<DWORD>(reply.size()), &written,
                               nullptr)) {
                    break;
                }
                FlushFileBuffers(pipe);
            }

            newline = buffer.find('\n');
        }
    }

    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
}

void PipeServer::AcceptLoop() {
    while (running_) {
        HANDLE pipe = CreatePipeInstance();
        if (pipe == INVALID_HANDLE_VALUE) {
            // Back off so a persistent failure does not spin the CPU.
            if (WaitForSingleObject(stopEvent_, 1000) == WAIT_OBJECT_0) break;
            continue;
        }

        OVERLAPPED overlapped{};
        overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);

        BOOL connected = ConnectNamedPipe(pipe, &overlapped);
        DWORD error = GetLastError();

        if (!connected && error == ERROR_IO_PENDING) {
            HANDLE waits[2] = {overlapped.hEvent, stopEvent_};
            const DWORD signalled =
                WaitForMultipleObjects(2, waits, FALSE, INFINITE);

            if (signalled == WAIT_OBJECT_0 + 1) {
                // Stopping.
                CancelIo(pipe);
                CloseHandle(overlapped.hEvent);
                CloseHandle(pipe);
                break;
            }

            DWORD transferred = 0;
            connected =
                GetOverlappedResult(pipe, &overlapped, &transferred, FALSE);
            error = GetLastError();
        }

        CloseHandle(overlapped.hEvent);

        if (!connected && error != ERROR_PIPE_CONNECTED) {
            CloseHandle(pipe);
            continue;
        }

        // One thread per client. There are at most a couple of them (the main
        // window and the tray panel share a single connection).
        std::thread(&PipeServer::HandleClient, this, pipe).detach();
    }
}

bool PipeServer::Start(const std::wstring& pipeName) {
    if (running_) return true;

    pipeName_ = pipeName;
    stopEvent_ = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!stopEvent_) {
        Log::LastError("CreateEvent(pipe stop) failed", GetLastError());
        return false;
    }

    running_ = true;
    acceptThread_ = std::thread(&PipeServer::AcceptLoop, this);

    Log::Info("Control pipe listening on \\\\.\\pipe\\" +
              AppData::ToUtf8(pipeName_));
    return true;
}

void PipeServer::Stop() {
    if (!running_) return;

    running_ = false;
    if (stopEvent_) SetEvent(stopEvent_);

    // Nudge the accept loop out of ConnectNamedPipe if it is still waiting.
    const std::wstring full = L"\\\\.\\pipe\\" + pipeName_;
    HANDLE nudge = CreateFileW(full.c_str(), GENERIC_READ, 0, nullptr,
                               OPEN_EXISTING, 0, nullptr);
    if (nudge != INVALID_HANDLE_VALUE) CloseHandle(nudge);

    if (acceptThread_.joinable()) acceptThread_.join();

    if (stopEvent_) {
        CloseHandle(stopEvent_);
        stopEvent_ = nullptr;
    }
    Log::Info("Control pipe stopped");
}

} // namespace gluk
