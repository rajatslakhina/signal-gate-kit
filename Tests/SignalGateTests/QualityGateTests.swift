import XCTest
@testable import SignalGate

final class QualityGateTests: XCTestCase {

    private func samples(_ sliceID: String, passed: Int, total: Int, prefix: String) -> [EvalSample] {
        (0..<total).map { index in
            EvalSample(caseID: "\(prefix)-\(sliceID)-\(index)", sliceID: sliceID, passed: index < passed)
        }
    }

    private var goodJudge: AgreementMatrix? {
        AgreementMatrix(bothPass: 66, judgePassHumanFail: 4, judgeFailHumanPass: 3, bothFail: 27)
    }

    // MARK: - Preconditions

    func testEmptyArmsReportNoSamples() {
        let report = QualityGate.evaluate(baseline: [], candidate: [], judgeMatrix: goodJudge)
        XCTAssertEqual(report.verdict, .inconclusive(reason: .noSamples, additionalSamplesNeeded: nil))
        XCTAssertFalse(report.verdict.allowsMerge)
    }

    /// The judge is checked *before* any pass-rate arithmetic. This is ordering,
    /// not decoration: an uncalibrated judge does not make the numbers noisy,
    /// it makes them meaningless.
    func testAnUnavailableJudgeBlocksCertificationEvenOnPerfectData() {
        let baseline = samples("en-US", passed: 900, total: 1000, prefix: "b")
        let candidate = samples("en-US", passed: 990, total: 1000, prefix: "c")
        let report = QualityGate.evaluate(baseline: baseline, candidate: candidate, judgeMatrix: nil)

        XCTAssertEqual(report.verdict, .inconclusive(reason: .judgeUnavailable, additionalSamplesNeeded: nil))
        XCTAssertFalse(report.verdict.allowsMerge,
                       "a candidate that improved by 9 points still cannot be certified without a judge")
        XCTAssertEqual(report.judgeStatus, .unavailable)
    }

    func testAnUncalibratedJudgeBlocksCertification() {
        let lenient = AgreementMatrix(
            bothPass: 55, judgePassHumanFail: 10, judgeFailHumanPass: 2, bothFail: 33
        )
        let baseline = samples("en-US", passed: 880, total: 1000, prefix: "b")
        let candidate = samples("en-US", passed: 880, total: 1000, prefix: "c")
        let report = QualityGate.evaluate(baseline: baseline, candidate: candidate, judgeMatrix: lenient)

        XCTAssertEqual(report.verdict, .inconclusive(reason: .judgeUncalibrated, additionalSamplesNeeded: nil))
        XCTAssertTrue(report.rationale.contains { $0.contains("lenient") })
    }

    func testAMissingSliceMakesTheRunIncomparable() {
        var baseline = samples("en-US", passed: 90, total: 100, prefix: "b")
        baseline += samples("de-DE", passed: 90, total: 100, prefix: "b")
        let candidate = samples("en-US", passed: 90, total: 100, prefix: "c")

        let report = QualityGate.evaluate(baseline: baseline, candidate: candidate, judgeMatrix: goodJudge)
        XCTAssertEqual(report.verdict, .inconclusive(reason: .incomparableSlices, additionalSamplesNeeded: nil))
        XCTAssertTrue(report.rationale.contains { $0.contains("de-DE") })
    }

    // MARK: - Three-state behaviour

    /// The case the package exists for. Twelve samples per arm cannot support
    /// either conclusion, and the gate says so instead of guessing.
    func testTinySamplesAreInconclusiveNotPassed() {
        let baseline = samples("en-US", passed: 11, total: 12, prefix: "b")
        let candidate = samples("en-US", passed: 10, total: 12, prefix: "c")
        let report = QualityGate.evaluate(baseline: baseline, candidate: candidate, judgeMatrix: goodJudge)

        guard case .inconclusive(let reason, let additional) = report.verdict else {
            return XCTFail("expected inconclusive, got \(report.verdict)")
        }
        XCTAssertEqual(reason, .insufficientEvidence)
        guard let additional else { return XCTFail("expected a sample-size estimate") }
        XCTAssertGreaterThan(additional, 0)
        XCTAssertFalse(report.verdict.allowsMerge)
    }

    func testALargeCleanRunPasses() {
        let baseline = samples("en-US", passed: 1760, total: 2000, prefix: "b")
        let candidate = samples("en-US", passed: 1760, total: 2000, prefix: "c")
        let report = QualityGate.evaluate(baseline: baseline, candidate: candidate, judgeMatrix: goodJudge)

        XCTAssertEqual(report.verdict, .pass)
        XCTAssertTrue(report.verdict.allowsMerge)
        guard let difference = report.differenceInterval else { return XCTFail("nil interval") }
        XCTAssertGreaterThan(difference.lowerBound, -0.03)
    }

    func testALargeRealRegressionBlocks() {
        let baseline = samples("en-US", passed: 1760, total: 2000, prefix: "b")
        let candidate = samples("en-US", passed: 1520, total: 2000, prefix: "c")
        let report = QualityGate.evaluate(baseline: baseline, candidate: candidate, judgeMatrix: goodJudge)

        XCTAssertEqual(report.verdict, .block)
        XCTAssertFalse(report.verdict.allowsMerge)
    }

    /// A drop smaller than the declared margin is not a regression, however
    /// many samples confirm it. This is what makes the gate a non-inferiority
    /// test rather than an equality test — and it is the behaviour that stops
    /// the gate blocking on every downward wobble.
    func testADropInsideTheMarginPassesEvenAtHugeSampleSizes() {
        let baseline = samples("en-US", passed: 8800, total: 10_000, prefix: "b")
        let candidate = samples("en-US", passed: 8700, total: 10_000, prefix: "c")
        let report = QualityGate.evaluate(baseline: baseline, candidate: candidate, judgeMatrix: goodJudge)

        XCTAssertEqual(report.verdict, .pass, "a 1-point drop is inside the 3-point margin")
        guard let difference = report.differenceInterval else { return XCTFail("nil interval") }
        XCTAssertLessThan(difference.pointEstimate, 0, "the drop is real…")
        XCTAssertGreaterThan(difference.lowerBound, -0.03, "…and still inside the margin")
    }

    // MARK: - Slice behaviour

    /// The aggregate is flat; one slice has collapsed. A gate watching only the
    /// overall number passes this build.
    func testASliceCollapseBlocksEvenWhenTheAggregateIsFlat() {
        var baseline: [EvalSample] = []
        var candidate: [EvalSample] = []
        for sliceID in ["en-US", "de-DE", "ja-JP", "pt-BR"] {
            baseline += samples(sliceID, passed: 440, total: 500, prefix: "b")
            // Three slices improve, one collapses — so the aggregate ends up
            // slightly *better* than baseline.
            let candidatePassed = (sliceID == "de-DE") ? 290 : 495
            candidate += samples(sliceID, passed: candidatePassed, total: 500, prefix: "c")
        }

        let report = QualityGate.evaluate(baseline: baseline, candidate: candidate, judgeMatrix: goodJudge)
        XCTAssertEqual(report.verdict, .block)

        let regressed = report.sliceResults.filter(\.isRegression).map(\.sliceID)
        XCTAssertEqual(regressed, ["de-DE"])

        // The overall difference is actually positive here — proof the block
        // came from the slice family and not from the aggregate.
        guard let difference = report.differenceInterval else { return XCTFail("nil interval") }
        XCTAssertGreaterThan(difference.pointEstimate, 0,
                             "aggregate improved; only the slice test can catch this")
    }

    func testReportCarriesTheUncorrectedComparisonForContrast() {
        var baseline: [EvalSample] = []
        var candidate: [EvalSample] = []
        for sliceID in GateScenario.sliceIDs {
            baseline += samples(sliceID, passed: 88, total: 100, prefix: "b")
            candidate += samples(sliceID, passed: 88, total: 100, prefix: "c")
        }
        let report = QualityGate.evaluate(baseline: baseline, candidate: candidate, judgeMatrix: goodJudge)
        guard let familyWise = report.uncorrectedFamilyWiseErrorRate else {
            return XCTFail("expected a family-wise error rate for 6 slices")
        }
        XCTAssertEqual(familyWise, 1 - pow(0.95, 6), accuracy: 1e-9)
        XCTAssertTrue(report.rationale.contains { $0.contains("Benjamini-Hochberg") })
    }

    // MARK: - Budget interaction

    /// Budget is only a reason to stop when more samples would have helped.
    func testAnExhaustedBudgetOnlyMattersWhenTheEvidenceIsAmbiguous() {
        let exhausted = BudgetState(
            spentUSD: 100, elapsedSeconds: 100, inferenceCalls: 100,
            isExhausted: true, exhaustedBy: "spend", utilization: 1
        )

        let ambiguousBaseline = samples("en-US", passed: 11, total: 12, prefix: "b")
        let ambiguousCandidate = samples("en-US", passed: 10, total: 12, prefix: "c")
        let ambiguous = QualityGate.evaluate(
            baseline: ambiguousBaseline, candidate: ambiguousCandidate,
            judgeMatrix: goodJudge, budget: exhausted
        )
        XCTAssertEqual(ambiguous.verdict, .inconclusive(reason: .budgetExhausted, additionalSamplesNeeded: nil))

        let decisiveBaseline = samples("en-US", passed: 1760, total: 2000, prefix: "b")
        let decisiveCandidate = samples("en-US", passed: 1520, total: 2000, prefix: "c")
        let decisive = QualityGate.evaluate(
            baseline: decisiveBaseline, candidate: decisiveCandidate,
            judgeMatrix: goodJudge, budget: exhausted
        )
        XCTAssertEqual(decisive.verdict, .block,
                       "an exhausted budget must not downgrade an already-decisive block")
    }

    // MARK: - Modes

    /// Sequential mode buys optional stopping and pays for it in width, so it
    /// must be strictly more conservative on identical borderline data.
    func testSequentialModeIsMoreConservativeThanFixedSample() {
        let baseline = samples("en-US", passed: 176, total: 200, prefix: "b")
        let candidate = samples("en-US", passed: 174, total: 200, prefix: "c")

        let fixed = QualityGate.evaluate(
            baseline: baseline, candidate: candidate, judgeMatrix: goodJudge,
            policy: GatePolicy(mode: .fixedSample)
        )
        let sequential = QualityGate.evaluate(
            baseline: baseline, candidate: candidate, judgeMatrix: goodJudge,
            policy: GatePolicy(mode: .sequential)
        )

        guard let fixedInterval = fixed.differenceInterval,
              let sequentialInterval = sequential.differenceInterval else {
            return XCTFail("nil interval")
        }
        XCTAssertGreaterThan(sequentialInterval.width, fixedInterval.width)
        XCTAssertTrue(sequential.rationale.contains { $0.contains("anytime-valid") })
    }

    // MARK: - Policy hardening

    /// A policy decoded from malformed CI config must degrade to defensible
    /// defaults rather than taking the gate offline or, worse, producing a
    /// `NaN` margin that every comparison silently fails against.
    func testMalformedPolicyValuesFallBackToDefaults() {
        let policy = GatePolicy(
            nonInferiorityMargin: .nan,
            confidence: 1.5,
            sliceFalseDiscoveryRate: -1,
            minimumDetectableEffect: .infinity,
            power: 0
        )
        XCTAssertEqual(policy.nonInferiorityMargin, 0.03)
        XCTAssertEqual(policy.confidence, 0.95)
        XCTAssertEqual(policy.sliceFalseDiscoveryRate, 0.05)
        XCTAssertEqual(policy.minimumDetectableEffect, 0.05)
        XCTAssertEqual(policy.power, 0.80)
    }

    /// The gate blocks if either the slice family or the overall test fires,
    /// so running both at the full run-level alpha would put the true
    /// false-block rate near their union. The budget is split; this asserts the
    /// split is real and adds up, rather than being described only in a comment.
    func testRunLevelErrorBudgetIsSplitAcrossBothFamilies() {
        let policy = GatePolicy(confidence: 0.95, sliceFalseDiscoveryRate: 0.05)
        XCTAssertEqual(policy.runLevelAlpha, 0.05, accuracy: 1e-12)
        XCTAssertEqual(policy.overallAlpha, 0.025, accuracy: 1e-12)
        XCTAssertEqual(policy.overallConfidence, 0.975, accuracy: 1e-12)
        XCTAssertEqual(policy.sliceQ, 0.025, accuracy: 1e-12)
        XCTAssertEqual(policy.perArmConfidence, 0.9875, accuracy: 1e-12)

        // At the default the two halves happen to sum to the run-level budget.
        XCTAssertEqual(policy.overallAlpha + policy.sliceQ, policy.runLevelAlpha, accuracy: 1e-12)
        XCTAssertEqual(policy.unionFalseBlockBound, policy.runLevelAlpha, accuracy: 1e-12)
    }

    /// The knobs are independent, so at a non-default policy the two halves do
    /// NOT sum to the run-level alpha — and the package must report the larger,
    /// true union bound rather than the flattering one.
    ///
    /// The default-only version of this test passed against an implementation
    /// whose slice budget was unrelated to the run-level budget, because 0.05
    /// and 0.05 coincide. This one does not.
    func testUnionBoundIsReportedHonestlyAtNonDefaultPolicies() {
        let mismatched = GatePolicy(confidence: 0.99, sliceFalseDiscoveryRate: 0.10)
        XCTAssertEqual(mismatched.runLevelAlpha, 0.01, accuracy: 1e-12)
        XCTAssertEqual(mismatched.overallAlpha, 0.005, accuracy: 1e-12)
        XCTAssertEqual(mismatched.sliceQ, 0.05, accuracy: 1e-12)

        // 0.055, not 0.01. Quoting the run-level alpha here would understate
        // the real false-block rate by 5.5x.
        XCTAssertEqual(mismatched.unionFalseBlockBound, 0.055, accuracy: 1e-12)
        XCTAssertGreaterThan(mismatched.unionFalseBlockBound, mismatched.runLevelAlpha)

        // And each family always gets exactly half its own configured budget.
        for (confidence, fdr) in [(0.95, 0.05), (0.99, 0.10), (0.90, 0.20), (0.80, 0.01)] {
            let policy = GatePolicy(confidence: confidence, sliceFalseDiscoveryRate: fdr)
            XCTAssertEqual(policy.overallAlpha, (1 - confidence) / 2, accuracy: 1e-12)
            XCTAssertEqual(policy.sliceQ, fdr / 2, accuracy: 1e-12)
            XCTAssertEqual(policy.unionFalseBlockBound,
                           Swift.min(1, policy.overallAlpha + policy.sliceQ), accuracy: 1e-12)
        }
    }

    /// The split must reach the actual interval, not just the policy struct.
    /// A wider allocation has to produce a visibly wider reported interval.
    func testTheSplitActuallyWidensTheReportedInterval() throws {
        let baseline = samples("en-US", passed: 880, total: 1000, prefix: "b")
        let candidate = samples("en-US", passed: 870, total: 1000, prefix: "c")

        let strict = QualityGate.evaluate(
            baseline: baseline, candidate: candidate, judgeMatrix: goodJudge,
            policy: GatePolicy(confidence: 0.95)
        )
        let loose = QualityGate.evaluate(
            baseline: baseline, candidate: candidate, judgeMatrix: goodJudge,
            policy: GatePolicy(confidence: 0.80)
        )
        let strictInterval = try XCTUnwrap(strict.differenceInterval)
        let looseInterval = try XCTUnwrap(loose.differenceInterval)

        XCTAssertGreaterThan(strictInterval.width, looseInterval.width)
        XCTAssertEqual(strictInterval.confidence, 0.975, accuracy: 1e-12,
                       "the reported interval is built at the split level, not the run level")
    }

    func testReportIsCodableRoundTrip() throws {
        let baseline = samples("en-US", passed: 176, total: 200, prefix: "b")
        let candidate = samples("en-US", passed: 150, total: 200, prefix: "c")
        let report = QualityGate.evaluate(baseline: baseline, candidate: candidate, judgeMatrix: goodJudge)

        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(GateReport.self, from: encoded)
        XCTAssertEqual(decoded.verdict, report.verdict)
        XCTAssertEqual(decoded.rationale, report.rationale)
        XCTAssertEqual(decoded.sliceResults, report.sliceResults)
    }
}
