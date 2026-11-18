import Foundation

// Local-only prototype types, deliberately NOT Codable/network protocol fields.
// Legacy public cells cannot prove compatible effort; v2 requires wire effort matching.
enum SharingProjectionSource { case currentPublicProtocol, effortStratifiedV2, syntheticMatchedEffort }
struct SharingProjectionObservation {
    let id: String
    let completedAt: Date
    let model: String
    let tier: String
    let exactEffort: String
    let verifiedParentEffort: Bool
    let outputTokens: Int64
    let durationMS: Double
    let ttftMS: Double
}
struct SharingProjectionDay {
    let localDay: Date
    let referenceStart: Date
    let referenceEnd: Date
    let replies: Int
    let generatingSpeed: Double
}
struct SharingProjectionBaseline {
    let windowStart: Int64
    let model: String
    let tier: String
    let exactEffort: String
    let methodId: String
    let generatingSpeed: Double
    let days: [SharingProjectionDay]
    let timeZoneIdentifier: String
    fileprivate init(windowStart:Int64,model:String,tier:String,exactEffort:String,generatingSpeed:Double,days:[SharingProjectionDay],timeZoneIdentifier:String) {
        self.windowStart=windowStart;self.model=model;self.tier=tier;self.exactEffort=exactEffort
        methodId=SharingMethod.id;self.generatingSpeed=generatingSpeed;self.days=days;self.timeZoneIdentifier=timeZoneIdentifier
    }
}
struct SharingProjectionEvidence {
    let cell: SharingPublicCell
    let exactEffort: String?
    let source: SharingProjectionSource
}
enum SharingProjectionBlock: String, Error {
    case publicEffortUnavailable = "Legacy public results combine efforts and do not identify effort. Projection withheld."
    case staleEvidence = "The projection evidence is stale or the clock changed. Request a fresh projection."
    case missingBaseline = "A matching local usual-speed baseline is missing. Projection withheld."
    case incompatible = "Model, tier, effort or observation window does not match. Projection withheld."
    case methodMismatch = "Comparison methods do not match. Projection withheld."
    case insufficientBaseline = "The local baseline does not meet the provisional evidence gates. Projection withheld."
    case invalidValue = "The projection inputs are invalid. Projection withheld."
}
struct SharingProjectionPoint: Identifiable {
    var id: Int64 { windowStart }
    let windowStart: Int64
    let model: String
    let tier: String
    let exactEffort: String
    let region: String
    let baseline: Double
    let ratio: Double
    let hypothetical: Double
    let baselineDays: Int
    let baselineTimeZone: String
}
enum SharingProjection {
    // Dated evidence is required; callers cannot construct a baseline from a
    // claimed day count. This pure calculator is exercised with synthetic data only.
    static func makeBaseline(observations:[SharingProjectionObservation], windowStart:Int64,
                             model:String,tier:String,effort:String,calendar:Calendar) -> SharingProjectionBaseline? {
        let known:Set<String>=["minimal","low","medium","high","xhigh","max","ultra"]
        guard windowStart>=0, windowStart<Int64.max-SharingMethod.windowMS,
              windowStart % SharingMethod.windowMS == 0, known.contains(effort),
              ["standard","fast","ultrafast"].contains(tier), !model.isEmpty else {return nil}
        guard !Task.isCancelled else { return nil }
        let selected=observations.filter {!Task.isCancelled && $0.model==model && $0.tier==tier && $0.exactEffort==effort}
        guard !Task.isCancelled, Set(selected.map(\.id)).count==selected.count else {return nil}
        let start=Date(timeIntervalSince1970:Double(windowStart)/1000)
        let end=start.addingTimeInterval(1800)
        let inclusiveEnd=Date(timeIntervalSinceReferenceDate:end.timeIntervalSinceReferenceDate.nextDown)
        guard calendar.timeZone.secondsFromGMT(for:start)==calendar.timeZone.secondsFromGMT(for:inclusiveEnd) else {return nil}
        let today=calendar.startOfDay(for:inclusiveEnd)
        func clock(_ d:Date)->DateComponents {calendar.dateComponents([.hour,.minute,.second],from:d)}
        var days:[SharingProjectionDay]=[];var seen=Set<Date>()
        for offset in 1...SharingMethod.lookbackDays {
            guard !Task.isCancelled else { return nil }
            guard let a=calendar.date(byAdding:.day,value:-offset,to:start),
                  let z=calendar.date(byAdding:.day,value:-offset,to:inclusiveEnd),
                  clock(a)==clock(start),clock(z)==clock(inclusiveEnd),
                  abs(z.timeIntervalSince(a)-inclusiveEnd.timeIntervalSince(start))<0.001,
                  calendar.timeZone.secondsFromGMT(for:a)==calendar.timeZone.secondsFromGMT(for:z),
                  seen.insert(calendar.startOfDay(for:a)).inserted else {continue}
            let rs=selected.filter {!Task.isCancelled && $0.completedAt>=a && $0.completedAt<=z && $0.completedAt<today &&
                $0.verifiedParentEffort && $0.outputTokens>=SharingMethod.minimumOutputTokens &&
                $0.durationMS.isFinite && $0.ttftMS.isFinite && $0.ttftMS>=0 && $0.durationMS>$0.ttftMS}
            guard !Task.isCancelled else { return nil }
            guard rs.count>=SharingMethod.minimumDayReplies else {continue}
            let seconds=rs.reduce(0.0){$0+($1.durationMS-$1.ttftMS)/1000}
            let speed=rs.reduce(0.0){$0+Double($1.outputTokens)}/seconds
            guard seconds.isFinite,seconds>0,speed.isFinite,speed>0 else {continue}
            days.append(SharingProjectionDay(localDay:calendar.startOfDay(for:a),referenceStart:a,referenceEnd:z,replies:rs.count,generatingSpeed:speed))
        }
        guard days.count>=SharingMethod.minimumBaselineDays else {return nil}
        let values=days.map(\.generatingSpeed).sorted()
        // Divide before adding so a finite high baseline does not overflow its median.
        let median=values[(values.count-1)/2]/2+values[values.count/2]/2
        guard median.isFinite,median>0 else {return nil}
        return SharingProjectionBaseline(windowStart:windowStart,model:model,tier:tier,exactEffort:effort,
            generatingSpeed:median,days:days,timeZoneIdentifier:calendar.timeZone.identifier)
    }
    static func calculate(_ evidence: SharingProjectionEvidence, baseline: SharingProjectionBaseline?) -> Result<SharingProjectionPoint, SharingProjectionBlock> {
        guard evidence.source != .currentPublicProtocol else { return .failure(.publicEffortUnavailable) }
        guard let baseline else { return .failure(.missingBaseline) }
        let cell = evidence.cell
        guard cell.methodId == SharingMethod.id, baseline.methodId == cell.methodId else { return .failure(.methodMismatch) }
        let efforts: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        guard let effort = evidence.exactEffort, efforts.contains(effort), cell.exactEffort == effort, baseline.exactEffort == effort,
              cell.model == baseline.model, cell.tier == baseline.tier, cell.windowStart == baseline.windowStart,
              ["standard", "fast", "ultrafast"].contains(cell.tier) else { return .failure(.incompatible) }
        guard baseline.days.count >= SharingMethod.minimumBaselineDays,
              baseline.days.count <= SharingMethod.lookbackDays,
              Set(baseline.days.map(\.localDay)).count == baseline.days.count,
              baseline.days.allSatisfy({ $0.replies >= SharingMethod.minimumDayReplies }) else { return .failure(.insufficientBaseline) }
        guard !cell.model.isEmpty, cell.model.utf8.count <= 128, ["americas", "europe", "asia-pacific"].contains(cell.region),
              cell.windowStart >= 0, cell.windowStart % SharingMethod.windowMS == 0,
              baseline.generatingSpeed.isFinite, baseline.generatingSpeed > 0,
              cell.median.isFinite, (0.3...3).contains(cell.median) else { return .failure(.invalidValue) }
        let projected = baseline.generatingSpeed * cell.median
        guard projected.isFinite, projected > 0 else { return .failure(.invalidValue) }
        return .success(SharingProjectionPoint(windowStart:cell.windowStart,model:cell.model,tier:cell.tier,
            exactEffort:effort,region:cell.region,baseline:baseline.generatingSpeed,ratio:cell.median,hypothetical:projected,
            baselineDays:baseline.days.count,baselineTimeZone:baseline.timeZoneIdentifier))
    }
    // Never connect different model/tier/effort/region selections as one time series.
    static func coherent(_ points: [SharingProjectionPoint]) -> Bool {
        guard let first = points.first else { return true }
        let ordered = points.sorted { $0.windowStart < $1.windowStart }
        let contiguous = zip(ordered, ordered.dropFirst()).allSatisfy { $1.windowStart - $0.windowStart == SharingMethod.windowMS }
        return contiguous && Set(points.map(\.windowStart)).count == points.count && points.allSatisfy {
            $0.model == first.model && $0.tier == first.tier && $0.exactEffort == first.exactEffort && $0.region == first.region && $0.baselineTimeZone == first.baselineTimeZone &&
            $0.baseline.isFinite && $0.baseline > 0 && $0.hypothetical.isFinite && $0.hypothetical > 0
        }
    }
}
