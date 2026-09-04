# The Anti-Fake Assertion Playbook

## 1. Code Review Checklist
- Does every test have at least one assertion that can fail?
- Does every assertion verify a meaningful property of the output, not just its existence (`expect(result != null)`)?
- Are mock verifications checking specific arguments, not just `any()`?
- Does the test fail when the production code is intentionally broken in a plausible way? (The "Mutation Test" litmus test)

## 2. Linting Rules & Static Analysis Recommendations
- Add custom Zig AST analysis or a Python regex script into CI to grep for test blocks matching `test ".*" { ... }` that contain zero `try std.testing.expect*(` statements.
- Ban assertions that merely expect a function not to panic without checking return values.
- Warn on tests that execute a side effect (e.g. database insertion, filesystem manipulation) but do not use an accessor pattern to query the side effect.

## 3. The "Break It to Prove It" Ritual
A recommended practice: before merging any test, the developer must temporarily break the production code in the exact way the test claims to guard against, run the test, and confirm it fails. Then fix the break. Only then does the test earn the right to exist.
