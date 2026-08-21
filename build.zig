const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const websocket_vendor_mod = b.createModule(.{
        .root_source_file = b.path("vendor/websocket.zig/src/websocket.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const bounded_queue_mod = b.createModule(.{
        .root_source_file = b.path("lib/bounded_queue.zig"),
        .target = target,
        .optimize = optimize,
    });
    {
        const options = b.addOptions();
        options.addOption(bool, "websocket_blocking", false);
        websocket_vendor_mod.addOptions("build", options);
    }
    const websocket_mod = b.createModule(.{
        .root_source_file = b.path("lib/websocket.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "websocket_vendor", .module = websocket_vendor_mod },
        },
    });
    const platform_mod = b.createModule(.{
        .root_source_file = b.path("lib/platform.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const logger_mod = b.createModule(.{
        .root_source_file = b.path("lib/logger.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "bounded_queue", .module = bounded_queue_mod },
            .{ .name = "platform", .module = platform_mod },
        },
    });
    const counting_allocator_mod = b.createModule(.{
        .root_source_file = b.path("lib/counting_allocator.zig"),
        .target = target,
        .optimize = optimize,
    });
    const terminal_markdown_mod = b.createModule(.{
        .root_source_file = b.path("lib/terminal_markdown.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
            .{ .name = "counting_allocator", .module = counting_allocator_mod },
        },
    });
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path("vendor/sqlite"));
    translate_c.addIncludePath(b.path("vendor/lua"));
    translate_c.addIncludePath(b.path("vendor/fzy"));
    translate_c.addIncludePath(b.path("vendor/fzy/src"));
    const c_mod = translate_c.createModule();

    const mod = b.addModule("nova", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bounded_queue", .module = bounded_queue_mod },
            .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
            .{ .name = "websocket", .module = websocket_mod },
            .{ .name = "logger", .module = logger_mod },
            .{ .name = "terminal_markdown", .module = terminal_markdown_mod },
            .{ .name = "counting_allocator", .module = counting_allocator_mod },
            .{ .name = "c", .module = c_mod },
            .{ .name = "platform", .module = platform_mod },
        },
    });

    // Version string embedded into the binary, surfaced by `nova --version` and
    // the settings panel. SSOT is the git tag: CI passes `-Dversion` explicitly on
    // release builds; local builds fall back to `git describe --tags --always`
    // (or "dev" when git is unavailable / not a repo). Exposed to every file in
    // the `nova` module as `@import("build").version`.
    const version = b.option([]const u8, "version", "Version string to embed (default: git describe or 'dev')") orelse blk: {
        var code: u8 = undefined;
        const raw = b.runAllowFail(&.{ "git", "describe", "--tags", "--always", "--dirty" }, &code, .ignore) catch break :blk "dev";
        break :blk std.mem.trim(u8, raw, " \n\r\t");
    };
    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", version);
    mod.addOptions("build", version_options);

    mod.link_libc = true;
    // C UB sanitizer for Debug builds: traps at the exact instruction on
    // undefined behavior in sqlite3.c / lua, giving a precise crash site
    // for gdb without needing the UBSan runtime library.
    if (optimize == .Debug) mod.sanitize_c = .trap;
    mod.addIncludePath(b.path("vendor/lua"));
    mod.addIncludePath(b.path("vendor/fzy"));
    mod.addIncludePath(b.path("vendor/fzy/src"));
    // Native keychain backends (src/keyring.zig): Windows Credential Manager
    // lives in advapi32; macOS Keychain Services needs Security (+ CoreFoundation
    // for CFRelease). Other targets use the plaintext file fallback.
    switch (target.result.os.tag) {
        .windows => mod.linkSystemLibrary("advapi32", .{}),
        .macos => {
            mod.linkFramework("Security", .{});
            mod.linkFramework("CoreFoundation", .{});
        },
        else => {},
    }
    mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=2",
            "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
            "-DSQLITE_USE_URI=1",
            "-DSQLITE_ENABLE_JSON1",
            "-DSQLITE_ENABLE_FTS5",
            "-Wno-implicit-function-declaration",
            "-Wno-unused-but-set-variable",
        },
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lapi.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lauxlib.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lbaselib.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lcode.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lcorolib.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lctype.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/ldblib.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/ldebug.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/ldo.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/ldump.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lfunc.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lgc.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/linit.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/liolib.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/llex.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lmathlib.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lmem.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/loadlib.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lobject.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lopcodes.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/loslib.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lparser.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lstate.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lstring.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lstrlib.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/ltable.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/ltablib.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/ltm.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lundump.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lutf8lib.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lvm.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/lua/lzio.c"),
        .flags = &.{"-std=c99"},
    });
    mod.addCSourceFile(.{
        .file = b.path("vendor/fzy/src/match.c"),
        .flags = &.{"-std=c99"},
    });

    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "nova",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "nova" is the name you will use in your source code to
                // import this module (e.g. `@import("nova")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "nova", .module = mod },
                .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
                .{ .name = "websocket", .module = websocket_mod },
                .{ .name = "logger", .module = logger_mod },
                .{ .name = "terminal_markdown", .module = terminal_markdown_mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // Install the vendored models.dev snapshot alongside the binary so
    // loadOrFetchRegistry can seed the cache from it when the network is
    // unavailable. Installed to <prefix>/share/nova/api.json.
    const install_vendor = b.addInstallFile(b.path("vendor/models.dev/api.json"), "share/nova/api.json");
    b.getInstallStep().dependOn(&install_vendor.step);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    // Optional substring filter: `zig build test -Dtest-filter=checkpoint`
    // compiles and runs only tests whose fully-qualified name contains it.
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const test_filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const mod_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = test_filters,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    for ([_]*std.Build.Module{
        terminal_markdown_mod,
        bounded_queue_mod,
        logger_mod,
        websocket_mod,
        platform_mod,
    }) |lib_mod| {
        const lib_tests = b.addTest(.{ .root_module = lib_mod, .filters = test_filters });
        test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    }

    // Benchmarks are standalone executables under bench/, always built
    // ReleaseFast so the numbers are meaningful, and wired only to
    // `zig build bench` — never to the default install or `zig build test`.
    const bench_step = b.step("bench", "Run benchmarks (ReleaseFast)");
    for ([_][]const u8{
        "bench/markdown_render.zig",
        "bench/markdown_incremental.zig",
    }) |bench_src| {
        const bench_exe = b.addExecutable(.{
            .name = b.fmt("bench-{s}", .{std.fs.path.stem(bench_src)}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(bench_src),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "terminal_markdown", .module = terminal_markdown_mod },
                    .{ .name = "counting_allocator", .module = counting_allocator_mod },
                },
            }),
        });
        bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
    }

    // Lua plugin test runner: `zig build test-plugin` runs Lua test files
    // through the Nova Lua sandbox. Tests are standalone .lua files under
    // examples/plugins/ that use the test_runner module.
    const lua_test_step = b.step("test-plugin", "Run Lua plugin tests");
    {
        const lua_test_exe = b.addExecutable(.{
            .name = "lua-test-runner",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/lua_test_runner.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "nova", .module = mod },
                },
            }),
        });
        const run_lua_tests = b.addRunArtifact(lua_test_exe);
        // Pass test file paths as arguments
        run_lua_tests.addArg("examples/plugins/hello-world/test.lua");
        run_lua_tests.addArg("examples/plugins/search-tools/test.lua");
        run_lua_tests.addArg("examples/plugins/todo/test.lua");
        run_lua_tests.addArg("examples/plugins/file-tools/test.lua");
        run_lua_tests.addArg("examples/plugins/git-tools/test.lua");
        run_lua_tests.addArg("examples/plugins/file-watcher/test.lua");
        run_lua_tests.addArg("examples/plugins/path-tools/test.lua");
        run_lua_tests.addArg("examples/plugins/modular-demo/test.lua");
        run_lua_tests.addArg("examples/plugins/sitting-duck/test.lua");
        lua_test_step.dependOn(&run_lua_tests.step);
    }

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
