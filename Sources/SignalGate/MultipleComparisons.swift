import Foundation

/// One hypothesis in a multiple-comparison family: "did slice X regress?"
public struct SliceTest: Sendable, Hashable, Codable {
    public let sliceID: String
    public let pValue: Double
    public let baselineRate: Double?
    public let candidateRate: Double?

    public init(sliceID: String, pValue: Double, baselineRate: Double? = nil, candidateRate: Double? = nil) {
        self.sliceID = sliceID
        self.pValue = pValue
        self.baselineRate = baselineRate
        self.candidateRate = candidateRate
    }
}

/// Result of correcting a family of slice tests.
public struct SliceTestResult: Sendable, Hashable, Codable {
    public let sliceID: String
    public let rawPValue: Double
    /// Benjamini–Hochberg adjusted p-value (monotonised).
    public let adjustedPValue: Double
    /// Whether this slice is declared a regression after correction.
    public let isRegression: Bool
    public let baselineRate: Double?
    public let candidateRate: Double?
}

/// Controls for testing many slices at once.
///
/// The problem this solves is the single most common statistical bug in
/// per-slice quality gates, and it is invisible until you count it: testing
/// `k` slices independently at α each gives a family-wise false-alarm rate of
/// `1 − (1 − α)^k`. At the very ordinary configuration of 12 slices and
/// α = 0.05, that is **46%** — so roughly one in two totally clean runs blocks
/// a merge on a slice that did not actually regress. Teams do not read that as
/// "our gate is miscalibrated." They read it as "the gate is flaky," and then
/// they turn it off.
public enum MultipleComparisons {

    /// Probability of at least one false positive when `count` independent
    /// tests are each run at `alpha`, with no correction.
    ///
    /// Exposed publicly because it is the number that wins the argument for
    /// correcting in the first place.
    public static func familyWiseErrorRate(testCount: Int, alpha: Double) -> Double? {
        guard testCount >= 0 else { return nil }
        guard alpha.isFinite, alpha >= 0, alpha <= 1 else { return nil }
        guard testCount > 0 else { return 0 }
        // pow with a non-negative base and an integral exponent; the base is in
        // [0, 1] so the result cannot overflow.
        let survival = pow(1 - alpha, Double(testCount))
        guard survival.isFinite else { return nil }
        return SafeMath.clampProbability(1 - survival)
    }

    /// Benjamini–Hochberg step-up procedure controlling the false discovery
    /// rate at `q`.
    ///
    /// FDR rather than family-wise error (Bonferroni) is the deliberate choice.
    /// Bonferroni controls the probability of *any* false block, which on 12
    /// slices means testing each at α/12 ≈ 0.004 — so conservative that a real
    /// regression confined to one slice will essentially never be detected at
    /// realistic sample sizes. FDR instead bounds the expected *proportion* of
    /// blocked slices that are false alarms, which is the quantity an engineer
    /// triaging a red gate actually cares about: "if this thing flags three
    /// slices, how many am I wasting my morning on?"
    ///
    /// Tests with a non-finite or out-of-range p-value are dropped from the
    /// family rather than coerced, and reported back through `discarded` — a
    /// silently coerced p-value would change `m` and shift every threshold.
    public static func benjaminiHochberg(
        tests: [SliceTest],
        falseDiscoveryRate q: Double = 0.05
    ) -> (results: [SliceTestResult], discarded: [String]) {
        guard q.isFinite, q > 0, q <= 1 else {
            return ([], tests.map(\.sliceID))
        }

        var usable: [SliceTest] = []
        var discarded: [String] = []
        for test in tests {
            if test.pValue.isFinite, test.pValue >= 0, test.pValue <= 1 {
                usable.append(test)
            } else {
                discarded.append(test.sliceID)
            }
        }

        let m = usable.count
        guard m > 0 else { return ([], discarded) }

        // Sort ascending by p-value; ties broken by sliceID so the output is
        // deterministic run to run rather than dependent on input order.
        let sorted = usable.sorted {
            $0.pValue == $1.pValue ? $0.sliceID < $1.sliceID : $0.pValue < $1.pValue
        }
        let mDouble = Double(m)

        // Step-up: largest rank k with p(k) <= (k/m)·q. Ranks are 1-based.
        var largestRejectedRank = 0
        for rank in stride(from: m, through: 1, by: -1) {
            guard let test = SafeMath.element(sorted, at: rank - 1) else { continue }
            guard let threshold = SafeMath.divide(Double(rank) * q, by: mDouble) else { continue }
            if test.pValue <= threshold {
                largestRejectedRank = rank
                break
            }
        }

        // Adjusted p-values: (m/rank)·p(rank), then enforced monotone
        // non-decreasing by sweeping from the largest rank down. Without the
        // sweep an adjusted value can exceed the one above it, which reads as
        // nonsense in a report.
        var adjusted = [Double](repeating: 1, count: m)
        var runningMinimum = Double.infinity
        for rank in stride(from: m, through: 1, by: -1) {
            guard let test = SafeMath.element(sorted, at: rank - 1) else { continue }
            let scaled = SafeMath.divide(mDouble * test.pValue, by: Double(rank)) ?? 1
            runningMinimum = Swift.min(runningMinimum, scaled)
            let value = SafeMath.clampProbability(runningMinimum) ?? 1
            if rank - 1 >= 0, rank - 1 < adjusted.count {
                adjusted[rank - 1] = value
            }
        }

        var results: [SliceTestResult] = []
        results.reserveCapacity(m)
        for offset in 0..<m {
            guard let test = SafeMath.element(sorted, at: offset) else { continue }
            let adjustedValue = SafeMath.element(adjusted, at: offset) ?? 1
            results.append(
                SliceTestResult(
                    sliceID: test.sliceID,
                    rawPValue: test.pValue,
                    adjustedPValue: adjustedValue,
                    // Rank is 1-based; everything up to the largest rejected
                    // rank is rejected, which is what makes this a *step-up*
                    // procedure rather than per-test thresholding.
                    isRegression: (offset + 1) <= largestRejectedRank,
                    baselineRate: test.baselineRate,
                    candidateRate: test.candidateRate
                )
            )
        }
        return (results, discarded)
    }

    /// The uncorrected comparison, provided so the difference can be measured
    /// rather than asserted. Used by the package's own negative-control tests
    /// and by the demo to show the two side by side.
    public static func uncorrected(tests: [SliceTest], alpha: Double = 0.05) -> [SliceTestResult] {
        tests.compactMap { test in
            guard test.pValue.isFinite, test.pValue >= 0, test.pValue <= 1 else { return nil }
            return SliceTestResult(
                sliceID: test.sliceID,
                rawPValue: test.pValue,
                adjustedPValue: test.pValue,
                isRegression: test.pValue <= alpha,
                baselineRate: test.baselineRate,
                candidateRate: test.candidateRate
            )
        }
    }
}
