package main

/*
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// PocProtectBridge is provided by protect_bridge.c compiled into this .so.
// At runtime, PocProtectBridgeSetFn() registers the real protect implementation.
int PocProtectBridge(int fd);
void PocProtectBridgeSetFn(int (*fn)(int));
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"
)

var (
	workerMu     sync.Mutex
	stopWorkerCh chan struct{}
	workerSeq    atomic.Int64
	lastEvent    atomic.Value
)

func setLastEvent(message string) {
	lastEvent.Store(message)
}

// ---------- POC-02 exports (unchanged) ----------

//export PocGoVersion
func PocGoVersion() *C.char {
	return C.CString("poc-go-core/0.2")
}

//export PocGoAdd
func PocGoAdd(left C.int32_t, right C.int32_t) C.int32_t {
	return left + right
}

//export PocGoStartWorker
func PocGoStartWorker(intervalMs C.int32_t) C.int32_t {
	workerMu.Lock()
	defer workerMu.Unlock()

	if stopWorkerCh != nil {
		return 1
	}

	if intervalMs <= 0 {
		intervalMs = 200
	}

	stopWorkerCh = make(chan struct{})
	localStop := stopWorkerCh
	setLastEvent("worker starting")

	go func() {
		ticker := time.NewTicker(time.Duration(intervalMs) * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				seq := workerSeq.Add(1)
				setLastEvent(fmt.Sprintf("worker tick %d", seq))
			case <-localStop:
				setLastEvent("worker stopped")
				return
			}
		}
	}()

	return 0
}

//export PocGoStopWorker
func PocGoStopWorker() C.int32_t {
	workerMu.Lock()
	defer workerMu.Unlock()

	if stopWorkerCh == nil {
		return 1
	}

	close(stopWorkerCh)
	stopWorkerCh = nil
	return 0
}

//export PocGoLastEvent
func PocGoLastEvent() *C.char {
	value := lastEvent.Load()
	if value == nil {
		return C.CString("no event")
	}
	return C.CString(value.(string))
}

//export PocGoPanicProbe
func PocGoPanicProbe() (code C.int32_t) {
	defer func() {
		if recovered := recover(); recovered != nil {
			setLastEvent(fmt.Sprintf("panic recovered: %v", recovered))
			code = 0
		}
	}()
	panic("POC-02 panic probe")
}

//export PocGoFree
func PocGoFree(ptr unsafe.Pointer) {
	C.free(ptr)
}

// ---------- POC-03: Socket protect tests ----------

type TcpTestResult struct {
	Ok          bool   `json:"ok"`
	Error       string `json:"error,omitempty"`
	UseProtect  bool   `json:"useProtect"`
	Host        string `json:"host"`
	Port        int    `json:"port"`
	ConnectMs   int64  `json:"connectMs"`
	WriteMs     int64  `json:"writeMs"`
	ReadMs      int64  `json:"readMs"`
	BytesRead   int    `json:"bytesRead"`
	ResponseLen int    `json:"responseLen"`
}

type UdpTestResult struct {
	Ok          bool   `json:"ok"`
	Error       string `json:"error,omitempty"`
	UseProtect  bool   `json:"useProtect"`
	Host        string `json:"host"`
	Port        int    `json:"port"`
	SendMs      int64  `json:"sendMs"`
	RecvMs      int64  `json:"recvMs"`
	BytesRecv   int    `json:"bytesRecv"`
	HasResponse bool   `json:"hasResponse"`
}

func doProtect(fd int) int {
	if fd < 0 {
		return -1
	}
	return int(C.PocProtectBridge(C.int(fd)))
}

//export PocGoSetProtectBridgeFn
func PocGoSetProtectBridgeFn(fn unsafe.Pointer) {
	C.PocProtectBridgeSetFn((*[0]byte)(fn))
}

//export PocGoTcpTest
func PocGoTcpTest(cHost *C.char, cPort C.int, useProtect C.int) *C.char {
	host := C.GoString(cHost)
	port := int(cPort)
	doProtectFlag := useProtect != 0

	result := runTcpTest(host, port, doProtectFlag)
	data, _ := json.Marshal(result)
	return C.CString(string(data))
}

//export PocGoUdpTest
func PocGoUdpTest(cHost *C.char, cPort C.int, useProtect C.int) *C.char {
	host := C.GoString(cHost)
	port := int(cPort)
	doProtectFlag := useProtect != 0

	result := runUdpTest(host, port, doProtectFlag)
	data, _ := json.Marshal(result)
	return C.CString(string(data))
}

func runTcpTest(host string, port int, useProtect bool) TcpTestResult {
	result := TcpTestResult{
		Ok:         false,
		UseProtect: useProtect,
		Host:       host,
		Port:       port,
	}

	t0 := time.Now()

	// Create raw TCP socket.
	// Using AF_INET=2, SOCK_STREAM=1, IPPROTO_TCP=6
	fd, err := syscallSocket(2, 1, 6)
	if err != 0 {
		result.Error = fmt.Sprintf("socket() failed: errno=%d", err)
		setLastEvent(fmt.Sprintf("tcp-test socket failed errno=%d", err))
		return result
	}
	defer syscallClose(fd)
	syscallSetSocketTimeouts(fd, 5, 0)

	// Call protect before connect if requested
	if useProtect {
		if protectErr := doProtect(fd); protectErr != 0 {
			result.Error = fmt.Sprintf("protect() failed: code=%d", protectErr)
			setLastEvent(fmt.Sprintf("tcp-test protect failed code=%d", protectErr))
			return result
		}
	}

	// Parse host to IP (try direct IP first, then we'll use 1.1.1.1 as fallback for well-known)
	addr := parseIPv4(host)
	if addr == 0 {
		// Use DNS-like well-known IPs for testing
		switch host {
		case "cloudflare-dns.com", "1.1.1.1":
			addr = 0x01010101 // 1.1.1.1
		case "google-dns.com", "8.8.8.8":
			addr = 0x08080808 // 8.8.8.8
		case "example.com":
			addr = 0x5db8d822 // 93.184.216.34
		default:
			addr = 0x01010101 // default to 1.1.1.1
		}
	}

	connAddr := syscallSockaddrInet4(addr, port)
	t1 := time.Now()

	// Connect
	err = syscallConnect(fd, connAddr)
	if err != 0 {
		result.Error = fmt.Sprintf("connect() failed: errno=%d", err)
		setLastEvent(fmt.Sprintf("tcp-test connect failed errno=%d useProtect=%v", err, useProtect))
		result.ConnectMs = time.Since(t1).Milliseconds()
		return result
	}
	result.ConnectMs = time.Since(t1).Milliseconds()
	t2 := time.Now()

	// Send minimal HTTP request
	httpReq := fmt.Sprintf("GET / HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n", host)
	_, err = syscallWrite(fd, []byte(httpReq))
	if err != 0 {
		result.Error = fmt.Sprintf("write() failed: errno=%d", err)
		setLastEvent(fmt.Sprintf("tcp-test write failed errno=%d useProtect=%v", err, useProtect))
		result.WriteMs = time.Since(t2).Milliseconds()
		return result
	}
	result.WriteMs = time.Since(t2).Milliseconds()
	t3 := time.Now()

	// Read response with timeout
	buf := make([]byte, 4096)
	totalRead := 0
	readDeadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(readDeadline) {
		n, err := syscallRead(fd, buf[totalRead:])
		if err != 0 {
			if totalRead > 0 {
				break // Got some data, that's fine
			}
			result.Error = fmt.Sprintf("read() failed: errno=%d", err)
			setLastEvent(fmt.Sprintf("tcp-test read failed errno=%d useProtect=%v", err, useProtect))
			result.ReadMs = time.Since(t3).Milliseconds()
			return result
		}
		totalRead += n
		if n == 0 || totalRead >= len(buf) {
			break
		}
	}
	result.ReadMs = time.Since(t3).Milliseconds()
	result.BytesRead = totalRead
	result.ResponseLen = totalRead
	result.Ok = totalRead > 0

	setLastEvent(fmt.Sprintf("tcp-test done ok=%v useProtect=%v connectMs=%d readMs=%d bytes=%d elapsed=%dms",
		result.Ok, useProtect, result.ConnectMs, result.ReadMs, totalRead, time.Since(t0).Milliseconds()))
	return result
}

func runUdpTest(host string, port int, useProtect bool) UdpTestResult {
	result := UdpTestResult{
		Ok:         false,
		UseProtect: useProtect,
		Host:       host,
		Port:       port,
	}

	t0 := time.Now()

	// Create UDP socket: AF_INET=2, SOCK_DGRAM=2, IPPROTO_UDP=17
	fd, err := syscallSocket(2, 2, 17)
	if err != 0 {
		result.Error = fmt.Sprintf("socket() failed: errno=%d", err)
		setLastEvent(fmt.Sprintf("udp-test socket failed errno=%d", err))
		return result
	}
	defer syscallClose(fd)
	syscallSetSocketTimeouts(fd, 2, 0)

	if useProtect {
		if protectErr := doProtect(fd); protectErr != 0 {
			result.Error = fmt.Sprintf("protect() failed: code=%d", protectErr)
			setLastEvent(fmt.Sprintf("udp-test protect failed code=%d", protectErr))
			return result
		}
	}

	addr := syscallSockaddrInet4(parseIPv4(host), port)

	t1 := time.Now()

	// Connect UDP socket to bind the peer and make route/error reporting explicit.
	err = syscallConnect(fd, addr)
	if err != 0 {
		result.Error = fmt.Sprintf("connect() failed: errno=%d", err)
		setLastEvent(fmt.Sprintf("udp-test connect failed errno=%d useProtect=%v", err, useProtect))
		result.SendMs = time.Since(t1).Milliseconds()
		return result
	}

	// Build DNS query for example.com (A record)
	dnsQuery := buildDnsQuery("example.com")

	// Send DNS query
	n, err := syscallWrite(fd, dnsQuery)
	if err != 0 || n < 0 {
		result.Error = fmt.Sprintf("write() failed: errno=%d n=%d", err, n)
		setLastEvent(fmt.Sprintf("udp-test write failed errno=%d useProtect=%v", err, useProtect))
		result.SendMs = time.Since(t1).Milliseconds()
		return result
	}
	result.SendMs = time.Since(t1).Milliseconds()
	t2 := time.Now()

	// Receive DNS response
	recvBuf := make([]byte, 512)
	n, err = syscallRead(fd, recvBuf)
	if err != 0 || n <= 0 {
		result.Error = fmt.Sprintf("read() failed: errno=%d n=%d", err, n)
		setLastEvent(fmt.Sprintf("udp-test read failed errno=%d useProtect=%v", err, useProtect))
		result.RecvMs = time.Since(t2).Milliseconds()
		return result
	}
	result.RecvMs = time.Since(t2).Milliseconds()
	result.BytesRecv = n
	result.HasResponse = n > 0
	result.Ok = n > 0

	setLastEvent(fmt.Sprintf("udp-test done ok=%v useProtect=%v sendMs=%d recvMs=%d bytes=%d elapsed=%dms",
		result.Ok, useProtect, result.SendMs, result.RecvMs, n, time.Since(t0).Milliseconds()))
	return result
}

// buildDnsQuery creates a simple DNS query for an A record.
func buildDnsQuery(domain string) []byte {
	// Build a minimal DNS query packet
	// Header: ID=0x1234, Flags=0x0100 (standard query, recursion desired), QDCOUNT=1
	query := []byte{
		0x12, 0x34, // Transaction ID
		0x01, 0x00, // Flags: standard query, recursion desired
		0x00, 0x01, // Questions: 1
		0x00, 0x00, // Answer RRs: 0
		0x00, 0x00, // Authority RRs: 0
		0x00, 0x00, // Additional RRs: 0
	}

	// Encode domain name as labels
	parts := splitDomain(domain)
	for _, part := range parts {
		query = append(query, byte(len(part)))
		query = append(query, []byte(part)...)
	}
	query = append(query, 0x00) // Terminating zero-length label

	// QTYPE: A (0x0001)
	query = append(query, 0x00, 0x01)
	// QCLASS: IN (0x0001)
	query = append(query, 0x00, 0x01)

	return query
}

func splitDomain(domain string) []string {
	var parts []string
	current := ""
	for _, c := range domain {
		if c == '.' {
			parts = append(parts, current)
			current = ""
		} else {
			current += string(c)
		}
	}
	if current != "" {
		parts = append(parts, current)
	}
	return parts
}

func parseIPv4(host string) uint32 {
	var a, b, c, d uint32
	n, _ := fmt.Sscanf(host, "%d.%d.%d.%d", &a, &b, &c, &d)
	if n == 4 && a <= 255 && b <= 255 && c <= 255 && d <= 255 {
		return (a << 24) | (b << 16) | (c << 8) | d
	}
	return 0
}

// ---------- Raw syscall wrappers ----------

func syscallSocket(domain, typ, proto int) (int, int) {
	return rawSocket(domain, typ, proto)
}

func syscallClose(fd int) {
	rawClose(fd)
}

func syscallConnect(fd int, addr [4]uint32) int {
	return rawConnect(fd, addr)
}

func syscallSendto(fd int, data []byte, addr [4]uint32) (int, int) {
	return rawSendto(fd, data, addr)
}

func syscallRecvfrom(fd int, buf []byte) (int, int) {
	return rawRecvfrom(fd, buf)
}

func syscallWrite(fd int, data []byte) (int, int) {
	return rawWrite(fd, data)
}

func syscallRead(fd int, buf []byte) (int, int) {
	return rawRead(fd, buf)
}

func syscallSockaddrInet4(ip uint32, port int) [4]uint32 {
	return [4]uint32{ip, uint32(port), 0, 0}
}

func syscallSetSocketTimeouts(fd int, sec int, usec int) {
	rawSetSocketTimeouts(fd, sec, usec)
}

func main() {}
