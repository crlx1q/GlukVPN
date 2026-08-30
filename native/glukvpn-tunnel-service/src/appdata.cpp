#include "appdata.h"

#include <windows.h>

#include <aclapi.h>
#include <sddl.h>
#include <shlobj.h>
#include <wincrypt.h>

#include <vector>

#include "log.h"

namespace gluk {
namespace {

constexpr wchar_t kFolderName[] = L"GlukVPN";

// SYSTEM and Administrators get full control; nobody else is on the list.
// Protected (P) so the inherited Users ACE from %PROGRAMDATA% is dropped.
constexpr wchar_t kRunSddl[] =
    L"D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

std::wstring JoinPath(const std::wstring& base, const std::wstring& leaf) {
    if (base.empty()) return leaf;
    if (base.back() == L'\\') return base + leaf;
    return base + L"\\" + leaf;
}

bool CreateDirectoryIfMissing(const std::wstring& path) {
    if (CreateDirectoryW(path.c_str(), nullptr)) return true;
    return GetLastError() == ERROR_ALREADY_EXISTS;
}

} // namespace

std::wstring AppData::Root() {
    PWSTR raw = nullptr;
    std::wstring base;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_ProgramData, 0, nullptr, &raw)) &&
        raw) {
        base.assign(raw);
    }
    if (raw) CoTaskMemFree(raw);

    if (base.empty()) {
        wchar_t buffer[MAX_PATH] = {};
        const DWORD length =
            GetEnvironmentVariableW(L"ProgramData", buffer, MAX_PATH);
        base.assign(buffer, length);
    }
    if (base.empty()) base = L"C:\\ProgramData";

    return JoinPath(base, kFolderName);
}

std::wstring AppData::RunDir() { return JoinPath(Root(), L"run"); }
std::wstring AppData::LogsDir() { return JoinPath(Root(), L"logs"); }

std::wstring AppData::ServiceLogPath() {
    return JoinPath(LogsDir(), L"service.log");
}

std::wstring AppData::TunnelConfigPath(const std::wstring& adapter) {
    return JoinPath(RunDir(), adapter + L".conf");
}

bool AppData::EnsureDirectories() {
    const std::wstring root = Root();
    if (!CreateDirectoryIfMissing(root)) {
        Log::LastError("CreateDirectory(root) failed", GetLastError());
        return false;
    }

    const std::wstring run = RunDir();
    const std::wstring logs = LogsDir();
    CreateDirectoryIfMissing(run);
    CreateDirectoryIfMissing(logs);

    // The run directory holds live key material, so it gets the tight ACL.
    ApplyRestrictiveAcl(run);
    return true;
}

bool AppData::ApplyRestrictiveAcl(const std::wstring& path) {
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
            kRunSddl, SDDL_REVISION_1, &descriptor, nullptr)) {
        Log::LastError("ConvertStringSecurityDescriptor failed", GetLastError());
        return false;
    }

    BOOL present = FALSE;
    BOOL defaulted = FALSE;
    PACL acl = nullptr;
    bool ok = false;

    if (GetSecurityDescriptorDacl(descriptor, &present, &acl, &defaulted) &&
        present) {
        const DWORD result = SetNamedSecurityInfoW(
            const_cast<LPWSTR>(path.c_str()), SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            nullptr, nullptr, acl, nullptr);
        ok = result == ERROR_SUCCESS;
        if (!ok) Log::LastError("SetNamedSecurityInfo failed", result);
    }

    LocalFree(descriptor);
    return ok;
}

bool AppData::WriteConfig(const std::wstring& path, const std::string& utf8) {
    // FILE_SHARE_READ only: tunnel.dll needs to read it, nothing else should.
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
                              nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        Log::LastError("CreateFile(config) failed", GetLastError());
        return false;
    }

    DWORD written = 0;
    const BOOL ok = WriteFile(file, utf8.data(),
                              static_cast<DWORD>(utf8.size()), &written,
                              nullptr);
    FlushFileBuffers(file);
    CloseHandle(file);

    if (!ok || written != utf8.size()) {
        Log::Error("Short write while saving tunnel configuration");
        return false;
    }
    return true;
}

void AppData::ShredFile(const std::wstring& path) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
        LARGE_INTEGER size{};
        if (GetFileSizeEx(file, &size) && size.QuadPart > 0 &&
            size.QuadPart < (1 << 20)) {
            std::vector<char> zeros(static_cast<size_t>(size.QuadPart), 0);
            DWORD written = 0;
            WriteFile(file, zeros.data(),
                      static_cast<DWORD>(zeros.size()), &written, nullptr);
            FlushFileBuffers(file);
        }
        CloseHandle(file);
    }
    DeleteFileW(path.c_str());
}

bool AppData::ProtectToFile(const std::wstring& path,
                            const std::string& plain) {
    DATA_BLOB in{};
    in.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(plain.data()));
    in.cbData = static_cast<DWORD>(plain.size());

    DATA_BLOB out{};
    // CRYPTPROTECT_LOCAL_MACHINE: the service must be able to read this back
    // after a reboot without a logged-in user.
    if (!CryptProtectData(&in, L"GlukVPN tunnel", nullptr, nullptr, nullptr,
                          CRYPTPROTECT_LOCAL_MACHINE, &out)) {
        Log::LastError("CryptProtectData failed", GetLastError());
        return false;
    }

    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    bool ok = false;
    if (file != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        ok = WriteFile(file, out.pbData, out.cbData, &written, nullptr) &&
             written == out.cbData;
        CloseHandle(file);
    } else {
        Log::LastError("CreateFile(dpapi) failed", GetLastError());
    }

    SecureZeroMemory(out.pbData, out.cbData);
    LocalFree(out.pbData);
    return ok;
}

bool AppData::UnprotectFromFile(const std::wstring& path, std::string& plain) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                              nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                              nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;

    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size) || size.QuadPart <= 0 ||
        size.QuadPart > (1 << 20)) {
        CloseHandle(file);
        return false;
    }

    std::vector<BYTE> buffer(static_cast<size_t>(size.QuadPart));
    DWORD read = 0;
    const BOOL ok =
        ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()), &read,
                 nullptr);
    CloseHandle(file);
    if (!ok || read != buffer.size()) return false;

    DATA_BLOB in{};
    in.pbData = buffer.data();
    in.cbData = static_cast<DWORD>(buffer.size());

    DATA_BLOB out{};
    if (!CryptUnprotectData(&in, nullptr, nullptr, nullptr, nullptr, 0, &out)) {
        return false;
    }

    plain.assign(reinterpret_cast<char*>(out.pbData), out.cbData);
    SecureZeroMemory(out.pbData, out.cbData);
    LocalFree(out.pbData);
    return true;
}

std::wstring AppData::ExecutablePath() {
    std::vector<wchar_t> buffer(MAX_PATH);
    for (;;) {
        const DWORD length = GetModuleFileNameW(nullptr, buffer.data(),
                                                static_cast<DWORD>(buffer.size()));
        if (length == 0) return L"";
        if (length < buffer.size() - 1) return std::wstring(buffer.data(), length);
        buffer.resize(buffer.size() * 2);
    }
}

std::wstring AppData::ExecutableDir() {
    std::wstring path = ExecutablePath();
    const size_t slash = path.find_last_of(L'\\');
    return slash == std::wstring::npos ? path : path.substr(0, slash);
}

std::string AppData::ToUtf8(const std::wstring& wide) {
    if (wide.empty()) return {};
    const int needed = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                           static_cast<int>(wide.size()),
                                           nullptr, 0, nullptr, nullptr);
    if (needed <= 0) return {};
    std::string out(static_cast<size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                        out.data(), needed, nullptr, nullptr);
    return out;
}

std::wstring AppData::ToWide(const std::string& utf8) {
    if (utf8.empty()) return {};
    const int needed = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                           static_cast<int>(utf8.size()),
                                           nullptr, 0);
    if (needed <= 0) return {};
    std::wstring out(static_cast<size_t>(needed), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                        out.data(), needed);
    return out;
}

} // namespace gluk
