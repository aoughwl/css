# Hardening the obfuscator — beating our own deobfuscator, cheaply, on the JS path

## The adversary is already in this tree

`~/aoughwl/bridges/nifi/deobf` reduces every routine to a **canonical summary**
with all parameters unknown: it folds branches whose arms agree, deletes dead
variables, runs counted loops with known bounds, folds arithmetic — then strips
names (calls → callee summary, enum → ordinal, field → index, everything else →
a positional marker). Renamed routines then match named ones by what they
*compute*: `o54 ≡ isIdentStart`, `cur ≡ o104`.

Today's `obf.nim` only **renames** identifiers and appends a few never-called
decoy procs. Its own docstring says it "injects NO control flow" and "execution
STRUCTURE is preserved exactly; only NAMES change." That is exactly the input
`deobf` was built to see through — the current obfuscator is a *test article for
the deobfuscator*, not a shield. On the last build `deobf` settled 191/536
summaries and rejoined 9 groups. **That is the score we have to move.**

So "hardened" is not a vibe here — it is a number:

> **Maximize the fraction of routines `deobf` leaves STUCK, drive its join-group
> count to zero, and leak zero string literals — while the emitted JS stays
> within a stated perf budget.** We already own the scoring function.

## One principle beats both grinders

Anything we emit is chewed by **two** reducers, and they pull in opposite
directions:

1. our semantic `deobf` (offline adversary), and
2. the V8 / JS JIT (online, every run).

A *constant-valued* opaque predicate is folded by **both**: `deobf` erases it
(no protection) and V8 erases it (no cost — but also no protection). The only
construct that survives both is one **grounded in a value both must treat as
unknown**: a per-run seed, an actual input byte, an env value. `deobf` runs
"all params unknown" so it cannot fold it; V8 cannot fold it because it is not a
compile-time constant. The runtime cost is a few integer ops. That single idea —
*seed the opacity in runtime-unknown data* — is the whole game, and it is what
makes "hardened" and "not much perf loss" compatible instead of opposed.

## The transforms (each: what it defeats / what it costs on JS)

| # | transform | defeats | JS cost |
|---|-----------|---------|---------|
| **T1** | **Seeded MBA opaque predicates & constant blinding** — replace guards and literals with mixed boolean-arithmetic over a per-run seed (`x^y = (x|y)-(x&y)`, etc.). | branch-fold, arithmetic-fold, V8 constant-fold | ~2–4 int ops — **best ratio, do first** |
| **T2** | **String / data blinding** — the current tool leaves every literal in the clear; on the JS path those are the loudest leak (CSS property names sit inline in the bundle). XOR/rotate the bytes under the seed, decode lazily and cache. | `grep`, and `deobf` cannot fold a seed-keyed decode | one pass per string, cached |
| **T3** | **Anti-join diversification** — inject a *per-routine*, seed-keyed no-op into structurally identical routines so their canonical summaries **diverge**. | the rejoin step directly — kills `o54 ≡ isIdentStart` | ~0 |
| **T4** | **Seed-keyed control-flow flattening** — basic blocks → a `switch(state)` loop whose next-state is computed by the MBA. `deobf` must symbolically run a dispatch it cannot decide. | summary reduction wholesale | real (switch overhead) — **budgeted, cold/sensitive routines only** |

T4 is the perf knob: it is the strongest and the only expensive one, so it is
applied to a *selected set*, not everywhere.

**What we do NOT claim.** Enum ordinals and field indices survive `deobf`'s
canonicalization by construction; hiding them is high-cost, low-value, so leave
them as-is rather than pretend. Honesty about the ceiling is the DEOBF.md house
style.

## Move off the text scanner — obfuscate the IR

`obf.nim` is a line-oriented character scanner: brittle, and it can *only*
rename. T1–T4 are all AST transforms. Do them at the **NIF / IR level** (the
aowl substrate) where they are structure-aware and robust, then emit JS. Bonus:
the IR we obfuscate is the *same artifact* `deobf` reads, so scoring stays
apples-to-apples — obfuscate the NIF, score the NIF, emit the JS.

## Layer 2 — obfuscate the emitted JS too

After the native-JS emit, an optional JS post-pass: mangle locals V8 does not
need named, string-array + rotate, property-access indirection, a self-defending
wrapper. This is **complementary**, not redundant: Layer 1 defeats the
*semantic* reducer; Layer 2 defeats casual JS reading and prettifiers. Keep it
optional and measured (bundle-size delta + a perf smoke test), because it is the
part most likely to cost runtime.

## The feedback loop — the actual "good thing"

Every obfuscated build is scored by `deobf.sh`: settled/stuck ratio, join-group
count and size, names leaked. Obfuscation strength stops being a claim and
becomes a number that must go the right way build-over-build, with the JS perf
budget as the guardrail. **An obfuscator that ships with its own oracle** is the
design worth having here — we are the only shop with the deobfuscator already
built.

## Phases

- **P0 — Baseline.** Wire `deobf.sh` as a scorer over `obf/build`. We already
  know the number to beat: 191 settled, 9 join-groups.
- **P1 — T1 + T2 + T3 at IR level.** Re-score: push settled **down** hard, joins
  to **zero**, confirm JS perf within budget.
- **P2 — T4 budgeted CFG flattening** over a sensitive-routine set. Re-score.
- **P3 — Layer-2 JS post-pass** + perf smoke.

Each phase ends with a `deobf` score and a JS perf number, in this file, the way
DEOBF.md carries its figures.
