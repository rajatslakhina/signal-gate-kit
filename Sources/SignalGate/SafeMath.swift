import Foundation

/// Arithmetic that saturates or reports failure instead of trapping.
///
/// Every function in this package that touches floating point routes through
/// here. The reason is narrow and specific: a merge gate runs unattended in CI,
/// and the inputs it receives are pass-rates and score means computed upstream
/// from model output. Those inputs *will* eventually contain a `NaN` (0/0 from
/// an empty slice), an infinity (a runaway latency measurement), or a value
/// outside `Int`'s range. `Int(someDouble)` traps on all three, and a trap in a
/// merge gate is an outage in everyone's pipeline, not a failed test.
public enum SafeMath {

    // MARK: - Int conversion

    /// The `Int` range expressed as `Double`, derived from `Int.max`/`Int.min`
    /// rather than hardcoded 64-bit literals — `Int` is 32-bit on watchOS, and a
    /// hardcoded `9.22e18` ceiling would silently be wrong there.
    ///
    /// Note `Double(Int.max)` rounds *up* to 2^63 on 64-bit platforms, so it is
    /// one ulp above the true maximum; comparing with `>=` handles that.
    public static let intUpperBoundAsDouble = Double(Int.max)
    public static let intLowerBoundAsDouble = Double(Int.min)

    /// `Int(_:)` conversion that clamps instead of trapping.
    ///
    /// - `NaN` maps to 0. There is no defensible integer for "not a number", and
    ///   0 is the value that makes downstream sample-count arithmetic degenerate
    ///   safely (a request for 0 more samples is a no-op, not a hang).
    public static func intClamping(_ value: Double) -> Int {
        if value.isNaN { return 0 }
        if value >= intUpperBoundAsDouble { return .max }
        if value <= intLowerBoundAsDouble { return .min }
        return Int(value)
    }

    /// Rounds up, then clamps. Used for sample-size requirements, where
    /// rounding down would under-power the test.
    public static func ceilingClamping(_ value: Double) -> Int {
        guard value.isFinite else {
            return value.isNaN ? 0 : (value > 0 ? .max : .min)
        }
        return intClamping(value.rounded(.up))
    }

    // MARK: - Division

    /// Division that returns `nil` rather than `inf`/`NaN` on a zero or
    /// non-finite denominator. Callers must decide what a missing quotient
    /// means; this package always maps it to `.inconclusive`, never to `.pass`.
    public static func divide(_ numerator: Double, by denominator: Double) -> Double? {
        guard denominator.isFinite, denominator != 0, numerator.isFinite else { return nil }
        let result = numerator / denominator
        return result.isFinite ? result : nil
    }

    /// Integer division guarding both division-by-zero and the single
    /// overflowing case in two's complement: `Int.min / -1`.
    public static func divide(_ numerator: Int, by denominator: Int) -> Int? {
        guard denominator != 0 else { return nil }
        guard !(numerator == Int.min && denominator == -1) else { return nil }
        return numerator / denominator
    }

    // MARK: - Saturating integer arithmetic

    public static func add(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard overflow else { return sum }
        return (b > 0) ? .max : .min
    }

    public static func multiply(_ a: Int, _ b: Int) -> Int {
        let (product, overflow) = a.multipliedReportingOverflow(by: b)
        guard overflow else { return product }
        // Sign of the true product decides which rail we saturate to.
        return ((a > 0) == (b > 0)) ? .max : .min
    }

    // MARK: - Transcendental guards

    /// `sqrt` of a value clamped at zero.
    ///
    /// Variance expressions in this package are non-negative in exact
    /// arithmetic but can land a few ulp below zero after catastrophic
    /// cancellation. `sqrt(-1e-18)` is `NaN`, which would then propagate
    /// silently through an interval and out into a gate decision.
    public static func sqrtClampingNegative(_ value: Double) -> Double {
        // `-infinity` returns 0, not `+infinity`: the square root of a negative
        // number is not a real number, and the contract of this function is
        // that it never emits a non-finite value.
        guard value.isFinite else { return value == .infinity ? .infinity : 0 }
        return value <= 0 ? 0 : value.squareRoot()
    }

    /// Natural log with the argument clamped to a small positive number, so
    /// `log(0)` cannot produce `-infinity` and poison a confidence radius.
    public static func logClampingNonPositive(_ value: Double) -> Double {
        // As with `sqrtClampingNegative`, `-infinity` maps to 0 rather than
        // propagating a non-finite value the caller cannot use.
        guard value.isFinite else { return value == .infinity ? .infinity : 0 }
        let floorValue = Double.leastNormalMagnitude
        return log(Swift.max(value, floorValue))
    }

    // MARK: - Range helpers

    /// Clamps a probability into `[0, 1]`, mapping `NaN` to `nil`.
    public static func clampProbability(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return Swift.min(1.0, Swift.max(0.0, value))
    }

    /// Bounds-checked element access. Reads throughout this package go through
    /// this rather than `array[i]`.
    public static func element<C: Collection>(_ collection: C, at offset: Int) -> C.Element?
    where C.Index == Int {
        guard offset >= 0, offset < collection.count else { return nil }
        let index = collection.startIndex + offset
        guard index < collection.endIndex else { return nil }
        return collection[index]
    }
}
