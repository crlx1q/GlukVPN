# GlukVPN tunnel service — privileged Windows helper.
#
# Build:
#   cmake -S . -B build -G "Visual Studio 17 2022" -A x64
#   cmake --build build --config Release
#
# Output: build/Release/GlukVpnTunnelService.exe

cmake_minimum_required(VERSION 3.21)

project(GlukVpnTunnelService
    VERSION 1.0.0
    DESCRIPTION "GlukVPN privileged tunnel service"
    LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Static CRT so the service has no vcredist dependency. A VPN helper that
# fails to start because a runtime DLL is missing is a support nightmare.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

add_executable(GlukVpnTunnelService
    src/main.cpp
    src/service.cpp
    src/pipe_server.cpp
    src/tunnel.cpp
    src/wireguard_nt.cpp
    src/wfp.cpp
    src/split_tunnel.cpp
    src/appdata.cpp
    src/json.cpp
    src/log.cpp
)

target_include_directories(GlukVpnTunnelService PRIVATE src)

target_compile_definitions(GlukVpnTunnelService PRIVATE
    UNICODE
    _UNICODE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    GLUK_SERVICE_VERSION="${PROJECT_VERSION}"
)

# advapi32  service control manager, registry, DPAPI
# crypt32   CryptProtectData / CryptUnprotectData
# fwpuclnt  Windows Filtering Platform (kill switch, split rules)
# iphlpapi  interface + route table manipulation
# ws2_32    address parsing / sockets
# shlwapi   path helpers
# rpcrt4    UuidCreate for filter keys
set(GLUK_LIBS
    advapi32 crypt32 fwpuclnt iphlpapi ws2_32 shlwapi rpcrt4 ole32 shell32 userenv
)
target_link_libraries(GlukVpnTunnelService PRIVATE ${GLUK_LIBS})

# No console window: the service must be invisible even when started manually.
set_target_properties(GlukVpnTunnelService PROPERTIES WIN32_EXECUTABLE TRUE)

if(MSVC)
    target_compile_options(GlukVpnTunnelService PRIVATE
        /W4 /permissive- /utf-8 /Zc:preprocessor
        $<$<CONFIG:Release>:/O2 /GL /guard:cf>
    )
    target_link_options(GlukVpnTunnelService PRIVATE
        $<$<CONFIG:Release>:/LTCG /OPT:REF /OPT:ICF>
        /GUARD:CF /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA
        # The manifest is supplied by the installer; embedding requireAdministrator
        # here would break "start as a service" semantics.
        /MANIFEST:NO
    )
endif()

# ---------------------------------------------------------------------------
# Data plane binaries
# ---------------------------------------------------------------------------
# glukvpn-wg.exe  our own wireguard-go build (go/glukvpn-wg). Implements
#                 WireGuard in userspace and is spawned by tunnel.cpp.
# wintun.dll      official WHQL-signed Wintun 0.14.1 - the only driver we ship.
#
# ROUND 7. tunnel.dll is gone. It came from wireguard-windows and was never a
# WireGuard implementation: it launches the WireGuardNT kernel driver and
# installs the unsigned wireguard.sys, which Core Isolation / WDAC refuses.
# That is why the worker died with ok=0, ran 1s. Userspace WireGuard over
# Wintun needs no kernel driver and no signing exception.
#
# Neither file is committed — see vendor/amd64/README.md for how to produce
# them (desktop\packaging\build-all.ps1 does it automatically).
set(GLUK_VENDOR_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vendor/amd64")

foreach(artifact glukvpn-wg.exe wintun.dll)
    if(EXISTS "${GLUK_VENDOR_DIR}/${artifact}")
        add_custom_command(TARGET GlukVpnTunnelService POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${GLUK_VENDOR_DIR}/${artifact}"
                "$<TARGET_FILE_DIR:GlukVpnTunnelService>/${artifact}"
            COMMENT "Copying ${artifact} next to the service")
    else()
        message(WARNING
            "${artifact} not found in ${GLUK_VENDOR_DIR}. "
            "The service will build but cannot bring a tunnel up until it is placed there. "
            "See vendor/amd64/README.md.")
    endif()
endforeach()

# ---------------------------------------------------------------------------
# Optional: WinDivert-based per-application redirection
# ---------------------------------------------------------------------------
# Off by default. WinDivert is LGPLv3/GPLv2 and ships an extra signed driver,
# which changes both the licensing story and the AV footprint. Without it the
# service still enforces per-app rules through WFP, which guarantees "selected
# apps never leak into the tunnel" but cannot force-redirect an app that
# ignores the routing table.
option(GLUK_WITH_WINDIVERT "Enable WinDivert per-app redirection engine" OFF)

if(GLUK_WITH_WINDIVERT)
    target_compile_definitions(GlukVpnTunnelService PRIVATE GLUK_HAVE_WINDIVERT=1)
    target_include_directories(GlukVpnTunnelService PRIVATE "${GLUK_VENDOR_DIR}/windivert/include")
    target_link_directories(GlukVpnTunnelService PRIVATE "${GLUK_VENDOR_DIR}/windivert")
    target_link_libraries(GlukVpnTunnelService PRIVATE WinDivert)
endif()

install(TARGETS GlukVpnTunnelService RUNTIME DESTINATION service)
