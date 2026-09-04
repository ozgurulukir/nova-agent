# Phase 1: Fake Assertion Autopsy

## Fake Assertion Inventory

| Category | Signature Pattern | Why It's Fake |
|----------|-------------------|---------------|
| **The Assertion-Free Zone** | `test "..." { func(); }` | The test runs code but verifies absolutely nothing |
| **The Void Assert** | `expect(result != null)` | Passes for any non-null return, even completely wrong output |

**1.2 Detailed Fake Assertion Catalog**

FAKE TEST ID: FT-src/vcs.zig-799
Test Name: worktreePrune executes cleanly on empty or populated repo
File & Line: src/vcs.zig:799
Fake Category: The Assertion-Free Zone
Deceptive Code: `try worktreePrune(gpa, io, repo);`
Why It Lies: It tests that it does not panic, but it does not test if the worktree is actually pruned.
Real Behavior That Should Be Asserted: Verify that the pruned worktree actually disappears from the `.git/worktrees` index.
Exploitation Scenario: A regression in `worktreePrune` leaves files around that balloon the size of the repo over time and test would still pass.
Priority: HIGH

FAKE TEST ID: FT-src/session.zig-1252
Test Name: initDefault creates directory and initializes database
File & Line: src/session.zig:1252
Fake Category: The Assertion-Free Zone
Deceptive Code: `try std.Io.Dir.accessAbsolute(std.testing.io, expected_path, .{});`
Why It Lies: It only checks if the database file was created on the file system, not if it contains the correct schema and is ready for use.
Real Behavior That Should Be Asserted: Perform a `list` query to ensure the database can answer SQL queries correctly based on the initialized schema.
Exploitation Scenario: If the schema initialization script was removed or corrupted, the file would still be created but every session operation in production would crash.
Priority: CRITICAL

FAKE TEST ID: FT-src/tui/lane_lifecycle.zig-3519
Test Name: cleanupLaneWorktreeAndBranch terminates background processes and removes worktree
File & Line: src/tui/lane_lifecycle.zig:3519
Fake Category: The Assertion-Free Zone
Deceptive Code: `cleanupLaneWorktreeAndBranch(&app, ".", "nonexistent/worktree/path", "nova/fake-branch");`
Why It Lies: It provides non-existent paths and does not verify any of the internal states after calling.
Real Behavior That Should Be Asserted: It should check that the background jobs associated with the lane are properly terminated and removed from the active jobs list.
Exploitation Scenario: A memory leak where background jobs are left running in the TUI when lanes are cleaned up.
Priority: HIGH

## 2. Phase 2: The Coverage Desert Survey
1. `src/vcs.zig` - Full lifecycle of creating and pruning worktrees properly under load. (P1)
2. `src/session.zig` - Missing tests for verifying correct DB schema initialization values. (P1)
