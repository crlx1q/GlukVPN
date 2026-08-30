// Filesystem locations and secret handling for the privileged service.
//
// The service runs as LocalSystem, so it cannot use the user's %APPDATA%.
// Everything it owns lives under %PROGRAMDATA%\GlukVPN with an ACL that only
// grants SYSTEM and Administrators access.

#pragma once

#include <string>
#include <vector>

namespace gluk {

class AppData {
public:
    // %PROGRAMDATA%\GlukVPN
    static std::wstring Root();

    // %PROGRAMDATA%\GlukVPN\run  — live tunnel configuration.
    static std::wstring RunDir();

    // %PROGRAMDATA%\GlukVPN\logs
    static std::wstring LogsDir();

    static std::wstring ServiceLogPath();

    // Full path of the .conf handed to tunnel.dll for a given adapter.
    static std::wstring TunnelConfigPath(const std::wstring& adapter);

    // Creates the directory tree and applies the restrictive ACL.
    static bool EnsureDirectories();

    // Writes a WireGuard configuration to disk.
    //
    // The plaintext .conf must exist on disk because tunnel.dll takes a file
    // path, but it is created with an explicit DACL, is written only inside
    // RunDir(), and is shredded by ShredFile() as soon as the tunnel stops.
    static bool WriteConfig(const std::wstring& path, const std::string& utf8);

    // Overwrites the file contents before deleting so the key material does
    // not linger in free clusters.
    static void ShredFile(const std::wstring& path);

    // DPAPI machine-scope helpers, used to keep a copy of the active config
    // across a service restart without leaving plaintext behind.
    static bool ProtectToFile(const std::wstring& path, const std::string& plain);
    static bool UnprotectFromFile(const std::wstring& path, std::string& plain);

    // Path of the running executable and its directory.
    static std::wstring ExecutablePath();
    static std::wstring ExecutableDir();

    static std::string ToUtf8(const std::wstring& wide);
    static std::wstring ToWide(const std::string& utf8);

private:
    static bool ApplyRestrictiveAcl(const std::wstring& path);
};

} // namespace gluk
