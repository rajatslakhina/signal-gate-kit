import Foundation

/// How the gate is being consulted.
public enum MonitoringMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// One evaluation at a pre-committed sample size. Uses Wilson intervals,
    /// which are the tightest correct choice *if* you look exactly once.
    case fixedSample
    /// The gate is consulted repeatedly as samples arrive, stopping as soon as
    /// it decides. Uses anytime-valid confidence sequences, which are wider but
    /// remain correct under optional stopping.
    case sequential

    public var displayName: String {
        switch self {
        case .fixedSample: return "Fixed sample"
        case .sequential: return "Sequential"
        }
    }
}

/// Everything the gate needs to be configurable about.
public struct GatePolicy: Sendable, Hashable, Codable {
    /// How much of a pass-rate drop is acceptable. The gate is a
    /// *non-inferiority* test against `baseline − margin`, not an equality
    /// test against `baseline`.
    ///
    /// Testing for equality is the wrong question and produces a gate that
    /// blocks on any downward wobble. The right question is the product one:
    /// "is this meaningfully worse?" — and answering it requires someone to
    /// write down what "meaningfully" is, in advance, as a number.
    public let nonInferiorityMargin: Double
    /// Confidence level for the interval on the difference.
    public let confidence: Double
    /// Budget allocated to the per-slice family. The FDR level actually
    /// applied is `sliceQ`, which is half of this — see the error-budget
    /// allocation section below for why.
    public let sliceFalseDiscoveryRate: Double
    /// Effect size the sample-size advice is computed against.
    public let minimumDetectableEffect: Double
    /// Power the sample-size advice targets.
    public let power: Double
    public let mode: MonitoringMode
    public let judgePolicy: JudgeCalibrationPolicy

    public init(
        nonInferiorityMargin: Double = 0.03,
        confidence: Double = 0.95,
        sliceFalseDiscoveryRate: Double = 0.05,
        minimumDetectableEffect: Double = 0.05,
        power: Double = 0.80,
        mode: MonitoringMode = .fixedSample,
        judgePolicy: JudgeCalibrationPolicy = .standard
    ) {
        // Clamped rather than failable: a policy is often decoded from CI
        // config, and a malformed value should degrade to a defensible default
        // instead of taking the whole gate offline. Each clamp is to the
        // conservative end.
        self.nonInferiorityMargin = nonInferiorityMargin.isFinite
            ? Swift.min(1, Swift.max(0, nonInferiorityMargin)) : 0.03
        self.confidence = (confidence.isFinite && confidence > 0 && confidence < 1) ? confidence : 0.95
        self.sliceFalseDiscoveryRate = (sliceFalseDiscoveryRate.isFinite
            && sliceFalseDiscoveryRate > 0 && sliceFalseDiscoveryRate <= 1) ? sliceFalseDiscoveryRate : 0.05
        self.minimumDetectableEffect = (minimumDetectableEffect.isFinite && minimumDetectableEffect > 0)
            ? Swift.min(1, minimumDetectableEffect) : 0.05
        self.power = (power.isFinite && power > 0 && power < 1) ? power : 0.80
        self.mode = mode
        self.judgePolicy = judgePolicy
    }

    public static let standard = GatePolicy()

    // MARK: - Error budget allocation

    /// The run-level error budget, `1 − confidence`.
    public var runLevelAlpha: Double { 1 - confidence }

    /// The gate blocks if **either** the per-slice family fires **or** the
    /// overall non-inferiority test fires. Those are two hypothesis families,
    /// and running each at its full configured level means the probability that
    /// at least one produces a false block is close to their union — the exact
    /// error-inflation this package exists to eliminate, reproduced one level
    /// up.
    ///
    /// So each family is run at **half** its configured level.
    ///
    /// Note precisely what that does and does not buy. `confidence` and
    /// `sliceFalseDiscoveryRate` are independent knobs, so the two halves sum
    /// to the run-level α only when they are configured equal — which the
    /// default policy is, but a custom one need not be. The honest guarantee is
    /// therefore `unionFalseBlockBound`, computed below, not "α". Stating it as
    /// α would be the same kind of unbacked claim the package exists to catch.
    ///
    /// This is not free: halving each level widens the overall interval and
    /// raises the per-slice bar, so the gate needs more samples to reach any
    /// verdict. That is the correct trade — the alternative is a gate whose
    /// advertised false-block rate is roughly half the real one.
    public var overallAlpha: Double { runLevelAlpha / 2 }

    /// Union bound on the probability of a false block from either family.
    ///
    /// This is the number to quote when someone asks how often the gate blocks
    /// a clean build. For the default policy it is exactly `runLevelAlpha`; for
    /// a policy whose two knobs disagree it is larger, and the gate says so
    /// rather than quoting the more flattering figure.
    public var unionFalseBlockBound: Double { Swift.min(1, overallAlpha + sliceQ) }

    /// Confidence level for the overall difference interval, after the split.
    public var overallConfidence: Double { 1 - overallAlpha }

    /// FDR level actually applied to the per-slice family, after the split.
    ///
    /// Deliberately *not* `sliceFalseDiscoveryRate`: that property is the
    /// budget the caller allocates to slice testing, and half of it is spent
    /// here so the other half can cover the overall test.
    public var sliceQ: Double { sliceFalseDiscoveryRate / 2 }

    /// Confidence each *arm* is built at when the composition is a union
    /// bound (sequential mode). Exposed for reporting; the composition itself
    /// derives it, so callers never have to keep the two in sync.
    public var perArmConfidence: Double { 1 - overallAlpha / 2 }
}

/// The full, reviewable output of one gate evaluation.
public struct GateReport: Sendable, Hashable, Codable {
    public let verdict: GateVerdict
    /// Interval on `candidate − baseline` overall pass rate.
    public let differenceInterval: ProportionInterval?
    public let baselineOverall: SliceCounts
    public let candidateOverall: SliceCounts
    public let sliceResults: [SliceTestResult]
    /// Slices dropped from the family because their p-value was undefined.
    public let discardedSlices: [String]
    public let judgeStatus: JudgeStatus
    public let budget: BudgetState?
    public let policy: GatePolicy
    /// Human-readable lines explaining the verdict, for the CI log and the PR
    /// comment. A gate that blocks without saying why gets disabled.
    public let rationale: [String]

    /// The uncorrected view, retained so a report can show what the naive gate
    /// would have concluded on identical data.
    public let uncorrectedRegressionCount: Int
    /// `1 − (1 − α)^k` for this run's slice count — the false-alarm rate the
    /// uncorrected gate would be running at.
    public let uncorrectedFamilyWiseErrorRate: Double?
}

/// The decision layer.
///
/// Takes graded eval outcomes plus judge and budget context, and returns a
/// three-state verdict with the statistics to defend it.
public enum QualityGate {

    public static func evaluate(
        baseline: [EvalSample],
        candidate: [EvalSample],
        judgeMatrix: AgreementMatrix?,
        budget: BudgetState? = nil,
        policy: GatePolicy = .standard
    ) -> GateReport {
        let baselineTally = SliceCounts.tally(baseline)
        let candidateTally = SliceCounts.tally(candidate)
        return evaluate(
            baselineSlices: baselineTally.bySlice,
            baselineOverall: baselineTally.overall,
            candidateSlices: candidateTally.bySlice,
            candidateOverall: candidateTally.overall,
            judgeMatrix: judgeMatrix,
            budget: budget,
            policy: policy
        )
    }

    // swiftlint:disable:next function_body_length
    public static func evaluate(
        baselineSlices: [SliceCounts],
        baselineOverall: SliceCounts,
        candidateSlices: [SliceCounts],
        candidateOverall: SliceCounts,
        judgeMatrix: AgreementMatrix?,
        budget: BudgetState? = nil,
        policy: GatePolicy = .standard
    ) -> GateReport {
        var rationale: [String] = []
        let judgeStatus = JudgeCalibration.evaluate(matrix: judgeMatrix, policy: policy.judgePolicy)

        func report(
            _ verdict: GateVerdict,
            differenceInterval: ProportionInterval? = nil,
            sliceResults: [SliceTestResult] = [],
            discarded: [String] = [],
            uncorrectedCount: Int = 0,
            familyWiseErrorRate: Double? = nil
        ) -> GateReport {
            GateReport(
                verdict: verdict,
                differenceInterval: differenceInterval,
                baselineOverall: baselineOverall,
                candidateOverall: candidateOverall,
                sliceResults: sliceResults,
                discardedSlices: discarded,
                judgeStatus: judgeStatus,
                budget: budget,
                policy: policy,
                rationale: rationale,
                uncorrectedRegressionCount: uncorrectedCount,
                uncorrectedFamilyWiseErrorRate: familyWiseErrorRate
            )
        }

        // 1. No data at all. Ordered first so the more specific diagnostics
        //    below never fire on an empty run and mislabel the problem.
        guard baselineOverall.total > 0, candidateOverall.total > 0 else {
            rationale.append("No usable samples in one or both arms.")
            return report(.inconclusive(reason: .noSamples, additionalSamplesNeeded: nil))
        }

        // 2. The judge is a *precondition*, checked before any pass-rate
        //    arithmetic. An uncalibrated or missing judge does not make the
        //    numbers noisy — it makes them meaningless, and computing a tidy
        //    confidence interval over meaningless inputs is how a broken eval
        //    pipeline produces a confident green.
        switch judgeStatus {
        case .unavailable:
            rationale.append("Judge unavailable — gate cannot certify this run. Failing to inconclusive, not to pass.")
            return report(.inconclusive(reason: .judgeUnavailable, additionalSamplesNeeded: nil))
        case .uncalibrated(let reason):
            rationale.append("Judge failed calibration: \(reason)")
            return report(.inconclusive(reason: .judgeUncalibrated, additionalSamplesNeeded: nil))
        case .calibrated(let kappa, let bias):
            rationale.append(String(format: "Judge calibrated: kappa %.3f, leniency bias %+.3f.", kappa, bias))
        }

        // 3. Slice comparability. Comparing a candidate run that is missing a
        //    slice against a baseline that has it is not a comparison; the
        //    missing slice would silently be scored as "no regression."
        let baselineSliceIDs = Set(baselineSlices.map(\.sliceID))
        let candidateSliceIDs = Set(candidateSlices.map(\.sliceID))
        let missingFromCandidate = baselineSliceIDs.subtracting(candidateSliceIDs)
        let missingFromBaseline = candidateSliceIDs.subtracting(baselineSliceIDs)
        // Checked in *both* directions, as `InconclusiveReason.incomparableSlices`
        // says. A candidate-only slice has no baseline to be compared against,
        // so it would silently drop out of the family and be scored as "no
        // regression" — a new locale shipping broken would read as clean.
        if !missingFromCandidate.isEmpty || !missingFromBaseline.isEmpty {
            if !missingFromCandidate.isEmpty {
                rationale.append(
                    "Candidate run is missing \(missingFromCandidate.count) baseline slice(s): "
                        + missingFromCandidate.sorted().joined(separator: ", ")
                )
            }
            if !missingFromBaseline.isEmpty {
                rationale.append(
                    "Candidate run has \(missingFromBaseline.count) slice(s) with no baseline to compare against: "
                        + missingFromBaseline.sorted().joined(separator: ", ")
                )
            }
            return report(.inconclusive(reason: .incomparableSlices, additionalSamplesNeeded: nil))
        }

        // 4. Per-slice family, FDR-corrected.
        let candidateBySliceID = Dictionary(
            candidateSlices.map { ($0.sliceID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var sliceTests: [SliceTest] = []
        // Slices whose test is undefined. These must be surfaced, not skipped.
        //
        // `regressionPValue` returns nil when the standard error is exactly
        // zero — which happens when BOTH arms sit at a boundary. The benign
        // case is 200/200 -> 200/200. The malignant one is **200/200 -> 0/200**:
        // a slice that has completely collapsed. Dropping it from the family
        // meant it was never tested, never reported, and did not affect the
        // verdict, so a build where an entire locale went to zero could return
        // `.pass` as long as the aggregate stayed inside the margin. That is
        // the precise failure this package exists to prevent, reintroduced by a
        // `continue`.
        var untestableSlices: [String] = []
        for baselineSlice in baselineSlices {
            guard let candidateSlice = candidateBySliceID[baselineSlice.sliceID] else { continue }
            // Same margin as the overall test. A slice family tested at
            // margin 0 while the aggregate is tested for non-inferiority is
            // incoherent: the gate would block on a slice drift it explicitly
            // declared acceptable in aggregate.
            guard let pValue = ProportionStatistics.regressionPValue(
                baseline: baselineSlice,
                candidate: candidateSlice,
                nonInferiorityMargin: policy.nonInferiorityMargin
            ) else {
                untestableSlices.append(baselineSlice.sliceID)
                continue
            }
            sliceTests.append(
                SliceTest(
                    sliceID: baselineSlice.sliceID,
                    pValue: pValue,
                    baselineRate: baselineSlice.passRate,
                    candidateRate: candidateSlice.passRate
                )
            )
        }

        let corrected = MultipleComparisons.benjaminiHochberg(
            tests: sliceTests, falseDiscoveryRate: policy.sliceQ
        )
        let discarded = (corrected.discarded + untestableSlices).sorted()
        let sliceResults = corrected.results
        let regressedSlices = sliceResults.filter(\.isRegression)
        let uncorrectedCount = MultipleComparisons
            .uncorrected(tests: sliceTests, alpha: policy.sliceFalseDiscoveryRate)
            .filter(\.isRegression).count
        let familyWiseErrorRate = MultipleComparisons.familyWiseErrorRate(
            testCount: sliceTests.count, alpha: policy.sliceFalseDiscoveryRate
        )

        if let familyWiseErrorRate, sliceTests.count > 1 {
            rationale.append(
                String(
                    format: "%d slices tested. Uncorrected, this family would false-alarm %.0f%% of the time; "
                        + "Benjamini-Hochberg at q=%.3f is applied instead (half the %.2f slice budget, the other "
                        + "half reserved for the overall test). Union bound on a false block from either "
                        + "family: %.3f.",
                    sliceTests.count, familyWiseErrorRate * 100, policy.sliceQ,
                    policy.sliceFalseDiscoveryRate, policy.unionFalseBlockBound
                )
            )
        }

        // 5. Overall difference interval, in the mode the caller is operating in.
        let componentInterval: (Int, Int, Double) -> ProportionInterval? = { passed, total, confidence in
            switch policy.mode {
            case .fixedSample:
                return ProportionStatistics.wilsonInterval(passed: passed, total: total, confidence: confidence)
            case .sequential:
                return ProportionStatistics.confidenceSequence(passed: passed, total: total, confidence: confidence)
            }
        }
        // Newcombe is only valid for Wilson components, so sequential mode —
        // whose components are Hoeffding sequences — composes by union bound.
        let difference = ProportionStatistics.differenceInterval(
            baseline: baselineOverall,
            candidate: candidateOverall,
            confidence: policy.overallConfidence,
            composition: policy.mode == .sequential ? .unionBound : .newcombe,
            componentInterval: componentInterval
        )

        // 5b. An untestable slice is a refusal to certify, not a pass.
        //
        // Checked before the aggregate decision, for the same reason the judge
        // is: a slice whose test is undefined is not weak evidence, it is no
        // evidence, and no amount of healthy aggregate makes up for not having
        // looked.
        if !untestableSlices.isEmpty {
            rationale.append(
                "Cannot certify: \(untestableSlices.count) slice(s) have an undefined test because both arms "
                    + "sit at a boundary — " + untestableSlices.sorted().joined(separator: ", ")
                    + ". A fully collapsed slice lands here, so this is never treated as 'no regression'."
            )
            return report(
                .inconclusive(reason: .insufficientEvidence, additionalSamplesNeeded: nil),
                differenceInterval: difference,
                sliceResults: sliceResults,
                discarded: discarded,
                uncorrectedCount: uncorrectedCount,
                familyWiseErrorRate: familyWiseErrorRate
            )
        }

        // 6. A slice regression blocks regardless of the overall number. This
        //    is the whole reason slices exist: an aggregate can hold steady
        //    while one locale, tier or device class falls off a cliff, and the
        //    aggregate is what a naive gate watches.
        if !regressedSlices.isEmpty {
            let names = regressedSlices.map(\.sliceID).sorted().joined(separator: ", ")
            rationale.append("Blocking: \(regressedSlices.count) slice(s) regressed after FDR correction — \(names).")
            return report(
                .block,
                differenceInterval: difference,
                sliceResults: sliceResults,
                discarded: discarded,
                uncorrectedCount: uncorrectedCount,
                familyWiseErrorRate: familyWiseErrorRate
            )
        }

        guard let difference else {
            rationale.append("Difference interval undefined for these counts — cannot certify.")
            return report(
                .inconclusive(reason: .insufficientEvidence, additionalSamplesNeeded: nil),
                sliceResults: sliceResults,
                discarded: discarded,
                uncorrectedCount: uncorrectedCount,
                familyWiseErrorRate: familyWiseErrorRate
            )
        }

        let margin = policy.nonInferiorityMargin
        rationale.append(
            String(
                format: "Overall difference %+.3f, %.1f%% %@ interval [%+.3f, %+.3f]; non-inferiority margin -%.3f.",
                difference.pointEstimate, policy.overallConfidence * 100,
                policy.mode == .sequential ? "anytime-valid" : "Wilson-Newcombe",
                difference.lowerBound, difference.upperBound, margin
            )
        )

        // 7. Non-inferiority decision on the difference interval.
        if difference.lowerBound > -margin {
            rationale.append("Pass: entire interval lies above the -\(String(format: "%.3f", margin)) margin.")
            return report(
                .pass,
                differenceInterval: difference,
                sliceResults: sliceResults,
                discarded: discarded,
                uncorrectedCount: uncorrectedCount,
                familyWiseErrorRate: familyWiseErrorRate
            )
        }

        if difference.upperBound < -margin {
            rationale.append("Block: entire interval lies below the -\(String(format: "%.3f", margin)) margin.")
            return report(
                .block,
                differenceInterval: difference,
                sliceResults: sliceResults,
                discarded: discarded,
                uncorrectedCount: uncorrectedCount,
                familyWiseErrorRate: familyWiseErrorRate
            )
        }

        // 8. The interval straddles the margin. This is the case a two-state
        //    gate has to guess at, and the case this package exists to name.
        //
        //    Budget is checked *here* rather than up front, because "we ran out
        //    of money" is only a reason to stop if more samples would have
        //    helped. If the gate already reached pass or block, an exhausted
        //    budget is irrelevant and reporting it would be noise.
        if let budget, budget.isExhausted {
            rationale.append(
                "Evidence is insufficient and the budget is exhausted"
                    + (budget.exhaustedBy.map { " (\($0) ceiling)" } ?? "")
                    + ". Reporting inconclusive rather than truncating the sample and certifying it."
            )
            return report(
                .inconclusive(reason: .budgetExhausted, additionalSamplesNeeded: nil),
                differenceInterval: difference,
                sliceResults: sliceResults,
                discarded: discarded,
                uncorrectedCount: uncorrectedCount,
                familyWiseErrorRate: familyWiseErrorRate
            )
        }

        let perArm = Swift.min(baselineOverall.total, candidateOverall.total)
        let mdeRequirement = ProportionStatistics.additionalSamplesNeeded(
            currentPerArm: perArm,
            baselineRate: baselineOverall.passRate ?? 0,
            minimumDetectableEffect: policy.minimumDetectableEffect,
            significance: policy.overallAlpha,
            power: policy.power
        )

        // If the run already has enough samples for the configured minimum
        // detectable effect and the gate *still* cannot decide, more samples
        // are not the binding constraint — the true effect is sitting near the
        // margin, and no sample size makes a boundary case unambiguous
        // quickly. Reporting "0 more samples needed" alongside an inconclusive
        // verdict would be actively misleading, so the estimate is withheld and
        // the rationale names the real decision: move the margin, or accept a
        // smaller detectable effect and pay for it in samples.
        let additional: Int? = (mdeRequirement ?? 0) > 0 ? mdeRequirement : nil

        if let additional {
            rationale.append(
                "Inconclusive: the interval straddles the margin, so the data supports neither pass nor block. "
                    + "Detecting a \(String(format: "%.0f", policy.minimumDetectableEffect * 100))-point drop "
                    + "at \(String(format: "%.0f", policy.power * 100))% power needs roughly \(additional) more "
                    + "samples per arm."
            )
        } else {
            rationale.append(
                "Inconclusive: the interval straddles the margin. This run already carries enough samples for a "
                    + "\(String(format: "%.0f", policy.minimumDetectableEffect * 100))-point detectable effect, so "
                    + "sample size is not the binding constraint — the observed effect sits near the "
                    + "\(String(format: "%.3f", margin)) margin. This is a policy decision, not a data collection one."
            )
        }
        return report(
            .inconclusive(reason: .insufficientEvidence, additionalSamplesNeeded: additional),
            differenceInterval: difference,
            sliceResults: sliceResults,
            discarded: discarded,
            uncorrectedCount: uncorrectedCount,
            familyWiseErrorRate: familyWiseErrorRate
        )
    }
}
