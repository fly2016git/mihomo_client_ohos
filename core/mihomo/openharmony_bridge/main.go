package main

/*
#include <stdlib.h>

typedef int (*protect_fn)(int);

static inline int call_protect_fn(protect_fn fn, int fd) {
	if (fn == NULL) {
		return 0;
	}
	return fn(fd);
}
*/
import "C"

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/config"
	CN "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/tunnel"
	"gopkg.in/yaml.v3"
)

var (
	stateMu     sync.Mutex
	started     bool
	activeTunFd int
	protectFn   C.protect_fn
	protectOn   bool
	protectBusy int
	lastErrText string
)

var protectIdle = sync.NewCond(&stateMu)

const stoppedConfig = `
mixed-port: 0
port: 0
socks-port: 0
redir-port: 0
tproxy-port: 0
allow-lan: false
mode: direct
log-level: info
ipv6: false
dns:
  enable: false
tun:
  enable: false
rules:
  - MATCH,DIRECT
`

const defaultDelayTestURL = "http://www.gstatic.com/generate_204"

type delayItem struct {
	Name  string `json:"name"`
	Delay uint16 `json:"delay"`
	OK    bool   `json:"ok"`
	Error string `json:"error"`
}

type delayResult struct {
	OK        bool        `json:"ok"`
	GroupName string      `json:"groupName"`
	NodeName  string      `json:"nodeName"`
	URL       string      `json:"url"`
	TimeoutMs int         `json:"timeoutMs"`
	Delays    []delayItem `json:"delays"`
	Error     string      `json:"error"`
}

func setLastErr(err error) C.int {
	if err != nil {
		lastErrText = err.Error()
		return -1
	}
	lastErrText = ""
	return 0
}

func bridgeLog(msg string) {
	fmt.Fprintln(os.Stderr, "MihomoOhosBridge: "+msg)
}

func delayResultCString(result delayResult) *C.char {
	data, err := json.Marshal(result)
	if err != nil {
		return C.CString(fmt.Sprintf(`{"ok":false,"error":"marshal delay result failed: %s"}`, err.Error()))
	}
	return C.CString(string(data))
}

func normalizeDelayURL(raw string) string {
	if raw == "" {
		return defaultDelayTestURL
	}
	return raw
}

func normalizeDelayTimeout(timeoutMs int) time.Duration {
	if timeoutMs <= 0 {
		timeoutMs = 5000
	}
	if timeoutMs < 1000 {
		timeoutMs = 1000
	}
	if timeoutMs > 30000 {
		timeoutMs = 30000
	}
	return time.Duration(timeoutMs) * time.Millisecond
}

func getExpectedDelayStatus() utils.IntRanges[uint16] {
	expected, err := utils.NewUnsignedRanges[uint16]("*")
	if err != nil {
		return nil
	}
	return expected
}

func mihomoIsStarted() bool {
	stateMu.Lock()
	defer stateMu.Unlock()
	return started
}

func findProxyByName(name string) CN.Proxy {
	if proxy, ok := tunnel.Proxies()[name]; ok {
		return proxy
	}
	for _, provider := range tunnel.Providers() {
		for _, proxy := range provider.Proxies() {
			if proxy.Name() == name {
				return proxy
			}
		}
	}
	return nil
}

func tunStatusText() string {
	tunConf := listener.GetTunConf()
	return fmt.Sprintf("tunStatus enable=%v fd=%d stack=%s inet4=%v dnsHijack=%v autoRoute=%v autoDetect=%v lastTunError=%q",
		tunConf.Enable,
		tunConf.FileDescriptor,
		tunConf.Stack.String(),
		tunConf.Inet4Address,
		tunConf.DNSHijack,
		tunConf.AutoRoute,
		tunConf.AutoDetectInterface,
		listener.GetTunError(),
	)
}

func mihomoProtectSocketHook(network, address string, conn syscall.RawConn) error {
	stateMu.Lock()
	if !started || !protectOn || protectFn == nil {
		stateMu.Unlock()
		return nil
	}
	fn := protectFn
	protectBusy++
	stateMu.Unlock()

	defer func() {
		stateMu.Lock()
		protectBusy--
		if protectBusy == 0 {
			protectIdle.Broadcast()
		}
		stateMu.Unlock()
	}()

	var protectErr error
	if err := conn.Control(func(fd uintptr) {
		code := int(C.call_protect_fn(fn, C.int(fd)))
		if code != 0 {
			protectErr = fmt.Errorf("protect() failed: code=%d", code)
		}
	}); err != nil {
		return err
	}
	return protectErr
}

func enableProtectHookLocked() {
	if protectFn == nil {
		bridgeLog("enableProtectHookLocked: protectFn is nil, cannot enable")
		return
	}
	protectOn = true
	dialer.DefaultSocketHook = mihomoProtectSocketHook
	bridgeLog("enableProtectHookLocked: protect hook activated")
}

func disableProtectHookLocked() {
	protectOn = false
	dialer.DefaultSocketHook = nil
}

func waitProtectIdleLocked(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for protectBusy > 0 {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return false
		}
		timer := time.AfterFunc(remaining, func() {
			stateMu.Lock()
			protectIdle.Broadcast()
			stateMu.Unlock()
		})
		protectIdle.Wait()
		timer.Stop()
	}
	return true
}

func injectTunFd(cfg []byte, tunFd int) ([]byte, error) {
	if tunFd < 0 {
		return cfg, nil
	}
	var root map[string]any
	if err := yaml.Unmarshal(cfg, &root); err != nil {
		return nil, err
	}

	// TUN config — fd-backed gVisor stack, hijack ALL DNS regardless of dst IP
	tunConfig := map[string]any{}
	if existing, ok := root["tun"].(map[string]any); ok {
		tunConfig = existing
	}
	tunConfig["enable"] = true
	tunConfig["file-descriptor"] = tunFd
	tunConfig["stack"] = "gvisor"
	tunConfig["auto-route"] = false
	tunConfig["auto-detect-interface"] = false
	// `any:53` is the canonical mihomo syntax for hijacking all DNS UDP queries
	// regardless of destination IP. `0.0.0.0:53` does NOT work for this purpose.
	tunConfig["dns-hijack"] = []string{"any:53"}
	tunConfig["inet4-address"] = []string{"10.7.0.2/24"}
	tunConfig["mtu"] = 1500
	root["tun"] = tunConfig

	// Ensure DNS section is properly configured for fake-ip mode.
	// We require a listen address, fake-ip-range, and at least one nameserver.
	dnsConfig := map[string]any{}
	if existing, ok := root["dns"].(map[string]any); ok {
		dnsConfig = existing
	}
	if _, hasEnable := dnsConfig["enable"]; !hasEnable {
		dnsConfig["enable"] = true
	}
	if _, hasListen := dnsConfig["listen"]; !hasListen {
		dnsConfig["listen"] = "0.0.0.0:53"
	}
	if _, hasEnhanced := dnsConfig["enhanced-mode"]; !hasEnhanced {
		dnsConfig["enhanced-mode"] = "fake-ip"
	}
	if _, hasFakeRange := dnsConfig["fake-ip-range"]; !hasFakeRange {
		dnsConfig["fake-ip-range"] = "198.18.0.0/15"
	}
	if _, hasNameserver := dnsConfig["nameserver"]; !hasNameserver {
		dnsConfig["nameserver"] = []string{"223.5.5.5", "119.29.29.29"}
	}
	if _, hasDefault := dnsConfig["default-nameserver"]; !hasDefault {
		dnsConfig["default-nameserver"] = []string{"223.5.5.5", "119.29.29.29"}
	}
	root["dns"] = dnsConfig

	patchedCfg, err := yaml.Marshal(root)
	if err != nil {
		return nil, err
	}
	bridgeLog(fmt.Sprintf(
		"injectTunFd: fd=%d stack=%v inet4=%v dnsHijack=%v dnsListen=%v enhancedMode=%v fakeIPRange=%v nameserver=%v",
		tunFd,
		tunConfig["stack"],
		tunConfig["inet4-address"],
		tunConfig["dns-hijack"],
		dnsConfig["listen"],
		dnsConfig["enhanced-mode"],
		dnsConfig["fake-ip-range"],
		dnsConfig["nameserver"],
	))
	return patchedCfg, nil
}

func startWithConfig(homeDir string, cfg []byte, tunFd int) C.int {
	stateMu.Lock()
	defer stateMu.Unlock()

	if homeDir == "" {
		homeDir = "."
	}
	if err := os.MkdirAll(homeDir, 0o755); err != nil {
		return setLastErr(err)
	}
	CN.SetHomeDir(homeDir)
	CN.SetConfig(filepath.Join(homeDir, "config.yaml"))

	if err := os.Setenv("SKIP_SAFE_PATH_CHECK", "true"); err != nil {
		return setLastErr(err)
	}
	if err := config.Init(homeDir); err != nil {
		return setLastErr(err)
	}
	if tunFd >= 0 {
		patchedCfg, err := injectTunFd(cfg, tunFd)
		if err != nil {
			return setLastErr(err)
		}
		cfg = patchedCfg
	}
	bridgeLog(fmt.Sprintf("startWithConfig: parsing config homeDir=%s tunFd=%d configBytes=%d", homeDir, tunFd, len(cfg)))
	if err := hub.Parse(cfg); err != nil {
		bridgeLog("startWithConfig: hub.Parse failed: " + err.Error())
		return setLastErr(err)
	}
	tunStatus := tunStatusText()
	bridgeLog(fmt.Sprintf("startWithConfig: hub.Parse ok homeDir=%s tunFd=%d %s", homeDir, tunFd, tunStatus))
	started = true
	activeTunFd = tunFd
	if tunFd >= 0 {
		enableProtectHookLocked()
	}
	lastErrText = tunStatus
	return 0
}

//export MihomoOhosVersion
func MihomoOhosVersion() *C.char {
	return C.CString(CN.MihomoName + "/" + CN.Version)
}

//export MihomoOhosPing
func MihomoOhosPing() C.int {
	return 404
}

//export MihomoOhosSetProtectBridge
func MihomoOhosSetProtectBridge(fn unsafe.Pointer) {
	stateMu.Lock()
	defer stateMu.Unlock()

	if fn == nil {
		protectFn = nil
		disableProtectHookLocked()
		return
	}
	protectFn = C.protect_fn(fn)
}

//export MihomoOhosEnableProtectHook
func MihomoOhosEnableProtectHook() C.int {
	stateMu.Lock()
	defer stateMu.Unlock()
	if protectFn == nil {
		return -1
	}
	if !started || activeTunFd < 0 {
		return -2
	}
	enableProtectHookLocked()
	return 0
}

//export MihomoOhosDisableProtectHook
func MihomoOhosDisableProtectHook() C.int {
	stateMu.Lock()
	protectOn = false
	dialer.DefaultSocketHook = nil
	idle := waitProtectIdleLocked(5 * time.Second)
	stateMu.Unlock()
	if idle {
		return 0
	}
	return -1
}

//export MihomoOhosIsRunning
func MihomoOhosIsRunning() C.int {
	stateMu.Lock()
	defer stateMu.Unlock()
	if started {
		return 1
	}
	return 0
}

//export MihomoOhosStartConfig
func MihomoOhosStartConfig(homeDir *C.char, configBytes *C.char, configLen C.int) C.int {
	if configBytes == nil || configLen <= 0 {
		stateMu.Lock()
		lastErrText = "empty mihomo config"
		stateMu.Unlock()
		return -1
	}

	var home string
	if homeDir != nil {
		home = C.GoString(homeDir)
	}
	cfg := C.GoBytes(unsafe.Pointer(configBytes), configLen)
	return startWithConfig(home, cfg, -1)
}

//export MihomoOhosStartConfigFile
func MihomoOhosStartConfigFile(homeDir *C.char, configPath *C.char) C.int {
	if configPath == nil {
		stateMu.Lock()
		lastErrText = "empty mihomo config path"
		stateMu.Unlock()
		return -1
	}
	data, err := os.ReadFile(C.GoString(configPath))
	if err != nil {
		stateMu.Lock()
		code := setLastErr(err)
		stateMu.Unlock()
		return code
	}

	var home string
	if homeDir != nil {
		home = C.GoString(homeDir)
	}
	return startWithConfig(home, data, -1)
}

//export MihomoOhosStartConfigFileWithTunFd
func MihomoOhosStartConfigFileWithTunFd(homeDir *C.char, configPath *C.char, tunFd C.int) C.int {
	if tunFd < 0 {
		stateMu.Lock()
		lastErrText = "invalid tun fd"
		stateMu.Unlock()
		return -1
	}
	if configPath == nil {
		stateMu.Lock()
		lastErrText = "empty mihomo config path"
		stateMu.Unlock()
		return -1
	}
	data, err := os.ReadFile(C.GoString(configPath))
	if err != nil {
		stateMu.Lock()
		code := setLastErr(err)
		stateMu.Unlock()
		return code
	}

	var home string
	if homeDir != nil {
		home = C.GoString(homeDir)
	}
	return startWithConfig(home, data, int(tunFd))
}

//export MihomoOhosStop
func MihomoOhosStop() C.int {
	stateMu.Lock()
	protectOn = false
	dialer.DefaultSocketHook = nil
	// Wait for in-flight protect calls to complete before releasing state
	idle := waitProtectIdleLocked(3 * time.Second)
	started = false
	activeTunFd = -1
	protectFn = nil
	lastErrText = ""
	stateMu.Unlock()
	if idle {
		return 0
	}
	return -1
}

// MihomoOhosGracefulStop transitions mihomo to a no-TUN, no-DNS, direct-mode
// config. This causes mihomo to drain its TUN reader, DNS resolver, and
// outbound dialer goroutines naturally, after which the caller can safely
// close the TUN fd (via VpnConnection.destroy).
//
// This avoids the SIGSEGV risk of calling MihomoOhosStop while mihomo
// goroutines are still actively using the fd-backed TUN.
//
//export MihomoOhosGracefulStop
func MihomoOhosGracefulStop() C.int {
	stateMu.Lock()
	if !started {
		stateMu.Unlock()
		return 0
	}
	// Disable hook first so no new outbound calls into NAPI
	protectOn = false
	dialer.DefaultSocketHook = nil
	if !waitProtectIdleLocked(3 * time.Second) {
		bridgeLog("MihomoOhosGracefulStop: protect wait timeout")
	}
	stateMu.Unlock()

	// Re-parse with stopped config — mihomo will tear down TUN/DNS/dialer
	// goroutines as part of reload. This call may take a moment but is
	// safer than abruptly closing the fd while goroutines are reading.
	bridgeLog("MihomoOhosGracefulStop: re-parsing with stopped config")
	if err := hub.Parse([]byte(stoppedConfig)); err != nil {
		stateMu.Lock()
		setLastErr(err)
		stateMu.Unlock()
		bridgeLog("MihomoOhosGracefulStop: hub.Parse(stoppedConfig) failed: " + err.Error())
		return -1
	}

	stateMu.Lock()
	started = false
	activeTunFd = -1
	lastErrText = ""
	stateMu.Unlock()
	bridgeLog("MihomoOhosGracefulStop: complete")
	return 0
}

//export MihomoOhosProxyDelay
func MihomoOhosProxyDelay(nodeName *C.char, testURL *C.char, timeoutMs C.int) *C.char {
	var node string
	if nodeName != nil {
		node = C.GoString(nodeName)
	}
	url := defaultDelayTestURL
	if testURL != nil {
		url = normalizeDelayURL(C.GoString(testURL))
	}
	result := delayResult{
		OK:        false,
		NodeName:  node,
		URL:       url,
		TimeoutMs: int(timeoutMs),
		Delays:    []delayItem{},
	}
	if node == "" {
		result.Error = "empty proxy node name"
		return delayResultCString(result)
	}
	if !mihomoIsStarted() {
		result.Error = "mihomo not running"
		return delayResultCString(result)
	}
	proxy := findProxyByName(node)
	if proxy == nil {
		result.Error = "proxy not found: " + node
		return delayResultCString(result)
	}

	timeout := normalizeDelayTimeout(int(timeoutMs))
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	delay, err := proxy.URLTest(ctx, url, getExpectedDelayStatus())
	item := delayItem{
		Name:  node,
		Delay: delay,
		OK:    err == nil && delay > 0,
	}
	if ctx.Err() != nil {
		item.Error = ctx.Err().Error()
		result.Error = item.Error
	} else if err != nil {
		item.Error = err.Error()
		result.Error = item.Error
	} else if delay == 0 {
		item.Error = "delay test returned zero"
		result.Error = item.Error
	}
	result.OK = item.OK
	result.Delays = []delayItem{item}
	return delayResultCString(result)
}

//export MihomoOhosGroupDelay
func MihomoOhosGroupDelay(groupName *C.char, testURL *C.char, timeoutMs C.int) *C.char {
	var group string
	if groupName != nil {
		group = C.GoString(groupName)
	}
	url := defaultDelayTestURL
	if testURL != nil {
		url = normalizeDelayURL(C.GoString(testURL))
	}
	result := delayResult{
		OK:        false,
		GroupName: group,
		URL:       url,
		TimeoutMs: int(timeoutMs),
		Delays:    []delayItem{},
	}
	if group == "" {
		result.Error = "empty proxy group name"
		return delayResultCString(result)
	}
	if !mihomoIsStarted() {
		result.Error = "mihomo not running"
		return delayResultCString(result)
	}
	proxy := findProxyByName(group)
	if proxy == nil {
		result.Error = "proxy group not found: " + group
		return delayResultCString(result)
	}
	proxyGroup, ok := proxy.Adapter().(outboundgroup.ProxyGroup)
	if !ok {
		result.Error = "proxy is not a group: " + group
		return delayResultCString(result)
	}

	timeout := normalizeDelayTimeout(int(timeoutMs))
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	delays, err := proxyGroup.URLTest(ctx, url, getExpectedDelayStatus())
	if err != nil {
		result.Error = err.Error()
	}
	for name, delay := range delays {
		result.Delays = append(result.Delays, delayItem{
			Name:  name,
			Delay: delay,
			OK:    delay > 0,
		})
	}
	result.OK = len(result.Delays) > 0 && result.Error == ""
	if len(result.Delays) == 0 && result.Error == "" {
		result.Error = "no proxy delay result"
	}
	return delayResultCString(result)
}

//export MihomoOhosLastError
func MihomoOhosLastError() *C.char {
	stateMu.Lock()
	defer stateMu.Unlock()
	return C.CString(lastErrText)
}

//export MihomoOhosFreeCString
func MihomoOhosFreeCString(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}

func main() {}
