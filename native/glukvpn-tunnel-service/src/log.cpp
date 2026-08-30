#include "log.h"

#include <windows.h>

#include <mutex>
#include <regex>
#include <string>

namespace gluk {
namespace {

std::mutex g_mutex;
HANDLE g_file = INVALID_HANDLE_VALUE;
std::wstring g_path;

std::string Timestamp() {
    SYSTEMTIME st{};
    GetLocalTime(&st);
    char buf[32];
    wsprintfA(buf, "%04d-%02d-%02d %02d:%02d:%02d.%03d", st.wYear, st.wMonth,
              st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    return buf;
}

// Rotates <name>.log to <name>.1.log once it grows past the cap.
void RotateIfNeeded() {
    if (g_file == INVALID_HANDLE_VALUE) return;

    LARGE_INTEGER size{};
    if (!GetFileSizeEx(g_file, &size)) return;
    if (static_cast<unsigned long long>(size.QuadPart) < Log::kMaxLogBytes) return;

    CloseHandle(g_file);
    g_file = INVALID_HANDLE_VALUE;

    std::wstring previous = g_path + L".1";
    DeleteFileW(previous.c_str());
    MoveFileW(g_path.c_str(), previous.c_str());

    g_file = CreateFileW(g_path.c_str(), FILE_APPEND_DATA,
                         FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                         OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
}

void WriteLine(const char* level, const std::string& message) {
    std::lock_guard<std::mutex> lock(g_mutex);

    const std::string line =
        Timestamp() + "  " + level + "  " + Log::Scrub(message) + "\r\n";

    // Always mirror to the debugger so --console runs are useful.
    OutputDebugStringA(line.c_str());

    if (g_file == INVALID_HANDLE_VALUE) return;

    RotateIfNeeded();
    if (g_file == INVALID_HANDLE_VALUE) return;

    DWORD written = 0;
    WriteFile(g_file, line.data(), static_cast<DWORD>(line.size()), &written,
              nullptr);
}

} // namespace

void Log::Init(const std::wstring& path) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_file != INVALID_HANDLE_VALUE) return;

    g_path = path;
    g_file = CreateFileW(path.c_str(), FILE_APPEND_DATA,
                         FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                         OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
}

void Log::Info(const std::string& message) { WriteLine("INFO ", message); }
void Log::Warn(const std::string& message) { WriteLine("WARN ", message); }
void Log::Error(const std::string& message) { WriteLine("ERROR", message); }

void Log::LastError(const std::string& message, unsigned long code) {
    LPSTR buffer = nullptr;
    const DWORD length = FormatMessageA(
        FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
            FORMAT_MESSAGE_IGNORE_INSERTS,
        nullptr, code, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
        reinterpret_cast<LPSTR>(&buffer), 0, nullptr);

    std::string detail;
    if (length && buffer) {
        detail.assign(buffer, length);
        while (!detail.empty() &&
               (detail.back() == '\r' || detail.back() == '\n' ||
                detail.back() == ' ')) {
            detail.pop_back();
        }
    }
    if (buffer) LocalFree(buffer);

    char code_text[24];
    wsprintfA(code_text, " (0x%08lx)", code);

    WriteLine("ERROR", message + ": " + detail + code_text);
}

void Log::Shutdown() {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_file != INVALID_HANDLE_VALUE) {
        CloseHandle(g_file);
        g_file = INVALID_HANDLE_VALUE;
    }
}

std::string Log::Scrub(const std::string& text) {
    // WireGuard keys are 43 base64 characters plus '='. Redact anything that
    // matches so a config dump can never leak private material, and redact the
    // PrivateKey line wholesale for good measure.
    static const std::regex kKeyLine(
        R"((PrivateKey|PresharedKey)\s*=\s*[^\r\n]*)",
        std::regex::icase);
    static const std::regex kBareKey(
        R"(\b[A-Za-z0-9+/]{42}[A-Za-z0-9+/=]=\b)");

    std::string out = std::regex_replace(text, kKeyLine, "$1 = <redacted>");
    out = std::regex_replace(out, kBareKey, "<redacted-key>");
    return out;
}

} // namespace gluk
