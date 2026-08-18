#if canImport(SwiftUI)
import SwiftUI
import SignalGate

// Every file in this target is wrapped in `canImport(SwiftUI)` so the module
// still compiles to an empty binary on Linux CI, where the core module's tests
// run. That keeps one CI job able to build the whole package.

/// Interactive console for the gate.
///
/// The point of the interaction is pedagogical: dragging the sample-size slider
/// walks a verdict from `inconclusive` through to a real decision, which makes
/// the central argument visible rather than asserted. At 24 samples per arm
/// *every* scenario is undecidable — including the ones hiding a genuine
/// 12-point regression.
public struct GateConsoleView: View {
    @State private var scenario: GateScenario
    @State private var samplesPerArm: Double
    @State private var mode: MonitoringMode

    private let basePolicy: GatePolicy

    /// - Parameter policy: the gate configuration. The demo app owns this and
    ///   passes it in, so margin and confidence are an application-level
    ///   decision rather than something the view invents.
    public init(
        policy: GatePolicy = .standard,
        initialScenario: GateScenario = .realRegression,
        initialSamplesPerArm: Int = 240
    ) {
        self.basePolicy = policy
        _scenario = State(initialValue: initialScenario)
        _samplesPerArm = State(initialValue: Double(Swift.min(6000, Swift.max(24, initialSamplesPerArm))))
        _mode = State(initialValue: policy.mode)
    }

    private var effectivePolicy: GatePolicy {
        GatePolicy(
            nonInferiorityMargin: basePolicy.nonInferiorityMargin,
            confidence: basePolicy.confidence,
            sliceFalseDiscoveryRate: basePolicy.sliceFalseDiscoveryRate,
            minimumDetectableEffect: basePolicy.minimumDetectableEffect,
            power: basePolicy.power,
            mode: mode,
            judgePolicy: basePolicy.judgePolicy
        )
    }

    private var sampleCount: Int {
        // The slider is bounded, but clamp anyway rather than trusting a
        // `Double` round-trip to land in range.
        Swift.min(6000, Swift.max(24, SafeSampleCount.from(samplesPerArm)))
    }

    private func makeReport() -> GateReport {
        scenario.evaluate(samplesPerArm: sampleCount, policy: effectivePolicy)
    }

    public var body: some View {
        // Bound once per body pass, deliberately.
        //
        // As a computed property this was evaluated at each of the eight use
        // sites below, and every evaluation allocates two arms of samples,
        // tallies them, runs a z-test per slice, sorts for Benjamini-Hochberg
        // and builds two intervals. Eight of those per render, on every drag
        // tick of the slider, is precisely the interaction this demo is built
        // to show off.
        let report = makeReport()
        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VerdictBanner(report: report)
                    controls
                    if let difference = report.differenceInterval {
                        IntervalStrip(interval: difference, margin: effectivePolicy.nonInferiorityMargin)
                    }
                    RationaleCard(rationale: report.rationale)
                    JudgeCard(status: report.judgeStatus)
                    if !report.sliceResults.isEmpty {
                        SliceTable(
                            results: report.sliceResults,
                            uncorrectedCount: report.uncorrectedRegressionCount,
                            familyWiseErrorRate: report.uncorrectedFamilyWiseErrorRate
                        )
                    }
                }
                .padding(20)
            }
            .navigationTitle("SignalGate")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Scenario", selection: $scenario) {
                ForEach(GateScenario.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)

            Text(scenario.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Samples per arm")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(sampleCount)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $samplesPerArm, in: 24...6000, step: 12)
            }

            Picker("Mode", selection: $mode) {
                ForEach(MonitoringMode.allCases, id: \.self) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text(mode == .sequential
                 ? "Anytime-valid: you may stop as soon as it decides. It costs roughly 2.4x the width at "
                   + "n=40, and never reaches PASS anywhere in this slider's range - that is the price of "
                   + "peeking, not a bug."
                 : "Fixed-sample interval: tightest correct choice, valid only if you look exactly once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Sample-count conversion isolated so the `Double` → `Int` step is guarded in
/// exactly one place. `Int(someDouble)` traps on `NaN`, and a `NaN` can reach a
/// slider binding through state restoration.
enum SafeSampleCount {
    static func from(_ value: Double) -> Int {
        guard value.isFinite else { return 24 }
        guard value < 6001, value > 0 else { return value <= 0 ? 24 : 6000 }
        return Int(value)
    }
}

struct VerdictBanner: View {
    let report: GateReport

    private var title: String {
        switch report.verdict {
        case .pass: return "PASS"
        case .block: return "BLOCK"
        case .inconclusive: return "INCONCLUSIVE"
        }
    }

    private var subtitle: String {
        switch report.verdict {
        case .pass:
            return "Merge may proceed."
        case .block:
            return "Merge blocked."
        case .inconclusive(let reason, let additional):
            if let additional {
                return "\(Self.describe(reason)) · ~\(additional) more samples per arm"
            }
            return Self.describe(reason)
        }
    }

    private static func describe(_ reason: InconclusiveReason) -> String {
        switch reason {
        case .insufficientEvidence: return "Evidence supports neither conclusion"
        case .judgeUncalibrated: return "Judge failed calibration"
        case .judgeUnavailable: return "Judge unavailable"
        case .budgetExhausted: return "Budget exhausted"
        case .noSamples: return "No samples"
        case .incomparableSlices: return "Slices not comparable"
        }
    }

    private var tint: Color {
        switch report.verdict {
        case .pass: return .green
        case .block: return .red
        case .inconclusive: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.heavy))
                .foregroundStyle(tint)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Only on `.inconclusive`. On a block there is no ambiguity for a
            // two-state gate to launder — it would pick block and be right —
            // so showing this line there garbles the argument.
            if report.verdict.isInconclusive {
                Text("A two-state gate would have had to pick pass or block here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Draws the difference interval against the non-inferiority margin, so the
/// three-state logic is visible geometrically: pass is "wholly right of the
/// margin", block is "wholly left", inconclusive is "straddling it".
struct IntervalStrip: View {
    let interval: ProportionInterval
    let margin: Double

    /// Half-width of the drawn axis, scaled to fit the interval it is given.
    ///
    /// A fixed span silently clipped wide intervals — and wide is exactly what
    /// a small-sample or sequential-mode interval is. A clipped bar runs into
    /// the wall and reads as decisive when the whole point is that it is not,
    /// which inverts the meaning of the one visual carrying the argument.
    private var span: Double {
        let needed = Swift.max(
            Swift.max(abs(interval.lowerBound), abs(interval.upperBound)),
            margin * 2
        )
        guard needed.isFinite, needed > 0 else { return 0.30 }
        return Swift.min(1.05, needed * 1.15)
    }

    private func position(_ value: Double, width: CGFloat) -> CGFloat {
        let axis = span
        guard value.isFinite, width.isFinite, width > 0, axis > 0 else { return 0 }
        let clamped = Swift.min(axis, Swift.max(-axis, value))
        let fraction = (clamped + axis) / (2 * axis)
        return width * CGFloat(fraction)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Candidate − baseline")
                .font(.subheadline.weight(.medium))

            GeometryReader { geometry in
                let width = geometry.size.width
                let lower = position(interval.lowerBound, width: width)
                let upper = position(interval.upperBound, width: width)
                let point = position(interval.pointEstimate, width: width)
                let marginX = position(-margin, width: width)
                let zeroX = position(0, width: width)

                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 8)
                        .offset(y: 12)
                    Capsule()
                        .fill(.tint)
                        .frame(width: Swift.max(2, upper - lower), height: 8)
                        .offset(x: lower, y: 12)
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: 1, height: 28)
                        .offset(x: zeroX, y: 2)
                    Rectangle()
                        .fill(.red)
                        .frame(width: 2, height: 28)
                        .offset(x: marginX, y: 2)
                    Circle()
                        .fill(.primary)
                        .frame(width: 9, height: 9)
                        .offset(x: point - 4.5, y: 11.5)
                }
            }
            .frame(height: 32)

            HStack {
                Text(String(format: "%+.3f", interval.lowerBound))
                Spacer()
                Text(String(format: "margin −%.3f", margin)).foregroundStyle(.red)
                Spacer()
                Text(String(format: "%+.3f", interval.upperBound))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct RationaleCard: View {
    let rationale: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Why")
                .font(.subheadline.weight(.medium))
            if rationale.isEmpty {
                Text("No rationale recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(rationale.enumerated()), id: \.offset) { _, line in
                    Text("• " + line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct JudgeCard: View {
    let status: JudgeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Judge")
                .font(.subheadline.weight(.medium))
            switch status {
            case .calibrated(let kappa, let bias):
                Text(String(format: "Calibrated — Cohen's κ %.3f, leniency bias %+.3f", kappa, bias))
                    .font(.caption)
                    .foregroundStyle(.green)
            case .uncalibrated(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .unavailable:
                Text("Unavailable — the gate cannot certify a run it could not measure.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SliceTable: View {
    let results: [SliceTestResult]
    let uncorrectedCount: Int
    let familyWiseErrorRate: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Slices")
                .font(.subheadline.weight(.medium))

            if let familyWiseErrorRate {
                Text(String(
                    format: "%d slices. Uncorrected, this family false-alarms %.0f%% of the time — "
                        + "it flags %d here; Benjamini–Hochberg flags %d.",
                    results.count, familyWiseErrorRate * 100,
                    uncorrectedCount, results.filter(\.isRegression).count
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(results, id: \.sliceID) { result in
                HStack(spacing: 8) {
                    Circle()
                        .fill(result.isRegression ? Color.red : Color.green.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text(result.sliceID)
                        .font(.caption.weight(.medium))
                    Spacer()
                    if let baseline = result.baselineRate, let candidate = result.candidateRate {
                        Text(String(format: "%.2f → %.2f", baseline, candidate))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(String(format: "q=%.3f", result.adjustedPValue))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(result.isRegression ? .red : .secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    GateConsoleView()
}
#endif
