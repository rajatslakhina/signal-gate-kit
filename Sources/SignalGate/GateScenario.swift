import Foundation

/// Deterministic pseudo-random generator, so a scenario at a given seed and
/// sample size produces byte-identical counts on every platform and every run.
///
/// SplitMix64. The `&*` and `&+` operators are *wrapping on purpose* —
/// modular arithmetic is the algorithm, not an overflow being tolerated. They
/// are the one place in this package where unchecked arithmetic is correct.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform double in `[0, 1)`. Uses the top 53 bits, which is exactly the
    /// mantissa width of a `Double`, so every representable value is reachable
    /// and none is over-represented.
    mutating func nextUnitDouble() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

/// A reproducible situation to run the gate against.
///
/// These are the cases that decide whether a quality gate is any good, and
/// every one of them is a case a naive point-estimate gate gets wrong.
public enum GateScenario: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// Candidate is genuinely equivalent to baseline. A correct gate passes;
    /// a naive one blocks whenever noise happens to land the wrong way.
    case equivalent
    /// Candidate is 2 points worse — inside the margin, and far inside the
    /// noise at realistic sample sizes. The gate must not block on this.
    case noiseNotRegression
    /// Candidate is 12 points worse. A real regression that must be caught.
    case realRegression
    /// The aggregate is flat, but one slice has collapsed. The case that
    /// justifies per-slice testing existing at all.
    case sliceOnlyRegression
    /// The judge is systematically more lenient than its human golden set, so
    /// nothing it reports can be trusted.
    case lenientJudge
    /// The judge could not be reached at all.
    case judgeOffline

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .equivalent: return "Equivalent build"
        case .noiseNotRegression: return "2-point wobble"
        case .realRegression: return "Real regression"
        case .sliceOnlyRegression: return "One slice collapsed"
        case .lenientJudge: return "Judge drifted lenient"
        case .judgeOffline: return "Judge offline"
        }
    }

    public var detail: String {
        switch self {
        case .equivalent:
            return "Candidate matches baseline. Passes once there is enough evidence to say so — though at "
                + "FDR q the slice family still produces the occasional false block, by design."
        case .noiseNotRegression:
            return "Candidate is 2 points lower — inside the 3-point margin. Blocking here is a false alarm."
        case .realRegression:
            return "Candidate is 12 points lower. Must block, and should block at a modest sample size."
        case .sliceOnlyRegression:
            return "Aggregate is flat; the `de-DE` slice dropped 30 points. Only per-slice testing sees it."
        case .lenientJudge:
            return "Judge passes 8 points more than its human golden set. Gate refuses to certify."
        case .judgeOffline:
            return "No judge verdicts at all. Gate must fail to inconclusive, never to pass."
        }
    }

    /// Slice identities used by every scenario, so runs stay comparable.
    public static let sliceIDs = ["en-US", "de-DE", "ja-JP", "pt-BR", "free-tier", "pro-tier"]

    /// A fixed per-scenario seed offset.
    ///
    /// Written out by hand rather than derived from `rawValue.hashValue`.
    /// `String.hashValue` is salted with a per-process random seed, so it
    /// returns a different value on every launch — a scenario keyed on it would
    /// silently produce different data each run, and the "reproducible fixture"
    /// property this type advertises would be false in exactly the way that is
    /// hardest to notice: locally it always looks fine, because you only ever
    /// compare within one process.
    var seedOffset: UInt64 {
        switch self {
        case .equivalent: return 1
        case .noiseNotRegression: return 2
        case .realRegression: return 3
        case .sliceOnlyRegression: return 4
        case .lenientJudge: return 5
        case .judgeOffline: return 6
        }
    }

    /// Baseline pass rate this scenario's candidate is measured against.
    public var baselineRate: Double { 0.88 }

    /// Candidate's overall pass rate.
    public var candidateRate: Double {
        switch self {
        case .equivalent, .lenientJudge, .judgeOffline: return 0.88
        case .noiseNotRegression: return 0.86
        case .realRegression: return 0.76
        case .sliceOnlyRegression: return 0.88
        }
    }

    /// Per-slice candidate rate. Only `sliceOnlyRegression` deviates.
    public func candidateRate(forSlice sliceID: String) -> Double {
        guard self == .sliceOnlyRegression else { return candidateRate }
        return sliceID == "de-DE" ? 0.58 : 0.94
    }

    public var judgeMatrix: AgreementMatrix? {
        switch self {
        case .judgeOffline:
            return nil
        case .lenientJudge:
            // Deliberately chosen so agreement is *good* (kappa ~0.75, well
            // above the 0.60 floor) and only the bias check catches it. A judge
            // that disagrees loudly is easy to spot; the dangerous one agrees
            // most of the time and is systematically generous at the margin.
            // Judge passes 65/100, humans 57/100 — bias +0.08.
            return AgreementMatrix(bothPass: 55, judgePassHumanFail: 10, judgeFailHumanPass: 2, bothFail: 33)
        default:
            // kappa 0.835, bias +0.010 — comfortably inside the standard policy.
            // (Verified in JudgeCalibrationTests, not eyeballed.)
            return AgreementMatrix(bothPass: 66, judgePassHumanFail: 4, judgeFailHumanPass: 3, bothFail: 27)
        }
    }

    /// Draws a reproducible run at the given per-arm sample size.
    ///
    /// ## Why the draw is nested
    ///
    /// Each slice gets its **own** generator, seeded independently of the
    /// sample size, and the run at size *n* is a strict prefix of the run at
    /// any larger size. That property is what makes the demo's slider mean
    /// "collect more samples" rather than "run a different experiment at a
    /// different n."
    ///
    /// The distinction is not cosmetic. With a single shared generator whose
    /// stream position depends on `perSlice`, every slice past the first
    /// shifts phase as soon as `n` changes, so consecutive slider positions
    /// draw unrelated datasets. The verdict then flickers — block, inconclusive,
    /// block — as `n` increases, which is the exact opposite of the argument
    /// the demo is making, and it is a genuinely misleading thing to show
    /// someone. Nested draws make the interval narrow monotonically in the way
    /// the statistics say it should.
    ///
    /// `samplesPerArm` is clamped into `1...60_000`: the UI drives it from a
    /// slider, and a zero or negative value would otherwise produce an empty
    /// arm that the gate correctly but uninformatively reports as `.noSamples`.
    public func draw(samplesPerArm: Int, seed: UInt64 = 20_260_818) -> (baseline: [EvalSample], candidate: [EvalSample]) {
        let perArm = Swift.min(60_000, Swift.max(1, samplesPerArm))
        let sliceCount = Swift.max(1, GateScenario.sliceIDs.count)

        var baseline: [EvalSample] = []
        var candidate: [EvalSample] = []
        baseline.reserveCapacity(perArm)
        candidate.reserveCapacity(perArm)

        for sliceIndex in 0..<sliceCount {
            guard let sliceID = SafeMath.element(GateScenario.sliceIDs, at: sliceIndex) else { continue }
            let candidateSliceRate = candidateRate(forSlice: sliceID)

            // The remainder is distributed across the leading slices so the
            // arms total exactly `perArm`, rather than silently returning fewer
            // samples than the caller asked for. Integer division and modulo
            // are both safe here: `sliceCount` is at least 1 by construction.
            let base = perArm / sliceCount
            let remainder = perArm % sliceCount
            let perSlice = base + (sliceIndex < remainder ? 1 : 0)
            guard perSlice > 0 else { continue }

            // Seeded per slice and independent of `perArm`, so the sequence for
            // this slice is identical at every sample size and shorter runs are
            // prefixes of longer ones.
            var generator = SplitMix64(seed: seed &+ seedOffset &* 1_000 &+ UInt64(sliceIndex))

            for index in 0..<perSlice {
                baseline.append(
                    EvalSample(
                        caseID: "\(sliceID)-b\(index)",
                        sliceID: sliceID,
                        passed: generator.nextUnitDouble() < baselineRate
                    )
                )
                candidate.append(
                    EvalSample(
                        caseID: "\(sliceID)-c\(index)",
                        sliceID: sliceID,
                        passed: generator.nextUnitDouble() < candidateSliceRate
                    )
                )
            }
        }
        return (baseline, candidate)
    }

    /// Runs the full gate for this scenario at a given sample size.
    public func evaluate(
        samplesPerArm: Int,
        policy: GatePolicy = .standard,
        budget: BudgetState? = nil,
        seed: UInt64 = 20_260_818
    ) -> GateReport {
        let drawn = draw(samplesPerArm: samplesPerArm, seed: seed)
        return QualityGate.evaluate(
            baseline: drawn.baseline,
            candidate: drawn.candidate,
            judgeMatrix: judgeMatrix,
            budget: budget,
            policy: policy
        )
    }
}
