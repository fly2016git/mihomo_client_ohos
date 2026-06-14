package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	_ "github.com/metacubex/mihomo/common/orderedmap"
	_ "github.com/metacubex/mihomo/common/structure"
	_ "github.com/metacubex/mihomo/common/utils"
	_ "github.com/metacubex/mihomo/common/yaml"
)

//export MihomoOhosVersion
func MihomoOhosVersion() *C.char { return C.CString("common-probe") }

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
