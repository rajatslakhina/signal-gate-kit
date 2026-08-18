import XCTest
@testable import SignalGate

final class JudgeCalibrationTests: XCTestCase {

    func testCohensKappaMatchesAHandComputedValue() {
        // 45/5/10/40 of 100. po = 0.85.
        // judge pass = 0.50, human pass = 0.55
        // pe = 0.50*0.55 + 0.50*0.45 = 0.275 + 0.225 = 0.50
        // kappa = (0.85 - 0.50) / (1 - 0.50) = 0.70
        guard let matrix = AgreementMatrix(
            bothPass: 45, judgePassHumanFail: 5, judgeFailHumanPass: 10, bothFail: 40
        ) else { return XCTFail("bad fixture") }
        XCTAssertEqual(matrix.total, 100)
        guard let kappa = matrix.cohensKappa else { return XCTFail("nil kappa") }
        XCTAssertEqual(kappa, 0.70, accuracy: 1e-9)
    }

    func testLeniencyBiasSignPointsAtTheJudge() {
        guard let lenient = AgreementMatrix(
            bothPass: 62, judgePassHumanFail: 16, judgeFailHumanPass: 2, bothFail: 20
        ) else { return XCTFail("bad fixture") }
        guard let bias = lenient.leniencyBias else { return XCTFail("nil bias") }
        // judge pass 78/100, human pass 64/100.
        XCTAssertEqual(bias, 0.14, accuracy: 1e-12)
        XCTAssertGreaterThan(bias, 0, "positive means the judge is more lenient")
    }

    /// The degenerate case that would divide by ~0. A golden set with no
    /// negatives cannot detect a lenient judge, and reporting κ = 1 there would
    /// be actively misleading.
    func testKappaIsNilWhenChanceAgreementIsOne() {
        guard let allPass = AgreementMatrix(
            bothPass: 100, judgePassHumanFail: 0, judgeFailHumanPass: 0, bothFail: 0
        ) else { return XCTFail("bad fixture") }
        XCTAssertNil(allPass.cohensKappa)

        guard let allFail = AgreementMatrix(
            bothPass: 0, judgePassHumanFail: 0, judgeFailHumanPass: 0, bothFail: 100
        ) else { return XCTFail("bad fixture") }
        XCTAssertNil(allFail.cohensKappa)
    }

    func testEmptyMatrixHasNoStatistics() {
        guard let empty = AgreementMatrix(
            bothPass: 0, judgePassHumanFail: 0, judgeFailHumanPass: 0, bothFail: 0
        ) else { return XCTFail("bad fixture") }
        XCTAssertEqual(empty.total, 0)
        XCTAssertNil(empty.cohensKappa)
        XCTAssertNil(empty.leniencyBias)
    }

    func testMatrixRejectsNegativeCounts() {
        XCTAssertNil(AgreementMatrix(bothPass: -1, judgePassHumanFail: 0, judgeFailHumanPass: 0, bothFail: 0))
        XCTAssertNil(AgreementMatrix(bothPass: 0, judgePassHumanFail: 0, judgeFailHumanPass: -5, bothFail: 0))
    }

    // MARK: - Policy

    func testAMissingMatrixIsUnavailableNotUncalibrated() {
        // The distinction matters operationally: unavailable is an incident,
        // uncalibrated is an eval-infra bug.
        XCTAssertEqual(JudgeCalibration.evaluate(matrix: nil), .unavailable)
        XCTAssertFalse(JudgeCalibration.evaluate(matrix: nil).isTrustworthy)
    }

    func testAWellBehavedJudgeIsCalibrated() {
        guard let matrix = AgreementMatrix(
            bothPass: 66, judgePassHumanFail: 4, judgeFailHumanPass: 3, bothFail: 27
        ) else { return XCTFail("bad fixture") }
        let status = JudgeCalibration.evaluate(matrix: matrix)
        guard case .calibrated(let kappa, let bias) = status else {
            return XCTFail("expected calibrated, got \(status)")
        }
        XCTAssertGreaterThan(kappa, 0.60)
        XCTAssertLessThanOrEqual(abs(bias), 0.05)
        XCTAssertTrue(status.isTrustworthy)
    }

    /// The dangerous judge is not the one that disagrees loudly — that one is
    /// obvious. It is the one whose agreement looks *good* (kappa 0.75, well
    /// above the floor) while being systematically generous at the margin.
    /// This fixture is chosen so only the bias check can catch it.
    func testALenientJudgeFailsOnBiasEvenWithGoodAgreement() throws {
        let matrix = try XCTUnwrap(AgreementMatrix(
            bothPass: 55, judgePassHumanFail: 10, judgeFailHumanPass: 2, bothFail: 33
        ))
        let kappa = try XCTUnwrap(matrix.cohensKappa)
        let bias = try XCTUnwrap(matrix.leniencyBias)
        XCTAssertGreaterThan(kappa, 0.60, "precondition: agreement clears the floor")
        XCTAssertEqual(bias, 0.08, accuracy: 1e-12)

        let status = JudgeCalibration.evaluate(matrix: matrix)
        guard case .uncalibrated(let reason) = status else {
            return XCTFail("expected uncalibrated, got \(status)")
        }
        XCTAssertTrue(reason.contains("lenient"), "reason should name the direction: \(reason)")
        XCTAssertFalse(status.isTrustworthy)
    }

    func testASmallGoldenSetIsRejectedBeforeKappaIsEvenComputed() {
        // 12 labels with perfect agreement. Kappa would look excellent; the
        // point is that a kappa estimated from 12 labels is itself noise.
        guard let matrix = AgreementMatrix(
            bothPass: 6, judgePassHumanFail: 0, judgeFailHumanPass: 0, bothFail: 6
        ) else { return XCTFail("bad fixture") }
        let status = JudgeCalibration.evaluate(matrix: matrix)
        guard case .uncalibrated(let reason) = status else {
            return XCTFail("expected uncalibrated, got \(status)")
        }
        XCTAssertTrue(reason.contains("12"), reason)
    }

    func testLowAgreementFailsCalibration() {
        // Near-chance agreement with a balanced golden set.
        guard let matrix = AgreementMatrix(
            bothPass: 30, judgePassHumanFail: 25, judgeFailHumanPass: 25, bothFail: 20
        ) else { return XCTFail("bad fixture") }
        let status = JudgeCalibration.evaluate(matrix: matrix)
        guard case .uncalibrated(let reason) = status else {
            return XCTFail("expected uncalibrated, got \(status)")
        }
        XCTAssertTrue(reason.contains("kappa"), reason)
    }

    func testPolicyThresholdsAreActuallyConsulted() {
        guard let matrix = AgreementMatrix(
            bothPass: 45, judgePassHumanFail: 5, judgeFailHumanPass: 10, bothFail: 40
        ) else { return XCTFail("bad fixture") }
        // kappa is 0.70 and bias is -0.05.
        XCTAssertTrue(JudgeCalibration.evaluate(
            matrix: matrix,
            policy: JudgeCalibrationPolicy(minimumKappa: 0.60, maximumAbsoluteBias: 0.06, minimumGoldenSetSize: 50)
        ).isTrustworthy)
        XCTAssertFalse(JudgeCalibration.evaluate(
            matrix: matrix,
            policy: JudgeCalibrationPolicy(minimumKappa: 0.75, maximumAbsoluteBias: 0.06, minimumGoldenSetSize: 50)
        ).isTrustworthy)
        XCTAssertFalse(JudgeCalibration.evaluate(
            matrix: matrix,
            policy: JudgeCalibrationPolicy(minimumKappa: 0.60, maximumAbsoluteBias: 0.06, minimumGoldenSetSize: 200)
        ).isTrustworthy)
    }
}
