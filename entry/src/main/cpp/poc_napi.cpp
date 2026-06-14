#include <dlfcn.h>
#include <fcntl.h>
#include <hilog/log.h>
#include <napi/native_api.h>
#include <poll.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace {
constexpr unsigned int POC_LOG_DOMAIN = 0x0001;
constexpr const char *POC_LOG_TAG = "MihomoPocNapi";
constexpr const char *GO_LIB_NAME = "libpoc_go_core.so";
constexpr const char *MIHOMO_LIB_NAME = "libmihomo_ohos.so";

// ---------- POC-02: Go core function pointers ----------

using PocGoVersionFn = const char *(*)();
using PocGoAddFn = int32_t (*)(int32_t, int32_t);
using PocGoStartWorkerFn = int32_t (*)(int32_t);
using PocGoStopWorkerFn = int32_t (*)();
using PocGoLastEventFn = const char *(*)();
using PocGoPanicProbeFn = int32_t (*)();
using PocGoFreeFn = void (*)(void *);

// ---------- POC-03: Go socket test function pointers ----------

using PocGoTcpTestFn = const char *(*)(const char *, int32_t, int32_t);
using PocGoUdpTestFn = const char *(*)(const char *, int32_t, int32_t);
using PocGoSetProtectBridgeFn = void (*)(void *fn);
using PocProtectBridgeSetFn = void (*)(int (*fn)(int));

// ---------- POC-04: mihomo c-shared function pointers ----------

using MihomoOhosVersionFn = const char *(*)();
using MihomoOhosPingFn = int32_t (*)();
using MihomoOhosStartConfigFn = int32_t (*)(const char *, const char *, int32_t);
using MihomoOhosStartConfigFileFn = int32_t (*)(const char *, const char *);
using MihomoOhosStartConfigFileWithTunFdFn = int32_t (*)(const char *, const char *, int32_t);
using MihomoOhosStopFn = int32_t (*)();
using MihomoOhosGracefulStopFn = int32_t (*)();
using MihomoOhosSetProtectBridgeFn = void (*)(void *fn);
using MihomoOhosEnableProtectHookFn = int32_t (*)();
using MihomoOhosDisableProtectHookFn = int32_t (*)();
using MihomoOhosIsRunningFn = int32_t (*)();
using MihomoOhosLastErrorFn = const char *(*)();
using MihomoOhosProxyDelayFn = const char *(*)(const char *, const char *, int32_t);
using MihomoOhosGroupDelayFn = const char *(*)(const char *, const char *, int32_t);
using MihomoOhosFreeCStringFn = void (*)(void *);

struct GoCoreApi {
    void *handle = nullptr;
    // POC-02
    PocGoVersionFn version = nullptr;
    PocGoAddFn add = nullptr;
    PocGoStartWorkerFn startWorker = nullptr;
    PocGoStopWorkerFn stopWorker = nullptr;
    PocGoLastEventFn lastEvent = nullptr;
    PocGoPanicProbeFn panicProbe = nullptr;
    PocGoFreeFn freeString = nullptr;
    // POC-03
    PocGoTcpTestFn tcpTest = nullptr;
    PocGoUdpTestFn udpTest = nullptr;
    PocGoSetProtectBridgeFn setProtectBridgeFn = nullptr;
    PocProtectBridgeSetFn protectBridgeSetFn = nullptr;
    std::string lastError;
};

std::mutex g_goMutex;
GoCoreApi g_go;

struct MihomoCoreApi {
    void *handle = nullptr;
    MihomoOhosVersionFn version = nullptr;
    MihomoOhosPingFn ping = nullptr;
    MihomoOhosStartConfigFn startConfig = nullptr;
    MihomoOhosStartConfigFileFn startConfigFile = nullptr;
    MihomoOhosStartConfigFileWithTunFdFn startConfigFileWithTunFd = nullptr;
    MihomoOhosStopFn stop = nullptr;
    MihomoOhosGracefulStopFn gracefulStop = nullptr;
    MihomoOhosSetProtectBridgeFn setProtectBridge = nullptr;
    MihomoOhosEnableProtectHookFn enableProtectHook = nullptr;
    MihomoOhosDisableProtectHookFn disableProtectHook = nullptr;
    MihomoOhosIsRunningFn isRunning = nullptr;
    MihomoOhosLastErrorFn lastErrorFn = nullptr;
    MihomoOhosProxyDelayFn proxyDelay = nullptr;
    MihomoOhosGroupDelayFn groupDelay = nullptr;
    MihomoOhosFreeCStringFn freeString = nullptr;
    std::string lastError;
};

std::mutex g_mihomoMutex;
MihomoCoreApi g_mihomo;
std::atomic<bool> g_tunProbeRunning{false};
std::mutex g_tunFdHoldMutex;
int g_heldTunFd = -1;

// ---------- POC-03: Protect callback infrastructure ----------

std::mutex g_protectCbMutex;
std::mutex g_protectCallMutex;
napi_threadsafe_function g_protectTsfn = nullptr;
std::atomic<bool> g_protectDone{false};
std::atomic<int> g_protectError{0};
std::atomic<int> g_pendingProtectFd{-1};

struct ProtectPromiseCallbackContext;

struct ProtectPromiseState {
    int fd = -1;
    bool settled = false;
    ProtectPromiseCallbackContext *resolveCtx = nullptr;
    ProtectPromiseCallbackContext *rejectCtx = nullptr;
};

struct ProtectPromiseCallbackContext {
    ProtectPromiseState *state = nullptr;
    bool resolve = false;
};

struct SocketTestAsyncData {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    bool tcp = true;
    bool useProtect = false;
    int32_t port = 0;
    std::string host;
    std::string result;
    std::string error;
};

struct MihomoAsyncData {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string op;
    std::string homeDir;
    std::string config;
    int32_t originalTunFd = -1;
    int32_t tunFd = -1;
    std::string message;
    int32_t code = 0;
    bool ok = false;
};

struct MihomoDelayAsyncData {
    napi_env env = nullptr;
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    bool group = false;
    std::string name;
    std::string url;
    int32_t timeoutMs = 5000;
    std::string result;
    std::string error;
};

int ProtectResultFromValue(napi_env env, napi_value value)
{
    napi_valuetype valueType = napi_undefined;
    if (napi_typeof(env, value, &valueType) != napi_ok) {
        return -20;
    }

    if (valueType == napi_boolean) {
        bool ok = false;
        if (napi_get_value_bool(env, value, &ok) != napi_ok) {
            return -21;
        }
        return ok ? 0 : -22;
    }

    if (valueType == napi_number) {
        int32_t code = 0;
        if (napi_get_value_int32(env, value, &code) != napi_ok) {
            return -23;
        }
        return code;
    }

    return 0;
}

void CompleteProtectPromise(ProtectPromiseCallbackContext *ctx, int error)
{
    if (ctx == nullptr || ctx->state == nullptr) {
        return;
    }

    ProtectPromiseState *state = ctx->state;
    if (!state->settled) {
        state->settled = true;
        g_protectError.store(error);
        g_protectDone.store(true);

        OH_LOG_Print(LOG_APP, error == 0 ? LOG_INFO : LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
            "protect promise settled fd=%{public}d error=%{public}d", state->fd, error);
    }

    delete state->resolveCtx;
    delete state->rejectCtx;
    delete state;
}

napi_value ProtectPromiseCallback(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    void *data = nullptr;
    napi_get_cb_info(env, info, &argc, args, nullptr, &data);

    auto *ctx = static_cast<ProtectPromiseCallbackContext *>(data);
    int error = 0;
    if (ctx == nullptr || !ctx->resolve) {
        error = -24;
    } else if (argc >= 1 && args[0] != nullptr) {
        error = ProtectResultFromValue(env, args[0]);
    }

    CompleteProtectPromise(ctx, error);

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

bool AttachProtectPromiseHandlers(napi_env env, napi_value promise, int fd)
{
    napi_value thenFn = nullptr;
    if (napi_get_named_property(env, promise, "then", &thenFn) != napi_ok) {
        return false;
    }

    napi_valuetype thenType = napi_undefined;
    if (napi_typeof(env, thenFn, &thenType) != napi_ok || thenType != napi_function) {
        return false;
    }

    auto *state = new ProtectPromiseState();
    state->fd = fd;
    state->resolveCtx = new ProtectPromiseCallbackContext();
    state->rejectCtx = new ProtectPromiseCallbackContext();
    state->resolveCtx->state = state;
    state->resolveCtx->resolve = true;
    state->rejectCtx->state = state;
    state->rejectCtx->resolve = false;

    napi_value onResolve = nullptr;
    napi_value onReject = nullptr;
    napi_create_function(env, "protectResolved", NAPI_AUTO_LENGTH, ProtectPromiseCallback, state->resolveCtx, &onResolve);
    napi_create_function(env, "protectRejected", NAPI_AUTO_LENGTH, ProtectPromiseCallback, state->rejectCtx, &onReject);

    napi_value thenArgs[2] = { onResolve, onReject };
    napi_value ignored = nullptr;
    napi_status status = napi_call_function(env, promise, thenFn, 2, thenArgs, &ignored);
    if (status != napi_ok) {
        delete state->resolveCtx;
        delete state->rejectCtx;
        delete state;
        return false;
    }

    return true;
}

// Called by the NAPI thread-safe function on the main thread.
// Invokes the ArkTS protect callback with the fd.
void ProtectTsfnCallback(napi_env env, napi_value jsCallback, void *context, void *data)
{
    (void)context;

    std::unique_ptr<int> fdPtr(static_cast<int *>(data));
    int fd = fdPtr == nullptr ? -1 : *fdPtr;
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "protect callback invoked fd=%{public}d", fd);

    if (jsCallback == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG,
            "protect callback is null, fd=%{public}d", fd);
        g_protectError.store(-1);
        g_protectDone.store(true);
        return;
    }

    // Call the ArkTS callback: callback(fd)
    napi_value jsFd;
    napi_create_int32(env, fd, &jsFd);
    napi_value args[1] = {jsFd};

    napi_value global;
    napi_get_global(env, &global);

    napi_value result;
    napi_status status = napi_call_function(env, global, jsCallback, 1, args, &result);
    if (status != napi_ok) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG,
            "protect callback invocation failed status=%{public}d fd=%{public}d", status, fd);
        g_protectError.store(-2);
    } else {
        bool isPromise = false;
        if (napi_is_promise(env, result, &isPromise) == napi_ok && isPromise) {
            if (AttachProtectPromiseHandlers(env, result, fd)) {
                OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                    "protect callback returned promise fd=%{public}d", fd);
                return;
            }
            OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG,
                "protect promise handler attach failed fd=%{public}d", fd);
            g_protectError.store(-4);
        } else {
            int protectError = ProtectResultFromValue(env, result);
            OH_LOG_Print(LOG_APP, protectError == 0 ? LOG_INFO : LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
                "protect callback completed fd=%{public}d error=%{public}d", fd, protectError);
            g_protectError.store(protectError);
        }
    }
    g_protectDone.store(true);
}

// C ABI function registered with Go core's protect bridge.
// Called by Go core (via protect_bridge.c) between socket() and connect().
// This blocks until the ArkTS protect callback completes.
extern "C" int NapiProtectBridgeImpl(int fd)
{
    std::lock_guard<std::mutex> callLock(g_protectCallMutex);

    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "NapiProtectBridgeImpl called fd=%{public}d", fd);

    {
        std::lock_guard<std::mutex> lock(g_protectCbMutex);
        if (g_protectTsfn == nullptr) {
            OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG,
                "protect tsfn not registered, fd=%{public}d", fd);
            return -1;
        }
    }

    g_protectDone.store(false);
    g_protectError.store(0);
    g_pendingProtectFd.store(fd);

    int *queuedFd = new int(fd);
    napi_status status = napi_call_threadsafe_function(g_protectTsfn, queuedFd, napi_tsfn_blocking);
    if (status != napi_ok) {
        delete queuedFd;
        OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG,
            "napi_call_threadsafe_function failed status=%{public}d fd=%{public}d", status, fd);
        g_protectDone.store(true);
        g_protectError.store(-3);
        return -3;
    }

    // Wait for the protect callback to complete (on the main thread).
    // With a timeout of 5 seconds.
    int waited = 0;
    while (!g_protectDone.load() && waited < 500) {
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
        waited += 10;
    }

    if (!g_protectDone.load()) {
        OH_LOG_Print(LOG_APP, LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
            "protect timed out after %{public}d ms fd=%{public}d", waited, fd);
        g_protectError.store(-6);
    } else if (g_protectError.load() != 0) {
        OH_LOG_Print(LOG_APP, LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
            "protect error=%{public}d fd=%{public}d", g_protectError.load(), fd);
    } else {
        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
            "protect done ok fd=%{public}d", fd);
    }

    return g_protectError.load();
}

// ---------- Symbol loading ----------

bool LoadSymbol(void *handle, const char *name, void **out)
{
    dlerror();
    *out = dlsym(handle, name);
    const char *err = dlerror();
    if (err != nullptr || *out == nullptr) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG, "dlsym %{public}s failed: %{public}s", name,
            err == nullptr ? "unknown" : err);
        return false;
    }
    return true;
}

bool EnsureGoCoreLocked()
{
    if (g_go.handle != nullptr) {
        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
            "Go core already loaded, reuse handle");
        return true;
    }

    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "dlopen %{public}s begin", GO_LIB_NAME);
    dlerror();
    void *handle = dlopen(GO_LIB_NAME, RTLD_NOW);
    if (handle == nullptr) {
        const char *err = dlerror();
        g_go.lastError = std::string("dlopen ") + GO_LIB_NAME + " failed: " + (err == nullptr ? "unknown" : err);
        OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG, "%{public}s", g_go.lastError.c_str());
        return false;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "dlopen %{public}s ok handle=%{public}p", GO_LIB_NAME, handle);

    GoCoreApi next;
    next.handle = handle;
    // POC-02 symbols (required)
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "resolving POC-02 Go symbols begin");
    bool ok = LoadSymbol(handle, "PocGoVersion", reinterpret_cast<void **>(&next.version)) &&
        LoadSymbol(handle, "PocGoAdd", reinterpret_cast<void **>(&next.add)) &&
        LoadSymbol(handle, "PocGoStartWorker", reinterpret_cast<void **>(&next.startWorker)) &&
        LoadSymbol(handle, "PocGoStopWorker", reinterpret_cast<void **>(&next.stopWorker)) &&
        LoadSymbol(handle, "PocGoLastEvent", reinterpret_cast<void **>(&next.lastEvent)) &&
        LoadSymbol(handle, "PocGoPanicProbe", reinterpret_cast<void **>(&next.panicProbe)) &&
        LoadSymbol(handle, "PocGoFree", reinterpret_cast<void **>(&next.freeString));

    if (!ok) {
        dlclose(handle);
        g_go.lastError = "Go core symbol resolution failed (POC-02)";
        return false;
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "resolving POC-02 Go symbols ok");

    // POC-03 symbols (optional - only resolve if present)
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "resolving POC-03 Go symbols begin");
    bool hasTcpTest = LoadSymbol(handle, "PocGoTcpTest", reinterpret_cast<void **>(&next.tcpTest));
    bool hasUdpTest = LoadSymbol(handle, "PocGoUdpTest", reinterpret_cast<void **>(&next.udpTest));
    bool hasSetProtectBridge = LoadSymbol(handle, "PocGoSetProtectBridgeFn",
        reinterpret_cast<void **>(&next.setProtectBridgeFn));
    bool hasDirectProtectBridgeSet = LoadSymbol(handle, "PocProtectBridgeSetFn",
        reinterpret_cast<void **>(&next.protectBridgeSetFn));
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "resolving POC-03 Go symbols done tcp=%{public}d udp=%{public}d goProtect=%{public}d cProtect=%{public}d",
        hasTcpTest ? 1 : 0, hasUdpTest ? 1 : 0, hasSetProtectBridge ? 1 : 0, hasDirectProtectBridgeSet ? 1 : 0);

    if (!hasTcpTest) {
        OH_LOG_Print(LOG_APP, LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
            "PocGoTcpTest not found in Go core - POC-03 tcp test unavailable");
        next.tcpTest = nullptr;
    }
    if (!hasUdpTest) {
        OH_LOG_Print(LOG_APP, LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
            "PocGoUdpTest not found in Go core - POC-03 udp test unavailable");
        next.udpTest = nullptr;
    }

    // Register the NAPI protect bridge directly into protect_bridge.c.
    // Avoid entering Go runtime only to set a C static function pointer.
    if (hasDirectProtectBridgeSet && next.protectBridgeSetFn != nullptr) {
        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
            "calling PocProtectBridgeSetFn directly");
        next.protectBridgeSetFn(NapiProtectBridgeImpl);
        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
            "protect bridge registered: C PocProtectBridge -> NAPI NapiProtectBridgeImpl");
    } else {
        OH_LOG_Print(LOG_APP, LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
            "PocProtectBridgeSetFn not found - protect bridge not registered");
    }

    next.lastError.clear();
    g_go = next;
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "Go core loaded (POC-02 + POC-03 symbols)");
    return true;
}

std::string TakeGoStringLocked(const char *value)
{
    if (value == nullptr) {
        return "";
    }
    std::string copied(value);
    if (g_go.freeString != nullptr) {
        g_go.freeString(const_cast<char *>(value));
    }
    return copied;
}

std::string TakeMihomoStringLocked(const char *value)
{
    if (value == nullptr) {
        return "";
    }
    std::string copied(value);
    if (g_mihomo.freeString != nullptr) {
        g_mihomo.freeString(const_cast<char *>(value));
    }
    return copied;
}

bool EnsureMihomoCoreLocked()
{
    if (g_mihomo.handle != nullptr) {
        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
            "mihomo core already loaded, reuse handle");
        return true;
    }

    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "dlopen %{public}s begin", MIHOMO_LIB_NAME);
    dlerror();
    void *handle = dlopen(MIHOMO_LIB_NAME, RTLD_NOW);
    if (handle == nullptr) {
        const char *err = dlerror();
        g_mihomo.lastError = std::string("dlopen ") + MIHOMO_LIB_NAME + " failed: " +
            (err == nullptr ? "unknown" : err);
        OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG, "%{public}s", g_mihomo.lastError.c_str());
        return false;
    }

    MihomoCoreApi next;
    next.handle = handle;
    bool ok = LoadSymbol(handle, "MihomoOhosVersion", reinterpret_cast<void **>(&next.version)) &&
        LoadSymbol(handle, "MihomoOhosPing", reinterpret_cast<void **>(&next.ping)) &&
        LoadSymbol(handle, "MihomoOhosStartConfig", reinterpret_cast<void **>(&next.startConfig)) &&
        LoadSymbol(handle, "MihomoOhosStartConfigFile", reinterpret_cast<void **>(&next.startConfigFile)) &&
        LoadSymbol(handle, "MihomoOhosStartConfigFileWithTunFd",
            reinterpret_cast<void **>(&next.startConfigFileWithTunFd)) &&
        LoadSymbol(handle, "MihomoOhosStop", reinterpret_cast<void **>(&next.stop)) &&
        LoadSymbol(handle, "MihomoOhosSetProtectBridge", reinterpret_cast<void **>(&next.setProtectBridge)) &&
        LoadSymbol(handle, "MihomoOhosLastError", reinterpret_cast<void **>(&next.lastErrorFn)) &&
        LoadSymbol(handle, "MihomoOhosFreeCString", reinterpret_cast<void **>(&next.freeString));

    if (!ok) {
        dlclose(handle);
        g_mihomo.lastError = "mihomo core symbol resolution failed";
        return false;
    }

    // Optional symbols (MVP-01B protect hook control + graceful stop)
    LoadSymbol(handle, "MihomoOhosEnableProtectHook", reinterpret_cast<void **>(&next.enableProtectHook));
    LoadSymbol(handle, "MihomoOhosDisableProtectHook", reinterpret_cast<void **>(&next.disableProtectHook));
    LoadSymbol(handle, "MihomoOhosIsRunning", reinterpret_cast<void **>(&next.isRunning));
    LoadSymbol(handle, "MihomoOhosGracefulStop", reinterpret_cast<void **>(&next.gracefulStop));
    LoadSymbol(handle, "MihomoOhosProxyDelay", reinterpret_cast<void **>(&next.proxyDelay));
    LoadSymbol(handle, "MihomoOhosGroupDelay", reinterpret_cast<void **>(&next.groupDelay));

    next.lastError.clear();
    next.setProtectBridge(reinterpret_cast<void *>(NapiProtectBridgeImpl));
    g_mihomo = next;
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "mihomo core loaded and protect bridge registered hooks=%{public}d/%{public}d/%{public}d graceful=%{public}d delay=%{public}d/%{public}d",
        next.enableProtectHook != nullptr ? 1 : 0,
        next.disableProtectHook != nullptr ? 1 : 0,
        next.isRunning != nullptr ? 1 : 0,
        next.gracefulStop != nullptr ? 1 : 0,
        next.proxyDelay != nullptr ? 1 : 0,
        next.groupDelay != nullptr ? 1 : 0);
    return true;
}

std::string MihomoLastErrorLocked()
{
    if (g_mihomo.lastErrorFn == nullptr) {
        return g_mihomo.lastError;
    }
    std::string error = TakeMihomoStringLocked(g_mihomo.lastErrorFn());
    return error.empty() ? g_mihomo.lastError : error;
}

bool ReadStringArg(napi_env env, napi_value value, std::string *out)
{
    if (out == nullptr) {
        return false;
    }
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    std::string result(len + 1, '\0');
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, &result[0], result.size(), &copied) != napi_ok) {
        return false;
    }
    result.resize(copied);
    *out = result;
    return true;
}

napi_value MakeString(napi_env env, const std::string &value)
{
    napi_value result = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &result);
    return result;
}

napi_value MakeInt(napi_env env, int32_t value)
{
    napi_value result = nullptr;
    napi_create_int32(env, value, &result);
    return result;
}

napi_value MakeBool(napi_env env, bool value)
{
    napi_value result = nullptr;
    napi_get_boolean(env, value, &result);
    return result;
}

void SetNamed(napi_env env, napi_value object, const char *name, napi_value value)
{
    napi_set_named_property(env, object, name, value);
}

napi_value MakeStatus(napi_env env, bool ok, int32_t code, const std::string &message)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    SetNamed(env, result, "ok", MakeBool(env, ok));
    SetNamed(env, result, "code", MakeInt(env, code));
    SetNamed(env, result, "message", MakeString(env, message));
    return result;
}

napi_value MakeRejectedPromise(napi_env env, const std::string &message)
{
    napi_deferred deferred = nullptr;
    napi_value promise = nullptr;
    napi_create_promise(env, &deferred, &promise);
    napi_reject_deferred(env, deferred, MakeString(env, message));
    return promise;
}

void CompleteMihomoAsync(napi_env env, napi_status status, void *rawData)
{
    auto *workData = static_cast<MihomoAsyncData *>(rawData);
    if (status != napi_ok) {
        napi_reject_deferred(env, workData->deferred, MakeString(env, workData->op + " async work failed"));
    } else {
        napi_resolve_deferred(env, workData->deferred, MakeStatus(env, workData->ok, workData->code,
            workData->message));
    }
    napi_delete_async_work(env, workData->work);
    delete workData;
}

// ---------- POC-02: NAPI exports (unchanged) ----------

napi_value LoadGoCore(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_goMutex);
    if (!EnsureGoCoreLocked()) {
        return MakeStatus(env, false, -1, g_go.lastError);
    }

    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "calling PocGoVersion");
    const char *versionPtr = g_go.version();
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "PocGoVersion returned ptr=%{public}p", versionPtr);
    std::string version = TakeGoStringLocked(versionPtr);
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "LoadGoCore version copied");
    return MakeStatus(env, true, 0, version);
}

napi_value Add(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t left = 0;
    int32_t right = 0;
    if (argc < 2 || napi_get_value_int32(env, args[0], &left) != napi_ok ||
        napi_get_value_int32(env, args[1], &right) != napi_ok) {
        return MakeInt(env, -1);
    }

    std::lock_guard<std::mutex> lock(g_goMutex);
    if (!EnsureGoCoreLocked()) {
        return MakeInt(env, -1);
    }
    int32_t result = g_go.add(left, right);
    return MakeInt(env, result);
}

napi_value StartWorker(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t intervalMs = 200;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &intervalMs);
    }

    std::lock_guard<std::mutex> lock(g_goMutex);
    if (!EnsureGoCoreLocked()) {
        return MakeStatus(env, false, -1, g_go.lastError);
    }

    int32_t code = g_go.startWorker(intervalMs);
    return MakeStatus(env, code == 0, code, code == 0 ? "worker started" : "worker already running");
}

napi_value StopWorker(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_goMutex);
    if (!EnsureGoCoreLocked()) {
        return MakeStatus(env, false, -1, g_go.lastError);
    }

    int32_t code = g_go.stopWorker();
    return MakeStatus(env, code == 0, code, code == 0 ? "worker stopped" : "worker not running");
}

napi_value GetLastEvent(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_goMutex);
    if (!EnsureGoCoreLocked()) {
        return MakeString(env, g_go.lastError);
    }

    return MakeString(env, TakeGoStringLocked(g_go.lastEvent()));
}

napi_value PanicProbe(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_goMutex);
    if (!EnsureGoCoreLocked()) {
        return MakeStatus(env, false, -1, g_go.lastError);
    }

    int32_t code = g_go.panicProbe();
    return MakeStatus(env, code == 0, code, code == 0 ? "panic converted to error" : "panic probe failed");
}

// ---------- POC-03: NAPI exports ----------

napi_value RegisterProtect(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        return MakeStatus(env, false, -1, "registerProtect requires a callback function");
    }

    napi_valuetype argType;
    napi_typeof(env, args[0], &argType);
    if (argType != napi_function) {
        return MakeStatus(env, false, -2, "registerProtect argument must be a function");
    }

    std::lock_guard<std::mutex> lock(g_protectCbMutex);

    // Release existing tsfn if any
    if (g_protectTsfn != nullptr) {
        napi_release_threadsafe_function(g_protectTsfn, napi_tsfn_release);
        g_protectTsfn = nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "PocProtectTsfn", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_threadsafe_function(
        env,
        args[0],            // js callback
        nullptr,            // async resource
        resourceName,       // resource name
        0,                  // max queue size (0 = unlimited)
        1,                  // initial thread count
        nullptr,            // thread finalize data
        nullptr,            // thread finalize callback
        nullptr,            // context
        ProtectTsfnCallback, // call js callback
        &g_protectTsfn
    );

    if (status != napi_ok) {
        g_protectTsfn = nullptr;
        OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG,
            "napi_create_threadsafe_function failed status=%{public}d", status);
        return MakeStatus(env, false, -3, "failed to create protect threadsafe function");
    }

    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG, "protect callback registered");
    return MakeStatus(env, true, 0, "protect callback registered");
}

napi_value RunTcpTest(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 3) {
        return MakeRejectedPromise(env, "runTcpTest requires host, port, useProtect");
    }

    // Get host string
    char hostBuf[256] = {};
    size_t hostLen = 0;
    if (napi_get_value_string_utf8(env, args[0], hostBuf, sizeof(hostBuf) - 1, &hostLen) != napi_ok) {
        return MakeRejectedPromise(env, "host must be a string");
    }

    // Get port
    int32_t port = 0;
    if (napi_get_value_int32(env, args[1], &port) != napi_ok) {
        return MakeRejectedPromise(env, "port must be an integer");
    }

    // Get useProtect
    bool useProtect = false;
    napi_get_value_bool(env, args[2], &useProtect);

    auto *data = new SocketTestAsyncData();
    data->env = env;
    data->tcp = true;
    data->host = hostBuf;
    data->port = port;
    data->useProtect = useProtect;

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "PocTcpTest", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<SocketTestAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_goMutex);
            if (!EnsureGoCoreLocked()) {
                workData->error = g_go.lastError;
                return;
            }
            if (g_go.tcpTest == nullptr) {
                workData->error = "PocGoTcpTest not available in Go core";
                return;
            }
            const char *jsonResult = g_go.tcpTest(workData->host.c_str(), workData->port, workData->useProtect ? 1 : 0);
            workData->result = TakeGoStringLocked(jsonResult);
        },
        [](napi_env env, napi_status status, void *rawData) {
            auto *workData = static_cast<SocketTestAsyncData *>(rawData);
            if (status != napi_ok) {
                napi_reject_deferred(env, workData->deferred, MakeString(env, "tcp async work failed"));
            } else if (!workData->error.empty()) {
                napi_reject_deferred(env, workData->deferred, MakeString(env, workData->error));
            } else {
                OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                    "tcp test result: %{public}s", workData->result.c_str());
                napi_resolve_deferred(env, workData->deferred, MakeString(env, workData->result));
            }
            napi_delete_async_work(env, workData->work);
            delete workData;
        },
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        return MakeRejectedPromise(env, "failed to queue tcp async work");
    }

    return promise;
}

napi_value RunUdpTest(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 3) {
        return MakeRejectedPromise(env, "runUdpTest requires host, port, useProtect");
    }

    char hostBuf[256] = {};
    size_t hostLen = 0;
    if (napi_get_value_string_utf8(env, args[0], hostBuf, sizeof(hostBuf) - 1, &hostLen) != napi_ok) {
        return MakeRejectedPromise(env, "host must be a string");
    }

    int32_t port = 0;
    if (napi_get_value_int32(env, args[1], &port) != napi_ok) {
        return MakeRejectedPromise(env, "port must be an integer");
    }

    bool useProtect = false;
    napi_get_value_bool(env, args[2], &useProtect);

    auto *data = new SocketTestAsyncData();
    data->env = env;
    data->tcp = false;
    data->host = hostBuf;
    data->port = port;
    data->useProtect = useProtect;

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "PocUdpTest", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<SocketTestAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_goMutex);
            if (!EnsureGoCoreLocked()) {
                workData->error = g_go.lastError;
                return;
            }
            if (g_go.udpTest == nullptr) {
                workData->error = "PocGoUdpTest not available in Go core";
                return;
            }
            const char *jsonResult = g_go.udpTest(workData->host.c_str(), workData->port, workData->useProtect ? 1 : 0);
            workData->result = TakeGoStringLocked(jsonResult);
        },
        [](napi_env env, napi_status status, void *rawData) {
            auto *workData = static_cast<SocketTestAsyncData *>(rawData);
            if (status != napi_ok) {
                napi_reject_deferred(env, workData->deferred, MakeString(env, "udp async work failed"));
            } else if (!workData->error.empty()) {
                napi_reject_deferred(env, workData->deferred, MakeString(env, workData->error));
            } else {
                OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                    "udp test result: %{public}s", workData->result.c_str());
                napi_resolve_deferred(env, workData->deferred, MakeString(env, workData->result));
            }
            napi_delete_async_work(env, workData->work);
            delete workData;
        },
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        return MakeRejectedPromise(env, "failed to queue udp async work");
    }

    return promise;
}

napi_value GetPendingProtectFd(napi_env env, napi_callback_info info)
{
    (void)info;
    return MakeInt(env, g_pendingProtectFd.load());
}

// ---------- POC-04: mihomo NAPI exports ----------

napi_value GetMihomoVersion(napi_env env, napi_callback_info info)
{
    (void)info;

    auto *data = new MihomoAsyncData();
    data->env = env;
    data->op = "MihomoVersion";

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "PocMihomoVersion", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<MihomoAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_mihomoMutex);
            if (!EnsureMihomoCoreLocked()) {
                workData->code = -1;
                workData->ok = false;
                workData->message = g_mihomo.lastError;
                return;
            }
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-04 calling MihomoOhosVersion");
            const char *versionPtr = g_mihomo.version();
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-04 MihomoOhosVersion returned ptr=%{public}p", versionPtr);
            workData->message = TakeMihomoStringLocked(versionPtr);
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-04 MihomoOhosVersion copied value=%{public}s", workData->message.c_str());
            workData->code = 0;
            workData->ok = true;
        },
        CompleteMihomoAsync,
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        return MakeRejectedPromise(env, "failed to queue mihomo version async work");
    }

    return promise;
}

napi_value StartMihomoConfig(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        return MakeRejectedPromise(env, "startMihomoConfig requires homeDir and config");
    }

    std::string homeDir;
    std::string config;
    if (!ReadStringArg(env, args[0], &homeDir)) {
        return MakeRejectedPromise(env, "homeDir must be a string");
    }
    if (!ReadStringArg(env, args[1], &config)) {
        return MakeRejectedPromise(env, "config must be a string");
    }

    auto *data = new MihomoAsyncData();
    data->env = env;
    data->op = "MihomoStartConfig";
    data->homeDir = homeDir;
    data->config = config;

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "PocMihomoStartConfig", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<MihomoAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_mihomoMutex);
            if (!EnsureMihomoCoreLocked()) {
                workData->code = -1;
                workData->ok = false;
                workData->message = g_mihomo.lastError;
                return;
            }
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-04 calling MihomoOhosStartConfig homeDir=%{public}s configLen=%{public}zu",
                workData->homeDir.c_str(), workData->config.size());
            int32_t code = g_mihomo.startConfig(workData->homeDir.c_str(), workData->config.c_str(),
                static_cast<int32_t>(workData->config.size()));
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-04 MihomoOhosStartConfig returned code=%{public}d", code);
            workData->code = code;
            workData->ok = code == 0;
            workData->message = code == 0 ? "mihomo started" : MihomoLastErrorLocked();
        },
        CompleteMihomoAsync,
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        return MakeRejectedPromise(env, "failed to queue mihomo start async work");
    }

    return promise;
}

napi_value StartMihomoConfigFile(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        return MakeRejectedPromise(env, "startMihomoConfigFile requires homeDir and configPath");
    }

    std::string homeDir;
    std::string configPath;
    if (!ReadStringArg(env, args[0], &homeDir)) {
        return MakeRejectedPromise(env, "homeDir must be a string");
    }
    if (!ReadStringArg(env, args[1], &configPath)) {
        return MakeRejectedPromise(env, "configPath must be a string");
    }

    auto *data = new MihomoAsyncData();
    data->env = env;
    data->op = "MihomoStartConfigFile";
    data->homeDir = homeDir;
    data->config = configPath;

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "PocMihomoStartConfigFile", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<MihomoAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_mihomoMutex);
            if (!EnsureMihomoCoreLocked()) {
                workData->code = -1;
                workData->ok = false;
                workData->message = g_mihomo.lastError;
                return;
            }
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-05 calling MihomoOhosStartConfigFile homeDir=%{public}s configPath=%{public}s",
                workData->homeDir.c_str(), workData->config.c_str());
            int32_t code = g_mihomo.startConfigFile(workData->homeDir.c_str(), workData->config.c_str());
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-05 MihomoOhosStartConfigFile returned code=%{public}d", code);
            workData->code = code;
            workData->ok = code == 0;
            workData->message = code == 0 ? "mihomo started" : MihomoLastErrorLocked();
        },
        CompleteMihomoAsync,
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        return MakeRejectedPromise(env, "failed to queue mihomo start config file async work");
    }

    return promise;
}

napi_value StartMihomoConfigFileWithTunFd(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 3) {
        return MakeRejectedPromise(env, "startMihomoConfigFileWithTunFd requires homeDir, configPath and tunFd");
    }

    std::string homeDir;
    std::string configPath;
    int32_t tunFd = -1;
    if (!ReadStringArg(env, args[0], &homeDir)) {
        return MakeRejectedPromise(env, "homeDir must be a string");
    }
    if (!ReadStringArg(env, args[1], &configPath)) {
        return MakeRejectedPromise(env, "configPath must be a string");
    }
    if (napi_get_value_int32(env, args[2], &tunFd) != napi_ok || tunFd < 0) {
        return MakeRejectedPromise(env, "tunFd must be a non-negative number");
    }

    int32_t mihomoTunFd = dup(tunFd);
    if (mihomoTunFd < 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG,
            "MVP-01B dup tun fd for mihomo failed tunFd=%{public}d errno=%{public}d", tunFd, errno);
        return MakeRejectedPromise(env, "failed to dup tun fd for mihomo");
    }
    int flags = fcntl(mihomoTunFd, F_GETFL, 0);
    if (flags >= 0) {
        (void)fcntl(mihomoTunFd, F_SETFL, flags | O_NONBLOCK);
    } else {
        OH_LOG_Print(LOG_APP, LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
            "MVP-01B get tun fd flags failed tunFd=%{public}d mihomoTunFd=%{public}d errno=%{public}d",
            tunFd, mihomoTunFd, errno);
    }

    auto *data = new MihomoAsyncData();
    data->env = env;
    data->op = "MihomoStartConfigFileWithTunFd";
    data->homeDir = homeDir;
    data->config = configPath;
    data->originalTunFd = tunFd;
    data->tunFd = mihomoTunFd;

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "PocMihomoStartConfigFileWithTunFd", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<MihomoAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_mihomoMutex);
            if (!EnsureMihomoCoreLocked()) {
                close(workData->tunFd);
                workData->tunFd = -1;
                workData->code = -1;
                workData->ok = false;
                workData->message = g_mihomo.lastError;
                return;
            }
            g_mihomo.setProtectBridge(reinterpret_cast<void *>(NapiProtectBridgeImpl));
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "MVP-01B calling MihomoOhosStartConfigFileWithTunFd homeDir=%{public}s configPath=%{public}s tunFd=%{public}d mihomoTunFd=%{public}d",
                workData->homeDir.c_str(), workData->config.c_str(), workData->originalTunFd, workData->tunFd);
            int32_t code = g_mihomo.startConfigFileWithTunFd(
                workData->homeDir.c_str(), workData->config.c_str(), workData->tunFd);
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "MVP-01B MihomoOhosStartConfigFileWithTunFd returned code=%{public}d tunFd=%{public}d mihomoTunFd=%{public}d",
                code, workData->originalTunFd, workData->tunFd);
            if (code != 0) {
                close(workData->tunFd);
                workData->tunFd = -1;
            }
            workData->code = code;
            workData->ok = code == 0;
            workData->message = code == 0 ? "mihomo started with tun fd" : MihomoLastErrorLocked();
            if (code == 0) {
                std::string status = MihomoLastErrorLocked();
                if (!status.empty()) {
                    workData->message = status;
                }
            }
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "MVP-01B MihomoOhosStartConfigFileWithTunFd status=%{public}s",
                workData->message.c_str());
        },
        CompleteMihomoAsync,
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        close(data->tunFd);
        delete data;
        return MakeRejectedPromise(env, "failed to queue mihomo start config file with tun fd async work");
    }

    return promise;
}

napi_value StopMihomo(napi_env env, napi_callback_info info)
{
    (void)info;

    auto *data = new MihomoAsyncData();
    data->env = env;
    data->op = "MihomoStop";

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "PocMihomoStop", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<MihomoAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_mihomoMutex);
            if (!EnsureMihomoCoreLocked()) {
                workData->code = -1;
                workData->ok = false;
                workData->message = g_mihomo.lastError;
                return;
            }
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-04 calling MihomoOhosStop");
            int32_t code = g_mihomo.stop();
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-04 MihomoOhosStop returned code=%{public}d", code);
            workData->code = code;
            workData->ok = code == 0;
            workData->message = code == 0 ? "mihomo stopped" : MihomoLastErrorLocked();
        },
        CompleteMihomoAsync,
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        return MakeRejectedPromise(env, "failed to queue mihomo stop async work");
    }

    return promise;
}

napi_value StartTunFdReadinessProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t tunFd = -1;
    int32_t durationMs = 45000;
    if (argc < 1 || napi_get_value_int32(env, args[0], &tunFd) != napi_ok || tunFd < 0) {
        return MakeStatus(env, false, -1, "tunFd must be a non-negative number");
    }
    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &durationMs);
    }
    if (durationMs <= 0) {
        durationMs = 45000;
    }

    bool expected = false;
    if (!g_tunProbeRunning.compare_exchange_strong(expected, true)) {
        return MakeStatus(env, false, -2, "tun fd readiness probe already running");
    }

    int probeFd = dup(tunFd);
    if (probeFd < 0) {
        g_tunProbeRunning.store(false);
        OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG,
            "TUN readiness probe dup failed tunFd=%{public}d errno=%{public}d", tunFd, errno);
        return MakeStatus(env, false, -3, "dup tun fd failed");
    }

    std::thread([probeFd, tunFd, durationMs]() {
        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
            "TUN readiness probe begin tunFd=%{public}d probeFd=%{public}d durationMs=%{public}d",
            tunFd, probeFd, durationMs);

        int flags = fcntl(probeFd, F_GETFL, 0);
        if (flags >= 0) {
            (void)fcntl(probeFd, F_SETFL, flags | O_NONBLOCK);
        }
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(durationMs);
        int pollInCount = 0;
        int timeoutCount = 0;
        int errorCount = 0;
        int sampleCount = 0;
        while (std::chrono::steady_clock::now() < deadline) {
            pollfd pfd {};
            pfd.fd = probeFd;
            pfd.events = POLLIN | POLLERR | POLLHUP | POLLNVAL;
            int ret = poll(&pfd, 1, 1000);
            if (ret > 0) {
                if ((pfd.revents & POLLIN) != 0) {
                    pollInCount++;
                    if (pollInCount == 1 || pollInCount % 10 == 0) {
                        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                            "TUN readiness probe POLLIN tunFd=%{public}d probeFd=%{public}d count=%{public}d revents=0x%{public}x",
                            tunFd, probeFd, pollInCount, pfd.revents);
                    }
                    if (sampleCount < 3) {
                        uint8_t packet[2048] = {};
                        ssize_t readBytes = read(probeFd, packet, sizeof(packet));
                        if (readBytes > 0) {
                            sampleCount++;
                            uint8_t version = packet[0] >> 4;
                            uint8_t proto = readBytes >= 10 ? packet[9] : 0;
                            uint8_t src0 = readBytes >= 20 ? packet[12] : 0;
                            uint8_t src1 = readBytes >= 20 ? packet[13] : 0;
                            uint8_t src2 = readBytes >= 20 ? packet[14] : 0;
                            uint8_t src3 = readBytes >= 20 ? packet[15] : 0;
                            uint8_t dst0 = readBytes >= 20 ? packet[16] : 0;
                            uint8_t dst1 = readBytes >= 20 ? packet[17] : 0;
                            uint8_t dst2 = readBytes >= 20 ? packet[18] : 0;
                            uint8_t dst3 = readBytes >= 20 ? packet[19] : 0;
                            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                                "TUN readiness sample sample=%{public}d bytes=%{public}zd ipver=%{public}u proto=%{public}u src=%{public}u.%{public}u.%{public}u.%{public}u dst=%{public}u.%{public}u.%{public}u.%{public}u",
                                sampleCount, readBytes, version, proto,
                                src0, src1, src2, src3, dst0, dst1, dst2, dst3);
                        } else if (readBytes < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                            errorCount++;
                            OH_LOG_Print(LOG_APP, LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
                                "TUN readiness probe read failed tunFd=%{public}d probeFd=%{public}d errno=%{public}d",
                                tunFd, probeFd, errno);
                        }
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(1000));
                }
                if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                    errorCount++;
                    OH_LOG_Print(LOG_APP, LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
                        "TUN readiness probe event tunFd=%{public}d probeFd=%{public}d revents=0x%{public}x",
                        tunFd, probeFd, pfd.revents);
                    if ((pfd.revents & POLLNVAL) != 0) {
                        break;
                    }
                }
            } else if (ret == 0) {
                timeoutCount++;
                if (timeoutCount == 1 || timeoutCount % 10 == 0) {
                    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                        "TUN readiness probe waiting tunFd=%{public}d probeFd=%{public}d seconds=%{public}d",
                        tunFd, probeFd, timeoutCount);
                }
            } else {
                errorCount++;
                OH_LOG_Print(LOG_APP, LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
                    "TUN readiness probe poll failed tunFd=%{public}d probeFd=%{public}d errno=%{public}d",
                    tunFd, probeFd, errno);
                if (errno != EINTR) {
                    break;
                }
            }
        }

        close(probeFd);
        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
            "TUN readiness probe done tunFd=%{public}d pollIn=%{public}d samples=%{public}d timeout=%{public}d errors=%{public}d",
            tunFd, pollInCount, sampleCount, timeoutCount, errorCount);
        g_tunProbeRunning.store(false);
    }).detach();

    return MakeStatus(env, true, 0, "tun fd readiness probe started");
}

napi_value StartTunFdPollProbe(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = { nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t tunFd = -1;
    int32_t durationMs = 25000;
    if (argc < 1 || napi_get_value_int32(env, args[0], &tunFd) != napi_ok || tunFd < 0) {
        return MakeStatus(env, false, -1, "tunFd must be a non-negative number");
    }
    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &durationMs);
    }
    if (durationMs <= 0) {
        durationMs = 25000;
    }

    bool expected = false;
    if (!g_tunProbeRunning.compare_exchange_strong(expected, true)) {
        return MakeStatus(env, false, -2, "tun fd probe already running");
    }

    int probeFd = dup(tunFd);
    if (probeFd < 0) {
        g_tunProbeRunning.store(false);
        OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG,
            "TUN poll probe dup failed tunFd=%{public}d errno=%{public}d", tunFd, errno);
        return MakeStatus(env, false, -3, "dup tun fd failed");
    }

    std::thread([probeFd, tunFd, durationMs]() {
        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
            "TUN poll probe begin tunFd=%{public}d probeFd=%{public}d durationMs=%{public}d",
            tunFd, probeFd, durationMs);

        int flags = fcntl(probeFd, F_GETFL, 0);
        if (flags >= 0) {
            (void)fcntl(probeFd, F_SETFL, flags | O_NONBLOCK);
        }

        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(durationMs);
        int pollInCount = 0;
        int timeoutCount = 0;
        int errorCount = 0;
        while (std::chrono::steady_clock::now() < deadline) {
            pollfd pfd {};
            pfd.fd = probeFd;
            pfd.events = POLLIN | POLLERR | POLLHUP | POLLNVAL;
            int ret = poll(&pfd, 1, 1000);
            if (ret > 0) {
                if ((pfd.revents & POLLIN) != 0) {
                    pollInCount++;
                    if (pollInCount == 1 || pollInCount % 100000 == 0) {
                        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                            "TUN poll probe POLLIN tunFd=%{public}d probeFd=%{public}d count=%{public}d revents=0x%{public}x",
                            tunFd, probeFd, pollInCount, pfd.revents);
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(100));
                }
                if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                    errorCount++;
                    OH_LOG_Print(LOG_APP, LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
                        "TUN poll probe event tunFd=%{public}d probeFd=%{public}d revents=0x%{public}x",
                        tunFd, probeFd, pfd.revents);
                    if ((pfd.revents & POLLNVAL) != 0) {
                        break;
                    }
                }
            } else if (ret == 0) {
                timeoutCount++;
                if (timeoutCount == 1 || timeoutCount % 10 == 0) {
                    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                        "TUN poll probe waiting tunFd=%{public}d probeFd=%{public}d seconds=%{public}d",
                        tunFd, probeFd, timeoutCount);
                }
            } else {
                errorCount++;
                OH_LOG_Print(LOG_APP, LOG_WARN, POC_LOG_DOMAIN, POC_LOG_TAG,
                    "TUN poll probe poll failed tunFd=%{public}d probeFd=%{public}d errno=%{public}d",
                    tunFd, probeFd, errno);
                if (errno != EINTR) {
                    break;
                }
            }
        }

        close(probeFd);
        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
            "TUN poll probe done tunFd=%{public}d pollIn=%{public}d timeout=%{public}d errors=%{public}d",
            tunFd, pollInCount, timeoutCount, errorCount);
        g_tunProbeRunning.store(false);
    }).detach();

    return MakeStatus(env, true, 0, "tun fd poll probe started");
}

napi_value HoldTunFdReference(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = { nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t tunFd = -1;
    if (argc < 1 || napi_get_value_int32(env, args[0], &tunFd) != napi_ok || tunFd < 0) {
        return MakeStatus(env, false, -1, "tunFd must be a non-negative number");
    }

    int heldFd = dup(tunFd);
    if (heldFd < 0) {
        OH_LOG_Print(LOG_APP, LOG_ERROR, POC_LOG_DOMAIN, POC_LOG_TAG,
            "TUN fd hold dup failed tunFd=%{public}d errno=%{public}d", tunFd, errno);
        return MakeStatus(env, false, -2, "dup tun fd failed");
    }

    std::lock_guard<std::mutex> lock(g_tunFdHoldMutex);
    if (g_heldTunFd >= 0) {
        close(g_heldTunFd);
    }
    g_heldTunFd = heldFd;
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "TUN fd hold active tunFd=%{public}d heldFd=%{public}d", tunFd, heldFd);
    return MakeStatus(env, true, 0, "tun fd reference held");
}

napi_value ReleaseTunFdReference(napi_env env, napi_callback_info info)
{
    (void)info;
    int releasedFd = -1;
    {
        std::lock_guard<std::mutex> lock(g_tunFdHoldMutex);
        releasedFd = g_heldTunFd;
        g_heldTunFd = -1;
    }
    if (releasedFd >= 0) {
        close(releasedFd);
        OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
            "TUN fd hold released heldFd=%{public}d", releasedFd);
        return MakeStatus(env, true, 0, "tun fd reference released");
    }
    return MakeStatus(env, true, 1, "no tun fd reference held");
}

napi_value LoadMihomoCore(napi_env env, napi_callback_info info)
{
    (void)info;

    auto *data = new MihomoAsyncData();
    data->env = env;
    data->op = "MihomoLoad";

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "PocMihomoLoad", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<MihomoAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_mihomoMutex);
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-04 loadMihomoCore worker begin");
            if (!EnsureMihomoCoreLocked()) {
                workData->code = -1;
                workData->ok = false;
                workData->message = g_mihomo.lastError;
                return;
            }
            workData->code = 0;
            workData->ok = true;
            workData->message = "mihomo core loaded";
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-04 loadMihomoCore worker done");
        },
        CompleteMihomoAsync,
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        return MakeRejectedPromise(env, "failed to queue mihomo load async work");
    }

    return promise;
}

napi_value PingMihomo(napi_env env, napi_callback_info info)
{
    (void)info;

    auto *data = new MihomoAsyncData();
    data->env = env;
    data->op = "MihomoPing";

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "PocMihomoPing", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<MihomoAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_mihomoMutex);
            if (!EnsureMihomoCoreLocked()) {
                workData->code = -1;
                workData->ok = false;
                workData->message = g_mihomo.lastError;
                return;
            }
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-04 calling MihomoOhosPing");
            int32_t code = g_mihomo.ping();
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "POC-04 MihomoOhosPing returned code=%{public}d", code);
            workData->code = code;
            workData->ok = code == 404;
            workData->message = code == 404 ? "mihomo ping ok" : "unexpected mihomo ping code";
        },
        CompleteMihomoAsync,
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        return MakeRejectedPromise(env, "failed to queue mihomo ping async work");
    }

    return promise;
}

napi_value TestMihomoDelay(napi_env env, napi_callback_info info, bool group)
{
    size_t argc = 3;
    napi_value args[3] = { nullptr, nullptr, nullptr };
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        return MakeRejectedPromise(env, group ? "testMihomoGroupDelay requires group name" :
            "testMihomoProxyDelay requires node name");
    }

    std::string name;
    if (!ReadStringArg(env, args[0], &name) || name.empty()) {
        return MakeRejectedPromise(env, group ? "group name must be a non-empty string" :
            "node name must be a non-empty string");
    }

    std::string url = "http://www.gstatic.com/generate_204";
    if (argc >= 2 && args[1] != nullptr) {
        std::string candidate;
        if (ReadStringArg(env, args[1], &candidate) && !candidate.empty()) {
            url = candidate;
        }
    }

    int32_t timeoutMs = 5000;
    if (argc >= 3 && args[2] != nullptr) {
        napi_get_value_int32(env, args[2], &timeoutMs);
    }
    if (timeoutMs <= 0) {
        timeoutMs = 5000;
    }

    auto *data = new MihomoDelayAsyncData();
    data->env = env;
    data->group = group;
    data->name = name;
    data->url = url;
    data->timeoutMs = timeoutMs;

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, group ? "PocMihomoGroupDelay" : "PocMihomoProxyDelay", NAPI_AUTO_LENGTH,
        &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<MihomoDelayAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_mihomoMutex);
            if (!EnsureMihomoCoreLocked()) {
                workData->error = g_mihomo.lastError;
                return;
            }
            if (workData->group) {
                if (g_mihomo.groupDelay == nullptr) {
                    workData->error = "MihomoOhosGroupDelay not available";
                    return;
                }
                const char *jsonResult = g_mihomo.groupDelay(workData->name.c_str(), workData->url.c_str(),
                    workData->timeoutMs);
                workData->result = TakeMihomoStringLocked(jsonResult);
            } else {
                if (g_mihomo.proxyDelay == nullptr) {
                    workData->error = "MihomoOhosProxyDelay not available";
                    return;
                }
                const char *jsonResult = g_mihomo.proxyDelay(workData->name.c_str(), workData->url.c_str(),
                    workData->timeoutMs);
                workData->result = TakeMihomoStringLocked(jsonResult);
            }
        },
        [](napi_env env, napi_status status, void *rawData) {
            auto *workData = static_cast<MihomoDelayAsyncData *>(rawData);
            if (status != napi_ok) {
                napi_reject_deferred(env, workData->deferred, MakeString(env, "mihomo delay async work failed"));
            } else if (!workData->error.empty()) {
                napi_reject_deferred(env, workData->deferred, MakeString(env, workData->error));
            } else {
                OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                    "mihomo delay result: %{public}s", workData->result.c_str());
                napi_resolve_deferred(env, workData->deferred, MakeString(env, workData->result));
            }
            napi_delete_async_work(env, workData->work);
            delete workData;
        },
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        return MakeRejectedPromise(env, "failed to queue mihomo delay async work");
    }

    return promise;
}

napi_value TestMihomoProxyDelay(napi_env env, napi_callback_info info)
{
    return TestMihomoDelay(env, info, false);
}

napi_value TestMihomoGroupDelay(napi_env env, napi_callback_info info)
{
    return TestMihomoDelay(env, info, true);
}

// ---------- MVP-01B: protect hook control ----------

napi_value EnableProtectHook(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_mihomoMutex);
    if (!EnsureMihomoCoreLocked()) {
        return MakeStatus(env, false, -1, g_mihomo.lastError);
    }
    if (g_mihomo.enableProtectHook == nullptr) {
        return MakeStatus(env, false, -1, "MihomoOhosEnableProtectHook not available");
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "MVP-01B calling MihomoOhosEnableProtectHook (sync)");
    int32_t code = g_mihomo.enableProtectHook();
    OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
        "MVP-01B MihomoOhosEnableProtectHook returned code=%{public}d", code);
    return MakeStatus(env, code == 0, code,
        code == 0 ? "protect hook enabled" : "protect hook enable failed");
}

napi_value DisableProtectHook(napi_env env, napi_callback_info info)
{
    (void)info;

    auto *data = new MihomoAsyncData();
    data->env = env;
    data->op = "MihomoDisableProtectHook";

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "PocMihomoDisableProtectHook", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<MihomoAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_mihomoMutex);
            if (!EnsureMihomoCoreLocked()) {
                workData->code = -1;
                workData->ok = false;
                workData->message = g_mihomo.lastError;
                return;
            }
            if (g_mihomo.disableProtectHook == nullptr) {
                workData->code = -1;
                workData->ok = false;
                workData->message = "MihomoOhosDisableProtectHook not available";
                return;
            }
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "MVP-01B calling MihomoOhosDisableProtectHook (async)");
            int32_t code = g_mihomo.disableProtectHook();
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "MVP-01B MihomoOhosDisableProtectHook returned code=%{public}d", code);
            workData->code = code;
            workData->ok = code == 0;
            workData->message = code == 0 ? "protect hook disabled" : "protect hook disable timeout";
        },
        CompleteMihomoAsync,
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        return MakeRejectedPromise(env, "failed to queue mihomo disable protect hook async work");
    }

    return promise;
}

napi_value IsMihomoRunning(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_mihomoMutex);
    if (!EnsureMihomoCoreLocked()) {
        return MakeStatus(env, false, -1, g_mihomo.lastError);
    }
    if (g_mihomo.isRunning == nullptr) {
        return MakeStatus(env, false, -1, "MihomoOhosIsRunning not available");
    }
    int32_t running = g_mihomo.isRunning();
    return MakeStatus(env, true, running,
        running == 1 ? "mihomo running" : "mihomo not running");
}

// GracefulStopMihomo runs on a NAPI worker thread. The start path initializes
// mihomo from a worker thread as well; calling exported Go functions from the
// ArkTS main thread has proven unstable on OpenHarmony.
napi_value GracefulStopMihomo(napi_env env, napi_callback_info info)
{
    (void)info;

    auto *data = new MihomoAsyncData();
    data->env = env;
    data->op = "MihomoGracefulStop";

    napi_value promise = nullptr;
    napi_create_promise(env, &data->deferred, &promise);

    napi_value resourceName = nullptr;
    napi_create_string_utf8(env, "PocMihomoGracefulStop", NAPI_AUTO_LENGTH, &resourceName);

    napi_status status = napi_create_async_work(
        env,
        nullptr,
        resourceName,
        [](napi_env env, void *rawData) {
            (void)env;
            auto *workData = static_cast<MihomoAsyncData *>(rawData);
            std::lock_guard<std::mutex> lock(g_mihomoMutex);
            if (!EnsureMihomoCoreLocked()) {
                workData->code = -1;
                workData->ok = false;
                workData->message = g_mihomo.lastError;
                return;
            }
            if (g_mihomo.gracefulStop == nullptr) {
                workData->code = -1;
                workData->ok = false;
                workData->message = "MihomoOhosGracefulStop not available";
                return;
            }
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "MVP-01B calling MihomoOhosGracefulStop (async)");
            int32_t code = g_mihomo.gracefulStop();
            OH_LOG_Print(LOG_APP, LOG_INFO, POC_LOG_DOMAIN, POC_LOG_TAG,
                "MVP-01B MihomoOhosGracefulStop returned code=%{public}d", code);
            workData->code = code;
            workData->ok = code == 0;
            workData->message = code == 0 ? "mihomo graceful stop ok" : MihomoLastErrorLocked();
        },
        CompleteMihomoAsync,
        data,
        &data->work
    );

    if (status != napi_ok || napi_queue_async_work(env, data->work) != napi_ok) {
        napi_delete_async_work(env, data->work);
        delete data;
        return MakeRejectedPromise(env, "failed to queue mihomo graceful stop async work");
    }

    return promise;
}

// ---------- Module registration ----------

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        // POC-02
        { "loadGoCore", nullptr, LoadGoCore, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "add", nullptr, Add, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startWorker", nullptr, StartWorker, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "stopWorker", nullptr, StopWorker, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getLastEvent", nullptr, GetLastEvent, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "panicProbe", nullptr, PanicProbe, nullptr, nullptr, nullptr, napi_default, nullptr },
        // POC-03
        { "registerProtect", nullptr, RegisterProtect, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "runTcpTest", nullptr, RunTcpTest, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "runUdpTest", nullptr, RunUdpTest, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getPendingProtectFd", nullptr, GetPendingProtectFd, nullptr, nullptr, nullptr, napi_default, nullptr },
        // POC-04
        { "loadMihomoCore", nullptr, LoadMihomoCore, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "pingMihomo", nullptr, PingMihomo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "getMihomoVersion", nullptr, GetMihomoVersion, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startMihomoConfig", nullptr, StartMihomoConfig, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startMihomoConfigFile", nullptr, StartMihomoConfigFile, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startMihomoConfigFileWithTunFd", nullptr, StartMihomoConfigFileWithTunFd, nullptr, nullptr, nullptr,
            napi_default, nullptr },
        { "stopMihomo", nullptr, StopMihomo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "enableProtectHook", nullptr, EnableProtectHook, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "disableProtectHook", nullptr, DisableProtectHook, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "isMihomoRunning", nullptr, IsMihomoRunning, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "gracefulStopMihomo", nullptr, GracefulStopMihomo, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "testMihomoProxyDelay", nullptr, TestMihomoProxyDelay, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "testMihomoGroupDelay", nullptr, TestMihomoGroupDelay, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "startTunFdReadinessProbe", nullptr, StartTunFdReadinessProbe, nullptr, nullptr, nullptr, napi_default,
            nullptr },
        { "startTunFdPollProbe", nullptr, StartTunFdPollProbe, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "holdTunFdReference", nullptr, HoldTunFdReference, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "releaseTunFdReference", nullptr, ReleaseTunFdReference, nullptr, nullptr, nullptr, napi_default, nullptr },
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
} // namespace

static napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "poc_napi",
    .nm_priv = nullptr,
    .reserved = { 0 }
};

extern "C" __attribute__((constructor)) void RegisterPocNapiModule(void)
{
    napi_module_register(&g_module);
}
