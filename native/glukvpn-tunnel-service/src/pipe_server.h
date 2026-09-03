// Named-pipe control channel between the Flutter UI and the service.
//
// Wire format: one JSON object per line, UTF-8, newline terminated.
//
//   -> {"op":"up","v":1,"conf":"...","sessionId":"..."}
//   <- {"ok":true,"state":"starting", ...}
//   <- {"ok":false,"error":{"code":"driver_unavailable","message":"..."}}
//
// The pipe is created with an explicit DACL: SYSTEM and Administrators get
// full control, interactive users get read/write, and anonymous and network
// logons are denied outright. PIPE_REJECT_REMOTE_CLIENTS blocks SMB access.

#pragma once

#include <windows.h>

#include <atomic>
#include <string>
#include <thread>
#include <vector>

namespace gluk {

// Bumped whenever the message contract changes incompatibly. The client
// refuses to talk to a service with a different value.
//
// 2: "up" carries a gateway object, which selects the sing-box engine. Must
//    stay in lockstep with kTunnelProtocolVersion in
//    flutter-client/lib/desktop/services/tunnel_ipc.dart.
constexpr int kProtocolVersion = 2;

#ifndef GLUK_SERVICE_VERSION
#define GLUK_SERVICE_VERSION "1.0.0"
#endif
constexpr char kServiceVersion[] = GLUK_SERVICE_VERSION;

constexpr size_t kMaxMessageBytes = 256 * 1024;
constexpr DWORD kBufferSize = 64 * 1024;
constexpr int kMaxConcurrentClients = 8;
constexpr DWORD kClientTimeoutMs = 15000;

class PipeServer {
public:
    static PipeServer& Instance();

    // Starts the accept loop on a background thread.
    bool Start(const std::wstring& pipeName);

    // Signals the accept loop and joins it.
    void Stop();

    // Development escape hatch: skip client verification. Enabled only by the
    // --allow-any-client flag, which the installer never passes.
    void SetAllowAnyClient(bool value) { allowAnyClient_ = value; }

private:
    PipeServer() = default;

    void AcceptLoop();
    void HandleClient(HANDLE pipe);

    // Dispatches one request line and returns the reply line.
    std::string Dispatch(const std::string& line);

    // Checks that the connected process is a GlukVPN binary.
    bool VerifyClient(HANDLE pipe);

    HANDLE CreatePipeInstance();

    std::wstring pipeName_;
    std::thread acceptThread_;
    std::atomic<bool> running_{false};
    std::atomic<bool> allowAnyClient_{false};
    HANDLE stopEvent_ = nullptr;
};

} // namespace gluk
