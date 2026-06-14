// Protect bridge - compiled into Go .so so dlopen resolves all symbols.
// The actual protect function is set at runtime by the NAPI layer.

#include <stddef.h>

static int (*g_protect_fn)(int) = NULL;

// Called by Go core between socket() and connect().
int PocProtectBridge(int fd)
{
    if (g_protect_fn != NULL) {
        return g_protect_fn(fd);
    }
    return -100;
}

// Called by NAPI layer to register the real protect implementation.
void PocProtectBridgeSetFn(int (*fn)(int))
{
    g_protect_fn = fn;
}
