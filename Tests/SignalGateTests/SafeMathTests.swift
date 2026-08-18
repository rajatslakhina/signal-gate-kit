import XCTest
@testable import SignalGate

/// These test the exact operations that trap in Swift. Each one is written
/// against a value that would crash the process if the guard were removed —
/// the assertion is really "this line executed at all."
final class SafeMathTests: XCTestCase {

    func testIntConversionSurvivesNaNAndInfinities() {
        XCTAssertEqual(SafeMath.intClamping(.nan), 0)
        XCTAssertEqual(SafeMath.intClamping(.infinity), .max)
        XCTAssertEqual(SafeMath.intClamping(-.infinity), .min)
    }

    func testIntConversionClampsOutOfRangeDoubles() {
        // 1e300 is far outside Int's range; `Int(1e300)` traps.
        XCTAssertEqual(SafeMath.intClamping(1e300), .max)
        XCTAssertEqual(SafeMath.intClamping(-1e300), .min)
        XCTAssertEqual(SafeMath.intClamping(42.9), 42)
        XCTAssertEqual(SafeMath.intClamping(-42.9), -42)
    }

    func testCeilingClampingRoundsUpAndSurvivesNonFinite() {
        XCTAssertEqual(SafeMath.ceilingClamping(42.1), 43)
        XCTAssertEqual(SafeMath.ceilingClamping(43.0), 43)
        XCTAssertEqual(SafeMath.ceilingClamping(.nan), 0)
        XCTAssertEqual(SafeMath.ceilingClamping(.infinity), .max)
        XCTAssertEqual(SafeMath.ceilingClamping(1e300), .max)
    }

    func testDivisionByZeroReturnsNilRatherThanInfinity() {
        XCTAssertNil(SafeMath.divide(1.0, by: 0.0))
        XCTAssertNil(SafeMath.divide(0.0, by: 0.0))
        XCTAssertNil(SafeMath.divide(1.0, by: .nan))
        XCTAssertEqual(SafeMath.divide(1.0, by: 4.0), 0.25)
    }

    func testIntegerDivisionGuardsTheOneOverflowingCase() {
        // Int.min / -1 overflows two's complement and traps.
        XCTAssertNil(SafeMath.divide(Int.min, by: -1))
        XCTAssertNil(SafeMath.divide(7, by: 0))
        XCTAssertEqual(SafeMath.divide(7, by: 2), 3)
    }

    func testAdditionSaturatesInBothDirections() {
        XCTAssertEqual(SafeMath.add(.max, 1), .max)
        XCTAssertEqual(SafeMath.add(.min, -1), .min)
        XCTAssertEqual(SafeMath.add(2, 3), 5)
    }

    func testMultiplicationSaturatesWithCorrectSign() {
        XCTAssertEqual(SafeMath.multiply(.max, 2), .max)
        XCTAssertEqual(SafeMath.multiply(.max, -2), .min)
        XCTAssertEqual(SafeMath.multiply(.min, 2), .min)
        XCTAssertEqual(SafeMath.multiply(6, 7), 42)
    }

    func testSqrtClampsSmallNegativesInsteadOfReturningNaN() {
        // Catastrophic cancellation in a variance expression lands here.
        XCTAssertEqual(SafeMath.sqrtClampingNegative(-1e-18), 0)
        XCTAssertEqual(SafeMath.sqrtClampingNegative(0), 0)
        XCTAssertEqual(SafeMath.sqrtClampingNegative(9), 3, accuracy: 1e-12)
        // Exact values, not merely "not NaN" — the weaker assertion is also
        // satisfied by a function returning infinity or a negative number.
        XCTAssertEqual(SafeMath.sqrtClampingNegative(.nan), 0)
        XCTAssertEqual(SafeMath.sqrtClampingNegative(-.infinity), 0,
                       "sqrt of -infinity is not a real number; must not become +infinity")
        XCTAssertEqual(SafeMath.sqrtClampingNegative(.infinity), .infinity)
    }

    func testLogNeverReturnsNegativeInfinity() {
        XCTAssertTrue(SafeMath.logClampingNonPositive(0).isFinite)
        XCTAssertTrue(SafeMath.logClampingNonPositive(-5).isFinite)
        XCTAssertEqual(SafeMath.logClampingNonPositive(1), 0, accuracy: 1e-12)
        XCTAssertEqual(SafeMath.logClampingNonPositive(-.infinity), 0,
                       "log of -infinity is undefined; must not become +infinity")
        XCTAssertEqual(SafeMath.logClampingNonPositive(.nan), 0)
    }

    func testBoundsCheckedElementAccess() {
        let values = [10, 20, 30]
        XCTAssertEqual(SafeMath.element(values, at: 0), 10)
        XCTAssertEqual(SafeMath.element(values, at: 2), 30)
        XCTAssertNil(SafeMath.element(values, at: 3))
        XCTAssertNil(SafeMath.element(values, at: -1))
        XCTAssertNil(SafeMath.element([Int](), at: 0))
    }

    func testClampProbabilityRejectsNaNAndBoundsTheRest() {
        XCTAssertNil(SafeMath.clampProbability(.nan))
        XCTAssertEqual(SafeMath.clampProbability(-0.2), 0)
        XCTAssertEqual(SafeMath.clampProbability(1.7), 1)
        XCTAssertEqual(SafeMath.clampProbability(0.4), 0.4)
    }

    /// The `Int` range constants must be derived from `Int.max`/`Int.min`, not
    /// hardcoded 64-bit literals — `Int` is 32-bit on watchOS.
    func testIntBoundsTrackTheActualPlatformIntWidth() {
        XCTAssertEqual(SafeMath.intUpperBoundAsDouble, Double(Int.max))
        XCTAssertEqual(SafeMath.intLowerBoundAsDouble, Double(Int.min))
    }
}
