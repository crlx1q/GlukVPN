// Command glukvpn-wg is the GlukVPN data plane: a complete WireGuard
// implementation that runs entirely in userspace on top of Wintun.
//
// Why this program exists
//
// The previous design used tunnel.dll from wireguard-windows'
// embeddable-dll-service. That library is not a WireGuard implementation - it
// is a launcher for the WireGuardNT *kernel* driver, and it installs
// wireguard.sys on first use. wireguard.sys has no Microsoft WHQL signature,
// so on any machine with Core Isolation / Memory Integrity / WDAC turned on the
// kernel refuses to load it. The symptom was exact and repeatable:
//
//	Tunnel worker starting (driver unavailable)
//	Tunnel worker exited, ok=0, ran 1s
//
// Swapping wireguard.dll for wintun.dll did not help, because tunnel.dll never
// asked for Wintun in the first place. The fix is to stop using a kernel driver
// for the protocol at all: wireguard-go implements WireGuard in userspace and
// only needs a virtual adapter, which is what Wintun is - and Wintun *is* WHQL
// signed. This is the same architecture Proton, Mullvad and Tailscale ship on
// Windows.
//
// The service supervises this process rather than loading it as a library, so
// no cgo toolchain is needed to build it and a crash in the data plane cannot
// take the service down with it.
//
// Contract with the C++ service:
//
//	glukvpn-wg <tunnel.conf> [--parent <pid>] [--log <path>]
//
//   - the adapter name is the config file's base name (GlukVPN.conf -> GlukVPN);
//   - the process runs until the tunnel stops, then exits 0; any failure exits
//     non-zero with one human-readable line on stderr;
//   - stopping is the standard named event Global\WireGuard-Stop-<adapter>,
//     which is exactly what Tunnel::Down() already signals;
//   - live statistics are served on the standard WireGuard UAPI pipe
//     \\.\pipe\ProtectedPrefix\Administrators\WireGuard\<adapter>, which is
//     exactly what wireguard_nt.cpp already reads.
package main

import (
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/ipc"
	"golang.zx2c4.com/wireguard/tun"
	"golang.zx2c4.com/wireguard/windows/tunnel/winipcfg"
)

const defaultMTU = 1420

// Resolvers used when the tunnel config carries no DNS line of its own.
//
// Leaving the physical adapter's resolver in charge is how a "connected" VPN
// still leaks every lookup, and on Windows it is also how NCSI decides the
// machine has no internet: the probe is an HTTP GET to a name, and the name is
// resolved by whichever interface wins. Google and Cloudflare are the two the
// round 9 spec asks for.
var defaultDNS = []string{"8.8.8.8", "1.1.1.1"}

// A stable adapter GUID.
//
// Without one, every reconnect asks Wintun for a brand new adapter and Windows
// obliges: "GlukVPN", "GlukVPN 1", "GlukVPN 2", "GlukVPN 3" pile up in Network
// Connections, each with its own firewall profile, its own DNS cache and its
// own interface metric. Any fixed GUID fixes that as long as it never changes
// again - this one is ours.
var fixedGUID = windows.GUID{
	Data1: 0x25b5b244,
	Data2: 0x1f5e,
	Data3: 0x4b47,
	Data4: [8]byte{0xb8, 0x47, 0x5d, 0x8f, 0x28, 0xf0, 0xde, 0x20},
}

// ---------------------------------------------------------------- logging --

var logFile *os.File

func logf(format string, args ...any) {
	line := time.Now().Format("2006-01-02 15:04:05") + " [wg] " + fmt.Sprintf(format, args...)
	fmt.Fprintln(os.Stderr, line)
	if logFile != nil {
		fmt.Fprintln(logFile, line)
	}
}

// ------------------------------------------------------------------ entry --

func main() {
	if err := run(); err != nil {
		logf("fatal: %v", err)
		os.Exit(1)
	}
}

type options struct {
	confPath  string
	parentPID int
	logPath   string
}

func parseArgs(args []string) (options, error) {
	var opts options
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--parent":
			if i+1 >= len(args) {
				return opts, errors.New("--parent needs a process id")
			}
			i++
			value, err := strconv.Atoi(args[i])
			if err != nil {
				return opts, fmt.Errorf("--parent %q is not a number", args[i])
			}
			opts.parentPID = value
		case "--log":
			if i+1 >= len(args) {
				return opts, errors.New("--log needs a path")
			}
			i++
			opts.logPath = args[i]
		default:
			if opts.confPath == "" {
				opts.confPath = args[i]
			}
		}
	}
	if opts.confPath == "" {
		return opts, errors.New("usage: glukvpn-wg <tunnel.conf> [--parent <pid>] [--log <path>]")
	}
	return opts, nil
}

func run() error {
	opts, err := parseArgs(os.Args[1:])
	if err != nil {
		return err
	}

	if opts.logPath != "" {
		if f, openErr := os.OpenFile(opts.logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); openErr == nil {
			logFile = f
			defer f.Close()
		}
	}

	// wintun.dll ships next to this executable. Without this the loader would
	// search the service's working directory, which is %SystemRoot%\System32,
	// and the adapter would fail to create for a reason that looks like a
	// missing driver rather than a missing file.
	addExeDirToDLLSearchPath()

	raw, err := os.ReadFile(opts.confPath)
	if err != nil {
		return fmt.Errorf("cannot read the tunnel config: %w", err)
	}
	cfg, err := parseConfig(string(raw))
	if err != nil {
		return err
	}

	name := strings.TrimSuffix(filepath.Base(opts.confPath), filepath.Ext(opts.confPath))
	if name == "" {
		name = "GlukVPN"
	}

	mtu := cfg.mtu
	if mtu <= 0 {
		mtu = defaultMTU
	}

	// Everything below is built before the adapter is touched, so a bad config
	// fails without leaving a half-created network interface behind.
	uapiText, err := cfg.uapi()
	if err != nil {
		return err
	}

	logf("starting %q: mtu %d, %d peer(s), %d address(es)", name, mtu, len(cfg.peers), len(cfg.addresses))

	// Requesting a fixed GUID makes Windows reuse the same adapter on every
	// reconnect instead of spawning GlukVPN 1, GlukVPN 2, GlukVPN 3...
	tunDevice, err := tun.CreateTUNWithRequestedGUID(name, &fixedGUID, mtu)
	if err != nil {
		return fmt.Errorf("cannot create the Wintun adapter (is wintun.dll next to the service?): %w", err)
	}

	nativeTun, ok := tunDevice.(*tun.NativeTun)
	if !ok {
		tunDevice.Close()
		return errors.New("unexpected TUN backend: this build must use Wintun")
	}
	luid := winipcfg.LUID(nativeTun.LUID())

	logger := &device.Logger{
		Verbosef: func(format string, args ...any) { logf("wg: "+format, args...) },
		Errorf:   func(format string, args ...any) { logf("wg error: "+format, args...) },
	}

	dev := device.NewDevice(tunDevice, conn.NewDefaultBind(), logger)

	if err := dev.IpcSet(uapiText); err != nil {
		dev.Close()
		return fmt.Errorf("cannot apply the tunnel config: %w", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return fmt.Errorf("cannot bring the tunnel up: %w", err)
	}

	// Pin a host route to every peer endpoint through the *physical* gateway
	// before the default route lands on Wintun.
	//
	// This is the routing loop. WireGuard's own outgoing packets are ordinary
	// UDP to 138.2.186.223:51820, so once 0.0.0.0/0 points at the tunnel with
	// metric 0 those packets match it too: the data plane encrypts a packet,
	// hands it to the OS, the OS hands it straight back through Wintun, and it
	// gets encrypted again. That is the 200+ MB in a few seconds with no
	// working internet - the machine is talking to itself as fast as it can.
	//
	// A /32 always beats /0 under longest-prefix match, regardless of metric,
	// so the outer packets keep using Wi-Fi/Ethernet while everything else
	// goes into the tunnel. Order matters: the escape hatch has to exist
	// before the trap does.
	pinned := pinEndpointRoutes(luid, cfg.endpointAddrs())
	defer unpinEndpointRoutes(pinned)

	if err := configureInterface(luid, cfg, mtu); err != nil {
		dev.Close()
		return err
	}

	// Statistics. Non-fatal on purpose: a tunnel that carries traffic but
	// cannot report byte counters is still a working tunnel, and refusing to
	// connect over a missing pipe would be the wrong trade.
	if listener, listenErr := ipc.UAPIListen(name); listenErr != nil {
		logf("statistics pipe unavailable: %v", listenErr)
	} else {
		defer listener.Close()
		go func() {
			for {
				client, acceptErr := listener.Accept()
				if acceptErr != nil {
					return
				}
				go dev.IpcHandle(client)
			}
		}()
	}

	logf("tunnel %q is up", name)
	waitForStop(name, opts.parentPID, dev)
	logf("tunnel %q is going down", name)
	dev.Close()
	return nil
}

// ------------------------------------------------------------- interface ---

// configureInterface assigns the address, routes and DNS to the Wintun adapter.
//
// If the winipcfg API ever changes shape, this is the only function that has to
// follow it - everything else here talks to wireguard-go, whose device/tun/ipc
// surface has been stable for years.
func configureInterface(luid winipcfg.LUID, cfg *tunnelConfig, mtu int) error {
	addresses := make([]netip.Prefix, 0, len(cfg.addresses))
	for _, raw := range cfg.addresses {
		prefix, err := netip.ParsePrefix(raw)
		if err != nil {
			return fmt.Errorf("bad Address %q in the tunnel config: %w", raw, err)
		}
		addresses = append(addresses, prefix)
	}
	if len(addresses) == 0 {
		return errors.New("the tunnel config has no Address")
	}
	if err := luid.SetIPAddresses(addresses); err != nil {
		return fmt.Errorf("cannot assign the tunnel address: %w", err)
	}

	// Table = off means the split-tunnelling engine owns the routing table.
	if !cfg.tableOff {
		routes := make([]*winipcfg.RouteData, 0, 4)
		for i := range cfg.peers {
			for _, raw := range cfg.peers[i].allowedIPs {
				prefix, err := netip.ParsePrefix(raw)
				if err != nil {
					continue
				}
				nextHop := netip.IPv4Unspecified()
				if prefix.Addr().Is6() {
					nextHop = netip.IPv6Unspecified()
				}
				// A default route is never installed as a default route.
				// See splitDefaultRoute for why.
				for _, dest := range splitDefaultRoute(prefix) {
					routes = append(routes, &winipcfg.RouteData{
						Destination: dest,
						NextHop:     nextHop,
						Metric:      0,
					})
				}
			}
		}
		if len(routes) > 0 {
			if err := luid.SetRoutes(routes); err != nil {
				return fmt.Errorf("cannot install the tunnel routes: %w", err)
			}
		}
	}

	dnsServers := cfg.dns
	if len(dnsServers) == 0 {
		dnsServers = defaultDNS
	}
	if len(dnsServers) > 0 {
		var v4, v6 []netip.Addr
		for _, raw := range dnsServers {
			ip, err := netip.ParseAddr(raw)
			if err != nil {
				continue
			}
			if ip.Is4() {
				v4 = append(v4, ip)
			} else {
				v6 = append(v6, ip)
			}
		}
		if len(v4) > 0 {
			if err := luid.SetDNS(winipcfg.AddressFamily(windows.AF_INET), v4, nil); err != nil {
				logf("could not set IPv4 DNS: %v", err)
			}
		}
		if len(v6) > 0 {
			if err := luid.SetDNS(winipcfg.AddressFamily(windows.AF_INET6), v6, nil); err != nil {
				logf("could not set IPv6 DNS: %v", err)
			}
		}
	}

	// Without a low metric the physical adapter keeps winning the default
	// route and the tunnel comes up carrying no traffic - which looks exactly
	// like a broken VPN to the user.
	if iface, err := luid.IPInterface(winipcfg.AddressFamily(windows.AF_INET)); err == nil {
		iface.UseAutomaticMetric = false
		iface.Metric = 0
		iface.NLMTU = uint32(mtu)
		if err := iface.Set(); err != nil {
			logf("could not pin the interface metric: %v", err)
		}
	}

	return nil
}

// splitDefaultRoute turns a default route into the two halves every WireGuard
// client on Windows has always used, and leaves every other prefix alone.
//
//	0.0.0.0/0  ->  0.0.0.0/1  +  128.0.0.0/1
//	::/0       ->  ::/1       +  8000::/1
//
// Installing 0.0.0.0/0 on Wintun with metric 0 does send every packet into the
// tunnel - and that is exactly the problem. Windows sees the interface's own
// default gateway being taken over, so the Network Location Awareness service
// re-runs the NCSI probe through a tunnel that has not finished its handshake,
// the probe fails, and the tray icon says "No internet access". Some apps read
// that flag rather than trying a socket, so they refuse to load at all even
// though the tunnel works.
//
// Two /1 routes cover the identical address space and beat any /0 under
// longest-prefix match, so all traffic still goes into the tunnel - but the
// physical default route is never displaced, the network profile stays
// "connected", and NCSI keeps answering. This is why Proton, Mullvad and
// wireguard-windows all ship the same pair.
func splitDefaultRoute(prefix netip.Prefix) []netip.Prefix {
	if prefix.Bits() != 0 {
		return []netip.Prefix{prefix}
	}
	if prefix.Addr().Is6() {
		return []netip.Prefix{
			netip.PrefixFrom(netip.IPv6Unspecified(), 1),
			netip.PrefixFrom(netip.AddrFrom16([16]byte{0x80}), 1),
		}
	}
	return []netip.Prefix{
		netip.PrefixFrom(netip.IPv4Unspecified(), 1),
		netip.PrefixFrom(netip.AddrFrom4([4]byte{128, 0, 0, 0}), 1),
	}
}

// ---------------------------------------------------------- route pinning --

// pinnedRoute remembers a host route we added, so it can be taken away again.
type pinnedRoute struct {
	luid        winipcfg.LUID
	destination netip.Prefix
	nextHop     netip.Addr
}

type physicalHop struct {
	luid    winipcfg.LUID
	nextHop netip.Addr
}

// allPhysicalGateways finds every physical interface that holds a default route,
// returning (LUID, nextHop) pairs. In dual-homed laptops with Wi-Fi and Ethernet
// both connected, pinning only the lowest-metric interface breaks connectivity
// if the lowest-metric link has no internet route to the endpoint.
func allPhysicalGateways(
	exclude winipcfg.LUID,
	family winipcfg.AddressFamily,
) []physicalHop {
	rows, err := winipcfg.GetIPForwardTable2(family)
	if err != nil {
		logf("cannot read the routing table: %v", err)
		return nil
	}

	var hops []physicalHop
	seen := make(map[winipcfg.LUID]bool)
	for i := range rows {
		row := &rows[i]
		if row.InterfaceLUID == exclude || seen[row.InterfaceLUID] {
			continue
		}
		// Bits() == 0 is 0.0.0.0/0 or ::/0 - a default route and nothing else.
		if row.DestinationPrefix.Prefix().Bits() != 0 {
			continue
		}
		nextHop := row.NextHop.Addr()
		if !nextHop.IsValid() || nextHop.IsUnspecified() {
			continue
		}
		seen[row.InterfaceLUID] = true
		hops = append(hops, physicalHop{luid: row.InterfaceLUID, nextHop: nextHop})
	}
	return hops
}

// pinEndpointRoutes installs a /32 (or /128) route to each peer endpoint via
// all physical default gateways, and reports what it managed to add so the caller can
// undo exactly that and nothing more.
func pinEndpointRoutes(tunnelLUID winipcfg.LUID, endpoints []netip.Addr) []pinnedRoute {
	if len(endpoints) == 0 {
		logf("no peer endpoint address to pin; the tunnel may loop back on itself")
		return nil
	}

	pinned := make([]pinnedRoute, 0, len(endpoints))
	for _, endpoint := range endpoints {
		family := winipcfg.AddressFamily(windows.AF_INET)
		bits := 32
		if endpoint.Is6() {
			family = winipcfg.AddressFamily(windows.AF_INET6)
			bits = 128
		}

		gateways := allPhysicalGateways(tunnelLUID, family)
		if len(gateways) == 0 {
			logf("no physical default route found, not pinning %v", endpoint)
			continue
		}

		destination := netip.PrefixFrom(endpoint, bits)
		for _, gw := range gateways {
			if err := gw.luid.AddRoute(destination, gw.nextHop, 0); err != nil {
				// A leftover from a previous run is the state we wanted anyway, so
				// it is a success - but it is not ours to delete on the way out.
				if errors.Is(err, windows.ERROR_OBJECT_ALREADY_EXISTS) {
					logf("route to %v via %v was already pinned", endpoint, gw.nextHop)
					continue
				}
				logf("could not pin a route to %v via %v: %v", endpoint, gw.nextHop, err)
				continue
			}
			logf("pinned %v/%d via the physical gateway %v (LUID %v)", endpoint, bits, gw.nextHop, gw.luid)
			pinned = append(pinned, pinnedRoute{
				luid:        gw.luid,
				destination: destination,
				nextHop:     gw.nextHop,
			})
		}
	}
	return pinned
}

// unpinEndpointRoutes removes the host routes again. Leaving them behind would
// send traffic for that one address around the tunnel on the next connect,
// which is a quiet leak rather than a visible failure - so it must not happen.
func unpinEndpointRoutes(routes []pinnedRoute) {
	for _, route := range routes {
		if err := route.luid.DeleteRoute(route.destination, route.nextHop); err != nil {
			logf("could not remove the pinned route %v: %v", route.destination, err)
		}
	}
}

// endpointAddrs resolves every peer endpoint to a literal address.
//
// Names are resolved here, while the machine still has ordinary internet: once
// the default route is on the tunnel and the kill switch is armed, port 53 is
// blocked and the same lookup would fail.
func (c *tunnelConfig) endpointAddrs() []netip.Addr {
	seen := make(map[netip.Addr]bool, len(c.peers))
	out := make([]netip.Addr, 0, len(c.peers))

	add := func(addr netip.Addr) {
		addr = addr.Unmap()
		if !addr.IsValid() || seen[addr] {
			return
		}
		seen[addr] = true
		out = append(out, addr)
	}

	for i := range c.peers {
		endpoint := strings.TrimSpace(c.peers[i].endpoint)
		if endpoint == "" {
			continue
		}
		host := endpoint
		if h, _, err := net.SplitHostPort(endpoint); err == nil {
			host = h
		}
		if addr, err := netip.ParseAddr(host); err == nil {
			add(addr)
			continue
		}
		ips, err := net.LookupIP(host)
		if err != nil {
			logf("cannot resolve the endpoint %q: %v", host, err)
			continue
		}
		for _, ip := range ips {
			if addr, ok := netip.AddrFromSlice(ip); ok {
				add(addr)
			}
		}
	}
	return out
}

// ------------------------------------------------------------------ stop ---

func waitForStop(name string, parentPID int, dev *device.Device) {
	handles := make([]windows.Handle, 0, 2)

	if handle, err := openStopEvent(name); err == nil {
		defer windows.CloseHandle(handle)
		handles = append(handles, handle)
	} else {
		logf("stop event unavailable, relying on the device only: %v", err)
	}

	// If the service dies the tunnel must die with it. Otherwise the adapter
	// survives with a default route pointing into a process nobody owns, and
	// the machine loses internet until the next reboot.
	if parentPID > 0 {
		if handle, err := windows.OpenProcess(windows.SYNCHRONIZE, false, uint32(parentPID)); err == nil {
			defer windows.CloseHandle(handle)
			handles = append(handles, handle)
		} else {
			logf("cannot watch the parent process: %v", err)
		}
	}

	signalled := make(chan struct{})
	if len(handles) > 0 {
		go func() {
			_, _ = windows.WaitForMultipleObjects(handles, false, windows.INFINITE)
			close(signalled)
		}()
	}

	select {
	case <-dev.Wait():
	case <-signalled:
	}
}

func openStopEvent(name string) (windows.Handle, error) {
	// Same name the official client uses, so Tunnel::Down() needs no change.
	full, err := windows.UTF16PtrFromString(`Global\WireGuard-Stop-` + name)
	if err != nil {
		return 0, err
	}
	return windows.CreateEvent(nil, 1, 0, full)
}

func addExeDirToDLLSearchPath() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	dir, err := windows.UTF16PtrFromString(filepath.Dir(exe))
	if err != nil {
		return
	}
	proc := windows.NewLazySystemDLL("kernel32.dll").NewProc("SetDllDirectoryW")
	_, _, _ = proc.Call(uintptr(unsafe.Pointer(dir)))
}

// ----------------------------------------------------------------- config --

type peerConfig struct {
	publicKey    string
	presharedKey string
	endpoint     string
	allowedIPs   []string
	keepalive    int
}

type tunnelConfig struct {
	privateKey string
	listenPort int
	addresses  []string
	dns        []string
	mtu        int
	tableOff   bool
	peers      []peerConfig
}

// parseConfig reads the wg-quick format the control server hands us.
//
// Written by hand rather than pulled from wireguard-windows' conf package: this
// is a hundred lines of well-understood parsing, and it keeps the only
// dependency on that module down to winipcfg.
func parseConfig(text string) (*tunnelConfig, error) {
	cfg := &tunnelConfig{}
	section := ""

	for _, rawLine := range strings.Split(text, "\n") {
		line := strings.TrimSpace(strings.TrimSuffix(rawLine, "\r"))
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			section = strings.ToLower(strings.Trim(line, "[]"))
			if section == "peer" {
				cfg.peers = append(cfg.peers, peerConfig{})
			}
			continue
		}

		eq := strings.Index(line, "=")
		if eq < 0 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(line[:eq]))
		value := strings.TrimSpace(line[eq+1:])
		if value == "" {
			continue
		}

		switch section {
		case "interface":
			switch key {
			case "privatekey":
				cfg.privateKey = value
			case "listenport":
				cfg.listenPort = atoiOr(value, 0)
			case "address":
				cfg.addresses = append(cfg.addresses, splitList(value)...)
			case "dns":
				cfg.dns = append(cfg.dns, splitList(value)...)
			case "mtu":
				cfg.mtu = atoiOr(value, 0)
			case "table":
				cfg.tableOff = strings.EqualFold(value, "off")
			}
		case "peer":
			if len(cfg.peers) == 0 {
				continue
			}
			peer := &cfg.peers[len(cfg.peers)-1]
			switch key {
			case "publickey":
				peer.publicKey = value
			case "presharedkey":
				peer.presharedKey = value
			case "endpoint":
				peer.endpoint = value
			case "allowedips":
				peer.allowedIPs = append(peer.allowedIPs, splitList(value)...)
			case "persistentkeepalive":
				peer.keepalive = atoiOr(value, 0)
			}
		}
	}

	if cfg.privateKey == "" {
		return nil, errors.New("the tunnel config has no PrivateKey")
	}
	if len(cfg.peers) == 0 {
		return nil, errors.New("the tunnel config has no [Peer] section")
	}
	return cfg, nil
}

// uapi renders the config in the cross-platform WireGuard IPC format.
func (c *tunnelConfig) uapi() (string, error) {
	private, err := keyToHex(c.privateKey)
	if err != nil {
		return "", fmt.Errorf("bad PrivateKey: %w", err)
	}

	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", private)
	if c.listenPort > 0 {
		fmt.Fprintf(&b, "listen_port=%d\n", c.listenPort)
	}
	b.WriteString("replace_peers=true\n")

	for i := range c.peers {
		peer := &c.peers[i]

		public, err := keyToHex(peer.publicKey)
		if err != nil {
			return "", fmt.Errorf("bad PublicKey: %w", err)
		}
		fmt.Fprintf(&b, "public_key=%s\n", public)

		if peer.presharedKey != "" {
			psk, err := keyToHex(peer.presharedKey)
			if err != nil {
				return "", fmt.Errorf("bad PresharedKey: %w", err)
			}
			fmt.Fprintf(&b, "preshared_key=%s\n", psk)
		}

		if peer.endpoint != "" {
			// The UAPI takes an address, not a name. Nodes are addressed by
			// domain (de-01.gluk.tech), so the name is resolved here.
			resolved, err := resolveEndpoint(peer.endpoint)
			if err != nil {
				return "", err
			}
			fmt.Fprintf(&b, "endpoint=%s\n", resolved)
		}

		if peer.keepalive > 0 {
			fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", peer.keepalive)
		}

		b.WriteString("replace_allowed_ips=true\n")
		for _, allowed := range peer.allowedIPs {
			fmt.Fprintf(&b, "allowed_ip=%s\n", allowed)
		}
	}

	return b.String(), nil
}

func resolveEndpoint(raw string) (string, error) {
	host, port, err := net.SplitHostPort(raw)
	if err != nil {
		return "", fmt.Errorf("bad Endpoint %q: %w", raw, err)
	}
	if ip := net.ParseIP(host); ip != nil {
		return net.JoinHostPort(ip.String(), port), nil
	}

	ips, err := net.LookupIP(host)
	if err != nil {
		return "", fmt.Errorf("cannot resolve the server address %q: %w", host, err)
	}
	if len(ips) == 0 {
		return "", fmt.Errorf("cannot resolve the server address %q", host)
	}
	for _, ip := range ips {
		if ip.To4() != nil {
			return net.JoinHostPort(ip.String(), port), nil
		}
	}
	return net.JoinHostPort(ips[0].String(), port), nil
}

func keyToHex(value string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil {
		return "", err
	}
	if len(raw) != 32 {
		return "", fmt.Errorf("expected a 32-byte key, got %d bytes", len(raw))
	}
	return hex.EncodeToString(raw), nil
}

func splitList(value string) []string {
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

func atoiOr(value string, fallback int) int {
	parsed, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		return fallback
	}
	return parsed
}
