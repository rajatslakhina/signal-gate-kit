import XCTest
@testable import SignalGate

final class ProportionStatisticsTests: XCTestCase {

    // MARK: - Normal distribution

    func testNormalQuantileMatchesKnownCriticalValues() {
        guard let z95 = NormalDistribution.quantile(0.975),
              let z90 = NormalDistribution.quantile(0.95),
              let z80 = NormalDistribution.quantile(0.80) else {
            return XCTFail("Quantile returned nil for valid probabilities")
        }
        XCTAssertEqual(z95, 1.959964, accuracy: 1e-5)
        XCTAssertEqual(z90, 1.644854, accuracy: 1e-5)
        XCTAssertEqual(z80, 0.841621, accuracy: 1e-5)
    }

    func testNormalQuantileRejectsDegenerateInputs() {
        // Returning ±infinity here would produce an interval covering [0, 1]
        // and a gate that can never block.
        XCTAssertNil(NormalDistribution.quantile(0))
        XCTAssertNil(NormalDistribution.quantile(1))
        XCTAssertNil(NormalDistribution.quantile(.nan))
        XCTAssertNil(NormalDistribution.quantile(-0.1))
    }

    func testNormalCDFAndQuantileAreInverses() {
        for p in [0.001, 0.05, 0.25, 0.5, 0.75, 0.95, 0.999] {
            guard let z = NormalDistribution.quantile(p) else {
                return XCTFail("nil quantile at \(p)")
            }
            XCTAssertEqual(NormalDistribution.cdf(z), p, accuracy: 1e-6, "round trip failed at p=\(p)")
        }
    }

    // MARK: - Wilson

    func testWilsonMatchesPublishedValue() {
        // 8/10 at 95%: Wilson gives approximately [0.4902, 0.9433].
        guard let interval = ProportionStatistics.wilsonInterval(passed: 8, total: 10) else {
            return XCTFail("nil interval")
        }
        XCTAssertEqual(interval.lowerBound, 0.4902, accuracy: 1e-3)
        XCTAssertEqual(interval.upperBound, 0.9433, accuracy: 1e-3)
        XCTAssertEqual(interval.pointEstimate, 0.8, accuracy: 1e-12)
    }

    /// The headline reason Wilson is used instead of Wald. Wald at `p̂ = 1`
    /// produces a zero-width interval — "95% confident the rate is exactly
    /// 100%" — from 20 samples. This test asserts the specific pathology is
    /// absent, and `testWaldDegeneratesWhereWilsonDoesNot` in the
    /// negative-control suite asserts that the pathology is real.
    func testWilsonDoesNotDegenerateAtThePerfectScoreBoundary() {
        guard let interval = ProportionStatistics.wilsonInterval(passed: 20, total: 20) else {
            return XCTFail("nil interval")
        }
        XCTAssertEqual(interval.upperBound, 1.0, accuracy: 1e-12)
        XCTAssertLessThan(interval.lowerBound, 0.90,
                          "20/20 should not imply a lower bound above 0.90")
        XCTAssertGreaterThan(interval.width, 0.15,
                             "A perfect score on 20 samples carries real uncertainty")
    }

    func testWilsonStaysInsideTheUnitIntervalAtBothBoundaries() {
        for (passed, total) in [(0, 5), (5, 5), (0, 1), (1, 1), (1, 1000)] {
            guard let interval = ProportionStatistics.wilsonInterval(passed: passed, total: total) else {
                return XCTFail("nil interval for \(passed)/\(total)")
            }
            XCTAssertGreaterThanOrEqual(interval.lowerBound, 0, "\(passed)/\(total)")
            XCTAssertLessThanOrEqual(interval.upperBound, 1, "\(passed)/\(total)")
            XCTAssertLessThanOrEqual(interval.lowerBound, interval.upperBound)
        }
    }

    func testWilsonRejectsImpossibleCounts() {
        XCTAssertNil(ProportionStatistics.wilsonInterval(passed: 0, total: 0))
        XCTAssertNil(ProportionStatistics.wilsonInterval(passed: 5, total: 3))
        XCTAssertNil(ProportionStatistics.wilsonInterval(passed: -1, total: 3))
        XCTAssertNil(ProportionStatistics.wilsonInterval(passed: 1, total: 3, confidence: 1))
        XCTAssertNil(ProportionStatistics.wilsonInterval(passed: 1, total: 3, confidence: 0))
    }

    func testWilsonNarrowsAsSamplesGrow() {
        guard let small = ProportionStatistics.wilsonInterval(passed: 18, total: 20),
              let large = ProportionStatistics.wilsonInterval(passed: 180, total: 200) else {
            return XCTFail("nil interval")
        }
        XCTAssertLessThan(large.width, small.width)
    }

    // MARK: - Confidence sequence

    /// The anytime-valid sequence must be strictly wider than the fixed-n
    /// interval at the same data. If it ever were not, it would be buying
    /// optional stopping for free, which is not a thing.
    func testConfidenceSequenceIsStrictlyWiderThanWilson() {
        for total in [10, 40, 200, 1000] {
            let passed = (total * 88) / 100
            guard let wilson = ProportionStatistics.wilsonInterval(passed: passed, total: total),
                  let sequence = ProportionStatistics.confidenceSequence(passed: passed, total: total) else {
                return XCTFail("nil interval at n=\(total)")
            }
            XCTAssertGreaterThan(sequence.width, wilson.width,
                                 "Anytime-valid interval must cost width at n=\(total)")
        }
    }

    /// Pins the cost-of-peeking figure both READMEs quote. An earlier version
    /// claimed 1.5-1.7x, which was simply wrong at every pass rate — the kind
    /// of number that survives review because nobody re-measures prose.
    func testConfidenceSequenceCostMatchesTheDocumentedRatio() throws {
        var ratios: [Double] = []
        for passed in [20, 32, 35] {
            let wilson = try XCTUnwrap(ProportionStatistics.wilsonInterval(passed: passed, total: 40))
            let sequence = try XCTUnwrap(ProportionStatistics.confidenceSequence(passed: passed, total: 40))
            let ratio = sequence.width / wilson.width
            ratios.append(ratio)
            XCTAssertGreaterThan(ratio, 2.2, "documented as ~2.4x at n=40 (p-hat \(passed)/40)")
            XCTAssertLessThan(ratio, 2.7, "documented as ~2.4x at n=40 (p-hat \(passed)/40)")
        }
        XCTAssertEqual(ratios.count, 3)

        // And roughly 4x at the p-hat = 1 boundary, where Wilson is narrowest.
        let boundaryWilson = try XCTUnwrap(ProportionStatistics.wilsonInterval(passed: 40, total: 40))
        let boundarySequence = try XCTUnwrap(ProportionStatistics.confidenceSequence(passed: 40, total: 40))
        let boundaryRatio = boundarySequence.width / boundaryWilson.width
        XCTAssertGreaterThan(boundaryRatio, 3.5)
        XCTAssertLessThan(boundaryRatio, 4.8)
    }

    func testConfidenceSequenceStaysBoundedAndRejectsBadInput() {
        guard let sequence = ProportionStatistics.confidenceSequence(passed: 5, total: 5) else {
            return XCTFail("nil sequence")
        }
        XCTAssertGreaterThanOrEqual(sequence.lowerBound, 0)
        XCTAssertLessThanOrEqual(sequence.upperBound, 1)
        XCTAssertNil(ProportionStatistics.confidenceSequence(passed: 1, total: 0))
        XCTAssertNil(ProportionStatistics.confidenceSequence(passed: 1, total: 2, confidence: 1))
    }

    // MARK: - Difference interval

    func testDifferenceIntervalBracketsTheObservedDifference() {
        guard let baseline = SliceCounts(sliceID: "s", passed: 88, total: 100),
              let candidate = SliceCounts(sliceID: "s", passed: 76, total: 100) else {
            return XCTFail("bad fixture")
        }
        guard let difference = ProportionStatistics.differenceInterval(
            baseline: baseline, candidate: candidate
        ) else { return XCTFail("nil difference") }

        XCTAssertEqual(difference.pointEstimate, -0.12, accuracy: 1e-12)
        XCTAssertLessThan(difference.lowerBound, -0.12)
        XCTAssertGreaterThan(difference.upperBound, -0.12)
        XCTAssertGreaterThanOrEqual(difference.lowerBound, -1)
        XCTAssertLessThanOrEqual(difference.upperBound, 1)
    }

    /// The boundary case Wald handles worst: a baseline arm with zero observed
    /// variance. Newcombe must still produce a non-degenerate interval.
    func testDifferenceIntervalSurvivesAPerfectBaselineArm() {
        guard let baseline = SliceCounts(sliceID: "s", passed: 40, total: 40),
              let candidate = SliceCounts(sliceID: "s", passed: 38, total: 40) else {
            return XCTFail("bad fixture")
        }
        guard let difference = ProportionStatistics.differenceInterval(
            baseline: baseline, candidate: candidate
        ) else { return XCTFail("nil difference") }
        XCTAssertGreaterThan(difference.width, 0.05,
                             "A perfect baseline arm still carries uncertainty")
        XCTAssertTrue(difference.contains(-0.05))
    }

    func testDifferenceIntervalReportsTheSmallerArmAsItsSampleCount() {
        guard let baseline = SliceCounts(sliceID: "s", passed: 90, total: 100),
              let candidate = SliceCounts(sliceID: "s", passed: 18, total: 20) else {
            return XCTFail("bad fixture")
        }
        let difference = ProportionStatistics.differenceInterval(baseline: baseline, candidate: candidate)
        XCTAssertEqual(difference?.sampleCount, 20)
    }

    // MARK: - Regression p-value

    func testRegressionPValueIsSmallForALargeDropAndLargeForNone() {
        guard let baseline = SliceCounts(sliceID: "s", passed: 180, total: 200),
              let big = SliceCounts(sliceID: "s", passed: 140, total: 200),
              let none = SliceCounts(sliceID: "s", passed: 179, total: 200) else {
            return XCTFail("bad fixture")
        }
        guard let dropP = ProportionStatistics.regressionPValue(baseline: baseline, candidate: big),
              let flatP = ProportionStatistics.regressionPValue(baseline: baseline, candidate: none) else {
            return XCTFail("nil p-value")
        }
        XCTAssertLessThan(dropP, 0.001)
        XCTAssertGreaterThan(flatP, 0.30)
    }

    /// A pooled rate of exactly 0 or 1 makes the standard error zero. Returning
    /// a p-value there would be inventing evidence from a degenerate test.
    func testRegressionPValueIsNilWhenTheTestHasNoResolvingPower() {
        guard let allPassA = SliceCounts(sliceID: "s", passed: 20, total: 20),
              let allPassB = SliceCounts(sliceID: "s", passed: 30, total: 30),
              let allFailA = SliceCounts(sliceID: "s", passed: 0, total: 20),
              let allFailB = SliceCounts(sliceID: "s", passed: 0, total: 30),
              let empty = SliceCounts(sliceID: "s", passed: 0, total: 0) else {
            return XCTFail("bad fixture")
        }
        XCTAssertNil(ProportionStatistics.regressionPValue(baseline: allPassA, candidate: allPassB))
        XCTAssertNil(ProportionStatistics.regressionPValue(baseline: allFailA, candidate: allFailB))
        XCTAssertNil(ProportionStatistics.regressionPValue(baseline: allPassA, candidate: empty))
    }

    // MARK: - Sample size planning

    /// The number that makes the "40-row golden set" conversation concrete.
    /// Detecting a 5-point drop from 0.90 at α=0.05 one-sided, 80% power takes
    /// several hundred samples per arm — so a 40-row dataset is not a small
    /// working gate, it is a gate with almost no power.
    func testRequiredSampleSizeExposesUnderpoweredGoldenSets() {
        guard let required = ProportionStatistics.requiredSamplesPerArm(
            baselineRate: 0.90, minimumDetectableEffect: 0.05
        ) else { return XCTFail("nil requirement") }
        XCTAssertGreaterThan(required, 300)
        XCTAssertLessThan(required, 700)
    }

    func testRequiredSampleSizeGrowsAsTheDetectableEffectShrinks() {
        guard let coarse = ProportionStatistics.requiredSamplesPerArm(
                baselineRate: 0.90, minimumDetectableEffect: 0.10),
              let fine = ProportionStatistics.requiredSamplesPerArm(
                baselineRate: 0.90, minimumDetectableEffect: 0.02) else {
            return XCTFail("nil requirement")
        }
        XCTAssertGreaterThan(fine, coarse)
    }

    /// A vanishing effect size drives the requirement past `Int.max`.
    /// `Int(n)` would trap on the resulting `1.1e20`; the clamp saturates.
    func testRequiredSampleSizeSaturatesInsteadOfTrappingOnATinyEffect() {
        let required = ProportionStatistics.requiredSamplesPerArm(
            baselineRate: 0.90, minimumDetectableEffect: 1e-10
        )
        XCTAssertEqual(required, .max)
    }

    /// An effect so small it is not representable as a difference between two
    /// `Double` rates — `0.9 - 1e-300 == 0.9` exactly — leaves no effect to
    /// detect, and the function says so rather than returning a number.
    func testRequiredSampleSizeRejectsAnUnrepresentableEffect() {
        XCTAssertNil(ProportionStatistics.requiredSamplesPerArm(
            baselineRate: 0.90, minimumDetectableEffect: 1e-300))
    }

    /// A baseline lower than the requested drop truncates the target rate at
    /// zero, so the effect actually tested is the full baseline rate. This is
    /// a real behaviour worth pinning down, not an error case.
    func testRequiredSampleSizeTruncatesAnEffectThatWouldGoBelowZero() throws {
        let required = try XCTUnwrap(ProportionStatistics.requiredSamplesPerArm(
            baselineRate: 0.03, minimumDetectableEffect: 0.05))
        let equivalent = try XCTUnwrap(ProportionStatistics.requiredSamplesPerArm(
            baselineRate: 0.03, minimumDetectableEffect: 0.03))
        XCTAssertEqual(required, equivalent, "the drop is clamped at a rate of zero")
    }

    func testRequiredSampleSizeRejectsUndefinedConfigurations() {
        XCTAssertNil(ProportionStatistics.requiredSamplesPerArm(
            baselineRate: 0.90, minimumDetectableEffect: 0))
        XCTAssertNil(ProportionStatistics.requiredSamplesPerArm(
            baselineRate: 0.90, minimumDetectableEffect: -0.05))
        XCTAssertNil(ProportionStatistics.requiredSamplesPerArm(
            baselineRate: .nan, minimumDetectableEffect: 0.05))
        XCTAssertNil(ProportionStatistics.requiredSamplesPerArm(
            baselineRate: 0.90, minimumDetectableEffect: 0.05, power: 1))
        XCTAssertNil(ProportionStatistics.requiredSamplesPerArm(
            baselineRate: 0.90, minimumDetectableEffect: 0.05, significance: 0))
    }

    // MARK: - Non-inferiority margin

    /// With `margin = 0` the test is an equality test, whose power grows
    /// without bound in `n`: a fixed, uninteresting half-point drift becomes
    /// "significant" once the suite is large enough, and the gate blocks every
    /// merge. Shifting the null by the margin keeps the answer stable in `n`.
    func testTheMarginStopsLargeSamplesFlaggingTrivialDrift() throws {
        let baseline = try XCTUnwrap(SliceCounts(sliceID: "s", passed: 8800, total: 10_000))
        let candidate = try XCTUnwrap(SliceCounts(sliceID: "s", passed: 8700, total: 10_000))

        let equalityP = try XCTUnwrap(ProportionStatistics.regressionPValue(
            baseline: baseline, candidate: candidate, nonInferiorityMargin: 0))
        XCTAssertLessThan(equalityP, 0.05,
                          "precondition: an equality test does flag this 1-point drift at n=10,000")

        let marginP = try XCTUnwrap(ProportionStatistics.regressionPValue(
            baseline: baseline, candidate: candidate, nonInferiorityMargin: 0.03))
        XCTAssertGreaterThan(marginP, 0.50,
                             "a drop well inside the margin must not be flagged, however large n gets")
    }

    func testTheMarginStillLetsARealRegressionThrough() throws {
        let baseline = try XCTUnwrap(SliceCounts(sliceID: "s", passed: 440, total: 500))
        let candidate = try XCTUnwrap(SliceCounts(sliceID: "s", passed: 290, total: 500))
        let marginP = try XCTUnwrap(ProportionStatistics.regressionPValue(
            baseline: baseline, candidate: candidate, nonInferiorityMargin: 0.03))
        XCTAssertLessThan(marginP, 0.001, "a 30-point collapse must survive the margin")
    }

    func testMalformedMarginsDegradeToZero() throws {
        let baseline = try XCTUnwrap(SliceCounts(sliceID: "s", passed: 180, total: 200))
        let candidate = try XCTUnwrap(SliceCounts(sliceID: "s", passed: 160, total: 200))
        let zero = try XCTUnwrap(ProportionStatistics.regressionPValue(
            baseline: baseline, candidate: candidate, nonInferiorityMargin: 0))
        for bad in [Double.nan, -0.5, -.infinity] {
            let value = try XCTUnwrap(ProportionStatistics.regressionPValue(
                baseline: baseline, candidate: candidate, nonInferiorityMargin: bad))
            XCTAssertEqual(value, zero, accuracy: 1e-12, "margin \(bad) should behave as 0")
        }
    }

    func testAdditionalSamplesNeededNeverGoesNegative() {
        let already = ProportionStatistics.additionalSamplesNeeded(
            currentPerArm: 100_000, baselineRate: 0.90, minimumDetectableEffect: 0.05
        )
        XCTAssertEqual(already, 0)
        XCTAssertNil(ProportionStatistics.additionalSamplesNeeded(
            currentPerArm: -1, baselineRate: 0.90, minimumDetectableEffect: 0.05))
    }
}
