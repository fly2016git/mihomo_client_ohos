package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	_ "github.com/metacubex/mihomo/rules"
	_ "github.com/metacubex/mihomo/rules/bundle"
	_ "github.com/metacubex/mihomo/rules/common"
	_ "github.com/metacubex/mihomo/rules/provider"
	_ "github.com/metacubex/mihomo/rules/wrapper"
)

//export MihomoOhosVersion
func MihomoOhosVersion() *C.char { return C.CString("rules-probe") }

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
