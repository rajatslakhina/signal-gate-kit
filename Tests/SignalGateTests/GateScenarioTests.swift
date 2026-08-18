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
        XCTAssertEqual(GateScenario.equivalent.evaluate(samplesPerArm: 3000).verdict, .pass)
    }

    /// Every scenario, at the sample size the demo app actually opens on.
    ///
    /// This exists because a reviewer's first impression is formed here and
    /// nowhere else. The specific failure being guarded against: an earlier
    /// build returned PASS for `sliceOnlyRegression` at the default n, so
    /// someone who opened the app, picked "One slice collapsed" and touched
    /// nothing got a green merge on a build where a locale had dropped 30
    /// points — the exact opposite of the scenario's own description.
    func testNoScenarioShowsAWrongVerdictAtTheDemoDefaultSampleSize() {
        let demoDefault = 120
        for scenario in GateScenario.allCases {
            let verdict = scenario.evaluate(samplesPerArm: demoDefault).verdict
            XCTAssertFalse(
                verdict.allowsMerge,
                "\(scenario.rawValue) certifies a merge at the demo's default n=\(demoDefault)"
            )
        }

        // Wrong in the other direction too — a hardwired `.block` would satisfy
        // the loop above while being just as wrong for a clean build.
        XCTAssertFalse(GateScenario.equivalent.evaluate(samplesPerArm: demoDefault).verdict.isBlock,
                       "an equivalent build is condemned at the demo's default n")
        XCTAssertFalse(GateScenario.noiseNotRegression.evaluate(samplesPerArm: demoDefault).verdict.isBlock,
                       "a within-margin build is condemned at the demo's default n")
    }

    /// The demo's headline: the default view opens on a genuine regression that
    /// the evidence at that sample size cannot yet establish.
    func testDemoDefaultStateIsInconclusiveOnARealRegression() throws {
        let report = GateScenario.realRegression.evaluate(samplesPerArm: 120)
        guard case .inconclusive(let reason, let additional) = report.verdict else {
            return XCTFail("expected inconclusive, got \(report.verdict)")
        }
        XCTAssertEqual(reason, .insufficientEvidence)
        XCTAssertNotNil(additional, "the banner needs a sample-size number to show")
        XCTAssertEqual(report.sliceResults.count, GateScenario.sliceIDs.count)
        XCTAssertFalse(report.rationale.isEmpty)
        XCTAssertNotNil(report.differenceInterval)
    }

    func testRealRegressionBlocksOnceThereIsEnoughEvidence() {
        XCTAssertTrue(GateScenario.realRegression.evaluate(samplesPerArm: 24).verdict.isInconclusive)
        XCTAssertEqual(GateScenario.realRegression.evaluate(samplesPerArm: 1200).verdict, .block)
    }

    /// Once the regression is established it must *stay* established as more
    /// samples arrive. Non-monotone behaviour here would mean the slider is
    /// redrawing unrelated experiments rather than extending one.
    func testRealRegressionStaysBlockedAsSamplesGrow() {
        var sampleSize = 1_200
        while sampleSize <= 6_000 {
            XCTAssertEqual(GateScenario.realRegression.evaluate(samplesPerArm: sampleSize).verdict, .block,
                           "regression became undetectable again at n=\(sampleSize)")
            sampleSize += 600
        }
    }

    /// The 2-point wobble sits inside the margin, so no sample size should ever
    /// turn it into a block. This sweeps every slider stop rather than probing
    /// one convenient value — an earlier build blocked at 23 of them.
    func testTheWobbleScenarioNeverBlocksAtAnySliderPosition() {
        var sampleSize = 24
        var blocked: [Int] = []
        while sampleSize <= 6_000 {
            if GateScenario.noiseNotRegression.evaluate(samplesPerArm: sampleSize).verdict.isBlock {
                blocked.append(sampleSize)
            }
            sampleSize += 12
        }
        XCTAssertTrue(blocked.isEmpty, "blocked a within-margin build at n = \(blocked)")
    }

    /// The aggregate stays inside the margin while `de-DE` collapses. Only the
    /// per-slice family can see it.
    func testSliceCollapseNeverCertifiesAMergeAtAnySliderPosition() {
        var sampleSize = 24
        var passed: [Int] = []
        while sampleSize <= 6_000 {
            if GateScenario.sliceOnlyRegression.evaluate(samplesPerArm: sampleSize).verdict.allowsMerge {
                passed.append(sampleSize)
            }
            sampleSize += 12
        }
        XCTAssertTrue(passed.isEmpty, "certified a collapsed-slice build at n = \(passed)")
    }

    func testSliceCollapseIsCaughtBySliceTestingNotTheAggregate() throws {
        // n=3000, chosen because at that size the aggregate interval sits
        // *entirely above* the margin — so the aggregate alone would have
        // returned PASS, and the block provably comes from the slice family.
        // At smaller n the aggregate is merely inconclusive, which would make
        // the claim weaker than the test's name.
        let report = GateScenario.sliceOnlyRegression.evaluate(samplesPerArm: 3000)
        XCTAssertEqual(report.verdict, .block)
        XCTAssertEqual(report.sliceResults.filter(\.isRegression).map(\.sliceID), ["de-DE"])

        // The assertion has to be the one that actually establishes the claim:
        // the aggregate on its own would NOT have blocked, because its interval
        // sits entirely above the non-inferiority margin. `upperBound > 0` was
        // the earlier, weaker version of this check — it is satisfied by an
        // implementation hardwired to return `.block`, so it proved nothing.
        let difference = try XCTUnwrap(report.differenceInterval)
        let margin = GatePolicy.standard.nonInferiorityMargin
        XCTAssertGreaterThan(difference.lowerBound, -margin,
                             "aggregate alone would have passed — so the block came from the slice family")
        XCTAssertTrue(difference.contains(0), "aggregate interval still straddles zero")
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
