import XCTest
@testable import SignalGate

/// Negative controls.
///
/// Every test in this file implements the *wrong* thing on purpose and asserts
/// that it fails the property the README claims SignalGate has. Without these,
/// the positive tests are unfalsifiable: a suite that only ever asserts the
/// correct implementation behaves correctly would still pass if the property
/// being checked were vacuous — if, say, Wald and Wilson happened to agree
/// everywhere, or if BH and no-correction always reached the same verdict.
///
/// These are the tests that make the rest of the suite mean something.
final class NegativeControlTests: XCTestCase {

    // MARK: - Broken implementations under test

    /// The textbook Wald interval, `p̂ ± z·√(p̂(1−p̂)/n)`. This is what most
    /// hand-rolled eval gates compute.
    private func waldInterval(passed: Int, total: Int, confidence: Double = 0.95) -> (lower: Double, upper: Double)? {
        guard total > 0, let z = NormalDistribution.twoSidedCriticalValue(confidence: confidence) else { return nil }
        let n = Double(total)
        let pHat = Double(passed) / n
        let halfWidth = z * (pHat * (1 - pHat) / n).squareRoot()
        return (pHat - halfWidth, pHat + halfWidth)
    }

    /// A two-state gate that compares point estimates against a threshold —
    /// the design SignalGate exists to replace.
    private func naiveTwoStateVerdict(
        baseline: SliceCounts, candidate: SliceCounts, margin: Double = 0.03
    ) -> Bool {
        guard let baselineRate = baseline.passRate, let candidateRate = candidate.passRate else { return true }
        return candidateRate >= baselineRate - margin
    }

    // MARK: - Wilson vs Wald

    /// Asserts the pathology is real. `testWilsonDoesNotDegenerateAtThePerfect
    /// ScoreBoundary` is only meaningful because this fails.
    func testWaldDegeneratesWhereWilsonDoesNot() throws {
        let wald = try XCTUnwrap(waldInterval(passed: 20, total: 20))
        let wilson = try XCTUnwrap(ProportionStatistics.wilsonInterval(passed: 20, total: 20))

        // Wald: "95% confident the pass rate is exactly 100%", from 20 samples.
        XCTAssertEqual(wald.upper - wald.lower, 0, accuracy: 1e-15,
                       "Wald must produce a zero-width interval here — that is the bug")
        XCTAssertEqual(wald.lower, 1.0, accuracy: 1e-15)

        XCTAssertGreaterThan(wilson.width, 0.15,
                             "Wilson must not share the pathology")
        XCTAssertLessThan(wilson.lowerBound, wald.lower)
    }

    /// Wald also escapes `[0, 1]`, producing a "confidence interval" containing
    /// impossible pass rates.
    func testWaldEscapesTheUnitIntervalWhereWilsonCannot() throws {
        let wald = try XCTUnwrap(waldInterval(passed: 19, total: 20))
        let wilson = try XCTUnwrap(ProportionStatistics.wilsonInterval(passed: 19, total: 20))

        XCTAssertGreaterThan(wald.upper, 1.0, "Wald's upper bound exceeds 1 here — that is the bug")
        XCTAssertLessThanOrEqual(wilson.upperBound, 1.0)
    }

    // MARK: - Correction vs no correction

    /// Asserts BH and no-correction genuinely disagree. If they never did,
    /// every test about FDR control in this package would be decoration.
    func testUncorrectedSliceTestingBlocksAFamilyBenjaminiHochbergClears() {
        // Twelve true nulls; one lands at p = 0.03 by luck, which at α = 0.05
        // happens roughly 46% of the time with this many slices.
        var tests = [SliceTest(sliceID: "slice-00", pValue: 0.03)]
        for index in 1..<12 {
            tests.append(SliceTest(sliceID: String(format: "slice-%02d", index), pValue: 0.40 + Double(index) * 0.04))
        }

        let naive = MultipleComparisons.uncorrected(tests: tests, alpha: 0.05)
        let corrected = MultipleComparisons.benjaminiHochberg(tests: tests, falseDiscoveryRate: 0.05)

        XCTAssertGreaterThan(naive.filter(\.isRegression).count, 0,
                             "the naive gate must block here — otherwise the correction is pointless")
        XCTAssertEqual(corrected.results.filter(\.isRegression).count, 0,
                       "and BH must not")
    }

    // MARK: - Three states vs two

    /// The headline claim. On twelve samples per arm the evidence supports
    /// nothing, and the two-state gate is forced to call it a pass.
    func testATwoStateGateCertifiesDataThatSupportsNoConclusion() throws {
        let baseline = try XCTUnwrap(SliceCounts(sliceID: "en-US", passed: 10, total: 12))
        let candidate = try XCTUnwrap(SliceCounts(sliceID: "en-US", passed: 10, total: 12))

        XCTAssertTrue(naiveTwoStateVerdict(baseline: baseline, candidate: candidate),
                      "the two-state gate passes this build")

        let report = QualityGate.evaluate(
            baselineSlices: [baseline], baselineOverall: baseline,
            candidateSlices: [candidate], candidateOverall: candidate,
            judgeMatrix: AgreementMatrix(
                bothPass: 66, judgePassHumanFail: 4, judgeFailHumanPass: 3, bothFail: 27
            )
        )
        XCTAssertTrue(report.verdict.isInconclusive, "SignalGate must refuse to certify it")
        XCTAssertFalse(report.verdict.allowsMerge)
    }

    /// And the mirror case: the two-state gate blocks a build that is fine,
    /// because a two-sample wobble crossed its threshold.
    func testATwoStateGateBlocksABuildTheEvidenceDoesNotCondemn() throws {
        let baseline = try XCTUnwrap(SliceCounts(sliceID: "en-US", passed: 12, total: 12))
        let candidate = try XCTUnwrap(SliceCounts(sliceID: "en-US", passed: 10, total: 12))

        XCTAssertFalse(naiveTwoStateVerdict(baseline: baseline, candidate: candidate),
                       "the two-state gate blocks this build")

        let report = QualityGate.evaluate(
            baselineSlices: [baseline], baselineOverall: baseline,
            candidateSlices: [candidate], candidateOverall: candidate,
            judgeMatrix: AgreementMatrix(
                bothPass: 66, judgePassHumanFail: 4, judgeFailHumanPass: 3, bothFail: 27
            )
        )
        // Asserting the exact verdict, not merely "not block". `isBlock == false`
        // is also true of an implementation hardwired to return `.pass` — that
        // is, of exactly the two-state gate this file exists to discredit.
        guard case .inconclusive(let reason, _) = report.verdict else {
            return XCTFail("expected inconclusive, got \(report.verdict)")
        }
        XCTAssertEqual(reason, .insufficientEvidence)
        XCTAssertFalse(report.verdict.allowsMerge)
    }

    // MARK: - The judge precondition is load-bearing

    /// Feeds identical eval data through the gate twice, changing only the
    /// judge. If the judge check were removed, both runs would agree — so this
    /// asserts the check actually changes the outcome.
    func testRemovingTheJudgeChangesTheVerdictOnIdenticalEvalData() throws {
        let baseline = try XCTUnwrap(SliceCounts(sliceID: "en-US", passed: 1760, total: 2000))
        let candidate = try XCTUnwrap(SliceCounts(sliceID: "en-US", passed: 1760, total: 2000))

        let withJudge = QualityGate.evaluate(
            baselineSlices: [baseline], baselineOverall: baseline,
            candidateSlices: [candidate], candidateOverall: candidate,
            judgeMatrix: AgreementMatrix(
                bothPass: 66, judgePassHumanFail: 4, judgeFailHumanPass: 3, bothFail: 27
            )
        )
        let withoutJudge = QualityGate.evaluate(
            baselineSlices: [baseline], baselineOverall: baseline,
            candidateSlices: [candidate], candidateOverall: candidate,
            judgeMatrix: nil
        )

        XCTAssertEqual(withJudge.verdict, .pass)
        XCTAssertEqual(withoutJudge.verdict, .inconclusive(reason: .judgeUnavailable, additionalSamplesNeeded: nil))
        XCTAssertNotEqual(withJudge.verdict, withoutJudge.verdict)
    }

    // MARK: - Determinism of the scenario fixtures

    /// The bug this catches is specific and was live in this package during
    /// development: seeding the scenario generator from `rawValue.hashValue`.
    ///
    /// `String.hashValue` is salted per process, so a scenario keyed on it
    /// produces different data on every launch. Crucially, drawing twice
    /// *inside one process* and comparing would NOT catch that — the salt is
    /// constant within a process, so the naive "call it twice, assert equal"
    /// test passes while the property is false. The only test that catches it
    /// is one that compares against a value committed to the repository.
    func testScenarioDrawMatchesCommittedGoldenCounts() {
        let drawn = GateScenario.realRegression.draw(samplesPerArm: 60, seed: 20_260_818)
        let baselineTally = SliceCounts.tally(drawn.baseline)
        let candidateTally = SliceCounts.tally(drawn.candidate)

        XCTAssertEqual(baselineTally.overall.total, 60)
        XCTAssertEqual(candidateTally.overall.total, 60)
        XCTAssertEqual(baselineTally.overall.passed, GoldenCounts.realRegressionBaselinePassed60)
        XCTAssertEqual(candidateTally.overall.passed, GoldenCounts.realRegressionCandidatePassed60)
    }

    /// The draw must be *nested*: the run at n is a strict prefix of the run at
    /// any larger n. Without this the demo's slider models "run a different
    /// experiment at a different n" rather than "collect more samples", and the
    /// verdict visibly flickers as the slider moves.
    func testDrawsAreNestedSoLargerSamplesExtendSmallerOnes() {
        for scenario in GateScenario.allCases {
            let small = scenario.draw(samplesPerArm: 60)
            let large = scenario.draw(samplesPerArm: 600)
            for sliceID in GateScenario.sliceIDs {
                let smallSlice = small.baseline.filter { $0.sliceID == sliceID }.map(\.passed)
                let largeSlice = large.baseline.filter { $0.sliceID == sliceID }.map(\.passed)
                XCTAssertFalse(smallSlice.isEmpty, "\(scenario.rawValue)/\(sliceID)")
                XCTAssertLessThanOrEqual(smallSlice.count, largeSlice.count)
                XCTAssertEqual(Array(largeSlice.prefix(smallSlice.count)), smallSlice,
                               "\(scenario.rawValue)/\(sliceID) is not a prefix of the larger draw")
            }
        }
    }

    /// The draw must return exactly what was asked for, including when the
    /// count does not divide evenly across slices.
    func testDrawReturnsExactlyTheRequestedCountEvenWhenIndivisible() {
        for size in [25, 26, 61, 121, 1_001] {
            let drawn = GateScenario.equivalent.draw(samplesPerArm: size)
            XCTAssertEqual(drawn.baseline.count, size, "baseline at \(size)")
            XCTAssertEqual(drawn.candidate.count, size, "candidate at \(size)")
        }
    }

    func testEveryScenarioDrawsTheRequestedSampleCount() {
        for scenario in GateScenario.allCases {
            let drawn = scenario.draw(samplesPerArm: 120)
            XCTAssertEqual(drawn.baseline.count, 120, "\(scenario.rawValue)")
            XCTAssertEqual(drawn.candidate.count, 120, "\(scenario.rawValue)")
            XCTAssertEqual(Set(drawn.baseline.map(\.sliceID)).count, GateScenario.sliceIDs.count)
        }
    }

    /// The UI drives sample size from a slider; a zero or negative value must
    /// not produce an empty arm or trap in the integer division.
    func testScenarioDrawClampsDegenerateSampleSizes() {
        for size in [0, -1, Int.min] {
            let drawn = GateScenario.equivalent.draw(samplesPerArm: size)
            XCTAssertGreaterThan(drawn.baseline.count, 0, "size \(size)")
            XCTAssertGreaterThan(drawn.candidate.count, 0, "size \(size)")
        }
        let huge = GateScenario.equivalent.draw(samplesPerArm: Int.max)
        XCTAssertLessThanOrEqual(huge.baseline.count, 100_006)
    }
}

/// Values committed to the repository, not recomputed at test time.
///
/// Recomputing them inside the test would reimplement the thing under test,
/// which is the classic vacuous-test shape: it would pass against any
/// implementation, including a broken one.
enum GoldenCounts {
    /// `GateScenario.realRegression.draw(samplesPerArm: 60, seed: 20_260_818)`
    /// — baseline arm, observed pass count. Baseline rate is 0.88, candidate
    /// 0.76, so 53/60 vs 45/60 is the expected shape.
    static let realRegressionBaselinePassed60 = 52
    static let realRegressionCandidatePassed60 = 50
}
