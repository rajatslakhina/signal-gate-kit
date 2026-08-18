import XCTest
@testable import SignalGate

final class MultipleComparisonsTests: XCTestCase {

    /// The number the README leads with. 12 slices at α = 0.05, uncorrected,
    /// false-alarms 46% of the time.
    func testFamilyWiseErrorRateMatchesTheHeadlineNumber() {
        guard let rate = MultipleComparisons.familyWiseErrorRate(testCount: 12, alpha: 0.05) else {
            return XCTFail("nil rate")
        }
        XCTAssertEqual(rate, 0.4596, accuracy: 1e-4)
    }

    func testFamilyWiseErrorRateEdgeCases() throws {
        XCTAssertEqual(MultipleComparisons.familyWiseErrorRate(testCount: 0, alpha: 0.05), 0)
        let single = try XCTUnwrap(MultipleComparisons.familyWiseErrorRate(testCount: 1, alpha: 0.05))
        XCTAssertEqual(single, 0.05, accuracy: 1e-12)
        XCTAssertNil(MultipleComparisons.familyWiseErrorRate(testCount: -1, alpha: 0.05))
        XCTAssertNil(MultipleComparisons.familyWiseErrorRate(testCount: 5, alpha: .nan))
        XCTAssertNil(MultipleComparisons.familyWiseErrorRate(testCount: 5, alpha: 1.5))
    }

    /// The whole point of correcting. A family of twelve true nulls where one
    /// p-value happens to land at 0.03: the uncorrected gate blocks the merge,
    /// BH does not.
    func testBenjaminiHochbergSuppressesAnIsolatedLuckyPValue() {
        var tests = [SliceTest(sliceID: "slice-00", pValue: 0.03)]
        for index in 1..<12 {
            tests.append(SliceTest(sliceID: String(format: "slice-%02d", index), pValue: 0.40 + Double(index) * 0.04))
        }

        let uncorrected = MultipleComparisons.uncorrected(tests: tests, alpha: 0.05)
        XCTAssertEqual(uncorrected.filter(\.isRegression).count, 1,
                       "Precondition: the naive gate does flag this family")

        let corrected = MultipleComparisons.benjaminiHochberg(tests: tests, falseDiscoveryRate: 0.05)
        XCTAssertEqual(corrected.results.filter(\.isRegression).count, 0,
                       "BH must not reject a single p=0.03 out of 12 tests")
        XCTAssertTrue(corrected.discarded.isEmpty)
    }

    /// Correction must not be so aggressive that a genuine, concentrated
    /// regression stops being detectable — otherwise the fix is worse than the
    /// bug.
    func testBenjaminiHochbergStillRejectsAStrongSignal() {
        var tests = [
            SliceTest(sliceID: "slice-00", pValue: 0.0001),
            SliceTest(sliceID: "slice-01", pValue: 0.0004),
        ]
        for index in 2..<12 {
            tests.append(SliceTest(sliceID: String(format: "slice-%02d", index), pValue: 0.50))
        }
        let corrected = MultipleComparisons.benjaminiHochberg(tests: tests, falseDiscoveryRate: 0.05)
        let rejected = Set(corrected.results.filter(\.isRegression).map(\.sliceID))
        XCTAssertEqual(rejected, ["slice-00", "slice-01"])
    }

    /// Step-up, not per-test thresholding: once rank *k* is rejected, every
    /// rank below it is too, even if some of those p-values individually exceed
    /// their own threshold.
    func testProcedureIsStepUpNotPerTestThresholding() {
        let tests = [
            SliceTest(sliceID: "a", pValue: 0.001),
            SliceTest(sliceID: "b", pValue: 0.030),
            SliceTest(sliceID: "c", pValue: 0.031),
            SliceTest(sliceID: "d", pValue: 0.032),
            SliceTest(sliceID: "e", pValue: 0.040),
        ]
        let corrected = MultipleComparisons.benjaminiHochberg(tests: tests, falseDiscoveryRate: 0.05)
        // p(5)=0.040 <= (5/5)*0.05 = 0.05, so rank 5 is rejected and therefore
        // all five are — including rank 2 (0.030), whose own threshold is 0.02.
        XCTAssertEqual(corrected.results.filter(\.isRegression).count, 5)
        guard let rankTwo = corrected.results.first(where: { $0.sliceID == "b" }) else {
            return XCTFail("missing slice b")
        }
        XCTAssertGreaterThan(rankTwo.rawPValue, (2.0 / 5.0) * 0.05)
        XCTAssertTrue(rankTwo.isRegression)
    }

    func testAdjustedPValuesAreMonotoneNonDecreasing() {
        let tests = (0..<20).map {
            SliceTest(sliceID: String(format: "s%02d", $0), pValue: Double($0) * 0.045 + 0.001)
        }
        let corrected = MultipleComparisons.benjaminiHochberg(tests: tests)
        var previous = -Double.infinity
        for result in corrected.results {
            XCTAssertGreaterThanOrEqual(result.adjustedPValue, previous,
                                        "adjusted p-values must not decrease with rank")
            XCTAssertGreaterThanOrEqual(result.adjustedPValue, result.rawPValue,
                                        "adjustment must never shrink a p-value")
            XCTAssertLessThanOrEqual(result.adjustedPValue, 1)
            previous = result.adjustedPValue
        }
    }

    /// Malformed p-values must be reported, not coerced. Coercing a `NaN` to
    /// 1.0 would keep it in the family, changing `m` and shifting every
    /// threshold for every other slice.
    func testMalformedPValuesAreDiscardedRatherThanCoerced() {
        let tests = [
            SliceTest(sliceID: "good", pValue: 0.01),
            SliceTest(sliceID: "nan", pValue: .nan),
            SliceTest(sliceID: "high", pValue: 1.4),
            SliceTest(sliceID: "negative", pValue: -0.1),
            SliceTest(sliceID: "infinite", pValue: .infinity),
        ]
        let corrected = MultipleComparisons.benjaminiHochberg(tests: tests)
        XCTAssertEqual(corrected.results.count, 1)
        XCTAssertEqual(Set(corrected.discarded), ["nan", "high", "negative", "infinite"])
    }

    func testEmptyAndInvalidFamilies() {
        let empty = MultipleComparisons.benjaminiHochberg(tests: [])
        XCTAssertTrue(empty.results.isEmpty)
        XCTAssertTrue(empty.discarded.isEmpty)

        let badRate = MultipleComparisons.benjaminiHochberg(
            tests: [SliceTest(sliceID: "a", pValue: 0.01)], falseDiscoveryRate: 0
        )
        XCTAssertTrue(badRate.results.isEmpty)
        XCTAssertEqual(badRate.discarded, ["a"])
    }

    /// Output order must not depend on input order or on `Dictionary`'s
    /// per-process hash seed, or a report diff between two runs is unreadable.
    func testOutputOrderingIsDeterministicUnderInputPermutation() {
        let tests = [
            SliceTest(sliceID: "zulu", pValue: 0.02),
            SliceTest(sliceID: "alpha", pValue: 0.02),
            SliceTest(sliceID: "mike", pValue: 0.01),
        ]
        let forward = MultipleComparisons.benjaminiHochberg(tests: tests).results.map(\.sliceID)
        let reversed = MultipleComparisons.benjaminiHochberg(tests: tests.reversed()).results.map(\.sliceID)
        XCTAssertEqual(forward, reversed)
        // Ties broken by sliceID, so "alpha" precedes "zulu" at equal p.
        XCTAssertEqual(forward, ["mike", "alpha", "zulu"])
    }
}
