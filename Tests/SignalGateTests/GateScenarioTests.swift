import XCTest
@testable import SignalGate

/// End-to-end checks on the six built-in scenarios.
///
/// These matter beyond the library: the demo app's headline claim is that
/// dragging a sample-size slider walks a verdict from inconclusive to a real
/// decision. If these assertions ever stop holding, that claim becomes false,
/// and the demo's README along with it.
final class GateScenarioTests: XCTestCase {

    /// At 24 samples per arm nothing is knowable, including the cases where a
    /// real regression is present. A gate that returned an answer here would be
    /// making it up.
    func testNoScenarioIsDecidableAtTwentyFourSamples() {
        for scenario in GateScenario.allCases {
            let report = scenario.evaluate(samplesPerArm: 24)
            XCTAssertTrue(report.verdict.isInconclusive,
                          "\(scenario.rawValue) should be undecidable at n=24, got \(report.verdict)")
            XCTAssertFalse(report.verdict.allowsMerge, scenario.rawValue)
        }
    }

    func testEquivalentBuildPassesOnceThereIsEnoughEvidence() {
        XCTAssertTrue(GateScenario.equivalent.evaluate(samplesPerArm: 24).verdict.isInconclusive)
        XCTAssertEqual(GateScenario.equivalent.evaluate(samplesPerArm: 1200).verdict, .pass)
    }

    func testRealRegressionBlocksOnceThereIsEnoughEvidence() {
        XCTAssertTrue(GateScenario.realRegression.evaluate(samplesPerArm: 24).verdict.isInconclusive)
        XCTAssertEqual(GateScenario.realRegression.evaluate(samplesPerArm: 1200).verdict, .block)
    }

    /// The aggregate stays inside the margin while `de-DE` collapses. Only the
    /// per-slice family can see it.
    func testSliceCollapseIsCaughtBySliceTestingNotTheAggregate() throws {
        let report = GateScenario.sliceOnlyRegression.evaluate(samplesPerArm: 1200)
        XCTAssertEqual(report.verdict, .block)
        XCTAssertEqual(report.sliceResults.filter(\.isRegression).map(\.sliceID), ["de-DE"])

        let difference = try XCTUnwrap(report.differenceInterval)
        XCTAssertGreaterThan(difference.upperBound, 0,
                             "aggregate interval still includes zero — the block came from the slice family")
    }

    /// Judge failures short-circuit before any sample size can rescue them.
    func testJudgeFailuresAreUnaffectedBySampleSize() {
        for samples in [24, 1200, 6000] {
            XCTAssertEqual(
                GateScenario.judgeOffline.evaluate(samplesPerArm: samples).verdict,
                .inconclusive(reason: .judgeUnavailable, additionalSamplesNeeded: nil),
                "n=\(samples)"
            )
            XCTAssertEqual(
                GateScenario.lenientJudge.evaluate(samplesPerArm: samples).verdict,
                .inconclusive(reason: .judgeUncalibrated, additionalSamplesNeeded: nil),
                "n=\(samples)"
            )
        }
    }

    /// A 2-point true drop against a 3-point margin is a genuine boundary case:
    /// it never resolves cleanly, and the gate keeps saying so instead of
    /// eventually guessing. When it does, it must not claim that zero further
    /// samples are needed — that pairing reads as a bug.
    func testABoundaryEffectStaysInconclusiveWithoutBogusSampleAdvice() throws {
        let report = GateScenario.noiseNotRegression.evaluate(samplesPerArm: 6000)
        guard case .inconclusive(let reason, let additional) = report.verdict else {
            return XCTFail("expected inconclusive, got \(report.verdict)")
        }
        XCTAssertEqual(reason, .insufficientEvidence)
        XCTAssertNil(additional, "must not advise '0 more samples' while returning inconclusive")
        XCTAssertTrue(
            report.rationale.contains { $0.contains("policy decision") },
            "rationale should name the real decision: \(report.rationale)"
        )
    }

    /// At smaller sample sizes the advice is a real, positive number.
    func testSampleAdviceIsPositiveWhenSamplesAreGenuinelyTheConstraint() throws {
        let report = GateScenario.realRegression.evaluate(samplesPerArm: 60)
        guard case .inconclusive(_, let additional) = report.verdict else {
            return XCTFail("expected inconclusive, got \(report.verdict)")
        }
        let needed = try XCTUnwrap(additional)
        XCTAssertGreaterThan(needed, 0)
        XCTAssertTrue(report.rationale.contains { $0.contains("more samples per arm") })
    }

    func testEveryScenarioExposesNonEmptyPresentationText() {
        for scenario in GateScenario.allCases {
            XCTAssertFalse(scenario.title.isEmpty, scenario.rawValue)
            XCTAssertFalse(scenario.detail.isEmpty, scenario.rawValue)
            XCTAssertEqual(scenario.id, scenario.rawValue)
        }
        XCTAssertEqual(GateScenario.allCases.count, 6)
    }
}
