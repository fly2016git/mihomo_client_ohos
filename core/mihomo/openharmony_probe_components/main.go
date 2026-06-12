package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	_ "github.com/metacubex/mihomo/component/age"
	_ "github.com/metacubex/mihomo/component/auth"
	_ "github.com/metacubex/mihomo/component/cidr"
	_ "github.com/metacubex/mihomo/component/fakeip"
	_ "github.com/metacubex/mihomo/component/geodata"
	_ "github.com/metacubex/mihomo/component/process"
	_ "github.com/metacubex/mihomo/component/resolver"
	_ "github.com/metacubex/mihomo/component/sniffer"
	_ "github.com/metacubex/mihomo/component/trie"
)

//export MihomoOhosVersion
func MihomoOhosVersion() *C.char { return C.CString("components-probe") }

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
