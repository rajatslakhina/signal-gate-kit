import Foundation

/// Ceilings on what one gate evaluation is allowed to consume.
///
/// This exists because a probabilistic gate inverts the economics of CI. In a
/// deterministic suite a test costs microseconds and running more of them is
/// free, so nobody budgets. Here every "test" is an inference call with a
/// dollar cost and a second of latency, and the statistically correct answer to
/// "is this a real regression?" is frequently "collect 400 more samples." Left
/// uncapped, the honest statistical procedure is also the one that bankrupts
/// the CI budget.
public struct EvalBudgetPolicy: Sendable, Hashable, Codable {
    public let maximumSpendUSD: Double
    public let maximumWallClockSeconds: Double
    public let maximumInferenceCalls: Int

    /// Returns `nil` for non-positive or non-finite ceilings — a zero budget is
    /// almost always a misconfiguration, and it would make every gate run
    /// return `.budgetExhausted` before collecting a single sample.
    public init?(maximumSpendUSD: Double, maximumWallClockSeconds: Double, maximumInferenceCalls: Int) {
        guard maximumSpendUSD.isFinite, maximumSpendUSD > 0,
              maximumWallClockSeconds.isFinite, maximumWallClockSeconds > 0,
              maximumInferenceCalls > 0 else { return nil }
        self.maximumSpendUSD = maximumSpendUSD
        self.maximumWallClockSeconds = maximumWallClockSeconds
        self.maximumInferenceCalls = maximumInferenceCalls
    }
}

/// A point-in-time view of budget consumption.
public struct BudgetState: Sendable, Hashable, Codable {
    public let spentUSD: Double
    public let elapsedSeconds: Double
    public let inferenceCalls: Int
    public let isExhausted: Bool
    /// Which ceiling was hit first, for the CI log. `nil` while healthy.
    public let exhaustedBy: String?

    /// Fraction of the tightest budget consumed, in `[0, 1]`.
    public let utilization: Double
}

/// Tracks spend across an evaluation run and refuses to let it overrun.
///
/// ## Concurrency note
///
/// No method on this actor contains an `await`. That is a deliberate design
/// constraint, not an accident of the current implementation, and it is the
/// property that makes the ledger correct under concurrent callers.
///
/// An actor guarantees exclusive access only *between* suspension points. If
/// `charge` awaited anything mid-update — a pricing lookup, a log write — then
/// two tasks could each read `spentUSD` at 0.95 of the cap, each await, and
/// each then commit a charge, ending at 1.9× budget with both callers having
/// been told they were within it. Keeping the read-modify-write in a single
/// synchronous body makes that unrepresentable. Any future change that needs
/// async work must do it *before* calling `charge`, and pass the result in.
public actor EvalBudgetLedger {
    private let policy: EvalBudgetPolicy
    private var spentUSD: Double = 0
    private var elapsedSeconds: Double = 0
    private var inferenceCalls: Int = 0

    public init(policy: EvalBudgetPolicy) {
        self.policy = policy
    }

    /// Records consumption and returns the resulting state.
    ///
    /// Non-finite or negative inputs are ignored rather than accumulated: a
    /// `NaN` latency reading from a timed-out call would otherwise make
    /// `elapsedSeconds` permanently `NaN`, and every subsequent comparison
    /// against the ceiling would evaluate false — an exhausted budget that
    /// reports itself healthy forever.
    @discardableResult
    public func charge(costUSD: Double, latencySeconds: Double, calls: Int = 1) -> BudgetState {
        if costUSD.isFinite, costUSD > 0 {
            let updated = spentUSD + costUSD
            spentUSD = updated.isFinite ? updated : policy.maximumSpendUSD
        }
        if latencySeconds.isFinite, latencySeconds > 0 {
            let updated = elapsedSeconds + latencySeconds
            elapsedSeconds = updated.isFinite ? updated : policy.maximumWallClockSeconds
        }
        if calls > 0 {
            inferenceCalls = SafeMath.add(inferenceCalls, calls)
        }
        return currentState()
    }

    public func state() -> BudgetState {
        currentState()
    }

    /// Whether another sample can be afforded at the given estimated cost.
    public func canAfford(estimatedCostUSD: Double, estimatedLatencySeconds: Double) -> Bool {
        guard !currentState().isExhausted else { return false }
        let projectedSpend = spentUSD + (estimatedCostUSD.isFinite && estimatedCostUSD > 0 ? estimatedCostUSD : 0)
        let projectedTime = elapsedSeconds
            + (estimatedLatencySeconds.isFinite && estimatedLatencySeconds > 0 ? estimatedLatencySeconds : 0)
        return projectedSpend <= policy.maximumSpendUSD
            && projectedTime <= policy.maximumWallClockSeconds
            && SafeMath.add(inferenceCalls, 1) <= policy.maximumInferenceCalls
    }

    private func currentState() -> BudgetState {
        let spendFraction = SafeMath.divide(spentUSD, by: policy.maximumSpendUSD) ?? 1
        let timeFraction = SafeMath.divide(elapsedSeconds, by: policy.maximumWallClockSeconds) ?? 1
        let callFraction = SafeMath.divide(Double(inferenceCalls), by: Double(policy.maximumInferenceCalls)) ?? 1

        var exhaustedBy: String?
        // Ordered so the message names the ceiling that is actually binding.
        if spendFraction >= 1 {
            exhaustedBy = "spend"
        } else if timeFraction >= 1 {
            exhaustedBy = "wall-clock"
        } else if callFraction >= 1 {
            exhaustedBy = "inference-calls"
        }

        let utilization = SafeMath.clampProbability(
            Swift.max(spendFraction, Swift.max(timeFraction, callFraction))
        ) ?? 1

        return BudgetState(
            spentUSD: spentUSD,
            elapsedSeconds: elapsedSeconds,
            inferenceCalls: inferenceCalls,
            isExhausted: exhaustedBy != nil,
            exhaustedBy: exhaustedBy,
            utilization: utilization
        )
    }
}
