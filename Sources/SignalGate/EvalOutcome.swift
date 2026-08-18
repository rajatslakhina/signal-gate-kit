import Foundation

/// One graded eval sample.
///
/// Deliberately *post-grading*: this package never calls a model. It consumes
/// outcomes an upstream harness (Apple's `Evaluations` framework, an in-house
/// runner, anything) already produced. That boundary is what makes the whole
/// decision layer hermetic and unit-testable — the statistics are exercised
/// against fixtures, not against a live judge.
public struct EvalSample: Sendable, Hashable, Codable {
    /// Stable identity of the eval case, so the same case can be tracked across runs.
    public let caseID: String
    /// The slice this case belongs to (locale, user tier, prompt template, device class…).
    public let sliceID: String
    /// Whether the case met its bar. Scoring evaluators are thresholded upstream.
    public let passed: Bool
    /// Optional continuous score, retained for reporting. Not used by the gate:
    /// gating on a mean invites a single catastrophic outlier to be averaged away.
    public let score: Double?

    public init(caseID: String, sliceID: String, passed: Bool, score: Double? = nil) {
        self.caseID = caseID
        self.sliceID = sliceID
        self.passed = passed
        self.score = score
    }
}

/// Pass/total counts for one slice. Constructed only through the initializer,
/// which enforces `0 <= passed <= total` so no downstream code has to re-check.
public struct SliceCounts: Sendable, Hashable, Codable {
    public let sliceID: String
    public let passed: Int
    public let total: Int

    /// Returns `nil` for negative counts or `passed > total` — a caller that
    /// managed to produce those has a bug upstream, and silently repairing it
    /// would hide the bug behind a plausible-looking pass rate.
    public init?(sliceID: String, passed: Int, total: Int) {
        guard total >= 0, passed >= 0, passed <= total else { return nil }
        self.sliceID = sliceID
        self.passed = passed
        self.total = total
    }

    /// `nil` when `total == 0`. An empty slice has no pass rate, and returning
    /// 0.0 would make an unrun slice indistinguishable from a totally broken one.
    public var passRate: Double? {
        SafeMath.divide(Double(passed), by: Double(total))
    }

    /// Non-failable initializer used only where the caller has already
    /// established the invariant structurally rather than by checking it.
    /// Private, so the public surface remains impossible to misuse.
    private init(validated sliceID: String, passed: Int, total: Int) {
        self.sliceID = sliceID
        self.passed = passed
        self.total = total
    }

    /// Aggregates samples into per-slice counts, plus the whole-suite total.
    public static func tally(_ samples: [EvalSample]) -> (bySlice: [SliceCounts], overall: SliceCounts) {
        var passedBySlice: [String: Int] = [:]
        var totalBySlice: [String: Int] = [:]
        for sample in samples {
            totalBySlice[sample.sliceID, default: 0] = SafeMath.add(totalBySlice[sample.sliceID] ?? 0, 1)
            if sample.passed {
                passedBySlice[sample.sliceID, default: 0] = SafeMath.add(passedBySlice[sample.sliceID] ?? 0, 1)
            }
        }
        // Sorted so a report diff between two runs is stable rather than
        // reordering with Dictionary's per-process hash seed.
        let slices: [SliceCounts] = totalBySlice.keys.sorted().compactMap { sliceID in
            SliceCounts(sliceID: sliceID, passed: passedBySlice[sliceID] ?? 0, total: totalBySlice[sliceID] ?? 0)
        }
        // `overallPassed` counts a subset of `samples`, so
        // `0 <= overallPassed <= samples.count` holds by construction and the
        // non-failable initializer is justified structurally, not by assertion.
        let overallPassed = samples.reduce(0) { $0 + ($1.passed ? 1 : 0) }
        let overall = SliceCounts(validated: "__overall__", passed: overallPassed, total: samples.count)
        return (slices, overall)
    }
}

/// Why a gate could not reach a verdict.
///
/// Every one of these is a reason to *stop*, never a reason to wave a merge
/// through. They are enumerated separately because the operational response
/// differs: more samples is a budget decision, an uncalibrated judge is an
/// eval-infra bug, and an unavailable judge is an incident.
public enum InconclusiveReason: String, Sendable, Hashable, Codable {
    /// The observed difference is inside sampling noise at the configured
    /// confidence. Collect more samples or accept a larger detectable effect.
    case insufficientEvidence
    /// The judge model's agreement with the human golden set is below the
    /// configured floor, so its verdicts are not trustworthy inputs.
    case judgeUncalibrated
    /// The judge could not be reached. Fails to inconclusive, never to pass.
    case judgeUnavailable
    /// The inference budget ran out before the test could decide.
    case budgetExhausted
    /// The run produced no usable samples at all.
    case noSamples
    /// Baseline and candidate disagree on which slices exist, so a
    /// slice-by-slice comparison would be comparing different populations.
    case incomparableSlices
}

/// The gate's verdict. Three states, and that is the whole point of the package.
///
/// A two-state gate on probabilistic data is not a simplification, it is a bug:
/// when the evidence is genuinely ambiguous the gate must pick `pass` or `block`
/// anyway, and every team configures it to pick `pass`. The ambiguity does not
/// disappear — it silently becomes a merge.
public enum GateVerdict: Sendable, Hashable, Codable {
    /// Evidence supports "not meaningfully worse than baseline."
    case pass
    /// Evidence supports a real regression at the configured confidence.
    case block
    /// The data cannot support either conclusion.
    /// `additionalSamplesNeeded` is a planning estimate, not a promise — it
    /// assumes the observed effect size is the true one.
    case inconclusive(reason: InconclusiveReason, additionalSamplesNeeded: Int?)

    public var isPass: Bool { if case .pass = self { return true }; return false }
    public var isBlock: Bool { if case .block = self { return true }; return false }
    public var isInconclusive: Bool { if case .inconclusive = self { return true }; return false }

    /// Whether CI should let the merge proceed. Only an affirmative `pass` does.
    public var allowsMerge: Bool { isPass }
}
