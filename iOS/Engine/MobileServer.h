#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
// C API of the embedded server (MobileServer.cpp), called from Swift through the bridging
// header. Every function is thread-safe.
#ifdef __cplusplus
extern "C" {
#endif
// Replaces the models the router can load with the sections of a models.ini file.
// Callable at any time, including before a run; a loaded model keeps its settings until
// it loads again. On failure, keeps the previous models and writes the reason to error.
bool mobile_server_set_presets(const char * path, char * error, size_t size);
// Blocks until stopped. Call on a dedicated background queue, once at a time.
// Serves the router API the WebUI expects; at most one model is loaded at a time.
// initial_model, when not NULL, is loaded as soon as the server is up; if that fails the
// server stays up so another model can be chosen.
// Returns 0 after a stop, 1 when the server could not start, 2 when one is already running.
int mobile_server_run(const char * initial_model, int port, bool gpu);
// Asks a running server to stop; mobile_server_run then returns. No effect when none runs.
void mobile_server_stop(void);
// True once the server is up and the initial model load has been attempted.
bool mobile_server_ready(void);
// Copies the loaded model's name into buffer (empty when none) and returns its length.
size_t mobile_server_loaded_model(char * buffer, size_t size);
// Frees the loaded model, after the requests using it end. Blocks until then.
void mobile_server_unload(void);
// Estimates a model's total memory at n_ctx, in bytes, without loading it. Measures what
// `llama fit-params -fitp on` reports on the Mac. Slow (it reads the model); call off the
// main thread. Works whether or not a server runs.
bool mobile_server_probe_memory(const char * model_path, unsigned n_ctx, bool gpu, uint64_t * total_bytes);
// Writes the engine's log to path from now on, as `llama serve --log-file` does: the file
// is truncated, so it holds one run. Call while no server runs.
void mobile_server_set_log_file(const char * path);
// The llama.cpp build the engine was compiled from, e.g. "b11429-d8123504".
const char * mobile_server_build_info(void);
#ifdef __cplusplus
}
#endif
