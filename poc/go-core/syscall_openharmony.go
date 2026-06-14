package main

// Raw syscall wrappers for OpenHarmony (Linux arm64 ABI).
// Uses the syscall instruction with aarch64 calling convention.

import (
	"syscall"
	"unsafe"
)

// rawSocket creates a socket: socket(domain, type, protocol)
func rawSocket(domain, typ, proto int) (int, int) {
	fd, _, errno := syscall.Syscall(syscall.SYS_SOCKET, uintptr(domain), uintptr(typ), uintptr(proto))
	if errno != 0 {
		return -1, int(errno)
	}
	return int(fd), 0
}

// rawClose closes a file descriptor: close(fd)
func rawClose(fd int) {
	syscall.Syscall(syscall.SYS_CLOSE, uintptr(fd), 0, 0)
}

// rawConnect connects a socket: connect(fd, sockaddr, addrlen)
func rawConnect(fd int, addr [4]uint32) int {
	// Build sockaddr_in: family(2) + port(2) + ip(4) + padding(8) = 16 bytes
	sockaddr := make([]byte, 16)
	// sin_family = AF_INET (2)
	sockaddr[0] = 2
	sockaddr[1] = 0
	// sin_port = htons(port)
	port := uint16(addr[1])
	sockaddr[2] = byte(port >> 8)
	sockaddr[3] = byte(port & 0xFF)
	// sin_addr = ip (network byte order, already big-endian)
	ip := addr[0]
	sockaddr[4] = byte(ip >> 24)
	sockaddr[5] = byte(ip >> 16)
	sockaddr[6] = byte(ip >> 8)
	sockaddr[7] = byte(ip)

	_, _, errno := syscall.Syscall(syscall.SYS_CONNECT, uintptr(fd), uintptr(unsafe.Pointer(&sockaddr[0])), uintptr(16))
	if errno != 0 {
		return int(errno)
	}
	return 0
}

// rawSendto sends data on a socket: sendto(fd, buf, len, flags, dest_addr, addrlen)
func rawSendto(fd int, data []byte, addr [4]uint32) (int, int) {
	// Build sockaddr_in
	sockaddr := make([]byte, 16)
	sockaddr[0] = 2
	sockaddr[1] = 0
	port := uint16(addr[1])
	sockaddr[2] = byte(port >> 8)
	sockaddr[3] = byte(port & 0xFF)
	ip := addr[0]
	sockaddr[4] = byte(ip >> 24)
	sockaddr[5] = byte(ip >> 16)
	sockaddr[6] = byte(ip >> 8)
	sockaddr[7] = byte(ip)

	var bufPtr unsafe.Pointer
	if len(data) > 0 {
		bufPtr = unsafe.Pointer(&data[0])
	}
	n, _, errno := syscall.Syscall6(syscall.SYS_SENDTO, uintptr(fd), uintptr(bufPtr), uintptr(len(data)),
		uintptr(0), uintptr(unsafe.Pointer(&sockaddr[0])), uintptr(16))
	if errno != 0 {
		return -1, int(errno)
	}
	return int(n), 0
}

// rawRecvfrom receives data on a socket: recvfrom(fd, buf, len, flags, NULL, NULL)
func rawRecvfrom(fd int, buf []byte) (int, int) {
	var bufPtr unsafe.Pointer
	if len(buf) > 0 {
		bufPtr = unsafe.Pointer(&buf[0])
	}
	n, _, errno := syscall.Syscall6(syscall.SYS_RECVFROM, uintptr(fd), uintptr(bufPtr), uintptr(len(buf)),
		uintptr(0), uintptr(0), uintptr(0))
	if errno != 0 {
		return -1, int(errno)
	}
	return int(n), 0
}

// rawWrite writes data to a file descriptor: write(fd, buf, len)
func rawWrite(fd int, data []byte) (int, int) {
	var bufPtr unsafe.Pointer
	if len(data) > 0 {
		bufPtr = unsafe.Pointer(&data[0])
	}
	n, _, errno := syscall.Syscall(syscall.SYS_WRITE, uintptr(fd), uintptr(bufPtr), uintptr(len(data)))
	if errno != 0 {
		return -1, int(errno)
	}
	return int(n), 0
}

// rawRead reads data from a file descriptor: read(fd, buf, len)
func rawRead(fd int, buf []byte) (int, int) {
	var bufPtr unsafe.Pointer
	if len(buf) > 0 {
		bufPtr = unsafe.Pointer(&buf[0])
	}
	n, _, errno := syscall.Syscall(syscall.SYS_READ, uintptr(fd), uintptr(bufPtr), uintptr(len(buf)))
	if errno != 0 {
		return -1, int(errno)
	}
	return int(n), 0
}

// rawSetSocketTimeouts sets socket send/receive timeouts.
// timeval structure: tv_sec (8 bytes), tv_usec (8 bytes) on 64-bit
func rawSetSocketTimeouts(fd int, sec int, usec int) {
	tv := make([]byte, 16)
	// timeval: tv_sec (int64) + tv_usec (int64) on 64-bit
	// Put sec in little-endian
	tv[0] = byte(sec)
	tv[1] = byte(sec >> 8)
	tv[2] = byte(sec >> 16)
	tv[3] = byte(sec >> 24)
	tv[4] = byte(sec >> 32)
	tv[5] = byte(sec >> 40)
	tv[6] = byte(sec >> 48)
	tv[7] = byte(sec >> 56)
	tv[8] = byte(usec)
	tv[9] = byte(usec >> 8)
	tv[10] = byte(usec >> 16)
	tv[11] = byte(usec >> 24)
	tv[12] = byte(usec >> 32)
	tv[13] = byte(usec >> 40)
	tv[14] = byte(usec >> 48)
	tv[15] = byte(usec >> 56)

	// SOL_SOCKET = 1, SO_RCVTIMEO = 20, SO_SNDTIMEO = 21
	syscall.Syscall6(syscall.SYS_SETSOCKOPT, uintptr(fd), uintptr(1), uintptr(20),
		uintptr(unsafe.Pointer(&tv[0])), uintptr(16), 0)
	syscall.Syscall6(syscall.SYS_SETSOCKOPT, uintptr(fd), uintptr(1), uintptr(21),
		uintptr(unsafe.Pointer(&tv[0])), uintptr(16), 0)
}
