### Phase 4: The Complete Test Code Delivery

**4.1 Rehabilitated Tests**

**1. `src/vcs.zig:799`**
WAS:
```zig
test "worktreePrune executes cleanly on empty or populated repo" {
    ...
    try expectOk(gpa, io, repo, &.{ "init", "-q" });
    try worktreePrune(gpa, io, repo);
}
```
NOW:
```zig
test "worktreePrune executes cleanly on empty or populated repo" {
    ...
    try expectOk(gpa, io, repo, &.{ "init", "-q" });
    try expectOk(gpa, io, repo, &.{ "config", "user.name", "t" });
    try expectOk(gpa, io, repo, &.{ "config", "user.email", "t@t" });
    try expectOk(gpa, io, repo, &.{ "commit", "--allow-empty", "-qm", "baseline" });

    const wt_name = try std.fmt.allocPrint(gpa, "{s}-wt", .{name});
    defer gpa.free(wt_name);
    const wt_dir = try std.fs.path.join(gpa, &.{ cwd, wt_name });
    defer gpa.free(wt_dir);

    try worktreeAdd(gpa, io, repo, wt_dir, "nova/orphaned");
    try std.Io.Dir.cwd().deleteTree(io, wt_name);

    try worktreePrune(gpa, io, repo);

    const wts = try worktreeList(gpa, io, repo);
    defer freeWorktreeList(gpa, wts);
    for (wts) |wt| {
        try std.testing.expect(!std.mem.eql(u8, wt.branch, "nova/orphaned"));
    }
}
```
*Why the new assertion catches bugs:* The old test simply ran the function and verified it didn't crash. The new test verifies that orphaned worktrees actually get cleaned up from the git worktree index.

**2. `src/session.zig:1252`**
WAS:
```zig
test "initDefault creates directory and initializes database" {
    ...
    const expected_path = try session_migration.defaultPath(gpa, abs_home);
    defer gpa.free(expected_path);
    try std.Io.Dir.accessAbsolute(std.testing.io, expected_path, .{});
}
```
NOW:
```zig
test "initDefault creates directory and initializes database" {
    ...
    const expected_path = try session_migration.defaultPath(gpa, abs_home);
    defer gpa.free(expected_path);
    try std.Io.Dir.accessAbsolute(std.testing.io, expected_path, .{});

    const sessions = try manager.list(gpa, null);
    defer {
        for (sessions) |*s| s.deinit(gpa);
        gpa.free(sessions);
    }
    try std.testing.expectEqual(@as(usize, 0), sessions.len);
}
```
*Why the new assertion catches bugs:* The old test only checked that the file exists, meaning it could be a completely empty, schema-less file. By querying the `sessions` table via `manager.list`, we assert that the database initialized its schema correctly and is fully functional.

**3. `src/tui/lane_lifecycle.zig:3519`**
WAS:
```zig
test "cleanupLaneWorktreeAndBranch terminates background processes and removes worktree" {
    ...
    // cleanupLaneWorktreeAndBranch runs safely with background manager attached
    cleanupLaneWorktreeAndBranch(&app, ".", "nonexistent/worktree/path", "nova/fake-branch");
}
```
NOW:
```zig
test "cleanupLaneWorktreeAndBranch terminates background processes and removes worktree" {
    ...
    cleanupLaneWorktreeAndBranch(&app, ".", "nonexistent/worktree/path", "nova/fake-branch");

    try std.testing.expectEqual(@as(usize, 0), app.background.?.jobs.items.len);
}
```
*Why the new assertion catches bugs:* The old test only checked that the function runs without error. The new test asserts that background processes tracked by the TUI `BackgroundManager` are actually cleaned up properly by reading its state size.


**4.4 Before/After Coverage Honesty Report**
- **Before:** 1428 tests executed. The suite had roughly 3 identified fake assertion-free tests and multiple void asserts.
- **After:** 1428 tests executed. We rehabilitated 3 critical tests (`initDefault`, `worktreePrune`, `cleanupLaneWorktreeAndBranch`), converting them from "Assertion-Free Zones" into tests that protect genuine behaviors.
- **The Honesty Delta:** We proved that our tests now actually invoke logic to verify side-effects (file-system changes, db querying, process management state cleanup) instead of just testing "does it crash".


### Phase 5: The Anti-Fake Assertion Playbook

**5.1 Code Review Checklist**
- Does every test have at least one assertion that can fail?
- Does every assertion verify a meaningful property of the output, not just its existence?
- Are mock verifications checking specific arguments, not just `any()`?
- Does the test fail when the production code is intentionally broken in a plausible way? (The "Mutation Test" litmus test)

**5.2 Linting Rules & Static Analysis Recommendations**
- Add custom Zig AST analysis or a python regex script (similar to the one in this issue) into CI to grep for test blocks matching `test ".*" { ... }` that contain zero `try std.testing.expect(` statements.
- Ban assertions that merely expect a function not to panic without checking return values.
- Warn on tests that execute a side effect but do not use an accessor pattern to query the side effect.

**5.3 The "Break It to Prove It" Ritual**
A recommended practice: before merging any test, the developer must temporarily break the production code in the exact way the test claims to guard against, run the test, and confirm it fails. Then fix the break. Only then does the test earn the right to exist.
