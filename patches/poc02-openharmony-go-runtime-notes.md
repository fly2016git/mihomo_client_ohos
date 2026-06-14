# POC-02 OpenHarmony Go Runtime Patch Notes

POC-02 passed on device `192.168.3.65:41235` only after applying these local runtime changes to the temporary OpenHarmony Go tree at `/private/tmp/ohos_golang_go`.

This file records the minimal change set that matters. Earlier diagnostic runtime logging has been removed from the temporary tree; the remaining items below are the functional changes that should be preserved in a long-lived fork or patch set.

## Toolchain

- Go tree: `/private/tmp/ohos_golang_go`
- Go binary: `/private/tmp/ohos_golang_go/bin/go`
- Build env file: `scripts/huawei_tools_env.sh`

## Required Runtime Changes

1. Treat OpenHarmony arm64 `runtime.tls_g` like Android and Darwin: keep it as an offset variable instead of ELF TLS.

```diff
diff --git a/src/runtime/tls_arm64.h b/src/runtime/tls_arm64.h
@@
 #ifdef GOOS_openharmony
 #define TLS_linux
+#define TLSG_IS_VARIABLE
 #endif
```

2. Pass the OpenHarmony TLS base and `&runtime.tls_g` into `_cgo_init`, matching the Android path.

```diff
diff --git a/src/runtime/asm_arm64.s b/src/runtime/asm_arm64.s
@@
-#ifdef GOOS_android
+#if defined(GOOS_android) || defined(GOOS_openharmony)
 	MRS_TPIDR_R0
 	MOVD	R0, R3
 	MOVD	$runtime·tls_g(SB), R2
 #else
 	MOVD	$0, R2
 #endif
```

3. Add OpenHarmony cgo TLS initialization that scans pthread TLS for a known key value and stores the resulting TPIDR_EL0 offset in `runtime.tls_g`.

```c
// src/runtime/cgo/gcc_openharmony.c
//go:build openharmony

#include <pthread.h>
#include <stdint.h>
#include "libcgo.h"

#define magic1 (0x23581321345589ULL)

static void
inittls(void **tlsg, void **tlsbase)
{
	pthread_key_t k;
	int i, err;

	err = pthread_key_create(&k, nil);
	if (err != 0) {
		fatalf("pthread_key_create failed: %d", err);
	}
	pthread_setspecific(k, (void*)magic1);

	for (i = 0; i < 384; i++) {
		if (*(tlsbase + i) == (void*)magic1) {
			*tlsg = (void*)(i * sizeof(void *));
			pthread_setspecific(k, 0);
			return;
		}
	}
	fatalf("inittls: could not find pthread key");
}

void (*x_cgo_inittls)(void **tlsg, void **tlsbase) = inittls;
```

4. Do not let Linux startup code parse the synthetic OpenHarmony c-shared argv/env/auxv block as a real process stack.

```diff
diff --git a/src/runtime/runtime1.go b/src/runtime/runtime1.go
@@
 func goargs() {
 	if GOOS == "windows" {
 		return
 	}
+	if IsOpenharmony {
+		return
+	}
 
 	if libmusl {
 		argslice = readNullTerminatedStringsFromFile(procCmdline)
```

```diff
diff --git a/src/runtime/os_linux.go b/src/runtime/os_linux.go
@@
-	if !libmusl {
+	if !libmusl && !IsOpenharmony {
 		for argv_index(argv, n) != nil {
 			n++
 		}
```

5. Initialize OpenHarmony envs to an empty non-nil slice. `nil` makes `gogetenv` throw in `parsedebugvars`.

```diff
diff --git a/src/runtime/os_linux.go b/src/runtime/os_linux.go
@@
 func goenvs() {
+	if IsOpenharmony {
+		envs = make([]string, 0)
+		return
+	}
 	if libmusl {
 		envs = readNullTerminatedStringsFromFile(procEnviron)
```

## Verified Result

After rebuilding `libpoc_go_core.so` with this patched toolchain and rebuilding the HAP, device logs showed:

```text
POC-02 self-test begin
Go core loaded
POC-02 self-test loadGoCore ok=true code=0 message=poc-go-core/0.1
POC-02 self-test add(7, 35)=42
POC-02 self-test workers runs=3 lastEvent=worker tick 3
POC-02 self-test panicProbe ok=true code=0 message=panic converted to error event=panic recovered: POC-02 panic probe
POC-02 self-test done failures=0
```

## Follow-up

- Convert `/private/tmp/ohos_golang_go` into a maintainable fork, patch set, or internal toolchain build script before depending on it for the full mihomo port.
- Keep only the functional runtime changes above in the long-lived version.
- Use `IsOpenharmony` for runtime conditionals. In this toolchain the runtime `GOOS` constant may still be `"linux"` on OpenHarmony paths.
