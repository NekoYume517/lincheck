# Exit code contract

One table, because two of these codes are easy to conflate and doing so
produces a misleading report.

| Code | Meaning | A conclusion? |
|---|---|---|
| 0 | Linearizable | yes |
| 1 | Violation found | yes |
| 2 | Usage error | no — the command was wrong |
| 3 | Unknown (search budget exhausted) | no |
| 4 | Input data error | no — there was nothing to judge |

## The distinction that matters

Codes 0 and 1 are **answers**. Codes 2, 3 and 4 are the **absence of an
answer**, for three different reasons.

The dangerous confusion is between `1` and `4`:

- `1` says "this history really is not linearizable". The system under test
  has a bug.
- `4` says "the history could not be read or parsed". Nothing was tested.

A script that maps both to "failed" will report a broken fixture file as a
discovered concurrency bug. That is the worst possible outcome, because it
sends someone debugging a system that was never examined.

## Why 3 is its own code

Linearizability checking is NP-hard in general. Any real history will
eventually exceed the search budget. At that point the honest answer is
"unknown", and it must not be rounded to either neighbour:

- rounding to `0` (linearizable) misses real violations
- rounding to `1` (violation) raises false alarms

Keeping a third state forces the caller to decide what to do with an
inconclusive run, which is the correct place for that decision.

## On `visualize` and `minimize`

Both subcommands run the checker as part of their work, and both inherit its
exit code. On a deliberately violating fixture such as
`examples/register_bad.jsonl` they therefore return `1`.

That is intentional, not a crash. It means these commands can be used in CI
directly, and it keeps the semantics consistent: every command that reads a
history reports what it found in the exit code.

When you only want the rendering, ignore the exit code. When you want a
verdict, use `check`.
