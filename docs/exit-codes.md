# Exit code contract

One table, because two of these codes are easy to conflate and doing so
produces a misleading report.

| Code | Meaning | A conclusion? |
|---|---|---|
| 0 | Linearizable | yes |
| 1 | Violation found | yes |
| 2 | Usage error | no — the command was wrong |
| 3 | Unknown (missing responses, invalid intervals, or search budget exhausted) | no |
| 4 | Input data error (unreadable/unparseable file) | no — there was nothing to judge |

Note: a history that *parses* but contains an invalid interval
(`start > end`) surfaces as `3` (Unknown), not `4` — the file was readable,
so `check` ran and reported "cannot judge" rather than "could not read".
`4` is reserved for failures before any history exists to examine.

A parsed `Nil` result means the response is unknown. Under the default
strict configuration, the checker reports how many responses are missing
and returns `3` before searching. `minimize` retains these operations for
inspection without claiming a violation, and `visualize` renders the timeline
with the same unknown verdict. Library callers can explicitly enable
`allow_unknown_results` to assume a model-compatible response for every `Nil`;
this still applies every recorded operation within its recorded interval and
does not implement optional completion of pending operations.

For example, `moon run cmd/lincheck -- check --history examples/unknown_results.jsonl --model register --json`
returns `{"verdict":"unknown","reason":"...2 个未知结果..."}` and exits `3`.
The same fixture works with `minimize` and `visualize` and also exits `3`.

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

Linearizability checking has an exponential worst case. A sufficiently hard
history can exceed the search budget. At that point the honest answer is
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
