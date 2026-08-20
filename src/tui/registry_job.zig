//! Background models.dev registry refresh. `openProviderPicker` installs the
//! disk-cached registry synchronously (never network — a blocking HTTP fetch
//! on the UI thread froze the whole TUI on slow networks) and starts this job
//! so newly added providers still appear without waiting for the 24h cache
//! TTL. Structurally cloned from the model_loader_job pattern: job struct,
//! `done` atomic polled by the tick, future owned by App state.

const std = @import("std");
const log = std.log.scoped(.tui);
const modelsdev = @import("../models/registry.zig");
const provider_model = @import("provider_model.zig");
const tui = @import("../tui.zig");

const App = tui.App;

pub const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Owned copy: the focused lane's runtime may park mid-fetch, and the
    /// registry load reads/writes the cache under home_dir.
    home_dir: []u8,
    done: *std.atomic.Value(bool),
};

/// Worker entry point for `io.concurrent`. Owns `job` — frees it (and the
/// home_dir copy) on exit. Flips `done` to `true` immediately before
/// returning (through a captured pointer — the job is already freed) so the
/// tick knows it can `await` without blocking. `loadOrFetchRegistry` never
/// errors (it falls back to cache/vendored/builtins), so the future's Result
/// is always a fully-initialized Registry.
pub fn run(job: *Job) modelsdev.Registry {
    const registry = modelsdev.loadOrFetchRegistry(job.gpa, job.io, job.home_dir);
    const done = job.done;
    const gpa = job.gpa;
    gpa.free(job.home_dir);
    gpa.destroy(job);
    done.store(true, .release);
    return registry;
}

/// Kick off a background refresh. No-op when one is already running or there
/// is no live runtime / home dir (headless tests, idle lanes).
pub fn start(app: *App) !void {
    if (app.provider_state.registry_refresh == .loading) return;
    const runtime = app.liveRuntime() orelse return;
    if (runtime.home_dir.len == 0) return;

    const job = try app.gpa.create(Job);
    errdefer app.gpa.destroy(job);
    const home = try app.gpa.dupe(u8, runtime.home_dir);
    errdefer app.gpa.free(home);
    job.* = .{
        .gpa = app.gpa,
        .io = app.io,
        .home_dir = home,
        .done = undefined, // armed below
    };
    // Arm before the spawn: the job captures the address of the union's
    // `done` field, so the union must stay `.loading` (untouched) until
    // drain/cancel moves it out.
    app.provider_state.registry_refresh = .{
        .loading = .{
            .future = undefined, // set below
            .done = .init(false),
        },
    };
    job.done = &app.provider_state.registry_refresh.loading.done;
    app.provider_state.registry_refresh.loading.future = app.io.concurrent(run, .{job}) catch |err| {
        // Never leave an armed `.loading` with an undefined future (the
        // cancelModelLoad UB class): reset to `.idle` and re-raise. The
        // errdefers free home + job — `run` never took ownership of them,
        // so there is nothing to clean up by hand here (a manual free would
        // double-free once the error return fires the errdefers).
        app.provider_state.registry_refresh = .idle;
        return err;
    };
}

/// Poll the done flag; once the worker signals completion, await the fresh
/// registry and adopt it. Returns true when a redraw is needed.
pub fn drain(app: *App) !bool {
    if (app.provider_state.registry_refresh != .loading) return false;
    if (!app.provider_state.registry_refresh.loading.done.load(.acquire)) return false;

    const registry = app.provider_state.registry_refresh.loading.future.await(app.io);
    app.provider_state.registry_refresh = .idle;
    adoptRefreshedRegistry(app, registry);
    return true;
}

/// Swap in a freshly fetched registry. Three borrow hazards, in order:
/// (1) an open `.dynamic` form handle holds a Provider by value whose
///     strings point into the OLD registry — re-resolve by id, or drop the
///     form when the provider vanished;
/// (2) the merged picker entries borrow the old registry too — rebuild them
///     BEFORE freeing it;
/// (3) if the rebuild fails (OOM), the still-installed old entries would
///     dangle the moment the old registry is freed — invalidate them so the
///     picker rebuilds safely on its next open.
pub fn adoptRefreshedRegistry(app: *App, registry: modelsdev.Registry) void {
    var old = app.provider_state.modelsdev_registry;
    app.provider_state.modelsdev_registry = registry;

    if (app.pickers.provider.stage == .form) {
        if (app.pickers.provider.form_handle) |handle| {
            switch (handle) {
                .dynamic => |provider| {
                    const rebound: ?modelsdev.Provider = if (app.provider_state.modelsdev_registry) |*reg|
                        reg.lookup(provider.id)
                    else
                        null;
                    if (rebound) |fresh| {
                        app.pickers.provider.form_handle = .{ .dynamic = fresh };
                    } else {
                        app.pickers.provider.stage = .list;
                        app.pickers.provider.form_handle = null;
                        app.input_buffers.provider_key.clearRetainingCapacity();
                    }
                },
                else => {},
            }
        }
    }

    provider_model.rebuildProviderEntries(app) catch |err| {
        log.warn("registry.refresh.rebuild_failed err={s}", .{@errorName(err)});
        provider_model.invalidateProviderEntries(app);
    };
    if (old) |*o| o.deinit(app.gpa);
}

/// Cancel + join an in-flight refresh (app teardown). `Future.cancel` is
/// "await with a cancelation request" — it blocks until the task returns, so
/// the registry it hands back is fully initialized and owned by us; nobody
/// will drain it, so free it wholesale.
pub fn cancel(app: *App) void {
    if (app.provider_state.registry_refresh == .loading) {
        var future = app.provider_state.registry_refresh.loading.future;
        var registry = future.cancel(app.io);
        registry.deinit(app.gpa);
        app.provider_state.registry_refresh = .idle;
    }
}

pub fn active(app: *const App) bool {
    return app.provider_state.registry_refresh == .loading;
}

test "start no-ops without a live runtime" {
    const agent_mod = @import("../agent.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Focused idle lane (mirrors the mode_lifecycle fixture): no runtime, so
    // start must arm nothing.
    const lane = try gpa.create(tui.Thread);
    errdefer gpa.destroy(lane);
    const branch = try std.fmt.allocPrint(gpa, "nova/regjob", .{});
    errdefer gpa.free(branch);
    const path = try std.fmt.allocPrint(gpa, "/tmp/nova-lanes/regjob", .{});
    errdefer gpa.free(path);
    lane.* = .{ .engine = .{ .idle = .{ .working = .{ .branch = branch, .path = path } } } };
    try app.threads.append(lane);
    app.thread = lane;

    try start(&app);
    try std.testing.expect(app.provider_state.registry_refresh == .idle);
}

test "cancel on idle state is a no-op" {
    const agent_mod = @import("../agent.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    cancel(&app);
    try std.testing.expect(app.provider_state.registry_refresh == .idle);
}

test "drain returns false when idle" {
    const agent_mod = @import("../agent.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    try std.testing.expect(!try drain(&app));
    try std.testing.expect(!active(&app));
}

test "adoptRefreshedRegistry rebinds or drops a stale dynamic form handle" {
    const agent_mod = @import("../agent.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Two independent registries: the open form handle borrows the first
    // one's string storage, the adopt must never leave it dangling.
    const reg_a = modelsdev.loadRegistryCached(gpa, std.testing.io, "");
    app.provider_state.modelsdev_registry = reg_a;
    try std.testing.expect(reg_a.providers.len > 0);
    const stale = reg_a.providers[0];
    var id_buf: [64]u8 = undefined;
    const id_len = @min(stale.id.len, id_buf.len);
    @memcpy(id_buf[0..id_len], stale.id[0..id_len]);
    const original_id = id_buf[0..id_len];

    app.pickers.provider.stage = .form;
    app.pickers.provider.form_handle = .{ .dynamic = stale };

    // Fresh registry still has the provider: the form rebinds into the NEW
    // storage and stays open.
    const reg_b = modelsdev.loadRegistryCached(gpa, std.testing.io, "");
    adoptRefreshedRegistry(&app, reg_b);
    try std.testing.expectEqual(@import("widgets/provider_picker.zig").Stage.form, app.pickers.provider.stage);
    const handle = app.pickers.provider.form_handle.?;
    try std.testing.expectEqualStrings(original_id, handle.dynamic.id);

    // Registry without the provider: the form is dropped back to the list.
    adoptRefreshedRegistry(&app, .{ .providers = &.{}, .models = &.{}, .strings = .empty });
    try std.testing.expectEqual(@import("widgets/provider_picker.zig").Stage.list, app.pickers.provider.stage);
    try std.testing.expect(app.pickers.provider.form_handle == null);
}

test "adoptRefreshedRegistry invalidates entries when the rebuild fails" {
    const agent_mod = @import("../agent.zig");
    const gpa = std.testing.allocator;
    var agent = agent_mod.Agent.init(gpa, std.testing.io, ".", .none);
    defer agent.deinit();
    var app = try tui.App.init(std.testing.io, gpa, &agent);
    defer app.deinit();

    // Installed entries that would dangle once the old registry is freed.
    app.provider_state.modelsdev_registry = modelsdev.loadRegistryCached(gpa, std.testing.io, "");
    try provider_model.rebuildProviderEntries(&app);
    try std.testing.expect(app.provider_state.entries_slice != null);

    // Every rebuild failure must leave entries INVALIDATED (null), never the
    // stale installed slice — it borrows the old registry being freed.
    var succeeded = false;
    var i: usize = 0;
    while (i < 128) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = i });
        app.gpa = failing.allocator();
        adoptRefreshedRegistry(&app, .{ .providers = &.{}, .models = &.{}, .strings = .empty });
        app.gpa = gpa;
        if (app.provider_state.entries_slice == null) continue;
        succeeded = true;
        break;
    }
    try std.testing.expect(succeeded);
}
