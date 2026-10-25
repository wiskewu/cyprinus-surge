// wg-probe 用用户态 WireGuard 客户端探测管理内网，不需要安装驱动或管理员权限。
//
// 它按 wg-quick 的配置格式读取客户端配置，建立隧道后向目标 TCP 端口发起连接，
// 读取 SSH 服务端标识，以此判断「客户端到内网 SSH」这条路径是否真的通。
// 仅用于验收：不写路由、不建系统接口、退出即销毁。
package main

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"net/netip"
	"os"
	"strings"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type peerConfig struct {
	address    string
	privateKey string
	publicKey  string
	preshared  string
	endpoint   string
	allowedIPs string
	keepalive  string
	mtu        int
}

func main() {
	var (
		confPath = flag.String("config", "", "wg-quick 客户端配置路径")
		target   = flag.String("target", "10.66.0.1:4061", "要连接的 内网地址:端口")
		timeout  = flag.Duration("timeout", 25*time.Second, "整体超时")
		quiet    = flag.Bool("q", false, "只输出结论")
		debug    = flag.Bool("debug", false, "失败时打印隧道状态")
	)
	flag.Parse()

	if *confPath == "" {
		fmt.Fprintln(os.Stderr, "wg-probe: 需要 -config <客户端配置>")
		os.Exit(2)
	}
	cfg, err := parseConfig(*confPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "wg-probe: 读配置失败：%v\n", err)
		os.Exit(2)
	}

	deadline := time.Now().Add(*timeout)
	banner, handshake, err := probe(cfg, *target, deadline, *debug)
	if err != nil {
		fmt.Fprintf(os.Stderr, "wg-probe: 失败：%v\n", err)
		os.Exit(1)
	}
	if !*quiet {
		fmt.Printf("握手完成用时 %s\n", handshake.Round(time.Millisecond))
	}
	fmt.Printf("通过隧道连上 %s，SSH 标识 %s\n", *target, banner)
}

func probe(cfg peerConfig, target string, deadline time.Time, debug bool) (string, time.Duration, error) {
	addr := cfg.address
	if !strings.Contains(addr, "/") {
		addr += "/32"
	}
	prefix, err := netip.ParsePrefix(addr)
	if err != nil {
		return "", 0, fmt.Errorf("Address 不合法：%v", err)
	}
	// 客户端配置里的 Address 通常是 /32，用户态栈拿不到子网路由，
	// 这里按 AllowedIPs 的网段补一条，等价于 wg-quick 在客户端加的路由。
	localAddr := []netip.Addr{prefix.Addr()}
	if prefix.Bits() == 32 {
		for _, cidr := range strings.Split(cfg.allowedIPs, ",") {
			p, err := netip.ParsePrefix(strings.TrimSpace(cidr))
			if err != nil || p.Bits() >= 32 {
				continue
			}
			localAddr = []netip.Addr{netip.PrefixFrom(prefix.Addr(), p.Bits()).Addr()}
			break
		}
	}
	tunDev, tnet, err := netstack.CreateNetTUN(localAddr, []netip.Addr{netip.MustParseAddr("1.1.1.1")}, cfg.mtu)
	if err != nil {
		return "", 0, fmt.Errorf("创建用户态网卡失败：%v", err)
	}
	lvl := device.LogLevelError
	if debug {
		lvl = device.LogLevelVerbose
	}
	if debug {
		tunDev = &debugTun{inner: tunDev, left: 6}
	}
	dev := device.NewDevice(tunDev, conn.NewDefaultBind(), device.NewLogger(lvl, "wg-probe: "))
	defer dev.Close()

	ipc, err := ipcConfig(cfg)
	if err != nil {
		return "", 0, err
	}
	if err := dev.IpcSet(ipc); err != nil {
		return "", 0, fmt.Errorf("下发 WireGuard 配置失败：%v", err)
	}
	if err := dev.Up(); err != nil {
		return "", 0, fmt.Errorf("启动隧道失败：%v", err)
	}
	time.Sleep(300 * time.Millisecond)

	ap, err := netip.ParseAddrPort(target)
	if err != nil {
		return "", 0, fmt.Errorf("目标地址不合法：%v", err)
	}
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	raw, err := tnet.DialContextTCPAddrPort(ctx, ap)
	if err != nil {
		if debug {
			state, _ := dev.IpcGet()
			fmt.Fprintf(os.Stderr, "隧道状态：%s\n", state)
		}
		return "", 0, fmt.Errorf("%s 不可达：%v", target, err)
	}
	defer raw.Close()
	handshake := time.Since(start)

	if err := raw.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return "", handshake, err
	}
	buf := make([]byte, 128)
	n, err := raw.Read(buf)
	if err != nil {
		return "", handshake, fmt.Errorf("已建立 TCP，但读 SSH 标识失败：%v", err)
	}
	line := strings.TrimRight(string(buf[:n]), "\r\n")
	if !strings.HasPrefix(line, "SSH-") {
		return "", handshake, fmt.Errorf("对端返回的不是 SSH 标识：%q", line)
	}
	return line, handshake, nil
}

// ipcConfig 把配置转成 device.IpcSet 需要的十六进制形式。
func ipcConfig(cfg peerConfig) (string, error) {
	priv, err := keyToHex(cfg.privateKey)
	if err != nil {
		return "", fmt.Errorf("PrivateKey 不合法：%v", err)
	}
	pub, err := keyToHex(cfg.publicKey)
	if err != nil {
		return "", fmt.Errorf("PublicKey 不合法：%v", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", priv)
	fmt.Fprintf(&b, "listen_port=0\n")
	fmt.Fprintf(&b, "replace_peers=true\n")
	fmt.Fprintf(&b, "public_key=%s\n", pub)
	if cfg.preshared != "" {
		psk, err := keyToHex(cfg.preshared)
		if err != nil {
			return "", fmt.Errorf("PresharedKey 不合法：%v", err)
		}
		fmt.Fprintf(&b, "preshared_key=%s\n", psk)
	}
	fmt.Fprintf(&b, "endpoint=%s\n", cfg.endpoint)
	for _, cidr := range strings.Split(cfg.allowedIPs, ",") {
		cidr = strings.TrimSpace(cidr)
		if cidr != "" {
			fmt.Fprintf(&b, "allowed_ip=%s\n", cidr)
		}
	}
	if cfg.keepalive != "" {
		fmt.Fprintf(&b, "persistent_keepalive_interval=%s\n", cfg.keepalive)
	}
	return b.String(), nil
}

func keyToHex(b64 string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return "", err
	}
	if len(raw) != 32 {
		return "", errors.New("密钥长度不是 32 字节")
	}
	return hex.EncodeToString(raw), nil
}

func parseConfig(path string) (peerConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return peerConfig{}, err
	}
	cfg := peerConfig{mtu: 1420}
	for _, raw := range strings.Split(string(data), "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "[") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(strings.ToLower(k))
		v = strings.TrimSpace(v)
		switch k {
		case "address":
			cfg.address = strings.Split(v, ",")[0]
		case "privatekey":
			cfg.privateKey = v
		case "publickey":
			cfg.publicKey = v
		case "presharedkey":
			cfg.preshared = v
		case "endpoint":
			cfg.endpoint = v
		case "allowedips":
			cfg.allowedIPs = v
		case "persistentkeepalive":
			cfg.keepalive = v
		}
	}
	if cfg.privateKey == "" || cfg.publicKey == "" || cfg.endpoint == "" {
		return peerConfig{}, errors.New("配置缺少 PrivateKey、PublicKey 或 Endpoint")
	}
	if cfg.allowedIPs == "" {
		cfg.allowedIPs = "10.66.0.0/24"
	}
	return cfg, nil
}

// debugTun 包一层，把送到隧道里的 IP 包前 40 字节打印出来，用于排查
// 「客户端认为发出去了、服务端却收不到」这类问题。
type debugTun struct {
	inner tun.Device
	left  int
}

func (d *debugTun) File() *os.File { return d.inner.File() }

func (d *debugTun) Name() (string, error) { return d.inner.Name() }

func (d *debugTun) MTU() (int, error) { return d.inner.MTU() }

func (d *debugTun) Events() <-chan tun.Event { return d.inner.Events() }

func (d *debugTun) Close() error { return d.inner.Close() }

func (d *debugTun) BatchSize() int { return d.inner.BatchSize() }

func (d *debugTun) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	n, err := d.inner.Read(bufs, sizes, offset)
	if err == nil && n > 0 && d.left > 0 {
		for i := 0; i < n; i++ {
			end := offset + 40
			if end > len(bufs[i]) {
				end = len(bufs[i])
			}
			fmt.Fprintf(os.Stderr, "出栈包 %d 字节，前 %d 字节：%x\n", sizes[i], end-offset, bufs[i][offset:end])
		}
		d.left--
	}
	return n, err
}

func (d *debugTun) Write(bufs [][]byte, offset int) (int, error) {
	for _, b := range bufs {
		if d.left <= 0 {
			break
		}
		end := offset + 40
		if end > len(b) {
			end = len(b)
		}
		fmt.Fprintf(os.Stderr, "出包 %d 字节，前 %d 字节：%x\n", len(b)-offset, end-offset, b[offset:end])
		d.left--
	}
	return d.inner.Write(bufs, offset)
}
