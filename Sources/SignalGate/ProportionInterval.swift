import Foundation

/// A confidence interval on a pass rate.
public struct ProportionInterval: Sendable, Hashable, Codable {
    public let pointEstimate: Double
    public let lowerBound: Double
    public let upperBound: Double
    /// Coverage the interval was built for, e.g. 0.95.
    public let confidence: Double
    /// Number of observations the interval is based on.
    public let sampleCount: Int

    public var width: Double { upperBound - lowerBound }

    public func contains(_ value: Double) -> Bool {
        value >= lowerBound && value <= upperBound
    }

    init(pointEstimate: Double, lowerBound: Double, upperBound: Double, confidence: Double, sampleCount: Int) {
        self.pointEstimate = pointEstimate
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.confidence = confidence
        self.sampleCount = sampleCount
    }
}

/// Normal-distribution helpers, implemented here rather than pulled from a
/// dependency so the package stays Foundation-only and the numerics are
/// auditable in review.
public enum NormalDistribution {

    /// Standard normal CDF.
    public static func cdf(_ z: Double) -> Double {
        guard z.isFinite else { return z.isNaN ? .nan : (z > 0 ? 1 : 0) }
        return 0.5 * erfc(-z / 2.0.squareRoot())
    }

    /// Standard normal quantile (inverse CDF), via Acklam's rational
    /// approximation — relative error below ~1.15e-9 across the open interval.
    ///
    /// Returns `nil` outside `(0, 1)` rather than `±infinity`, because an
    /// infinite critical value would silently produce an interval covering
    /// `[0, 1]` and a gate that can never block.
    public static func quantile(_ p: Double) -> Double? {
        guard p.isFinite, p > 0, p < 1 else { return nil }

        let a: [Double] = [-3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
                           1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00]
        let b: [Double] = [-5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
                           6.680131188771972e+01, -1.328068155288572e+01]
        let c: [Double] = [-7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
                           -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00]
        let d: [Double] = [7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
                           3.754408661907416e+00]

        // Every coefficient read is bounds-checked; the arrays are literals of
        // known length, but the accessor keeps that a property of the code
        // rather than of a comment.
        func coefficient(_ table: [Double], _ index: Int) -> Double {
            SafeMath.element(table, at: index) ?? 0
        }

        let pLow = 0.02425
        let pHigh = 1 - pLow
        var x: Double

        if p < pLow {
            let q = (-2 * SafeMath.logClampingNonPositive(p)).squareRoot()
            let numerator = ((((coefficient(c, 0) * q + coefficient(c, 1)) * q + coefficient(c, 2)) * q
                              + coefficient(c, 3)) * q + coefficient(c, 4)) * q + coefficient(c, 5)
            let denominator = (((coefficient(d, 0) * q + coefficient(d, 1)) * q + coefficient(d, 2)) * q
                               + coefficient(d, 3)) * q + 1
            guard let value = SafeMath.divide(numerator, by: denominator) else { return nil }
            x = value
        } else if p <= pHigh {
            let q = p - 0.5
            let r = q * q
            let numerator = (((((coefficient(a, 0) * r + coefficient(a, 1)) * r + coefficient(a, 2)) * r
                               + coefficient(a, 3)) * r + coefficient(a, 4)) * r + coefficient(a, 5)) * q
            let denominator = (((((coefficient(b, 0) * r + coefficient(b, 1)) * r + coefficient(b, 2)) * r
                                 + coefficient(b, 3)) * r + coefficient(b, 4)) * r + 1)
            guard let value = SafeMath.divide(numerator, by: denominator) else { return nil }
            x = value
        } else {
            let q = (-2 * SafeMath.logClampingNonPositive(1 - p)).squareRoot()
            let numerator = ((((coefficient(c, 0) * q + coefficient(c, 1)) * q + coefficient(c, 2)) * q
                              + coefficient(c, 3)) * q + coefficient(c, 4)) * q + coefficient(c, 5)
            let denominator = (((coefficient(d, 0) * q + coefficient(d, 1)) * q + coefficient(d, 2)) * q
                               + coefficient(d, 3)) * q + 1
            guard let value = SafeMath.divide(numerator, by: denominator) else { return nil }
            x = -value
        }

        return x.isFinite ? x : nil
    }

    /// Two-sided critical value for a given confidence level.
    public static func twoSidedCriticalValue(confidence: Double) -> Double? {
        guard confidence.isFinite, confidence > 0, confidence < 1 else { return nil }
        return quantile(1 - (1 - confidence) / 2)
    }
}

public enum ProportionStatistics {

    // MARK: - Wilson score interval

    /// Wilson score interval for a binomial proportion.
    ///
    /// Chosen over the textbook Wald interval (`p̂ ± z·√(p̂(1−p̂)/n)`) deliberately.
    /// Wald's actual coverage collapses exactly where an eval suite lives: small
    /// `n` and pass rates near 1. At `p̂ = 1.0` Wald produces a *zero-width*
    /// interval — the claim "we are 95% confident the pass rate is exactly
    /// 100%", from 20 samples. Wilson stays bounded inside `[0, 1]` and keeps
    /// roughly nominal coverage down to single-digit `n`.
    ///
    /// Returns `nil` for `n <= 0` or an unusable confidence level.
    public static func wilsonInterval(passed: Int, total: Int, confidence: Double = 0.95) -> ProportionInterval? {
        guard total > 0, passed >= 0, passed <= total else { return nil }
        guard let z = NormalDistribution.twoSidedCriticalValue(confidence: confidence) else { return nil }

        let n = Double(total)
        guard n.isFinite, n > 0 else { return nil }
        guard let pHat = SafeMath.divide(Double(passed), by: n) else { return nil }

        let zSquared = z * z
        guard let zSquaredOverN = SafeMath.divide(zSquared, by: n) else { return nil }
        let denominator = 1 + zSquaredOverN
        guard let center = SafeMath.divide(pHat + zSquaredOverN / 2, by: denominator) else { return nil }

        guard let varianceTerm = SafeMath.divide(pHat * (1 - pHat), by: n) else { return nil }
        guard let continuityTerm = SafeMath.divide(zSquared, by: 4 * n * n) else { return nil }
        // `varianceTerm + continuityTerm` is non-negative in exact arithmetic,
        // but clamp anyway: `pHat * (1 - pHat)` can land a few ulp below zero.
        let root = SafeMath.sqrtClampingNegative(varianceTerm + continuityTerm)
        guard let halfWidth = SafeMath.divide(z * root, by: denominator) else { return nil }

        guard let lower = SafeMath.clampProbability(center - halfWidth),
              let upper = SafeMath.clampProbability(center + halfWidth),
              let point = SafeMath.clampProbability(pHat) else { return nil }

        return ProportionInterval(
            pointEstimate: point,
            lowerBound: Swift.min(lower, upper),
            upperBound: Swift.max(lower, upper),
            confidence: confidence,
            sampleCount: total
        )
    }

    // MARK: - Anytime-valid confidence sequence

    /// A confidence *sequence*: an interval that is simultaneously valid at
    /// every sample size, so you may inspect it after each new sample and stop
    /// the moment it decides, without inflating the false-positive rate.
    ///
    /// This matters because the natural way to run an expensive eval is "keep
    /// sampling until the gate is confident, then stop." Doing that with a
    /// fixed-`n` interval like Wilson is the optional-stopping fallacy: peeking
    /// after every sample at nominal 95% drives the true error rate toward 1.
    ///
    /// Construction is a Hoeffding bound with the error budget split across
    /// sample sizes as `αₙ = α / (n(n+1))`, whose sum telescopes to exactly `α`.
    /// A union bound over `n` then makes the whole sequence valid at level `α`.
    /// Mixture and stitched boundaries are tighter, but this one is short enough
    /// that a reviewer can check its validity by hand — which is the right
    /// trade for something that decides whether code ships.
    ///
    /// The price is width: about **2.4×** a Wilson interval at n = 40 for a
    /// mid-range pass rate, and roughly **4×** at the p̂ = 1 boundary. (Measured,
    /// not estimated — see `ProportionStatisticsTests`.) That is not a defect,
    /// it is what peeking costs, made explicit rather than absorbed silently.
    public static func confidenceSequence(passed: Int, total: Int, confidence: Double = 0.95) -> ProportionInterval? {
        guard total > 0, passed >= 0, passed <= total else { return nil }
        guard confidence.isFinite, confidence > 0, confidence < 1 else { return nil }

        let alpha = 1 - confidence
        let n = Double(total)
        guard n.isFinite, n > 0 else { return nil }
        guard let pHat = SafeMath.divide(Double(passed), by: n) else { return nil }

        // αₙ = α / (n(n+1))  ⇒  radius = √( ln(2 / αₙ) / (2n) )
        let alphaN = SafeMath.divide(alpha, by: n * (n + 1))
        guard let alphaN, alphaN > 0 else { return nil }
        guard let logArgument = SafeMath.divide(2, by: alphaN) else { return nil }
        let logTerm = SafeMath.logClampingNonPositive(logArgument)
        guard let radiusSquared = SafeMath.divide(logTerm, by: 2 * n) else { return nil }
        let radius = SafeMath.sqrtClampingNegative(radiusSquared)

        guard let lower = SafeMath.clampProbability(pHat - radius),
              let upper = SafeMath.clampProbability(pHat + radius),
              let point = SafeMath.clampProbability(pHat) else { return nil }

        return ProportionInterval(
            pointEstimate: point,
            lowerBound: Swift.min(lower, upper),
            upperBound: Swift.max(lower, upper),
            confidence: confidence,
            sampleCount: total
        )
    }

    // MARK: - Difference of two proportions

    /// Confidence interval on `candidateRate − baselineRate`, via Newcombe's
    /// hybrid score method (his method 10), which composes the two single-arm
    /// score intervals rather than assuming normality of the difference.
    ///
    /// The naive alternative — a Wald interval on the difference — inherits
    /// Wald's failure at the boundary, and the boundary is where eval suites
    /// live. With baseline 40/40 and candidate 38/40, Wald's contribution from
    /// the baseline arm is exactly zero variance, so the interval is far too
    /// narrow and the gate blocks on noise.
    ///
    /// `componentInterval` is injected so the same composition works for the
    /// fixed-sample (Wilson) and anytime-valid (confidence sequence) modes.
    ///
    /// `composition` selects how the two arms are combined, and getting this
    /// pairing right matters more than it looks.
    ///
    /// Newcombe's root-sum-of-squares is an *empirical calibration derived for
    /// Wilson score intervals*. It is not a theorem, and it does not transfer to
    /// a Hoeffding confidence sequence. Using RSS on sequence components would
    /// be claiming a guarantee that has not been established — while also being
    /// strictly narrower than the union bound that would establish one, i.e.
    /// anti-conservative relative to its own derivation.
    ///
    /// So: `.newcombe` composes Wilson arms built at the target level, and
    /// `.unionBound` composes arms each built at `1 − α/2` using linear radii,
    /// which is the composition the union bound actually justifies. An earlier
    /// version mixed the two — RSS radii on arms inflated for a union bound —
    /// and got the worst of both: wider than Newcombe, narrower than the bound
    /// it cited.
    public enum DifferenceComposition: Sendable, Hashable {
        /// Newcombe method 10. Valid for Wilson components at the target level.
        case newcombe
        /// Linear (rectangle) composition of two arms each at `1 − α/2`.
        /// Distribution-free, and correct for any component interval.
        case unionBound
    }

    public static func differenceInterval(
        baseline: SliceCounts,
        candidate: SliceCounts,
        confidence: Double = 0.95,
        composition: DifferenceComposition = .newcombe,
        componentInterval: (Int, Int, Double) -> ProportionInterval? = { passed, total, confidence in
            wilsonInterval(passed: passed, total: total, confidence: confidence)
        }
    ) -> ProportionInterval? {
        // Under the union bound each arm carries half the error budget.
        let armConfidence: Double = {
            switch composition {
            case .newcombe:
                return confidence
            case .unionBound:
                let alpha = 1 - confidence
                let halved = 1 - alpha / 2
                return (halved.isFinite && halved > 0 && halved < 1) ? halved : confidence
            }
        }()
        guard let base = componentInterval(baseline.passed, baseline.total, armConfidence),
              let cand = componentInterval(candidate.passed, candidate.total, armConfidence) else { return nil }

        let pointDifference = cand.pointEstimate - base.pointEstimate
        guard pointDifference.isFinite else { return nil }

        let lowerTermCandidate = cand.pointEstimate - cand.lowerBound
        let lowerTermBaseline = base.upperBound - base.pointEstimate
        let upperTermCandidate = cand.upperBound - cand.pointEstimate
        let upperTermBaseline = base.pointEstimate - base.lowerBound

        let lowerRadius: Double
        let upperRadius: Double
        switch composition {
        case .newcombe:
            lowerRadius = SafeMath.sqrtClampingNegative(
                lowerTermCandidate * lowerTermCandidate + lowerTermBaseline * lowerTermBaseline
            )
            upperRadius = SafeMath.sqrtClampingNegative(
                upperTermCandidate * upperTermCandidate + upperTermBaseline * upperTermBaseline
            )
        case .unionBound:
            // Linear sum: the projection of the joint rectangle onto the
            // difference axis. Wider than RSS, and actually implied by the
            // union bound over two arms.
            lowerRadius = lowerTermCandidate + lowerTermBaseline
            upperRadius = upperTermCandidate + upperTermBaseline
        }

        let lower = Swift.max(-1, pointDifference - lowerRadius)
        let upper = Swift.min(1, pointDifference + upperRadius)
        guard lower.isFinite, upper.isFinite else { return nil }

        return ProportionInterval(
            pointEstimate: pointDifference,
            lowerBound: Swift.min(lower, upper),
            upperBound: Swift.max(lower, upper),
            confidence: confidence,
            // The binding sample size for a difference is the smaller arm.
            sampleCount: Swift.min(baseline.total, candidate.total)
        )
    }

    // MARK: - Two-proportion test

    /// One-sided two-proportion z-test for "candidate is worse than baseline by
    /// more than `nonInferiorityMargin`."
    ///
    /// The margin is not cosmetic. With `margin = 0` this is an *equality*
    /// test, and an equality test has a property that quietly ruins a gate:
    /// its power grows without bound in `n`. Run a large enough suite and a
    /// completely uninteresting half-point drift becomes "statistically
    /// significant," so the gate blocks every merge and the team disables it.
    /// Shifting the null hypothesis by the margin asks the question the
    /// business actually has — "is it *meaningfully* worse?" — whose answer
    /// stays stable as `n` grows.
    ///
    /// Uses the unpooled standard error. Pooling estimates the variance under
    /// a null of *equal* rates, which is not the null being tested once a
    /// margin is introduced.
    ///
    /// Returns `nil` when the test is undefined — most commonly when both arms
    /// are all-pass or all-fail, which makes the standard error exactly zero.
    /// A `nil` here must never be read as "no regression"; callers map it to
    /// `.inconclusive`.
    public static func regressionPValue(
        baseline: SliceCounts,
        candidate: SliceCounts,
        nonInferiorityMargin: Double = 0
    ) -> Double? {
        guard baseline.total > 0, candidate.total > 0 else { return nil }
        let n1 = Double(baseline.total)
        let n2 = Double(candidate.total)
        guard n1 > 0, n2 > 0 else { return nil }

        guard let p1 = SafeMath.divide(Double(baseline.passed), by: n1),
              let p2 = SafeMath.divide(Double(candidate.passed), by: n2) else { return nil }

        let margin = (nonInferiorityMargin.isFinite && nonInferiorityMargin > 0)
            ? Swift.min(1, nonInferiorityMargin) : 0

        guard let variance1 = SafeMath.divide(p1 * (1 - p1), by: n1),
              let variance2 = SafeMath.divide(p2 * (1 - p2), by: n2) else { return nil }
        let standardError = SafeMath.sqrtClampingNegative(variance1 + variance2)
        // Degenerate: both arms are at a boundary, so the test has no
        // resolving power at all.
        guard standardError > 0 else { return nil }

        guard let z = SafeMath.divide(p2 - p1 + margin, by: standardError) else { return nil }
        let pValue = NormalDistribution.cdf(z)
        return pValue.isFinite ? Swift.min(1, Swift.max(0, pValue)) : nil
    }

    // MARK: - Sample size planning

    /// Samples per arm needed to detect a drop of `minimumDetectableEffect` at
    /// the given one-sided significance and power.
    ///
    /// This is the number that makes the "40-row golden set" conversation
    /// concrete. Detecting a 5-point drop from a 0.90 baseline at α=0.05,
    /// power 0.80 needs several hundred samples per arm — so a 40-row dataset
    /// is not a small version of a working gate, it is a gate with almost no
    /// power, whose green runs carry very little information.
    public static func requiredSamplesPerArm(
        baselineRate: Double,
        minimumDetectableEffect: Double,
        significance: Double = 0.05,
        power: Double = 0.80
    ) -> Int? {
        guard let p1 = SafeMath.clampProbability(baselineRate) else { return nil }
        guard minimumDetectableEffect.isFinite, minimumDetectableEffect > 0 else { return nil }
        guard significance.isFinite, significance > 0, significance < 1 else { return nil }
        guard power.isFinite, power > 0, power < 1 else { return nil }

        guard let p2 = SafeMath.clampProbability(p1 - minimumDetectableEffect) else { return nil }
        let delta = p1 - p2
        // The clamp above can shrink the effective effect to zero when the
        // baseline is at or below the requested drop; the test is then undefined.
        guard delta > 0 else { return nil }

        guard let zAlpha = NormalDistribution.quantile(1 - significance),
              let zBeta = NormalDistribution.quantile(power) else { return nil }

        let pBar = (p1 + p2) / 2
        let pooledTerm = zAlpha * SafeMath.sqrtClampingNegative(2 * pBar * (1 - pBar))
        let separateTerm = zBeta * SafeMath.sqrtClampingNegative(p1 * (1 - p1) + p2 * (1 - p2))
        let numerator = (pooledTerm + separateTerm) * (pooledTerm + separateTerm)
        guard let n = SafeMath.divide(numerator, by: delta * delta) else { return nil }
        guard n.isFinite, n >= 0 else { return nil }

        // Ceiling, then clamp — `Int(n)` would trap for a large-but-finite `n`
        // produced by a tiny `minimumDetectableEffect`.
        return SafeMath.ceilingClamping(n)
    }

    /// How many more samples per arm the current run would need. Never negative.
    public static func additionalSamplesNeeded(
        currentPerArm: Int,
        baselineRate: Double,
        minimumDetectableEffect: Double,
        significance: Double = 0.05,
        power: Double = 0.80
    ) -> Int? {
        guard currentPerArm >= 0 else { return nil }
        guard let required = requiredSamplesPerArm(
            baselineRate: baselineRate,
            minimumDetectableEffect: minimumDetectableEffect,
            significance: significance,
            power: power
        ) else { return nil }
        return Swift.max(0, SafeMath.add(required, -currentPerArm))
    }
}
