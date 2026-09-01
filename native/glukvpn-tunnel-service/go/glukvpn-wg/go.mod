module gluk.tech/glukvpn-wg

go 1.22

// Pinned deliberately.
//
// v0.5.3 is the last tagged WireGuard for Windows release, so its winipcfg API
// (net.IPNet based) is frozen and cannot drift under us. Pinning it also pins
// wireguard-go through the module graph to a version whose device/tun/ipc API
// matches the code in main.go. `go mod tidy` fills in the rest.
//
// Only winipcfg is used from this module - the adapter/driver installer half of
// wireguard-windows is never imported, so nothing here can try to load the
// unsigned WireGuardNT kernel driver.
require golang.zx2c4.com/wireguard/windows v0.5.3
