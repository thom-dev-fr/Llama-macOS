#include "MobileServer.h"
#include "build-info.h"
#include "common.h"
#include "llama.h"
#include "log.h"
#include "mtmd.h"
#include "preset.h"
#include "server-common.h"
#include "server-context.h"
#include "server-http.h"
#include "server-stream.h"
#include "src/llama-ext.h" // memory breakdown, as common/fit.cpp measures it
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <mutex>
#include <memory>
#include <set>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

// The embedded llama.cpp server for iOS, in the app's own process.
//
// On macOS, `llama serve` runs in router mode: the router (tools/server/server-models.cpp)
// spawns one child server process per model and proxies HTTP requests to it. The WebUI
// relies on that mode for its model picker. iOS apps cannot spawn processes, and the
// router refuses to start without them, so this file serves the same router API itself:
//
//   Session  one HTTP server, from mobile_server_run until it returns
//   Engine   one loaded model: a server_context, its upstream route handlers, its loop thread
//   Lease    keeps an Engine alive and loaded while a request uses it
//   Feed     the /models/sse status events the WebUI waits on when it loads a model
//
// Models come from the same models.ini the Mac hands to `llama serve --models-preset`,
// read with the upstream preset parser: each section's options apply to its model's
// parameters as they would to a child server's command line.
//
// Requests that name a model are run by the upstream handlers on that model's Engine,
// swapping it in when needed. At most one Engine exists: a swap waits for the current
// one's leases to end, frees it, then loads the next, so two models never share memory.
//
// Lock order: the global mutex, Session::swap, then Session::state. Feed and Catalog locks
// are leaves.
//
// The JSON of /props, /models and /models/sse mirrors the upstream router at the pinned
// llama.cpp version; check it against server-models.cpp when updating the pin.

namespace {
struct http_error : std::runtime_error {
    int status;
    std::string type;
    http_error(int status, const std::string & type, const std::string & message)
        : std::runtime_error(message), status(status), type(type) {}
};

server_http_res_ptr error_response(int status, const std::string & type, const std::string & message) {
    auto res = std::make_unique<server_http_res>();
    res->status = status;
    res->data = json({{"error", {{"message", message}, {"type", type}, {"code", status}}}}).dump();
    return res;
}

server_http_res_ptr ok_response(const json & data) {
    auto res = std::make_unique<server_http_res>();
    res->data = data.dump();
    return res;
}

// HTTP handlers must never let C++ exceptions escape the request thread.
server_http_context::handler_t guarded(server_http_context::handler_t handler) {
    return [handler](const server_http_req & req) -> server_http_res_ptr {
        try {
            return handler(req);
        } catch (const http_error & e) {
            return error_response(e.status, e.type, e.what());
        } catch (const std::exception & e) {
            return error_response(400, "invalid_request_error", e.what());
        } catch (...) {
            return error_response(500, "server_error", "Internal inference error");
        }
    };
}

// One loaded model with its own inference loop.
struct Engine {
    std::string name;
    common_params params;
    server_context context;
    std::unique_ptr<server_routes> routes;
    json info;
    std::thread loop;
    std::atomic<bool> loop_done{false};
    int active = 0; // in-flight requests, guarded by Session::state
    ~Engine() {
        // Upstream start_loop resets its running flag. Repeated termination
        // avoids losing a stop arriving before the loop entered.
        while (loop.joinable()) {
            context.terminate();
            if (loop_done.load()) loop.join();
            else std::this_thread::sleep_for(std::chrono::milliseconds(20));
        }
    }
};

// Records for /models/sse. Readers only see events published after they connect.
struct Feed {
    std::mutex mutex;
    std::condition_variable changed;
    std::deque<std::string> events;
    uint64_t first = 0;
    bool closed = false;

    void publish(const std::string & event, const std::string & model, const json & data = nullptr) {
        json record = {{"model", model}, {"event", event}};
        if (!data.is_null()) record["data"] = data;
        std::lock_guard<std::mutex> lock(mutex);
        events.push_back(record.dump());
        if (events.size() > 64) { events.pop_front(); first++; }
        changed.notify_all();
    }
    uint64_t end() {
        std::lock_guard<std::mutex> lock(mutex);
        return first + events.size();
    }
    bool next(uint64_t & cursor, std::string & output, const std::function<bool()> & should_stop) {
        std::unique_lock<std::mutex> lock(mutex);
        while (!closed && !should_stop()) {
            cursor = std::max(cursor, first);
            if (cursor < first + events.size()) {
                output = "data: " + events[cursor - first] + "\n\n";
                cursor++;
                return true;
            }
            changed.wait_for(lock, std::chrono::milliseconds(500));
        }
        return false;
    }
    void close() {
        std::lock_guard<std::mutex> lock(mutex);
        closed = true;
        changed.notify_all();
    }
};

// A models.ini section, with what the model list reports before the model loads.
// Sections come out in name order, as the upstream parser keeps them.
struct Entry {
    common_preset preset;
    std::string path;
    json tags = json::array();
    json architecture;
    uint32_t n_ctx_train = 0; // from the GGUF metadata; 0 when unknown
};

struct Catalog {
    std::mutex mutex;
    std::vector<Entry> models;
} catalog;

// Parameters every model starts from, before its models.ini section applies.
// Small batches keep compute buffers within a phone's memory.
void mobile_defaults(common_params & p, bool gpu) {
    p.n_ctx = 4096;
    p.n_parallel = 1;
    p.n_batch = 512;
    p.n_ubatch = 128;
    p.cpuparams.n_threads = 4;
    p.cpuparams_batch.n_threads = 4;
    p.n_gpu_layers = gpu ? 99 : 0;
    // Models with dynamic resolution otherwise turn a camera photo into thousands of
    // tokens, which take minutes to encode and decode on a phone.
    p.image_max_tokens = 1024;
    // The app picks the context; a request past it is refused rather than truncated.
    p.fit_params = false;
    p.ctx_shift = false;
}

json split_list(const std::string & value) {
    json out = json::array();
    std::stringstream stream(value);
    std::string item;
    while (std::getline(stream, item, ',')) {
        if (!item.empty()) out.push_back(item);
    }
    return out;
}

struct Session;

// Keeps an engine loaded and running while a request uses it.
struct Lease {
    std::shared_ptr<Session> session;
    std::shared_ptr<Engine> engine;
    std::string conversation; // the WebUI's X-Conversation-Id, while its stream runs
    Lease(std::shared_ptr<Session> session, std::shared_ptr<Engine> engine);
    Lease(Lease && other) noexcept = default;
    ~Lease();
};

// Wraps an engine response so the engine outlives it, including streams that keep
// generating after the client disconnects. The engine's handler gets `req`, a copy of
// the request that also stops when the server does: upstream otherwise waits for the
// client, which a suspended WebView never closes. Members are destroyed in reverse
// order, so the inner response goes before the request it refers to and the lease.
struct leased_res : server_http_res {
    Lease lease;
    std::function<bool()> stop;
    server_http_req req;
    server_http_res_ptr inner;
    leased_res(Lease && lease, const server_http_req & original);
    void wrap(server_http_res_ptr response) {
        inner = std::move(response);
        content_type = inner->content_type;
        status = inner->status;
        // A stream's handler keeps its first event in its own `data`, sent by the first
        // `next`; the HTTP layer reads the outer `data` only for whole responses.
        if (!inner->is_stream()) data = std::move(inner->data);
        headers = inner->headers;
        if (inner->next) next = [r = inner.get()](std::string & output) { return r->next(output); };
    }
    void on_complete() override { inner->on_complete(); }
};

struct Session {
    common_params params;
    server_http_context http;
    Feed feed;
    std::atomic<bool> cancelled{false}; // the server is stopping; requests end, none start
    std::atomic<bool> started{false}; // the initial load has been attempted
    std::mutex swap; // serializes loads and unloads
    std::mutex state;
    std::condition_variable idle;
    std::shared_ptr<Engine> current;
    std::string loading;
    std::multiset<std::string> conversations; // of running leases, guarded by state
    bool gpu = false;
};

Lease::Lease(std::shared_ptr<Session> session, std::shared_ptr<Engine> engine)
    : session(std::move(session)), engine(std::move(engine)) {
    this->engine->active++; // caller holds Session::state
}

Lease::~Lease() {
    if (!engine) return;
    std::lock_guard<std::mutex> lock(session->state);
    engine->active--;
    if (!conversation.empty()) session->conversations.erase(session->conversations.find(conversation));
    session->idle.notify_all();
}

leased_res::leased_res(Lease && lease, const server_http_req & original)
    : lease(std::move(lease)),
      stop([s = this->lease.session.get(), client = &original.should_stop] {
          return s->cancelled.load() || (*client)();
      }),
      req{original.params, original.headers, original.path, original.query_string,
          original.body, original.files, stop} {}

std::mutex mutex;
std::shared_ptr<Session> current;
std::once_flag backend;

// Lines below this level are logged as debug on this thread. The llama logger is set
// once, here: replacing it while other threads log is a race (llama_log_set writes
// the callback and its data separately), so a memory probe quiets its thread instead.
thread_local ggml_log_level quiet_below = GGML_LOG_LEVEL_NONE;

void log_callback(ggml_log_level level, const char * text, void * user_data) {
    common_log_default_callback(level >= quiet_below ? level : GGML_LOG_LEVEL_DEBUG, text, user_data);
}

void init_backend() {
    std::call_once(backend, [] {
        common_init();
        llama_log_set(log_callback, nullptr);
        llama_backend_init();
    });
}

bool find_preset(const std::string & name, common_preset & preset) {
    std::lock_guard<std::mutex> lock(catalog.mutex);
    for (const auto & entry : catalog.models) {
        if (entry.preset.name == name) { preset = entry.preset; return true; }
    }
    return false;
}

// Caller holds Session::swap. Waits for in-flight requests, then frees the model.
void unload(const std::shared_ptr<Session> & s) {
    std::shared_ptr<Engine> old;
    {
        std::unique_lock<std::mutex> lock(s->state);
        if (!s->current) return;
        old = std::move(s->current); // new requests can no longer lease it
        s->idle.wait(lock, [&] { return old->active == 0; });
    }
    std::string name = old->name;
    old.reset();
    s->feed.publish("status_change", name, {{"status", "unloaded"}, {"exit_code", 0}});
}

// Caller holds Session::swap and nothing is loaded.
std::shared_ptr<Engine> load(const std::shared_ptr<Session> & s, const std::string & name, const common_preset & preset) {
    {
        std::lock_guard<std::mutex> lock(s->state);
        s->loading = name;
    }
    s->feed.publish("status_change", name, {{"status", "loading"}});
    auto engine = std::make_shared<Engine>();
    engine->name = name;
    auto & p = engine->params;
    p = s->params;
    bool loaded = false;
    try {
        preset.apply_to_params(p);
        p.model_alias = {name};
        // The simulator has no Metal; a section cannot turn the GPU on there.
        if (!s->gpu) p.n_gpu_layers = 0;
        // Nor fit: it swaps the global logger while other threads log (see init_backend).
        p.fit_params = false;
        engine->routes = std::make_unique<server_routes>(p, engine->context);
        loaded = engine->context.load_model(p);
    } catch (const std::exception & e) {
        LOG_ERR("Mobile server: %s: %s\n", name.c_str(), e.what());
    }
    {
        std::lock_guard<std::mutex> lock(s->state);
        s->loading.clear();
    }
    if (!loaded) {
        s->feed.publish("status_change", name, {{"status", "unloaded"}, {"exit_code", 1}});
        throw http_error(500, "server_error", "Model loading failed: " + name);
    }
    engine->routes->update_meta(engine->context);
    engine->info = engine->routes->get_model_info();
    engine->loop = std::thread([e = engine.get()] {
        e->context.start_loop();
        e->loop_done.store(true);
    });
    return engine;
}

// Returns a lease on the named model, swapping it in if needed. An empty name means
// whichever model is loaded.
Lease acquire(const std::shared_ptr<Session> & s, const std::string & name) {
    auto leased = [&]() -> std::unique_ptr<Lease> {
        std::lock_guard<std::mutex> lock(s->state);
        if (s->current && (name.empty() || s->current->name == name)) {
            return std::make_unique<Lease>(s, s->current);
        }
        return nullptr;
    };
    if (s->cancelled.load()) throw http_error(503, "unavailable_error", "The server is stopping");
    if (auto lease = leased()) return std::move(*lease);
    if (name.empty()) throw http_error(503, "unavailable_error", "No model is loaded; select one first");
    common_preset preset;
    if (!find_preset(name, preset)) throw http_error(404, "not_found_error", "model is not found: " + name);
    std::lock_guard<std::mutex> swap(s->swap);
    if (auto lease = leased()) return std::move(*lease); // loaded while we waited
    if (s->cancelled.load()) throw http_error(503, "unavailable_error", "The server is stopping");
    unload(s);
    auto engine = load(s, name, preset);
    std::lock_guard<std::mutex> lock(s->state);
    s->current = engine;
    s->feed.publish("status_change", name, {{"status", "loaded"}});
    return Lease(s, engine);
}

std::string requested_model(const server_http_req & req) {
    std::string name = req.get_param("model");
    if (name.empty() && !req.body.empty()) {
        try {
            json body = json::parse(req.body);
            if (body.is_object()) name = json_value(body, "model", std::string());
        } catch (const std::exception &) {} // the handler reports malformed bodies
    }
    return name;
}

using route = server_http_context::handler_t server_routes::*;

double elapsed_ms(std::chrono::steady_clock::time_point since) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - since).count();
}

// Handlers hold their session weakly: the session owns them through its HTTP server.
std::shared_ptr<Session> locked(const std::weak_ptr<Session> & session) {
    auto s = session.lock();
    if (!s) throw http_error(503, "unavailable_error", "The server is stopping");
    return s;
}

// Runs an upstream single-model handler on the requested model. A timed route reports
// in a Server-Timing header how long getting the model took (a load, or waiting for a
// swap; near zero when it was in memory) and how long the handler took. Only for
// handlers that answer in one piece: a stream's handler returns before its work.
server_http_context::handler_t forward(const std::weak_ptr<Session> & session, route handler, bool timed = false) {
    return guarded([session, handler, timed](const server_http_req & req) -> server_http_res_ptr {
        auto s = locked(session);
        const auto start = std::chrono::steady_clock::now();
        Lease lease = acquire(s, requested_model(req));
        const double load_ms = elapsed_ms(start);
        // A WebUI stream keeps generating after its client goes; the shutdown cancels it
        // by this ID. Registered with the stopping check so the shutdown sees every one.
        std::string conversation = server_stream_conv_id_from_headers(req.headers);
        if (!conversation.empty()) {
            std::lock_guard<std::mutex> lock(s->state);
            if (s->cancelled.load()) throw http_error(503, "unavailable_error", "The server is stopping");
            s->conversations.insert(conversation);
            lease.conversation = std::move(conversation);
        }
        auto res = std::make_unique<leased_res>(std::move(lease), req);
        const auto computing = std::chrono::steady_clock::now();
        auto response = (res->lease.engine->routes.get()->*handler)(res->req);
        if (timed && !response->is_stream()) {
            response->headers["Server-Timing"] =
                string_format("load;dur=%.1f, compute;dur=%.1f", load_ms, elapsed_ms(computing));
        }
        res->wrap(std::move(response));
        return res;
    });
}

json model_list(const std::shared_ptr<Session> & s) {
    std::vector<Entry> models;
    {
        std::lock_guard<std::mutex> lock(catalog.mutex);
        models = catalog.models;
    }
    std::string loaded, loading;
    json info;
    {
        std::lock_guard<std::mutex> lock(s->state);
        if (s->current) { loaded = s->current->name; info = s->current->info; }
        loading = s->loading;
    }
    json data = json::array();
    for (const auto & model : models) {
        const std::string & name = model.preset.name;
        std::string status = name == loaded ? "loaded" : name == loading ? "loading" : "unloaded";
        json entry = {
            {"id", name},
            {"aliases", json::array()},
            {"tags", model.tags},
            {"object", "model"},
            {"owned_by", "llamacpp"},
            {"created", std::time(nullptr)},
            {"status", {{"value", status}, {"args", json::array()}}},
            {"architecture", model.architecture},
            {"source", "local"},
            {"can_remove", false},
            {"in_cache", false},
            {"path", model.path},
        };
        if (model.n_ctx_train > 0) entry["context_length"] = model.n_ctx_train;
        // Same merge as the upstream router: the loaded model reports its own details.
        if (name == loaded) {
            for (auto it = info.begin(); it != info.end(); ++it) {
                if (!entry.contains(it.key())) entry[it.key()] = it.value();
            }
        }
        data.push_back(entry);
    }
    return {{"data", data}, {"object", "list"}};
}

void register_routes(const std::shared_ptr<Session> & session, json ui_settings) {
    auto & h = session->http;
    const std::weak_ptr<Session> s = session;
    auto health = guarded([](const server_http_req &) { return ok_response({{"status", "ok"}}); });
    h.get("/health", health);
    h.get("/v1/health", health);

    auto props = forward(s, &server_routes::get_props);
    h.get("/props", guarded([props, ui_settings](const server_http_req & req) -> server_http_res_ptr {
        if (!req.get_param("model").empty()) return props(req);
        return ok_response({
            {"role", "router"},
            {"max_instances", 1},
            {"models_autoload", true},
            // Placeholders the upstream router also sends so the UI does not break.
            {"model_alias", "llama-server"},
            {"model_path", "none"},
            {"default_generation_settings", {{"params", json::object()}, {"n_ctx", 0}}},
            {"ui_settings", ui_settings},
            {"build_info", std::string(llama_build_info())},
            {"cors_proxy_enabled", false},
        });
    }));

    auto models = guarded([s](const server_http_req &) { return ok_response(model_list(locked(s))); });
    h.get("/models", models);
    h.get("/v1/models", models);

    h.post("/models/load", guarded([session = s](const server_http_req & req) -> server_http_res_ptr {
        auto s = locked(session);
        std::string name = json_value(json::parse(req.body), "model", std::string());
        common_preset preset;
        if (!find_preset(name, preset)) throw http_error(404, "not_found_error", "model is not found");
        {
            std::lock_guard<std::mutex> lock(s->state);
            if (s->current && s->current->name == name) {
                throw http_error(400, "invalid_request_error", "model is already running");
            }
        }
        acquire(s, name);
        return ok_response({{"success", true}});
    }));
    h.post("/models/unload", guarded([session = s](const server_http_req & req) -> server_http_res_ptr {
        auto s = locked(session);
        std::string name = json_value(json::parse(req.body), "model", std::string());
        std::lock_guard<std::mutex> swap(s->swap);
        {
            std::lock_guard<std::mutex> lock(s->state);
            if (!s->current || s->current->name != name) {
                throw http_error(400, "invalid_request_error", "model is not running");
            }
        }
        unload(s);
        return ok_response({{"success", true}});
    }));
    h.get("/models/sse", guarded([session = s](const server_http_req & req) -> server_http_res_ptr {
        auto s = locked(session);
        auto res = std::make_unique<server_http_res>();
        res->content_type = "text/event-stream";
        res->next = [s, cursor = s->feed.end(), &req](std::string & output) mutable {
            return s->feed.next(cursor, output, req.should_stop);
        };
        return res;
    }));

    h.get("/slots", forward(s, &server_routes::get_slots));
    h.post("/completion", forward(s, &server_routes::post_completions));
    h.post("/v1/completions", forward(s, &server_routes::post_completions_oai));
    h.post("/chat/completions", forward(s, &server_routes::post_chat_completions));
    h.post("/v1/chat/completions", forward(s, &server_routes::post_chat_completions));
    h.post("/v1/chat/completions/control", forward(s, &server_routes::post_control));
    h.post("/chat/completions/input_tokens", forward(s, &server_routes::post_chat_completions_tok));
    h.post("/v1/chat/completions/input_tokens", forward(s, &server_routes::post_chat_completions_tok));
    h.post("/tokenize", forward(s, &server_routes::post_tokenize));
    h.post("/detokenize", forward(s, &server_routes::post_detokenize));
    h.post("/apply-template", forward(s, &server_routes::post_apply_template));
    // Decision models answer typed questions here instead of chatting.
    h.post("/v1/systemone", forward(s, &server_routes::post_systemone, true));
    // Resumable streams are buffered outside the engines, so they survive a swap.
    h.get("/v1/stream", guarded(server_stream_make_get_handler()));
    h.post("/v1/streams/lookup", guarded(server_stream_make_lookup_handler()));
    h.del("/v1/stream", guarded(server_stream_make_delete_handler()));

    auto disabled = [](const server_http_req &) {
        return error_response(403, "not_supported_error", "Not available in the iOS prototype");
    };
    h.get("/tools", disabled);
    h.post("/tools", disabled);
    h.get("/cors-proxy", disabled);
    h.post("/cors-proxy", disabled);
    h.post("/models", disabled);
    h.del("/models", disabled);
}

// A WebUI stream (X-Conversation-Id) outlives its client and stops only when cancelled,
// as the WebUI's Stop button does through DELETE /v1/stream. Cancels each until its
// request ends: one can create its stream after a pass, so this repeats.
void cancel_streams(const std::shared_ptr<Session> & s) {
    static const std::function<bool()> never = [] { return false; };
    const auto cancel = server_stream_make_delete_handler();
    std::unique_lock<std::mutex> lock(s->state);
    while (!s->conversations.empty()) {
        const std::set<std::string> ids(s->conversations.begin(), s->conversations.end());
        lock.unlock();
        for (const auto & id : ids) cancel(server_http_req{{{"conv_id", id}}, {}, "/v1/stream", "", "", {}, never});
        lock.lock();
        s->idle.wait_for(lock, std::chrono::milliseconds(200));
    }
}
}

bool mobile_server_set_presets(const char * path, char * error, size_t size) {
    init_backend(); // reading the projectors logs
    std::vector<Entry> models;
    try {
        common_preset_context context(LLAMA_EXAMPLE_SERVER);
        common_preset global;
        common_presets sections = context.load_from_ini(path, global);
        // As in the upstream router: a global section applies under each model's own.
        for (auto & [name, preset] : context.cascade(global, sections)) {
            if (name == "*" || name == COMMON_PRESET_DEFAULT_NAME) continue;
            Entry entry;
            entry.preset = preset;
            entry.preset.name = name;
            entry.preset.get_option("LLAMA_ARG_MODEL", entry.path);
            std::string tags, mmproj;
            if (entry.preset.get_option("LLAMA_ARG_TAGS", tags)) entry.tags = split_list(tags);
            // What the model accepts, as the upstream router reports it before a load.
            bool image = false, audio = false;
            if (entry.preset.get_option("LLAMA_ARG_MMPROJ", mmproj) && !mmproj.empty()) {
                mtmd_caps caps = mtmd_get_cap_from_file(mmproj.c_str());
                image = caps.inp_vision;
                audio = caps.inp_audio;
            }
            // Decision models report `decisions`, as the upstream router does; the tags
            // written by ModelPreset say the same for clients that read those.
            const common_gguf_info info = common_get_gguf_info(entry.path);
            entry.n_ctx_train = info.n_ctx_train;
            const auto outputs = server_model_output_modalities(info.decision_type);
            entry.architecture = server_model_architecture_json(image, audio, false, outputs);
            models.push_back(std::move(entry));
        }
    } catch (const std::exception & e) {
        if (error && size > 0) snprintf(error, size, "%s", e.what());
        return false;
    }
    {
        std::lock_guard<std::mutex> lock(catalog.mutex);
        catalog.models = std::move(models);
    }
    std::shared_ptr<Session> session;
    {
        std::lock_guard<std::mutex> lock(mutex);
        session = current;
    }
    if (session) session->feed.publish("models_reload", "");
    return true;
}

int mobile_server_run(const char * initial_model, int port, bool gpu) {
    std::shared_ptr<Session> session;
    bool streams_started = false;
    int result = 0;
    try {
        init_backend();
        session = std::make_shared<Session>();
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (current) return 2;
            current = session;
        }
        session->gpu = gpu;
        auto & p = session->params;
        p.hostnames = {"127.0.0.1"};
        p.port = port;
        p.cors_origins = "http://127.0.0.1:" + std::to_string(port);
        mobile_defaults(p, gpu);
        p.ui = true;
        p.ui_mcp_proxy = false;
        p.ui_config_json = R"({"showToolCalls":false})";

        if (!session->http.init(p)) throw std::runtime_error("HTTP initialization failed");
        register_routes(session, json::parse(p.ui_config_json));
        server_stream_session_manager_start();
        streams_started = true;
        if (!session->http.start()) throw std::runtime_error("Port unavailable");
        session->http.is_ready.store(true);
        if (initial_model && *initial_model && !session->cancelled.load()) {
            try {
                acquire(session, initial_model);
            } catch (const std::exception & error) {
                // The server stays up so another model can be chosen in the WebUI.
                LOG_ERR("Mobile server: %s\n", error.what());
            }
        }
        session->started.store(true);
        while (!session->cancelled.load()) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    } catch (const std::exception & error) {
        LOG_ERR("Mobile server: %s\n", error.what());
        result = 1;
    }
    // Same cleanup path for startup errors and normal termination.
    if (session) {
        session->http.is_ready.store(false);
        session->cancelled.store(true); // requests in flight stop, new ones are refused
        session->feed.close();
        session->http.stop();
        if (streams_started) {
            cancel_streams(session);
            server_stream_session_manager_stop(); // wakes the readers of finished streams
        }
        std::shared_ptr<Engine> engine;
        {
            std::lock_guard<std::mutex> lock(session->state);
            engine = session->current;
        }
        // Requests have stopped waiting on the engine; ends its loop too.
        if (engine) engine->context.terminate();
        session->http.join(); // after this, no handler or response holds the session
        {
            std::lock_guard<std::mutex> swap(session->swap);
            std::lock_guard<std::mutex> lock(session->state);
            session->current.reset();
        }
        engine.reset();
        std::lock_guard<std::mutex> lock(mutex);
        if (current == session) current.reset();
    }
    return result;
}

void mobile_server_stop(void) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!current) return;
    current->cancelled.store(true);
}

bool mobile_server_ready(void) {
    std::lock_guard<std::mutex> lock(mutex);
    return current && current->started.load();
}

size_t mobile_server_loaded_model(char * buffer, size_t size) {
    std::string name;
    {
        std::lock_guard<std::mutex> lock(mutex);
        if (current) {
            std::lock_guard<std::mutex> state(current->state);
            if (current->current) name = current->current->name;
        }
    }
    if (size == 0) return name.size();
    size_t length = std::min(name.size(), size - 1);
    memcpy(buffer, name.data(), length);
    buffer[length] = '\0';
    return length;
}

void mobile_server_unload(void) {
    std::shared_ptr<Session> session;
    {
        std::lock_guard<std::mutex> lock(mutex);
        session = current;
    }
    if (!session) return;
    std::lock_guard<std::mutex> swap(session->swap);
    unload(session);
}

bool mobile_server_probe_memory(const char * model_path, unsigned n_ctx, bool gpu, uint64_t * total_bytes) {
    try {
        init_backend();
        common_params p;
        mobile_defaults(p, gpu);
        p.model.path = model_path;
        p.n_ctx = n_ctx;
        // The same figures `llama fit-params -fitp on` prints for the Mac, measured
        // without allocating. Unlike common_get_device_memory_data, which swaps the
        // global logger for the duration, this only quiets the calling thread.
        auto mparams = common_model_params_to_llama(p);
        auto cparams = common_context_params_to_llama(p);
        mparams.no_alloc = true;
        mparams.load_mode = LLAMA_LOAD_MODE_NONE;
        struct quiet {
            quiet() { quiet_below = GGML_LOG_LEVEL_ERROR; }
            ~quiet() { quiet_below = GGML_LOG_LEVEL_NONE; }
        } logs;
        std::unique_ptr<llama_model, decltype(&llama_model_free)> model(
            llama_model_load_from_file(model_path, mparams), llama_model_free);
        if (!model) throw std::runtime_error("failed to load model");
        std::unique_ptr<llama_context, decltype(&llama_free)> ctx(
            llama_init_from_model(model.get(), cparams), llama_free);
        if (!ctx) throw std::runtime_error("failed to create llama_context from model");
        // Every device draws from the same memory: the host's buffers and the model's
        // devices', as fit.cpp counts them.
        uint64_t total = 0;
        for (const auto & [buft, usage] : llama_get_memory_breakdown(ctx.get())) {
            bool counted = ggml_backend_buft_is_host(buft);
            if (ggml_backend_dev_t dev = counted ? nullptr : ggml_backend_buft_get_device(buft)) {
                for (int i = 0; i < llama_model_n_devices(model.get()); i++) {
                    counted |= dev == llama_model_get_device(model.get(), i);
                }
            }
            if (counted) total += usage.total();
        }
        *total_bytes = total;
        return total > 0;
    } catch (const std::exception & e) {
        LOG_ERR("Mobile server: memory probe failed: %s\n", e.what());
        return false;
    }
}

void mobile_server_set_log_file(const char * path) {
    // common_init sets the prefix and timestamps the file lines carry.
    init_backend();
    common_log_set_file(common_log_main(), path);
}

const char * mobile_server_build_info(void) {
    return llama_build_info();
}
