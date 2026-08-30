// Rotating file log for the privileged service.
//
// Everything the service does happens without a UI, so the log is the only
// diagnostic surface. Private keys are scrubbed before anything is written.

#pragma once

#include <string>

namespace gluk {

class Log {
public:
    // Opens (or creates) the log file. Safe to call more than once.
    static void Init(const std::wstring& path);

    static void Info(const std::string& message);
    static void Warn(const std::string& message);
    static void Error(const std::string& message);

    // Appends ": <system error text> (code)" to the message.
    static void LastError(const std::string& message, unsigned long code);

    static void Shutdown();

    // Removes anything that looks like a WireGuard key so a shared log file
    // never leaks tunnel material.
    static std::string Scrub(const std::string& text);

    // Rotate once the file passes 2 MiB.
    static constexpr unsigned long long kMaxLogBytes = 2ull * 1024 * 1024;
};

} // namespace gluk
