package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	_ "golang.org/x/crypto/blowfish"
	_ "golang.org/x/crypto/cast5"
	_ "golang.org/x/crypto/salsa20"
	_ "golang.org/x/crypto/tea"
	_ "golang.org/x/crypto/twofish"
	_ "golang.org/x/crypto/xtea"
)

//export MihomoOhosVersion
func MihomoOhosVersion() *C.char { return C.CString("ext-old-crypto-probe") }

//export MihomoOhosPing
func MihomoOhosPing() C.int { return 404 }

//export MihomoOhosStartConfig
func MihomoOhosStartConfig(homeDir *C.char, configBytes *C.char, configLen C.int) C.int { return 0 }

//export MihomoOhosStartConfigFile
func MihomoOhosStartConfigFile(homeDir *C.char, configPath *C.char) C.int { return 0 }

//export MihomoOhosStop
func MihomoOhosStop() C.int { return 0 }

//export MihomoOhosLastError
func MihomoOhosLastError() *C.char { return C.CString("") }

//export MihomoOhosFreeCString
func MihomoOhosFreeCString(s *C.char) {
	if s != nil {
		C.free(unsafe.Pointer(s))
	}
}

func main() {}
