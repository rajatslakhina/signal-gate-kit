import Foundation

/// Judge-vs-human agreement counts on a golden set.
///
/// `judgePass`/`humanPass` name the two raters explicitly rather than using
/// "predicted"/"actual", because which one is ground truth is the entire
/// question this type exists to answer.
public struct AgreementMatrix: Sendable, Hashable, Codable {
    /// Judge said pass, human said pass.
    public let bothPass: Int
    /// Judge said pass, human said fail. The dangerous cell: the judge is
    /// waving through output a human would have rejected.
    public let judgePassHumanFail: Int
    /// Judge said fail, human said pass.
    public let judgeFailHumanPass: Int
    /// Both said fail.
    public let bothFail: Int

    public init?(bothPass: Int, judgePassHumanFail: Int, judgeFailHumanPass: Int, bothFail: Int) {
        guard bothPass >= 0, judgePassHumanFail >= 0, judgeFailHumanPass >= 0, bothFail >= 0 else { return nil }
        self.bothPass = bothPass
        self.judgePassHumanFail = judgePassHumanFail
        self.judgeFailHumanPass = judgeFailHumanPass
        self.bothFail = bothFail
    }

    public var total: Int {
        SafeMath.add(SafeMath.add(bothPass, judgePassHumanFail),
                     SafeMath.add(judgeFailHumanPass, bothFail))
    }

    /// Cohen's κ. `nil` when undefined — notably when chance agreement is
    /// exactly 1, which happens if both raters pass everything. That case is
    /// not "perfect agreement worth trusting"; it is "this golden set contains
    /// no negatives and therefore cannot detect a lenient judge at all."
    public var cohensKappa: Double? {
        let n = Double(total)
        guard n > 0 else { return nil }

        guard let observedAgreement = SafeMath.divide(Double(SafeMath.add(bothPass, bothFail)), by: n) else {
            return nil
        }
        guard let judgePassRate = SafeMath.divide(Double(SafeMath.add(bothPass, judgePassHumanFail)), by: n),
              let humanPassRate = SafeMath.divide(Double(SafeMath.add(bothPass, judgeFailHumanPass)), by: n)
        else { return nil }

        let chanceAgreement = judgePassRate * humanPassRate + (1 - judgePassRate) * (1 - humanPassRate)
        let denominator = 1 - chanceAgreement
        // Guard the classic κ degenerate case rather than dividing by ~0 and
        // shipping a ±1e17 "agreement score" into a gate decision.
        guard denominator > 1e-12 else { return nil }
        guard let kappa = SafeMath.divide(observedAgreement - chanceAgreement, by: denominator) else { return nil }
        return kappa.isFinite ? kappa : nil
    }

    /// Judge pass rate minus human pass rate.
    ///
    /// Positive means the judge is more lenient than the humans it stands in
    /// for. This is the direction that quietly destroys a gate: a judge biased
    /// +0.08 makes every candidate look 8 points better than it is, so the gate
    /// keeps returning green while real quality drifts down underneath it.
    public var leniencyBias: Double? {
        let n = Double(total)
        guard n > 0 else { return nil }
        guard let judgePassRate = SafeMath.divide(Double(SafeMath.add(bothPass, judgePassHumanFail)), by: n),
              let humanPassRate = SafeMath.divide(Double(SafeMath.add(bothPass, judgeFailHumanPass)), by: n)
        else { return nil }
        return judgePassRate - humanPassRate
    }
}

/// Whether the judge may be used as a gating input at all.
public enum JudgeStatus: Sendable, Hashable, Codable {
    case calibrated(kappa: Double, leniencyBias: Double)
    case uncalibrated(reason: String)
    case unavailable

    public var isTrustworthy: Bool {
        if case .calibrated = self { return true }
        return false
    }
}

/// Thresholds a judge must clear before its verdicts are allowed to gate merges.
public struct JudgeCalibrationPolicy: Sendable, Hashable, Codable {
    /// Minimum Cohen's κ. 0.60 is the conventional floor for "substantial"
    /// agreement; below it, the judge and the humans are measuring
    /// meaningfully different things.
    public let minimumKappa: Double
    /// Maximum tolerated |leniency bias|.
    public let maximumAbsoluteBias: Double
    /// Minimum size of the human-labelled golden set. A κ computed from 12
    /// labels is itself a noisy estimate, and calibrating on noise is worse
    /// than not calibrating, because it comes with a number attached.
    public let minimumGoldenSetSize: Int

    public init(minimumKappa: Double = 0.60, maximumAbsoluteBias: Double = 0.05, minimumGoldenSetSize: Int = 50) {
        self.minimumKappa = minimumKappa
        self.maximumAbsoluteBias = maximumAbsoluteBias
        self.minimumGoldenSetSize = minimumGoldenSetSize
    }

    public static let standard = JudgeCalibrationPolicy()
}

public enum JudgeCalibration {

    /// Evaluates a judge against a human golden set.
    ///
    /// A `nil` matrix means the judge could not be reached, which returns
    /// `.unavailable` and — through `QualityGate` — an inconclusive verdict.
    /// The failure mode being designed against is specific: a PCC-backed judge
    /// times out, the harness records no judge scores, the mean over the
    /// remaining deterministic checks looks fine, and the gate goes green on a
    /// run where the thing it was supposed to measure never ran.
    public static func evaluate(
        matrix: AgreementMatrix?,
        policy: JudgeCalibrationPolicy = .standard
    ) -> JudgeStatus {
        guard let matrix else { return .unavailable }
        guard matrix.total >= policy.minimumGoldenSetSize else {
            return .uncalibrated(
                reason: "Golden set has \(matrix.total) labels; policy requires at least \(policy.minimumGoldenSetSize)."
            )
        }
        guard let kappa = matrix.cohensKappa else {
            return .uncalibrated(
                reason: "Cohen's kappa is undefined for this golden set — chance agreement is ~1, "
                    + "which usually means the set contains no negative examples."
            )
        }
        guard let bias = matrix.leniencyBias else {
            return .uncalibrated(reason: "Leniency bias is undefined for this golden set.")
        }
        guard kappa >= policy.minimumKappa else {
            return .uncalibrated(
                reason: String(
                    format: "Cohen's kappa %.3f is below the %.2f floor.",
                    kappa, policy.minimumKappa
                )
            )
        }
        guard Swift.abs(bias) <= policy.maximumAbsoluteBias else {
            return .uncalibrated(
                reason: String(
                    format: "Leniency bias %+.3f exceeds the %.2f tolerance (%@).",
                    bias, policy.maximumAbsoluteBias,
                    bias > 0 ? "judge is more lenient than humans" : "judge is stricter than humans"
                )
            )
        }
        return .calibrated(kappa: kappa, leniencyBias: bias)
    }
}
