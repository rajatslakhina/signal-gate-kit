# SignalGate

**Your eval suite says the pass rate dropped from 0.86 to 0.81. On a 40-row golden set, that is two samples. Do you block the merge?**

Almost every AI quality gate in production answers this by comparing two point estimates against a threshold. That gate is wrong in both directions at once, and it is wrong quietly:

- It **blocks good builds**, because a two-sample wobble crosses the line often enough to look like a pattern.
- It **passes real regressions**, because at n=40 it has almost no power to detect anything smaller than a catastrophe.

Neither failure announces itself. The team reads the first as "the eval gate is flaky," turns it off, and the second failure mode continues undetected.

`SignalGate` is the decision layer that sits between a graded eval run and the merge button. It takes outcomes an eval harness already produced — Apple's `Evaluations` framework, an in-house runner, anything — and returns a **three-state verdict** with the statistics to defend it in review.

```swift
let report = QualityGate.evaluate(
    baseline: baselineSamples,
    candidate: candidateSamples,
    judgeMatrix: judgeAgreementOnGoldenSet,
    policy: .standard
)

switch report.verdict {
case .pass:                              exit(0)
case .block:                             exit(1)
case .inconclusive(let why, let more):   // ← the state everyone else deletes
    print("Cannot certify: \(why). Needs ~\(more ?? 0) more samples/arm.")
    exit(2)
}
```

---

## Why this matters

Deterministic test suites made a promise that probabilistic ones cannot keep: that a green run means the code is correct. Once "the test" is an inference call, a green run means *the sample you happened to draw did not contradict you.* Those are very different claims, and the entire toolchain around CI is built to display the first one.

Four specific things break, and this library is organised around them.

### 1. A two-state gate is not a simplification. It is a bug.

When the evidence genuinely supports neither conclusion, a pass/fail gate still has to emit pass or fail. Every team configures it to emit pass — because the alternative is blocking merges on noise, and that gets the gate deleted in a week. So the ambiguity does not go away. It silently becomes a merge.

`.inconclusive` is a first-class verdict here, carrying *why* and *what would resolve it*. `allowsMerge` is true only for an affirmative `.pass`.

### 2. Per-slice gating without correction false-alarms about half the time.

Testing `k` slices independently at α gives a family-wise error rate of `1 − (1 − α)^k`. At the wholly ordinary configuration of **12 slices and α = 0.05, that is 46%** — roughly one in two clean runs blocks a merge on a slice that did not regress.

This is not a hypothetical. It is the default behaviour of every per-slice quality gate that thresholds each slice separately, including one in [my own earlier eval-harness repo](https://github.com/rajatslakhina/llm-eval-harness-kit), which is where I went looking for it.

`SignalGate` applies Benjamini–Hochberg and controls the false discovery rate instead. `GateReport` carries the uncorrected result alongside the corrected one, so the difference is measurable rather than asserted.

### 3. The same error inflation comes back one level up, and it is easy to miss.

The gate blocks if **either** the per-slice family fires **or** the overall non-inferiority test fires. Those are two hypothesis families. Running each at the full run-level α puts the true false-block rate near their union — which is exactly the bug §2 exists to eliminate, reproduced at the level above it.

An earlier build of this package had precisely that flaw, and its footprint was measurable: on the "2-point wobble" scenario — a build the package itself defines as a non-regression — it blocked at 23 of 499 reachable sample sizes. The run-level budget is now split evenly across the two families (`GatePolicy.overallAlpha`, `GatePolicy.sliceQ`), and `testTheWobbleScenarioNeverBlocksAtAnySliderPosition` sweeps every one of those sample sizes to keep it fixed.

### 4. Nobody calibrates the judge, and an uncalibrated judge fails safe-looking.

If your LLM judge is 8 points more lenient than the humans it stands in for, every candidate looks 8 points better than it is. The gate keeps returning green while real quality drifts down underneath it. Nothing in the pipeline flags this, because from the gate's perspective everything is fine.

Judge calibration is a **precondition** here, evaluated before any pass-rate arithmetic. Cohen's κ below the floor, leniency bias outside tolerance, or a judge that could not be reached all produce `.inconclusive` — never `.pass`.

---

## Design decisions, and what was rejected

| Decision | Rejected alternative | Why |
|---|---|---|
| **Wilson score interval** | Wald (`p̂ ± z·√(p̂(1−p̂)/n)`) | Wald's coverage collapses exactly where eval suites live: small `n`, pass rates near 1. At `p̂ = 1.0` it produces a **zero-width** interval — "95% confident the rate is exactly 100%," from 20 samples — and at `p̂ = 0.95` its upper bound exceeds 1. Both pathologies are asserted in `NegativeControlTests`. |
| **Non-inferiority test against `baseline − margin`** | Equality test against `baseline` | An equality test's power grows without bound in `n`. Run a big enough suite and a half-point drift becomes "significant," so the gate blocks every merge. Shifting the null by a declared margin asks the question the business actually has, and its answer stays stable as `n` grows. |
| **Benjamini–Hochberg (FDR)** | Bonferroni (FWER) | Bonferroni on 12 slices tests each at α/12 ≈ 0.004 — so conservative that a real regression confined to one slice will essentially never be caught at realistic sample sizes. FDR bounds the expected *proportion* of blocked slices that are false alarms, which is what an engineer triaging a red gate actually wants to know. |
| **Run-level α split evenly across the two families** | Running both at the full α | Either family firing blocks the merge, so their errors compound. The split costs real power — a halved α widens the interval and raises the per-slice bar — but the alternative is a gate whose advertised 5% false-block rate is nearer 10%. |
| **Anytime-valid confidence sequence** for sequential mode | Reusing Wilson while peeking | If you re-check the gate as samples stream in and stop when it looks decided, fixed-`n` intervals are invalid — optional stopping drives the true error rate toward 1. The sequence splits the error budget as `αₙ = α/(n(n+1))`, which telescopes to exactly `α`. It costs about **2.4×** the width at n=40, and roughly **4×** at the `p̂ = 1` boundary; that width **is** the price of being allowed to peek, made explicit. |
| **Union bound when composing the two arms** | Newcombe alone in sequential mode | Newcombe's square-root-of-sum-of-squares is an empirical calibration derived *for Wilson intervals*. It is not a theorem that transfers to a Hoeffding sequence. So `differenceInterval` takes a separate `perArmConfidence`, and the gate builds each arm at `α/2` so the pair is jointly valid at `α` by a bound that actually holds. |
| **Nested scenario draws** | Re-seeding per sample size | With a shared generator whose position depends on `n`, every slice past the first shifts phase when `n` changes, so consecutive sample sizes draw unrelated datasets and the verdict flickers as it grows. Nesting makes "more samples" mean more samples. |
| **Budget checked only at the straddle** | Checking budget up front | "We ran out of money" is only a reason to stop if more samples would have helped. An exhausted budget must not downgrade an already-decisive `block`. |
| **`EvalBudgetLedger` has no `await` in any method** | Async pricing lookup inside `charge` | An actor guarantees exclusivity only *between* suspension points. An `await` mid-update lets two tasks each read spend at 0.95 of the cap, each suspend, and each commit — ending at 1.9× budget with both callers told they were within it. Keeping the read-modify-write synchronous makes that unrepresentable. |

---

## What's in it

**`SignalGate`** (core, Foundation only — no UI, no networking, never calls a model)

- `QualityGate` — the orchestrator. Preconditions (samples → judge → slice comparability, checked in both directions), then the per-slice FDR family, then the overall non-inferiority decision.
- `GateVerdict` — `.pass` / `.block` / `.inconclusive(reason:additionalSamplesNeeded:)`, with six distinct `InconclusiveReason`s that map to different operational responses.
- `GatePolicy` — margin, confidence, FDR, power, mode, judge thresholds, plus the derived error-budget allocation (`overallAlpha`, `sliceQ`, `perArmConfidence`).
- `ProportionStatistics` — Wilson intervals, anytime-valid confidence sequences, Newcombe difference intervals, margin-aware two-proportion tests, and power-based sample-size planning.
- `MultipleComparisons` — Benjamini–Hochberg with monotonised adjusted p-values, plus `familyWiseErrorRate` so the argument for correcting can be computed rather than argued.
- `JudgeCalibration` / `AgreementMatrix` — Cohen's κ, leniency bias, and a policy that gates on both.
- `EvalBudgetLedger` — an actor tracking spend, wall-clock and call count, with non-finite readings rejected rather than accumulated.
- `SafeMath` — the trapping operations this package touches, wrapped: `Int(Double)`, division by zero, `Int.min / -1`, `+`/`*` overflow, `sqrt` of a negative, `log` of zero.
- `GateScenario` — six reproducible, nested fixtures, seeded by a SplitMix64 with hand-written per-case offsets.

**`SignalGateUI`** — SwiftUI console, entirely behind `#if canImport(SwiftUI)` so the package still builds on Linux.

---

## On the numerics being deliberately unexciting

A merge gate runs unattended, and its inputs are pass rates computed upstream from model output. Those inputs *will* eventually contain a `NaN` from an empty slice, an infinity from a runaway latency measurement, or a value outside `Int`'s range. In Swift, `Int(someDouble)` traps on all three. A trap in a merge gate is not a failed test — it is an outage in everyone's pipeline.

So: no force-unwraps anywhere in `Sources/`, every collection access bounds-checked through `SafeMath.element`, division guarded, `sqrt` clamped against the few-ulp-negative results that catastrophic cancellation produces in variance expressions, and the `Int` range derived from `Int.max` rather than a hardcoded 64-bit literal — because `Int` is 32-bit on watchOS.

Two honest caveats, since the point of this section is precision: the one integer division in the package (`perArm / sliceCount` in `GateScenario`) is a raw `/`, safe because `sliceCount` is `max(1, …)` by construction; and `SplitMix64`'s `&*`/`&+` are unchecked because modular arithmetic *is* the algorithm there, not an overflow being tolerated.

---

## On the tests

**105 tests.** A meaningful share of them implement the *wrong* thing on purpose.

`NegativeControlTests` exists because a suite that only asserts the correct implementation behaves correctly is unfalsifiable — it would pass even if the property being checked were vacuous. So for each claim above, there is a test that feeds in the broken alternative and asserts it **fails**:

- `testWaldDegeneratesWhereWilsonDoesNot` — implements Wald, asserts a zero-width interval at 20/20.
- `testUncorrectedSliceTestingBlocksAFamilyBenjaminiHochbergClears` — asserts the two procedures genuinely disagree.
- `testATwoStateGateCertifiesDataThatSupportsNoConclusion` — implements the naive gate, asserts it passes data `SignalGate` refuses to certify.
- `testRemovingTheJudgeChangesTheVerdictOnIdenticalEvalData` — same eval data, judge removed, asserts the verdict changes.
- `testTheMarginStopsLargeSamplesFlaggingTrivialDrift` — asserts an equality test *does* flag a 1-point drift at n=10,000, and the margin-aware test does not.

Four more that were written specifically to avoid vacuous shapes:

- `testScenarioDrawMatchesCommittedGoldenCounts` compares against counts committed to this repository, **not** against a second call in the same process. Seeding was originally derived from `String.hashValue`, which is salted per process — a "call it twice and assert equal" test passes against that bug, because the salt is constant within one process. Only a committed golden value catches it.
- `testConcurrentChargesAreExactUnderRealParallelism` uses 500 tasks in a `TaskGroup`, not a sequential loop, and asserts the *exact* total. Its companion, `testConcurrentReadsNeverObserveATornState`, additionally asserts that some reader observed a non-zero ledger — otherwise a scheduler that runs every reader first satisfies the invariant without ever exercising a torn window.
- `testTheWobbleScenarioNeverBlocksAtAnySliderPosition` and `testSliceCollapseNeverCertifiesAMergeAtAnySliderPosition` sweep all 499 reachable sample sizes rather than probing one convenient value. Both were added after a review found real failures at sample sizes the original single-point tests never visited.
- `testNoScenarioShowsAWrongVerdictAtTheDemoDefaultSampleSize` pins the demo's opening state, which is the only impression most people will ever form of this project.

---

## Requirements

iOS 17+ / macOS 14+, Swift 6.0+.

## Installation

```swift
.package(url: "https://github.com/rajatslakhina/signal-gate-kit.git", from: "1.1.0")
```

## Demo app

Runnable SwiftUI app consuming this package as a remote dependency:
**[signal-gate-kit-demo-app](https://github.com/rajatslakhina/signal-gate-kit-demo-app)**

Drag the sample-size slider and watch a verdict walk from `inconclusive` to a real decision. It opens on a build hiding a genuine 12-point regression, at a sample size too small to prove it.

## Verification

See the [Actions tab](https://github.com/rajatslakhina/signal-gate-kit/actions) for what actually ran. Two jobs on every push:

- **Linux** (`swift:6.0` container) — clean `.build`, then `swift build -Xswiftc -warnings-as-errors` and `swift test`. The warnings-as-errors flag is what makes "zero warnings" a machine-enforced fact rather than a claim in prose; the clean step is because `swift build` on an up-to-date tree compiles nothing and still prints `Build complete!`.
- **macOS** (`macos-15`, Xcode 16) — same two commands. This is the job that genuinely compiles `SignalGateUI`, since SwiftUI is unavailable on Linux.

Neither job compiles for iOS. That claim is instead carried by the demo app's CI, which runs `xcodebuild -resolvePackageDependencies` (proving this package resolves from GitHub at its released tag) and then builds an iOS app against it for `generic/platform=iOS Simulator`. Both steps have run and passed — see the [demo repo's Actions tab](https://github.com/rajatslakhina/signal-gate-kit-demo-app/actions).

The demo app was **not** launched on a Simulator during the run that produced these repositories — computer-use access is refused on scheduled runs, and the refusal is quoted verbatim in the demo repo's README. No screenshots exist, and "compiles for a Simulator" is a separate and weaker claim than "ran on a Simulator."

This package was also reviewed by an independent adversarial pass that found twenty issues, including two genuine statistical composition errors (§3 above, and the arm-composition problem in the sequential mode). Both are fixed, and both now have tests. The review's other findings — a misstated interval-width ratio, three vacuous assertions, a non-monotone demo interaction — are fixed here too.

## License

MIT — see [LICENSE](LICENSE).
