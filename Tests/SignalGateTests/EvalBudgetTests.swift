import XCTest
@testable import SignalGate

final class EvalBudgetTests: XCTestCase {

    private func makePolicy(
        spend: Double = 10, seconds: Double = 600, calls: Int = 1000
    ) throws -> EvalBudgetPolicy {
        try XCTUnwrap(EvalBudgetPolicy(
            maximumSpendUSD: spend, maximumWallClockSeconds: seconds, maximumInferenceCalls: calls
        ))
    }

    func testPolicyRejectsNonPositiveAndNonFiniteCeilings() {
        XCTAssertNil(EvalBudgetPolicy(maximumSpendUSD: 0, maximumWallClockSeconds: 60, maximumInferenceCalls: 10))
        XCTAssertNil(EvalBudgetPolicy(maximumSpendUSD: -1, maximumWallClockSeconds: 60, maximumInferenceCalls: 10))
        XCTAssertNil(EvalBudgetPolicy(maximumSpendUSD: .nan, maximumWallClockSeconds: 60, maximumInferenceCalls: 10))
        XCTAssertNil(EvalBudgetPolicy(
            maximumSpendUSD: 1, maximumWallClockSeconds: .infinity, maximumInferenceCalls: 10))
        XCTAssertNil(EvalBudgetPolicy(maximumSpendUSD: 1, maximumWallClockSeconds: 60, maximumInferenceCalls: 0))
    }

    func testChargeAccumulatesAndReportsUtilization() async throws {
        let ledger = EvalBudgetLedger(policy: try makePolicy(spend: 10, seconds: 100, calls: 100))
        _ = await ledger.charge(costUSD: 2.5, latencySeconds: 5)
        let state = await ledger.charge(costUSD: 2.5, latencySeconds: 5)
        XCTAssertEqual(state.spentUSD, 5.0, accuracy: 1e-12)
        XCTAssertEqual(state.elapsedSeconds, 10.0, accuracy: 1e-12)
        XCTAssertEqual(state.inferenceCalls, 2)
        XCTAssertFalse(state.isExhausted)
        // Tightest ceiling is spend at 5/10.
        XCTAssertEqual(state.utilization, 0.5, accuracy: 1e-12)
    }

    func testExhaustionNamesTheBindingCeiling() async throws {
        let spendLedger = EvalBudgetLedger(policy: try makePolicy(spend: 1, seconds: 1000, calls: 1000))
        let spendState = await spendLedger.charge(costUSD: 1.5, latencySeconds: 1)
        XCTAssertTrue(spendState.isExhausted)
        XCTAssertEqual(spendState.exhaustedBy, "spend")

        let timeLedger = EvalBudgetLedger(policy: try makePolicy(spend: 1000, seconds: 5, calls: 1000))
        let timeState = await timeLedger.charge(costUSD: 0.01, latencySeconds: 9)
        XCTAssertTrue(timeState.isExhausted)
        XCTAssertEqual(timeState.exhaustedBy, "wall-clock")

        let callLedger = EvalBudgetLedger(policy: try makePolicy(spend: 1000, seconds: 1000, calls: 2))
        _ = await callLedger.charge(costUSD: 0.01, latencySeconds: 0.1)
        let callState = await callLedger.charge(costUSD: 0.01, latencySeconds: 0.1)
        XCTAssertTrue(callState.isExhausted)
        XCTAssertEqual(callState.exhaustedBy, "inference-calls")
    }

    /// A `NaN` latency reading from a timed-out call must not be accumulated.
    /// If it were, `elapsedSeconds` would be `NaN` forever, every comparison
    /// against the ceiling would evaluate false, and the budget would report
    /// itself healthy permanently — the worst possible failure for a cost cap.
    func testNonFiniteReadingsAreIgnoredRatherThanAccumulated() async throws {
        let ledger = EvalBudgetLedger(policy: try makePolicy(spend: 10, seconds: 10, calls: 10))
        _ = await ledger.charge(costUSD: .nan, latencySeconds: .nan)
        _ = await ledger.charge(costUSD: .infinity, latencySeconds: .infinity)
        _ = await ledger.charge(costUSD: -5, latencySeconds: -5)
        let clean = await ledger.charge(costUSD: 1, latencySeconds: 1)

        XCTAssertEqual(clean.spentUSD, 1.0, accuracy: 1e-12)
        XCTAssertEqual(clean.elapsedSeconds, 1.0, accuracy: 1e-12)
        XCTAssertFalse(clean.spentUSD.isNaN)
        XCTAssertFalse(clean.utilization.isNaN)
        XCTAssertFalse(clean.isExhausted)

        // And the ledger still detects real exhaustion afterwards.
        let exhausted = await ledger.charge(costUSD: 20, latencySeconds: 0.1)
        XCTAssertTrue(exhausted.isExhausted)
    }

    func testCanAffordRefusesOnceExhausted() async throws {
        let ledger = EvalBudgetLedger(policy: try makePolicy(spend: 1, seconds: 100, calls: 100))
        let affordableWhenFresh = await ledger.canAfford(estimatedCostUSD: 0.1, estimatedLatencySeconds: 1)
        XCTAssertTrue(affordableWhenFresh)

        _ = await ledger.charge(costUSD: 0.95, latencySeconds: 1)
        let affordableLargeCharge = await ledger.canAfford(estimatedCostUSD: 0.5, estimatedLatencySeconds: 1)
        XCTAssertFalse(affordableLargeCharge, "projected spend exceeds the ceiling")

        let affordableSmallCharge = await ledger.canAfford(estimatedCostUSD: 0.01, estimatedLatencySeconds: 1)
        XCTAssertTrue(affordableSmallCharge)
    }

    /// A genuinely concurrent writer, not a sequential loop dressed up as one.
    ///
    /// 500 tasks charge the same ledger simultaneously. The assertion is on the
    /// *exact* total: if the read-modify-write in `charge` were not atomic —
    /// if it were a plain class, or if an `await` were introduced mid-update —
    /// updates would interleave and the total would come out low.
    func testConcurrentChargesAreExactUnderRealParallelism() async throws {
        let taskCount = 500
        let ledger = EvalBudgetLedger(
            policy: try makePolicy(spend: 1_000_000, seconds: 1_000_000, calls: 1_000_000)
        )

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    _ = await ledger.charge(costUSD: 0.01, latencySeconds: 0.25)
                }
            }
            await group.waitForAll()
        }

        let state = await ledger.state()
        XCTAssertEqual(state.inferenceCalls, taskCount,
                       "every concurrent charge must be counted exactly once")
        XCTAssertEqual(state.spentUSD, Double(taskCount) * 0.01, accuracy: 1e-6)
        XCTAssertEqual(state.elapsedSeconds, Double(taskCount) * 0.25, accuracy: 1e-6)
    }

    /// Concurrent readers interleaved with concurrent writers must never
    /// observe a torn state — call count and spend must stay consistent with
    /// each other at every observation.
    func testConcurrentReadsNeverObserveATornState() async throws {
        let ledger = EvalBudgetLedger(
            policy: try makePolicy(spend: 1_000_000, seconds: 1_000_000, calls: 1_000_000)
        )
        let costPerCall = 0.02

        // Repeated, because a single pass can schedule every reader before every
        // writer — on a 2-core runner that is common — and then all readers see
        // (0, 0) and the invariant holds without ever exercising a torn window.
        // `observedNonZero` makes that vacuous outcome a failure.
        var observedNonZero = false
        for _ in 0..<25 {
            await withTaskGroup(of: (consistent: Bool, calls: Int)?.self) { group in
                for index in 0..<120 {
                    if index.isMultiple(of: 3) {
                        group.addTask {
                            let state = await ledger.state()
                            // Invariant: spend is always exactly calls × unit cost.
                            let ok = abs(state.spentUSD - Double(state.inferenceCalls) * costPerCall) < 1e-9
                            return (ok, state.inferenceCalls)
                        }
                    } else {
                        group.addTask {
                            _ = await ledger.charge(costUSD: costPerCall, latencySeconds: 0.1)
                            return nil
                        }
                    }
                }
                for await observation in group {
                    guard let observation else { continue }
                    XCTAssertTrue(observation.consistent, "observed a partially-applied charge")
                    if observation.calls > 0 { observedNonZero = true }
                }
            }
        }
        XCTAssertTrue(observedNonZero,
                      "no reader ever observed a non-zero ledger — the invariant held vacuously")
    }
}
