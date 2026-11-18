import Foundation

// Provisional versioned local calculation, not an activated upload path. No direct record encoding,
// record IDs, persistence, database access, networking, timer, or app activation.
// A narrow preparedDraft can be queued only through an explicitly opted-in controller.
// The preview UI never calls this builder and calculation never grants consent.
enum SharingMeasurementProposal {
    case unresolved
    case provisionalV1
}
enum SharingMeasurementOmission: String {
    case methodologyUnresolved, reportUnavailable, invalidWindow, incompleteWindow, calendarTransition
    case unreviewedModel, unsupportedTier, mixedEfforts, unverifiedEffort
    case duplicateReadings, insufficientCurrentTiming, insufficientBaseline, ratioOutOfRange, tooManyComparisons
}
struct SharingMeasurementCandidate {
    let model: String
    let tier: String
    let exactEffort: String // Uploaded and published only in this exact-effort stratum.
    let ratio: Double
    let currentReplies: Int
    let baselineDays: Int
}
struct SharingMeasurementSkipped {
    let model: String
    let tier: String
    let reason: SharingMeasurementOmission
}
struct SharingMeasurementPreview {
    let candidates: [SharingMeasurementCandidate]
    let skipped: [SharingMeasurementSkipped]
    let blockedBy: SharingMeasurementOmission?
    var observationWindowStart: Int64? = nil
    var canUpload: Bool { false } // No endpoint/consent/transport activation comes from a calculation.
    var isProvisional: Bool { true }
    var requiresActivationReview: Bool { true }
    func preparedDraft() -> SharingMeasurementDraft? {
        guard blockedBy == nil, let observationWindowStart, !candidates.isEmpty, candidates.count <= 12 else { return nil }
        return SharingMeasurementDraft(methodId: SharingMethod.id, windowStart: observationWindowStart,
            comparisons: candidates.map { SharingComparison(model: $0.model, tier: $0.tier, ratio: $0.ratio, exactEffort: $0.exactEffort) })
    }
}
enum SharingMeasurementPreviewBuilder {
    // Omit intervals spanning an offset transition. Shifted reference windows
    // must preserve wall-clock endpoints and elapsed length; nonexistent local
    // clock intervals are not normalized into a different comparison interval.
    private static func stableInterval(_ start: Date, _ inclusiveEnd: Date, calendar: Calendar) -> Bool {
        calendar.timeZone.secondsFromGMT(for: start) == calendar.timeZone.secondsFromGMT(for: inclusiveEnd)
    }
    private static func sameClock(_ a: Date, _ b: Date, calendar: Calendar) -> Bool {
        calendar.dateComponents([.hour, .minute, .second], from: a) == calendar.dateComponents([.hour, .minute, .second], from: b)
    }
    // Versioned copy of the established usualTiming same-clock daily-baseline rule.
    // Sharing's thresholds cannot drift if the viewer's presentation gates change.
    private static func frozenBaseline(_ history: [SpeedReading], start: Date, end: Date,
                                       calendar: Calendar) -> (median: Double, days: Int)? {
        let today = calendar.startOfDay(for: end)
        var rates: [Double] = []
        var referenceDays = Set<Date>()
        for day in 1...SharingMethod.lookbackDays {
            guard let a = calendar.date(byAdding: .day, value: -day, to: start),
                  let b = calendar.date(byAdding: .day, value: -day, to: end) else { continue }
            guard stableInterval(a, b, calendar: calendar), sameClock(a, start, calendar: calendar),
                  sameClock(b, end, calendar: calendar),
                  abs(b.timeIntervalSince(a) - end.timeIntervalSince(start)) < 0.001,
                  referenceDays.insert(calendar.startOfDay(for: a)).inserted else { continue }
            let matches = history.filter { $0.date >= a && $0.date <= b && $0.date < today }
            guard matches.count >= SharingMethod.minimumDayReplies, let timing = timingSplit(matches) else { continue }
            rates.append(timing.generating)
        }
        guard rates.count >= SharingMethod.minimumBaselineDays else { return nil }
        rates.sort()
        return ((rates[(rates.count - 1) / 2] + rates[rates.count / 2]) / 2, rates.count)
    }
    static func evaluate(_ report: RecentSpeedReport, windowStart: Date, asOf: Date,
                         publicModels: Set<String> = [], calendar: Calendar = .current,
                         proposal: SharingMeasurementProposal = .unresolved) -> SharingMeasurementPreview {
        func blocked(_ reason: SharingMeasurementOmission) -> SharingMeasurementPreview {
            SharingMeasurementPreview(candidates: [], skipped: [], blockedBy: reason)
        }
        guard proposal == .provisionalV1 else { return blocked(.methodologyUnresolved) }
        guard report.error == nil else { return blocked(.reportUnavailable) }
        let stamp = windowStart.timeIntervalSince1970
        guard stamp.isFinite, stamp >= 0, stamp < Double(Int64.max / 1000), stamp.truncatingRemainder(dividingBy: 1800) == 0,
              asOf.timeIntervalSince1970.isFinite else { return blocked(.invalidWindow) }
        let end = windowStart.addingTimeInterval(1800)
        guard asOf >= end else { return blocked(.incompleteWindow) }
        let finalInstant = Date(timeIntervalSinceReferenceDate: end.timeIntervalSinceReferenceDate.nextDown)
        guard stableInterval(windowStart, finalInstant, calendar: calendar) else { return blocked(.calendarTransition) }
        func inside(_ date: Date) -> Bool { date >= windowStart && date < end }
        let knownEfforts: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        func verified(_ reading: SpeedReading, effort: String) -> Bool {
            // Deliberately stricter than the viewer's legacy nil-verification fallback.
            reading.selectedEffortVerified == true && reading.usesSelected &&
            normalizedEffort(reading.selectedEffort) == effort && knownEfforts.contains(effort)
        }
        func timed(_ reading: SpeedReading) -> Bool {
            reading.outputTokens >= SharingMethod.minimumOutputTokens && reading.generatingSeconds != nil &&
            reading.generatingSpeed?.isFinite == true
        }
        var candidates: [SharingMeasurementCandidate] = [], skipped: [SharingMeasurementSkipped] = []
        for model in report.models {
            let tiers = Set(model.efforts.flatMap { $0.modes.map(\.mode) }).sorted()
            for tier in tiers {
                let active = model.efforts.flatMap { effort in
                    effort.modes.filter { $0.mode == tier }.filter { group in
                        group.responseDates.contains(where: inside) || group.readings.contains { inside($0.date) } || group.effortEvidence.contains { inside($0.date) }
                    }.map { (effort.effort, $0) }
                }
                guard !active.isEmpty else { continue }
                func omit(_ reason: SharingMeasurementOmission) { skipped.append(SharingMeasurementSkipped(model: model.model, tier: tier, reason: reason)) }
                guard publicModels.contains(model.model) else { omit(.unreviewedModel); continue }
                guard ["standard", "fast", "ultrafast"].contains(tier) else { omit(.unsupportedTier); continue }
                // Never select the fastest effort or pool different settings into one cell.
                guard active.count == 1 else { omit(.mixedEfforts); continue }
                let (rawEffort, group) = active[0]
                guard let effort = normalizedEffort(rawEffort), knownEfforts.contains(effort) else { omit(.unverifiedEffort); continue }
                let current = group.readings.filter { inside($0.date) }
                let evidence = group.effortEvidence.filter { inside($0.date) }
                guard current.allSatisfy({ verified($0, effort: effort) }),
                      evidence.allSatisfy({ $0.verified == true && $0.usesSelected && normalizedEffort($0.selected) == effort }) else { omit(.unverifiedEffort); continue }
                guard Set(group.readings.map(\.id)).count == group.readings.count else { omit(.duplicateReadings); continue }
                let qualifying = current.filter(timed)
                guard qualifying.count >= SharingMethod.minimumCurrentReplies, let measured = timingSplit(qualifying) else { omit(.insufficientCurrentTiming); continue }
                let history = group.readings.filter { verified($0, effort: effort) && timed($0) }
                // Existing usualTiming has an inclusive end. The next representable time
                // before the boundary keeps both current and reference windows half-open.
                let inclusiveEnd = Date(timeIntervalSinceReferenceDate: end.timeIntervalSinceReferenceDate.nextDown)
                guard let baseline = frozenBaseline(history, start: windowStart, end: inclusiveEnd, calendar: calendar), baseline.median > 0 else { omit(.insufficientBaseline); continue }
                let ratio = measured.generating / baseline.median
                guard ratio.isFinite, (0.3...3).contains(ratio) else { omit(.ratioOutOfRange); continue }
                candidates.append(SharingMeasurementCandidate(model: model.model, tier: tier, exactEffort: effort,
                    ratio: ratio, currentReplies: qualifying.count, baselineDays: baseline.days))
            }
        }
        guard candidates.count <= 12 else { return blocked(.tooManyComparisons) }
        return SharingMeasurementPreview(candidates: candidates, skipped: skipped, blockedBy: nil,
            observationWindowStart: Int64(stamp * 1000))
    }
}

// Ephemeral adapter for the explicitly requested local chart. No serialization,
// persistence, logging or network use. The caller supplies an authoritative snapshot.
extension SharingProjectionSnapshot {
    static func authoritativeReport(_ report: RecentSpeedReport, calendar: Calendar = .current) -> SharingProjectionSnapshot? {
        guard report.error == nil else { return nil }
        var observations: [SharingProjectionObservation] = []
        var inspected = 0
        for model in report.models {
            for group in model.efforts {
                guard let effort = normalizedEffort(group.effort), SharingMethod.exactEfforts.contains(effort) else { continue }
                for mode in group.modes where ["standard","fast","ultrafast"].contains(mode.mode) {
                    for reading in mode.readings {
                        inspected += 1
                        guard inspected <= 50_000, !Task.isCancelled else { return nil }
                        guard reading.selectedEffortVerified == true, reading.usesSelected,
                              normalizedEffort(reading.selectedEffort) == effort, let ttft = reading.ttftMS else { continue }
                        guard observations.count < 50_000 else { return nil }
                        observations.append(SharingProjectionObservation(id:reading.id,completedAt:reading.date,
                            model:model.model,tier:mode.mode,exactEffort:effort,verifiedParentEffort:true,
                            outputTokens:reading.outputTokens,durationMS:reading.durationMS,ttftMS:ttft))
                    }
                }
            }
        }
        return SharingProjectionSnapshot(observations:observations,checkedAt:report.checkedAt,snapshotAt:report.snapshotAt,
            heartbeat:report.heartbeat,methodId:SharingMethod.id,calendar:calendar)
    }
}
