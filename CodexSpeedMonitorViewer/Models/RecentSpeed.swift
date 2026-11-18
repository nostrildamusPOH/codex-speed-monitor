import SwiftUI
import Charts
import SQLite3

struct SpeedReading: Identifiable {
    let id: String
    let date: Date
    let speed: Double
    let outputTokens: Int64
    let durationMS: Double
    var selectedEffort:String?=nil
    var reportedEffort:String?=nil
    var effortSource:String="unresolved"
    var selectedEffortVerified:Bool?=nil
    var selectedEffortConflict=false
    var identityConflict=false
    var ttftMS:Double?=nil        // Codex-reported first-output timing, when logged
    var inputTokens:Int64?=nil    // context size, when logged
    var usesSelected:Bool {usableSelectedEffort(selectedEffort,source:effortSource,verified:selectedEffortVerified,conflict:selectedEffortConflict,identityConflict:identityConflict)}
}
extension SpeedReading {
    // Reported first-output wait and the residual interval used for the generation estimate.
    var waitSeconds:Double? {
        guard let t=ttftMS,generatingSeconds != nil else{return nil}
        return t/1000
    }
    var generatingSeconds:Double? {
        guard durationMS.isFinite,durationMS>0,let t=ttftMS,t.isFinite,t>=0,t<durationMS else{return nil}
        let seconds=(durationMS-t)/1000
        return seconds.isFinite && seconds>0 ? seconds : nil
    }
    var generatingSpeed:Double? {
        guard let seconds=generatingSeconds else{return nil}
        let rate=Double(outputTokens)/seconds
        return rate.isFinite && rate>=0 ? rate : nil
    }
}
// The exported flag uses the old five-second minimum. Exact retained timing
// identity lets the viewer admit shorter measured replies without changing collection.
func measuredReplyEligible(legacyEligible:Bool,matchingStreams:Int,matchingCompletions:Int,identityConflict:Bool,durationMS:Double,outputTokens:Int64,speed:Double?)->Bool {
    guard !identityConflict,durationMS.isFinite,durationMS>0,outputTokens>=100,
          let speed,speed.isFinite,speed>=0 else{return false}
    return legacyEligible || (matchingStreams==1 && matchingCompletions==1)
}
// Equivalent predicate for historical viewer queries and CSV export. No stored flag is changed.
func measuredReplyEligibilitySQL(legacyEligibleSQL:String,prefix:String="")->String {
    let j="CASE WHEN json_valid(\(prefix)raw_json) THEN \(prefix)raw_json ELSE '{}' END"
    return "((coalesce((\(legacyEligibleSQL)),0)=1 OR (json_extract(\(j),'$.matching_streams')=1 AND json_extract(\(j),'$.matching_completions')=1)) AND coalesce(json_extract(\(j),'$.identity_conflict'),0)=0 AND \(prefix)duration_ms>0 AND \(prefix)duration_ms<=1.7976931348623157e308 AND \(prefix)output_tokens>=100 AND \(prefix)output_tokens_per_second IS NOT NULL AND \(prefix)output_tokens_per_second>=0 AND \(prefix)output_tokens_per_second<=1.7976931348623157e308)"
}
func replyCoverageText(_ measured:Int,_ total:Int)->String {"\(measured.formatted())/\(total.formatted()) replies"}
let replyMeasurementExplanation="A qualifying reply needs valid positive timing, an unambiguous timing match and at least 100 output tokens; there is no minimum duration. Missing or ambiguous timing is excluded, never counted as zero. Speed is output tokens divided by the whole response duration, including the wait before output starts."
struct SpeedStats {
    let readings: [SpeedReading]
    var mean: Double? { readings.isEmpty ? nil : readings.reduce(0) { $0+$1.speed } / Double(readings.count) }
    var latest: Date? { readings.first?.date }
}
func normalizedEffort(_ value:String?)->String? {
    guard let value else{return nil}
    let clean=value.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
    guard !["","unknown","unspecified","null","n/a"].contains(clean) else{return nil}
    if ["extra high","extra-high","extra_high","extrahigh","x-high","x_high"].contains(clean) {return "xhigh"}
    return clean
}
func usableSelectedEffort(_ selected:String?,source:String,verified:Bool?,conflict:Bool,identityConflict:Bool)->Bool {
    guard !conflict && !identityConflict, ["parent_turn","retained_parent_turn"].contains(source), ["minimal","low","medium","high","xhigh","max","ultra"].contains(normalizedEffort(selected) ?? "") else{return false}
    return verified ?? true
}
struct EffortEvidence {
    let date:Date
    let selected:String?
    let reported:String?
    let source:String
    var verified:Bool?=nil
    var selectedConflict=false
    var identityConflict=false
    var usesSelected:Bool {usableSelectedEffort(selected,source:source,verified:verified,conflict:selectedConflict,identityConflict:identityConflict)}
    var mismatch:Bool {guard usesSelected,let selected=normalizedEffort(selected),let reported=normalizedEffort(reported) else{return false};return selected != reported}
}
func effortTitle(_ effort:String)->String {effort=="xhigh" ? "Extra high (xhigh)" : effort}
struct SpeedModeGroup: Identifiable {
    var id: String { mode }
    let mode: String
    var readings: [SpeedReading] = []
    var excluded = 0
    var responseDates: [Date] = []
    var excludedDates: [Date] = []
    var effortEvidence:[EffortEvidence]=[]
    var mismatchCount:Int {effortEvidence.filter(\.mismatch).count}
    var mismatchValues:String {Array(Set(effortEvidence.filter(\.mismatch).compactMap(\.reported))).sorted().joined(separator:", ")}
    var latestResponse: Date = .distantPast
    func stats() -> SpeedStats { SpeedStats(readings:readings) }
    func filtered(range:SpeedTimeRange,now:Date)->Self {
        let cutoff=now.addingTimeInterval(-range.seconds)
        func contains(_ d:Date)->Bool {d>=cutoff && d<=now}
        var group=self
        group.readings=readings.filter {contains($0.date)}
        group.responseDates=responseDates.filter(contains)
        group.excludedDates=excludedDates.filter(contains)
        group.effortEvidence=effortEvidence.filter{contains($0.date)}
        group.excluded=group.excludedDates.count
        group.latestResponse=group.responseDates.first ?? .distantPast
        return group
    }
    var plotReadings:[SpeedReading] {readings.sorted {$0.date<$1.date}}
}
struct SpeedEffortGroup: Identifiable {
    var id: String { effort }
    let effort: String
    var modes: [SpeedModeGroup]
}
struct SpeedModelGroup: Identifiable {
    var id: String { model }
    let model: String
    var efforts: [SpeedEffortGroup]
    let latestResponse: Date
}
struct SpeedSelection: Equatable {
    let model: String
    let effort: String
    let mode: String
}
struct SpeedNavigation {
    var selection: SpeedSelection?
    mutating func open(model:String,effort:String,mode:String) { selection=SpeedSelection(model:model,effort:effort,mode:mode) }
    mutating func back() { selection=nil }
}
enum SpeedTimeRange:String,CaseIterable {
    case hour="1h",fourHours="4h",twelveHours="12h",day,week,month
    var title:String {switch self {case .hour:return "1h";case .fourHours:return "4h";case .twelveHours:return "12h";case .day:return "24h";case .week:return "7d";case .month:return "30d"}}
    var label:String {switch self {case .hour:return "Last 1 hour";case .fourHours:return "Last 4 hours";case .twelveHours:return "Last 12 hours";case .day:return "Last 24 hours";case .week:return "Last 7 days";case .month:return "Last 30 days"}}
    var seconds:TimeInterval {switch self {case .hour:return 3600;case .fourHours:return 14400;case .twelveHours:return 43200;case .day:return 86400;case .week:return 7*86400;case .month:return 30*86400}}
}
func orderedModes(_ groups:[SpeedModeGroup])->[SpeedModeGroup] {
    let order=["ultrafast","fast","standard"]
    return groups.sorted {let a=order.firstIndex(of:$0.mode) ?? 9,b=order.firstIndex(of:$1.mode) ?? 9;return a==b ? $0.mode<$1.mode : a<b}
}
// Immutable snapshot sidecar: one day/hour pair per unique retained timestamp.
// Keeping this outside SpeedReading avoids enlarging arrays copied by bootstrap draws.
final class ReplyCalendarIndex:@unchecked Sendable {
    struct Parts {let day:Date;let hour:Int}
    let calendar:Calendar
    let fields:[Date:Parts]
    init(dates:[Date],calendar:Calendar) {
        self.calendar=calendar
        var values:[Date:Parts]=[:];values.reserveCapacity(dates.count)
        for date in dates where values[date]==nil {values[date]=Parts(day:calendar.startOfDay(for:date),hour:calendar.component(.hour,from:date))}
        fields=values
    }
    func matching(_ calendar:Calendar)->ReplyCalendarIndex? {self.calendar==calendar ? self : nil}
    func day(_ date:Date)->Date {fields[date]?.day ?? calendar.startOfDay(for:date)}
    func hour(_ date:Date)->Int {fields[date]?.hour ?? calendar.component(.hour,from:date)}
}
struct RecentSpeedReport {
    var calendarIndex:ReplyCalendarIndex?=nil
    var models: [SpeedModelGroup] = []
    var heartbeat: Date?
    var snapshotAt: Date?
    var checkedAt: Date?
    var error: String?
    var oldestAvailable:Date?
    func preservingOrder(from previous:Self) -> Self {
        var result=self
        let order=Dictionary(uniqueKeysWithValues:previous.models.enumerated().map { ($0.element.model,$0.offset) })
        let incoming=Dictionary(uniqueKeysWithValues:models.enumerated().map { ($0.element.model,$0.offset) })
        result.models.sort { (order[$0.model] ?? (order.count+incoming[$0.model]!)) < (order[$1.model] ?? (order.count+incoming[$1.model]!)) }
        return result
    }
    func filtered(range:SpeedTimeRange,now:Date)->Self {
        var result=self
        let cutoff=now.addingTimeInterval(-range.seconds)
        func contains(_ d:Date)->Bool {d>=cutoff && d<=now}
        result.models=models.compactMap {model in
            let efforts=model.efforts.compactMap {effort -> SpeedEffortGroup? in
                let modes=effort.modes.compactMap {original -> SpeedModeGroup? in
                    let group=original.filtered(range:range,now:now)
                    return group.responseDates.isEmpty ? nil : group
                }
                return modes.isEmpty ? nil : SpeedEffortGroup(effort:effort.effort,modes:modes)
            }
            guard !efforts.isEmpty else {return nil}
            let latest=efforts.flatMap(\.modes).map(\.latestResponse).max()!
            return SpeedModelGroup(model:model.model,efforts:efforts,latestResponse:latest)
        }
        return result
    }
    func group(for selection:SpeedSelection,range:SpeedTimeRange,now:Date)->SpeedModeGroup {
        (models.first{$0.model==selection.model}?.efforts.first{$0.effort==selection.effort}?.modes.first{$0.mode==selection.mode} ?? SpeedModeGroup(mode:selection.mode)).filtered(range:range,now:now)
    }
    static func read(_ db:OpaquePointer?,usageTable:String,speedTable:String,cached:Bool,path:String,now:Date=Date())->Self {
        let readingCalendar=Calendar.current
        var report=Self();report.checkedAt=now
        report.snapshotAt=(try? FileManager.default.attributesOfItem(atPath:path)[.modificationDate]) as? Date
        var stmt:OpaquePointer?
        if sqlite3_prepare_v2(db,"SELECT max(ts) FROM daemon_heartbeats",-1,&stmt,nil)==SQLITE_OK,sqlite3_step(stmt)==SQLITE_ROW,let value=sqlite3_column_text(stmt,0) { report.heartbeat=parseISO(String(cString:value)) }
        sqlite3_finalize(stmt)
        if sqlite3_prepare_v2(db,"SELECT completed_at FROM \(usageTable) WHERE julianday(completed_at)<=julianday(?,'unixepoch') ORDER BY julianday(completed_at) LIMIT 1",-1,&stmt,nil)==SQLITE_OK {
            sqlite3_bind_double(stmt,1,now.timeIntervalSince1970)
            if sqlite3_step(stmt)==SQLITE_ROW,let value=sqlite3_column_text(stmt,0) {report.oldestAvailable=parseISO(String(cString:value))}
        }
        sqlite3_finalize(stmt)
        // Prefer authoritative served tier, then requested tier, then legacy mode.
        // Literal ultrafast and unfamiliar tiers remain distinct; speed is never evidence.
        var columns=Set<String>();var schema:OpaquePointer?
        if sqlite3_prepare_v2(db,"PRAGMA table_info(\(usageTable))",-1,&schema,nil)==SQLITE_OK {
            while sqlite3_step(schema)==SQLITE_ROW {if let name=sqlite3_column_text(schema,1) {columns.insert(String(cString:name))}}
        }
        sqlite3_finalize(schema)
        var tierFields:[String]=[]
        for field in ["service_tier_served","service_tier_requested"] where columns.contains(field) {tierFields.append("nullif(trim(u.\(field)), '')")}
        tierFields.append("nullif(trim(u.mode), '')");tierFields.append("'unknown'")
        let tierExpression="lower(trim(coalesce("+tierFields.joined(separator:", ")+")))"
        let eligible=cached ? "u.speed_eligible=1" : "EXISTS(SELECT 1 FROM \(speedTable) s WHERE s.source=u.source AND s.source_id=u.source_id)"
        let metadata=columns.contains("raw_json") ? "CASE WHEN json_valid(u.raw_json) THEN u.raw_json ELSE '{}' END" : "'{}'"
        let sql="""
        SELECT coalesce(nullif(trim(model),''),'Unknown model'),reasoning_effort,
          CASE \(tierExpression) WHEN 'default' THEN 'standard' WHEN 'priority' THEN 'fast' WHEN '' THEN 'unknown' ELSE \(tierExpression) END,
          completed_at,output_tokens,duration_ms,output_tokens_per_second,\(eligible),source,source_id,
          json_extract(\(metadata),'$.selected_reasoning_effort'),json_extract(\(metadata),'$.reported_reasoning_effort'),
          json_extract(\(metadata),'$.selected_effort_source'),coalesce(json_extract(\(metadata),'$.selected_effort_conflict'),0),
          coalesce(json_extract(\(metadata),'$.identity_conflict'),0),json_extract(\(metadata),'$.matching_streams'),json_extract(\(metadata),'$.matching_completions'),
          \(columns.contains("ttft_ms") ? "u.ttft_ms" : "NULL"),\(columns.contains("input_tokens") ? "u.input_tokens" : "NULL")
        FROM \(usageTable) u WHERE julianday(completed_at)>=julianday(?,'unixepoch')-30
        ORDER BY julianday(completed_at) DESC,source,source_id DESC
        """
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK else { report.error="Measurements unavailable; the existing snapshot could not be read.";return report }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt,1,now.timeIntervalSince1970)
        struct Key:Hashable {let model:String;let effort:String;let mode:String}
        var groups:[Key:SpeedModeGroup]=[:]
        var latest:[String:Date]=[:]
        func string(_ i:Int32)->String { sqlite3_column_text(stmt,i).map {String(cString:$0)} ?? "" }
        var step=sqlite3_step(stmt)
        while step==SQLITE_ROW {
            if let date=parseISO(string(3)) {
                let selectedValue=string(10),source=string(12)
                let verified=["parent_turn","retained_parent_turn"].contains(source) && sqlite3_column_int(stmt,13)==0 && sqlite3_column_int(stmt,14)==0 && sqlite3_column_int(stmt,15)==1 && sqlite3_column_int(stmt,16)==1 && ["minimal","low","medium","high","xhigh","max","ultra"].contains(normalizedEffort(selectedValue) ?? "")
                let rawSelected=selectedValue.isEmpty ? nil : selectedValue
                let selected=verified ? rawSelected : nil
                let reported:String?
                if sqlite3_column_type(stmt,11) != SQLITE_NULL {reported=string(11)}
                else if sqlite3_column_type(stmt,1) != SQLITE_NULL {reported=string(1)}
                else {reported=nil}
                let key=Key(model:string(0),effort:normalizedEffort(selected ?? reported) ?? "unknown",mode:string(2))
                // Remove the value before appending so its growing arrays have unique
                // ownership instead of copying the entire history for every row.
                var group=groups.removeValue(forKey:key) ?? SpeedModeGroup(mode:key.mode)
                group.responseDates.append(date)
                group.effortEvidence.append(EffortEvidence(date:date,selected:rawSelected,reported:reported,source:source,verified:verified,selectedConflict:sqlite3_column_int(stmt,13) != 0,identityConflict:sqlite3_column_int(stmt,14) != 0))
                group.latestResponse=max(group.latestResponse,date)
                latest[key.model]=max(latest[key.model] ?? .distantPast,date)
                let duration=sqlite3_column_double(stmt,5),speed=sqlite3_column_double(stmt,6),output=sqlite3_column_int64(stmt,4)
                let valid=date<=now && measuredReplyEligible(legacyEligible:sqlite3_column_int(stmt,7)==1,matchingStreams:Int(sqlite3_column_int(stmt,15)),matchingCompletions:Int(sqlite3_column_int(stmt,16)),identityConflict:sqlite3_column_int(stmt,14) != 0,durationMS:duration,outputTokens:output,speed:sqlite3_column_type(stmt,6)==SQLITE_NULL ? nil : speed)
                if valid {
                    var reading=SpeedReading(id:string(8)+":"+string(9),date:date,speed:speed,outputTokens:output,durationMS:duration,selectedEffort:rawSelected,reportedEffort:reported,effortSource:source,selectedEffortVerified:verified,selectedEffortConflict:sqlite3_column_int(stmt,13) != 0,identityConflict:sqlite3_column_int(stmt,14) != 0)
                    if sqlite3_column_type(stmt,17) != SQLITE_NULL {reading.ttftMS=sqlite3_column_double(stmt,17)}
                    if sqlite3_column_type(stmt,18) != SQLITE_NULL {reading.inputTokens=sqlite3_column_int64(stmt,18)}
                    group.readings.append(reading)
                } else { group.excluded+=1;group.excludedDates.append(date) }
                groups[key]=group
            }
            step=sqlite3_step(stmt)
        }
        if step != SQLITE_DONE { report.error="Measurement read failed; refresh to retry." }
        let effortRank=["minimal","low","medium","high","xhigh","max","ultra","unspecified","unknown"]
        func rank(_ e:String)->Int { effortRank.firstIndex(of:e) ?? effortRank.count }
        for model in latest.keys.sorted(by:{latest[$0]! == latest[$1]! ? $0<$1 : latest[$0]!>latest[$1]!}) {
            let keys=groups.keys.filter{$0.model==model}
            let efforts=Set(keys.map(\.effort)).sorted {rank($0)==rank($1) ? $0<$1 : rank($0)<rank($1)}
            let rows=efforts.map {effort in
                let modes=keys.filter{$0.effort==effort}.map {groups[$0]!}
                return SpeedEffortGroup(effort:effort,modes:orderedModes(modes))
            }
            report.models.append(SpeedModelGroup(model:model,efforts:rows,latestResponse:latest[model]!))
        }
        report.calendarIndex=ReplyCalendarIndex(dates:report.models.flatMap {$0.efforts.flatMap {$0.modes.flatMap {$0.readings.map(\.date)}}},calendar:readingCalendar)
        return report
    }
}
func measurementAge(_ date:Date?,now:Date)->String {
    guard let date else{return "No valid timing"}
    let age=now.timeIntervalSince(date)
    if age < -5{return "Clock ahead"}
    if age<60{return "\(max(0,Int(age)))s ago"}
    if age<3600{return "\(Int(age/60))m ago"}
    if age<86400{return "\(Int(age/3600))h ago"}
    return "\(Int(age/86400))d ago"
}
func speedText(_ speed:Double?)->String {speed.map{String(format:"%.1f",$0)} ?? "—"}
// MARK: - Visual system
// One neutral dark surface, one data accent (trend lines and charts) and one
// link colour for things you can click. Tiers are told apart by name, not hue.
// Workbench palette (4 Nov). Roles, not decoration: purple = go somewhere / open a
// menu; yellow = slower; green = faster; everything else is neutral. Text colors
// keep ≥ 5:1 contrast on the panel; `quiet` is for disabled or empty only.
enum SpeedTheme {
    static let surface=Color(red:0.086,green:0.086,blue:0.102)     // #16161A panel
    static let window=Color(red:0.055,green:0.055,blue:0.067)      // #0E0E11 report background
    static let primary=Color(red:0.902,green:0.902,blue:0.918)     // #E6E6EA
    static let secondary=Color(red:0.631,green:0.631,blue:0.667)   // #A1A1AA
    static let tertiary=Color(red:0.557,green:0.557,blue:0.596)    // #8E8E98
    static let quiet=Color(red:0.369,green:0.369,blue:0.400)       // #5E5E66 disabled / empty
    static let hairline=Color.white.opacity(0.08)
    static let divider=Color.white.opacity(0.10)
    static let accent=Color(red:0.753,green:0.518,blue:0.988)      // #C084FC
    static let link=Color(red:0.753,green:0.518,blue:0.988)        // clickable = purple
    static let track=Color(red:0.067,green:0.067,blue:0.078)       // #111114 segmented track
    static let selectedSegment=Color(red:0.165,green:0.165,blue:0.192) // #2A2A31
    static let card=Color(red:0.071,green:0.071,blue:0.082)        // #121215 inset panel
    static let cardStroke=Color.white.opacity(0.08)
    static let tile=Color(red:0.106,green:0.106,blue:0.125)        // #1B1B20
    static let tileHover=Color(red:0.141,green:0.141,blue:0.165)   // #24242A
    static let slower=Color(red:1.0,green:0.271,blue:0.227)
    static let faster=Color(red:0.290,green:0.871,blue:0.502)      // #4ADE80
    static let slowerYellow=Color(red:0.961,green:0.769,blue:0.318) // #F5C451
    static let chartLine=Color(red:0.784,green:0.784,blue:0.816)   // #C8C8D0
}
// Short monospaced caps for section labels (three words or fewer), with an optional rule.
struct SectionLabel:View {
    let text:String
    var rule=true
    var color:Color=SpeedTheme.tertiary
    var body:some View {
        HStack(spacing:8) {
            Text(text.uppercased()).font(.system(size:10,weight:.regular,design:.monospaced)).tracking(0.8).foregroundStyle(color).lineLimit(1).layoutPriority(1)
            if rule {Rectangle().fill(SpeedTheme.hairline).frame(height:1)}
        }.accessibilityAddTraits(.isHeader)
    }
}
// Data, never clickable: a tinted verdict badge; neutral verdicts are plain caps.
enum BadgeTone {case slower,faster,neutral}
struct VerdictBadge:View {
    let text:String
    let tone:BadgeTone
    var body:some View {
        let color=tone == .slower ? SpeedTheme.slowerYellow : tone == .faster ? SpeedTheme.faster : SpeedTheme.tertiary
        Text(text.uppercased()).font(.system(size:10,weight:.bold,design:.monospaced)).tracking(0.8).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal,tone == .neutral ? 0 : 6).frame(height:20)
            .background(RoundedRectangle(cornerRadius:4).fill(tone == .neutral ? Color.clear : color.opacity(0.12)))
    }
}
// Purple chip: go somewhere or open a menu. 28 pt tall, hover and press states.
struct ChipButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {ChipButtonBody(configuration:configuration)}
}
private struct ChipButtonBody:View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration:ButtonStyle.Configuration
    @State private var hovering=false
    var body:some View {
        let on=hovering && isEnabled
        configuration.label
            .font(.system(size:12,weight:.medium)).foregroundStyle(SpeedTheme.accent)
            .padding(.horizontal,10).frame(minHeight:28)
            .background(RoundedRectangle(cornerRadius:7).fill(SpeedTheme.accent.opacity(configuration.isPressed ? 0.06 : (on ? 0.18 : 0.10))))
            .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(SpeedTheme.accent.opacity(on ? 0.60 : 0.40),lineWidth:1))
            .contentShape(RoundedRectangle(cornerRadius:7))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover {hovering=$0}
            .pointingHand()
    }
}
// MARK: - Interaction language
// One look per job so it's obvious what can be clicked:
// containers are flat; data tiles are color only; buttons and menus have an outline,
// a light fill and hover/press states; links are blue text; clickable cells and rows
// carry a visible ›; anything right-click can do also has a visible ⋯ button.
struct PointingHandCursor:ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var pushed=false
    @State private var hovering=false
    private func updateCursor() {
        if hovering && isEnabled && !pushed {NSCursor.pointingHand.push();pushed=true}
        else if (!hovering || !isEnabled) && pushed {NSCursor.pop();pushed=false}
    }
    func body(content:Content)->some View {
        content
            .onHover {inside in hovering=inside;updateCursor()}
            .onChange(of:isEnabled) {_ in updateCursor()}
            .onDisappear {if pushed {NSCursor.pop();pushed=false}}
    }
}
extension View {func pointingHand()->some View {modifier(PointingHandCursor())}}
struct OutlineButtonStyle:ButtonStyle {
    var compact=false
    func makeBody(configuration:Configuration)->some View {OutlineButtonBody(configuration:configuration,compact:compact)}
}
private struct OutlineButtonBody:View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration:ButtonStyle.Configuration
    let compact:Bool
    @State private var hovering=false
    var body:some View {
        let fill=configuration.isPressed ? 0.03 : (hovering && isEnabled ? 0.12 : 0.06)
        let stroke=hovering && isEnabled && !configuration.isPressed ? 0.32 : 0.20
        configuration.label
            .font(.system(size:12,weight:.medium)).foregroundStyle(SpeedTheme.primary)
            .padding(.horizontal,compact ? 6 : 10).frame(minWidth:24,minHeight:24)
            .background(RoundedRectangle(cornerRadius:6).fill(Color.white.opacity(fill)))
            .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(Color.white.opacity(stroke),lineWidth:1))
            .contentShape(RoundedRectangle(cornerRadius:6))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover {hovering=$0}
            .pointingHand()
    }
}
struct LinkTextButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {LinkTextBody(configuration:configuration)}
}
private struct LinkTextBody:View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration:ButtonStyle.Configuration
    @State private var hovering=false
    var body:some View {
        configuration.label.foregroundStyle(SpeedTheme.link.opacity(!isEnabled ? 0.45 : configuration.isPressed ? 0.6 : 1)).underline(hovering && isEnabled)
            .contentShape(Rectangle()).onHover {hovering=$0}.pointingHand()
    }
}
// A menu that looks like a button: label first, ⌄ after, outlined.
struct MenuButton:View {
    let title:String
    let options:[(id:String,label:String)]
    let select:(String)->Void
    @State private var open=false
    var body:some View {
        Button {open.toggle()} label: {
            HStack(spacing:6) {
                Text(title).lineLimit(1)
                Image(systemName:"chevron.down").font(.system(size:9,weight:.semibold))
            }
        }
        .buttonStyle(ChipButtonStyle())
        .accessibilityHint("Opens a list")
        .popover(isPresented:$open,arrowEdge:.bottom) {
            VStack(alignment:.leading,spacing:2) {
                ForEach(Array(options.enumerated()),id:\.offset) {_,o in
                    Button {select(o.id);open=false} label: {
                        HStack(spacing:8) {
                            Image(systemName:"checkmark").font(.system(size:10,weight:.semibold)).opacity(o.label==title ? 1 : 0)
                            Text(o.label).font(.system(size:12))
                            Spacer(minLength:0)
                        }.padding(.horizontal,8).frame(minWidth:160,minHeight:24,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(MenuRowStyle())
                }
            }.padding(4)
        }
    }
}
struct MenuRowStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {MenuRowBody(configuration:configuration)}
}
private struct MenuRowBody:View {
    let configuration:ButtonStyle.Configuration
    @State private var hovering=false
    var body:some View {
        configuration.label.foregroundStyle(SpeedTheme.primary)
            .background(RoundedRectangle(cornerRadius:4).fill(hovering ? SpeedTheme.link.opacity(0.35) : Color.clear))
            .onHover {hovering=$0}
    }
}
func readingTime(_ date:Date)->String {
    clockFormatter("dd MMM yyyy "+clockPattern(seconds:true)+" zzz").string(from:date)
}
func modeTitle(_ mode:String)->String { mode == "unknown" ? "Unknown mode" : mode.capitalized }
func freshness(_ date:Date?,now:Date)->String {
    guard let date else{return "No valid timing"}
    return measurementAge(date,now:now)+(now.timeIntervalSince(date)>86400 ? " · stale" : "")
}
func wholeSpeed(_ speed:Double?)->String {speed.map{String(format:"%.0f",$0)} ?? "—"}
func recency(_ date:Date?,now:Date)->String {
    guard let date else{return "no valid timing"}
    let age=now.timeIntervalSince(date)
    if age >= -5 && age<60 {return "just now"}
    return measurementAge(date,now:now)
}
func responseCount(_ n:Int)->String {n==1 ? "1 reply" : "\(n.formatted()) replies"}
// Tiles are narrow: 2,812 → "2.8k", 12,400 → "12k".
func compactCount(_ n:Int)->String {
    if n<1000 {return "\(n)"}
    if n<9950 {
        let s=String(format:"%.1f",Double(n)/1000)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s)+"k"
    }
    return "\(Int((Double(n)/1000).rounded()))k"
}
func compactReplies(_ n:Int)->String {n==1 ? "1 reply" : compactCount(n)+" replies"}
// Approximate two-sided 95% margin for the unweighted response-speed mean,
// in t/s: t(.975, n-1) * sample SD / sqrt(n). It is not response spread.
// Small-df values: NIST e-Handbook, eda3672 (.975 column); for df > 30,
// the inverse-t asymptotic expansion avoids understating skipped table rows.
func tCritical(_ df:Int)->Double {
    precondition(df>=4)
    let small:[Double]=[2.776,2.571,2.447,2.365,2.306,2.262,2.228,2.201,2.179,2.160,2.145,2.131,2.120,2.110,2.101,2.093,2.086,2.080,2.074,2.069,2.064,2.060,2.056,2.052,2.048,2.045,2.042]
    if df<=30 {return small[df-4]}
    let z=1.959963984540054,d=Double(df),z2=z*z
    return z+(z*z2+z)/(4*d)+(5*z*z2*z2+16*z*z2+3*z)/(96*d*d)+(3*z*z2*z2*z2+19*z*z2*z2+17*z*z2-15*z)/(384*d*d*d)
}
func marginOfError(_ speeds:[Double])->Double? {
    let n=speeds.count
    guard n>=5,speeds.allSatisfy({$0.isFinite}) else{return nil}
    let mean=speeds.reduce(0,+)/Double(n)
    let variance=speeds.reduce(0.0) {$0+($1-mean)*($1-mean)}/Double(n-1)
    return tCritical(n-1)*variance.squareRoot()/Double(n).squareRoot()
}
func marginText(_ margin:Double)->String {margin==0 ? "±0" : margin<0.5 ? "±<1" : "±\(Int(margin.rounded()))"}
func tokenText(_ n:Int64)->String {
    let d=Double(n)
    if d>=999_500 {return String(format:"%.1fM",d/1_000_000)}
    if d>=10_000 {return "\(Int((d/1000).rounded()))k"}
    if d>=1000 {let s=String(format:"%.1f",d/1000);return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s)+"k"}
    return "\(n)"
}
// Overview columns run slowest to fastest. Standard, Fast and Ultrafast are
// always shown, in this order, so cells never move between ranges or models.
let fixedTierColumns=["standard","fast","ultrafast"]
func tierOrder(_ names:[String])->[String] {
    let order=fixedTierColumns
    return names.sorted {let a=order.firstIndex(of:$0) ?? 9,b=order.firstIndex(of:$1) ?? 9;return a==b ? $0<$1 : a<b}
}
func effortShortTitle(_ effort:String)->String {
    switch effort {case "xhigh":return "Extra high";case "unknown":return "Unknown";default:return effort.capitalized}
}
// MARK: - Clock (12 / 24-hour)
// "system" follows the Mac's own setting; "12" and "24" override it (set in the Report window).
let clockStyleKey="clockStyle"
func clockIs24Hour(_ style:String?=UserDefaults.standard.string(forKey:clockStyleKey),locale:Locale = .current)->Bool {
    switch style {
    case "12":return false
    case "24":return true
    default:return !(DateFormatter.dateFormat(fromTemplate:"j",options:0,locale:locale) ?? "H").contains("a")
    }
}
func clockFormatter(_ pattern:String)->DateFormatter {
    let f=DateFormatter();f.timeZone = .current;f.locale=Locale(identifier:"en_US_POSIX");f.amSymbol="am";f.pmSymbol="pm";f.dateFormat=pattern;return f
}
func clockPattern(seconds:Bool,twentyFour:Bool=clockIs24Hour())->String {
    twentyFour ? (seconds ? "HH:mm:ss" : "HH:mm") : (seconds ? "h:mm:ss a" : "h:mm a")
}
func clockTime(_ date:Date,seconds:Bool=false,twentyFour:Bool=clockIs24Hour())->String {clockFormatter(clockPattern(seconds:seconds,twentyFour:twentyFour)).string(from:date)}
// Whole hours: "07:00" or "7am".
func hourClock(_ h:Int,twentyFour:Bool=clockIs24Hour())->String {
    twentyFour ? String(format:"%02d:00",h) : "\((h%12)==0 ? 12 : h%12)\(h<12 || h==24 ? "am" : "pm")"
}
// Grid column ticks: "03" or "3a".
func hourTick(_ h:Int,twentyFour:Bool=clockIs24Hour())->String {
    twentyFour ? String(format:"%02d",h) : "\((h%12)==0 ? 12 : h%12)\(h<12 ? "a" : "p")"
}
// Fits "23:59:59" or "12:59:59 pm" on one line (12-hour times need the wider column).
var responseTimeWidth:CGFloat {clockIs24Hour() ? 64 : 88}
func listTime(_ date:Date,now:Date)->String {
    now.timeIntervalSince(date)<86400 ? clockTime(date,seconds:true) : clockFormatter("d MMM ").string(from:date)+clockTime(date)
}
func axisTime(_ date:Date,range:SpeedTimeRange)->String {
    range.seconds>86400 ? clockFormatter("d MMM").string(from:date) : clockTime(date)
}
func tierTone(_ mode:String)->Color {
    switch mode {case "standard":return Color(red:1,green:0.77,blue:0.46);case "fast":return Color(red:0.45,green:0.80,blue:1);case "ultrafast":return Color(red:0.80,green:0.69,blue:1);default:return Color(red:0.80,green:0.85,blue:0.93)}
}
func shortReadingTime(_ date:Date,now:Date)->String {
    clockFormatter(now.timeIntervalSince(date)<86400 ? clockPattern(seconds:true)+" zzz" : "dd MMM "+clockPattern(seconds:false)+" zzz").string(from:date)
}
func periodBounds(range:SpeedTimeRange,now:Date)->String {
    let f=clockFormatter("dd MMM "+clockPattern(seconds:false)+" zzz")
    return f.string(from:now.addingTimeInterval(-range.seconds))+" → "+f.string(from:now)
}
func graphTime(_ date:Date,range:SpeedTimeRange)->String {
    range.seconds>86400 ? clockFormatter("dd MMM").string(from:date) : clockTime(date)
}
extension SpeedTimeRange {
    // Detail chart buckets: a readable number of slices with a nameable width.
    var chartBins:(count:Int,label:String) {
        switch self {case .hour:return (12,"5 min");case .fourHours:return (16,"15 min");case .twelveHours:return (24,"30 min");case .day:return (24,"hour");case .week:return (28,"6 hours");case .month:return (30,"day")}
    }
    var axisStep:TimeInterval {
        switch self {case .hour:return 900;case .fourHours:return 3600;case .twelveHours:return 3*3600;case .day:return 6*3600;case .week:return 86400;case .month:return 7*86400}
    }
}

// MARK: - Trend data (presentation only; never changes grouping or means)
func percentile(_ sorted:[Double],_ p:Double)->Double {
    guard !sorted.isEmpty else{return 0}
    let k=Double(sorted.count-1)*p,f=Int(k.rounded(.down)),c=min(f+1,sorted.count-1)
    return sorted[f]+(sorted[c]-sorted[f])*(k-Double(f))
}
struct SpeedTrend {
    let points:[Double?]
    let mean:Double
}
// A row trend needs at least 10 readings spread over 3 or more of its 12 slices;
// otherwise the row shows a quiet dash instead of a jagged line.
func speedTrend(_ readings:[SpeedReading],range:SpeedTimeRange,now:Date,buckets:Int=12)->SpeedTrend? {
    guard readings.count>=10 else{return nil}
    let start=now.addingTimeInterval(-range.seconds),width=range.seconds/Double(buckets)
    var sums=Array(repeating:0.0,count:buckets),counts=Array(repeating:0,count:buckets)
    for r in readings where r.date>=start && r.date<=now {
        let i=min(buckets-1,max(0,Int(r.date.timeIntervalSince(start)/width)))
        sums[i]+=r.speed;counts[i]+=1
    }
    let points:[Double?]=(0..<buckets).map {counts[$0]>0 ? sums[$0]/Double(counts[$0]) : nil}
    guard points.compactMap({$0}).count>=3 else{return nil}
    return SpeedTrend(points:points,mean:readings.reduce(0){$0+$1.speed}/Double(readings.count))
}
struct SpeedBin:Identifiable {
    let id:Int
    let date:Date
    let mean:Double
    let p25:Double
    let p75:Double
    let count:Int
    let segment:Int
}
// Detail chart slices. Empty slices are skipped and start a new segment, so the
// chart breaks where there was no data instead of drawing across the gap.
func speedBins(_ readings:[SpeedReading],range:SpeedTimeRange,now:Date)->[SpeedBin] {
    let count=range.chartBins.count,start=now.addingTimeInterval(-range.seconds),width=range.seconds/Double(count)
    var buckets=Array(repeating:[Double](),count:count)
    for r in readings where r.date>=start && r.date<=now {buckets[min(count-1,max(0,Int(r.date.timeIntervalSince(start)/width)))].append(r.speed)}
    var bins:[SpeedBin]=[],segment=0,previous = -2
    for (i,values) in buckets.enumerated() where !values.isEmpty {
        if i != previous+1 {segment+=1}
        previous=i
        let sorted=values.sorted()
        bins.append(SpeedBin(id:i,date:start.addingTimeInterval(width*(Double(i)+0.5)),mean:values.reduce(0,+)/Double(values.count),p25:percentile(sorted,0.25),p75:percentile(sorted,0.75),count:values.count,segment:segment))
    }
    return bins
}
// Smooth curve through points (Catmull-Rom converted to cubic Béziers).
func appendSmooth(_ pts:[CGPoint],to path:inout Path,move:Bool) {
    guard let first=pts.first else{return}
    if move {path.move(to:first)} else {path.addLine(to:first)}
    guard pts.count>1 else{return}
    for i in 0..<(pts.count-1) {
        let p0=pts[max(i-1,0)],p1=pts[i],p2=pts[i+1],p3=pts[min(i+2,pts.count-1)]
        let c1=CGPoint(x:p1.x+(p2.x-p0.x)/6,y:p1.y+(p2.y-p0.y)/6)
        let c2=CGPoint(x:p2.x-(p3.x-p1.x)/6,y:p2.y-(p3.y-p1.y)/6)
        path.addCurve(to:p2,control1:c1,control2:c2)
    }
}

// MARK: - Layout helpers
private struct SpeedHeightKey:PreferenceKey {
    static let defaultValue:CGFloat=0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) {value=max(value,nextValue())}
}
// Scrolls only when needed: the window hugs short content and caps tall content.
struct FittingScroll<Content:View>:View {
    let maxHeight:CGFloat
    var scrolled:Binding<Bool>?=nil
    @ViewBuilder let content:()->Content
    @State private var contentHeight:CGFloat=0
    var body:some View {
        ScrollView {
            content()
                .background(GeometryReader {proxy in Color.clear.preference(key:SpeedHeightKey.self,value:proxy.size.height)})
                .background(GeometryReader {proxy in Color.clear.preference(key:FittingScrollOffsetKey.self,value:proxy.frame(in:.named("fittingScroll")).minY)})
        }
        .coordinateSpace(name:"fittingScroll")
        .frame(height:contentHeight>0 ? min(contentHeight,maxHeight) : nil)
        .onPreferenceChange(SpeedHeightKey.self) {contentHeight=$0}
        .onPreferenceChange(FittingScrollOffsetKey.self) {y in
            if let scrolled,(y < -1) != scrolled.wrappedValue {scrolled.wrappedValue = y < -1}
        }
    }
}
private struct FittingScrollOffsetKey:PreferenceKey {
    static let defaultValue:CGFloat=0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) {value=nextValue()}
}
// Keep the hint open while crossing into it, but close promptly after leaving.
// All calls come from the main UI thread; cancellation prevents an old exit from
// dismissing a newly entered hint.
final class SpeedInfoHoverState:ObservableObject {
    @Published private(set) var isPresented=false
    private var triggerHovered=false
    private var contentHovered=false
    private var closeTask:Task<Void,Never>?
    static let exitDelayNS:UInt64=80_000_000
    func triggerHover(_ inside:Bool) {
        triggerHovered=inside
        if inside {closeTask?.cancel();isPresented=true} else {scheduleClose()}
    }
    func contentHover(_ inside:Bool) {
        contentHovered=inside
        if inside {closeTask?.cancel()} else {scheduleClose()}
    }
    func setPresented(_ shown:Bool) {
        closeTask?.cancel()
        isPresented=shown
        if !shown {contentHovered=false}
    }
    func toggle() {setPresented(!isPresented)}
    func dismiss() {triggerHovered=false;contentHovered=false;setPresented(false)}
    private func scheduleClose() {
        closeTask?.cancel()
        guard !triggerHovered && !contentHovered else{return}
        closeTask=Task { @MainActor in
            do {try await Task.sleep(nanoseconds:Self.exitDelayNS)} catch {return}
            guard !Task.isCancelled,!triggerHovered,!contentHovered else{return}
            isPresented=false
        }
    }
}
// The (?) hint: what the number is, then a key that shows each mark exactly as the tiles do.
struct SpeedInfoContent:View {
    func keyRow<Sample:View>(_ text:String,@ViewBuilder sample:()->Sample)->some View {
        HStack(spacing:12) {
            sample().frame(width:56,alignment:.trailing)
            Text(text).font(.system(size:12)).foregroundStyle(SpeedTheme.primary)
                .fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
        }.frame(minHeight:28)
    }
    func sample(_ value:String,marker:SpeedMarker?=nil,dim:Bool=false)->some View {
        HStack(spacing:3) {
            if let marker {SpeedMarkerGlyph(marker:marker)}
            Text(value).font(.system(size:15,weight:.semibold)).monospacedDigit().foregroundStyle(dim ? SpeedTheme.secondary : SpeedTheme.primary)
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            Text("HOW TO READ THE TILES").font(.system(size:10,weight:.medium,design:.monospaced)).tracking(0.8).foregroundStyle(SpeedTheme.primary)
            Text("Each number is generating speed: output tokens ÷ the time after output starts. Estimated from Codex’s first-output timing; the wait before output isn’t in it.")
                .font(.system(size:12)).foregroundStyle(SpeedTheme.secondary).padding(.top,8)
            VStack(alignment:.leading,spacing:8) {
                keyRow("Faster than your usual for these hours") {sample("132",marker:.faster)}
                keyRow("Slower than your usual for these hours") {sample("41",marker:.slower)}
                keyRow("Rough: too few replies to trust yet") {sample("~53",dim:true)}
                keyRow("Not used in this time range") {
                    Text("—").font(.system(size:12)).foregroundStyle(SpeedTheme.quiet).frame(width:40,height:24)
                        .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(Color.white.opacity(0.14),style:StrokeStyle(lineWidth:1,dash:[3,3])))
                }
            }.padding(.top,16)
            Rectangle().fill(SpeedTheme.hairline).frame(height:1).padding(.top,16)
            Text("A line under the tiles explains each ▲ or ▼. Replies under 100 tokens aren’t counted. Click a tile for its wait and overall speed.")
                .font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).padding(.top,12)
        }
        .fixedSize(horizontal:false,vertical:true)
        .frame(width:288,alignment:.leading).padding(16)
        // Popovers are separate presentations: the widget's dark preference is
        // not enough to set their native surface in a light system appearance.
        .background(SpeedTheme.surface)
        .preferredColorScheme(.dark)
    }
}
// A native presenter gives this small hover hint an immediate close rather
// than the system popover fade, and binds its arrow/chrome to the same dark theme.
struct SpeedInfoPopoverAnchor:NSViewRepresentable {
    @ObservedObject var hint:SpeedInfoHoverState
    final class Anchor:NSView {
        var windowChanged:(()->Void)?
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();windowChanged?()}
        override func hitTest(_ point:NSPoint)->NSView? {nil}
    }
    final class Coordinator:NSObject,NSPopoverDelegate {
        var hint:SpeedInfoHoverState
        let popover=NSPopover()
        init(hint:SpeedInfoHoverState) {
            self.hint=hint
            super.init()
            popover.behavior = .transient
            popover.animates=false
            popover.appearance=NSAppearance(named:.darkAqua)
            popover.delegate=self
            let host=NSHostingController(rootView:SpeedInfoContent().onHover {[weak self] inside in self?.hint.contentHover(inside)})
            popover.contentViewController=host
            // Ask SwiftUI for the laid-out text size; an unattached AppKit
            // view's fittingSize can still be only one point at this stage.
            host.sizingOptions = .preferredContentSize
            popover.contentSize=host.sizeThatFits(in:NSSize(width:304,height:CGFloat.greatestFiniteMagnitude))
        }
        func update(_ anchor:Anchor) {
            DispatchQueue.main.async {[weak self,weak anchor] in
                guard let self,let anchor else{return}
                if !self.hint.isPresented {
                    if self.popover.isShown {self.popover.performClose(nil)}
                } else if anchor.window != nil && !self.popover.isShown {
                    self.popover.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.minY)
                }
            }
        }
        func popoverDidClose(_ notification:Notification) {
            if hint.isPresented {hint.setPresented(false)}
        }
    }
    func makeCoordinator()->Coordinator {Coordinator(hint:hint)}
    func makeNSView(context:Context)->Anchor {
        let anchor=Anchor()
        anchor.windowChanged={[weak coordinator=context.coordinator,weak anchor] in
            if let anchor {coordinator?.update(anchor)}
        }
        return anchor
    }
    func updateNSView(_ anchor:Anchor,context:Context) {
        context.coordinator.hint=hint
        context.coordinator.update(anchor)
    }
    static func dismantleNSView(_ anchor:Anchor,coordinator:Coordinator) {
        anchor.windowChanged=nil
        coordinator.popover.performClose(nil)
    }
}
// A (?) that explains what the overview numbers mean. Opens on hover or click.
struct SpeedInfoButton:View {
    @StateObject private var hint=SpeedInfoHoverState()
    @State private var hovering=false
    var body:some View {
        Button {hint.toggle()} label: {
            Image(systemName:"questionmark.circle").font(.system(size:12,weight:.medium))
                .foregroundStyle(hovering || hint.isPresented ? SpeedTheme.primary : SpeedTheme.tertiary)
                .frame(width:16,height:16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .onHover {inside in hovering=inside;hint.triggerHover(inside)}
        .onDisappear {hint.dismiss()}
        .accessibilityLabel("What these numbers mean")
        .background(SpeedInfoPopoverAnchor(hint:hint))
    }
}

// MARK: - Controls
struct ExplicitSegmentButton:View {
    let title:String
    let selected:Bool
    let action:()->Void
    var body:some View {
        Button(action:action) {
            Text(title).font(.system(size:12,weight:selected ? .semibold : .medium))
                .foregroundStyle(selected ? SpeedTheme.primary : SpeedTheme.secondary)
                .frame(maxWidth:.infinity,minHeight:24)
                .background(RoundedRectangle(cornerRadius:6).fill(selected ? SpeedTheme.selectedSegment : Color.clear).shadow(color:Color.black.opacity(selected ? 0.35 : 0),radius:1,y:1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand().accessibilityValue(selected ? "Selected" : "Not selected").accessibilityAddTraits(selected ? .isSelected : [])
    }
}
struct SpeedRangeControl:View {
    @Binding var value:String
    var body:some View {
        HStack(spacing:2) {ForEach(SpeedTimeRange.allCases,id:\.self) {range in ExplicitSegmentButton(title:range.title,selected:value==range.rawValue) {value=range.rawValue}.help(range.label)}}
            .padding(2).background(SpeedTheme.track,in:RoundedRectangle(cornerRadius:8))
            .accessibilityElement(children:.contain).accessibilityLabel("Time range")
    }
}
struct VisibleBackButton:View {
    let action:()->Void
    var body:some View {
        Button(action:action) {
            HStack(spacing:4) {Image(systemName:"chevron.left").font(.system(size:10,weight:.semibold));Text("Overview")}
        }.buttonStyle(ChipButtonStyle()).accessibilityLabel("Back to overview").keyboardShortcut(.cancelAction)
    }
}
struct CoverageCaption:View {
    let report:RecentSpeedReport
    let range:SpeedTimeRange
    let now:Date
    var body:some View {
        if let oldest=report.oldestAvailable,oldest>now.addingTimeInterval(-range.seconds) {
            Text("Partial history: the earliest available response is from \(listTime(oldest,now:now)).")
                .font(.system(size:11)).foregroundStyle(Color.orange.opacity(0.9)).fixedSize(horizontal:false,vertical:true)
                .padding(.horizontal,16).padding(.top,6)
        }
    }
}

// MARK: - Overview
struct TrendSparkline:View {
    let trend:SpeedTrend
    var body:some View {
        Canvas {ctx,size in
            let values=trend.points.compactMap{$0}
            guard let minV=values.min(),let maxV=values.max() else{return}
            // Pad the scale to ±30% of the mean so steady speeds look steady.
            let lo=min(trend.mean*0.7,minV),hi=max(trend.mean*1.3,maxV),span=max(hi-lo,0.0001)
            let n=trend.points.count
            func x(_ i:Int)->CGFloat {n<=1 ? size.width/2 : 2+CGFloat(i)*(size.width-4)/CGFloat(n-1)}
            func y(_ v:Double)->CGFloat {size.height-2-CGFloat((v-lo)/span)*(size.height-4)}
            var avg=Path();avg.move(to:CGPoint(x:0,y:y(trend.mean)));avg.addLine(to:CGPoint(x:size.width,y:y(trend.mean)))
            ctx.stroke(avg,with:.color(Color.white.opacity(0.18)),style:StrokeStyle(lineWidth:1,dash:[2,3]))
            var line=Path(),run:[CGPoint]=[]
            func flush() {
                if run.count==1 {line.move(to:CGPoint(x:max(0,run[0].x-3),y:run[0].y));line.addLine(to:CGPoint(x:min(size.width,run[0].x+3),y:run[0].y))}
                else if let first=run.first {line.move(to:first);for p in run.dropFirst() {line.addLine(to:p)}}
                run.removeAll()
            }
            for (i,v) in trend.points.enumerated() {if let v {run.append(CGPoint(x:x(i),y:y(v)))} else {flush()}}
            flush()
            ctx.stroke(line,with:.color(SpeedTheme.accent),style:StrokeStyle(lineWidth:1.5,lineCap:.round,lineJoin:.round))
        }.frame(maxWidth:.infinity).frame(height:18).accessibilityHidden(true)
    }
}
struct TierSummarySection:View {
    let group:SpeedModeGroup
    let now:Date
    let context:String
    var compact=false
    var effort:String="unknown"
    var range:SpeedTimeRange = .day
    let action:()->Void
    @State private var hovering=false
    var body:some View {
        let stats=group.stats()
        let trend=speedTrend(stats.readings,range:range,now:now)
        let timed = !stats.readings.isEmpty
        let meta=timed ? "\(effortShortTitle(effort)) · \(responseCount(stats.readings.count)) · \(recency(stats.latest,now:now))" : "\(effortShortTitle(effort)) · \(responseCount(group.responseDates.count)), none timed"
        Button(action:action) {
            HStack(alignment:.center,spacing:12) {
                VStack(alignment:.leading,spacing:3) {
                    HStack(spacing:12) {
                        Text(modeTitle(group.mode)).font(.system(size:14)).foregroundStyle(SpeedTheme.primary).lineLimit(1).frame(width:88,alignment:.leading)
                        if let trend {TrendSparkline(trend:trend)} else {
                            Text("—").font(.system(size:12)).foregroundStyle(SpeedTheme.quiet).frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }.frame(height:18)
                    Text(meta).font(.system(size:12)).foregroundStyle(SpeedTheme.secondary).lineLimit(1)
                }
                HStack(alignment:.firstTextBaseline,spacing:2) {
                    Text(timed ? wholeSpeed(stats.mean) : "—").font(.system(size:20,weight:.semibold)).monospacedDigit()
                        .foregroundStyle(timed ? SpeedTheme.primary : SpeedTheme.tertiary)
                    if timed {Text("t/s").font(.system(size:11)).foregroundStyle(SpeedTheme.secondary)}
                }.frame(minWidth:56,alignment:.trailing)
                Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold)).foregroundStyle(SpeedTheme.tertiary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius:8).fill(hovering ? Color.white.opacity(0.05) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover {hovering=$0}
        .pointingHand()
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("\(modeTitle(group.mode)), \(effortShortTitle(effort)) effort")
        .accessibilityValue(timed ? "average \(wholeSpeed(stats.mean)) tokens per second, \(meta)" : meta)
        .accessibilityHint("Opens readings for \(context)")
        .accessibilityAddTraits(.isButton)
    }
}
extension SpeedEffortGroup {
    var measuredModes:[SpeedModeGroup] {orderedModes(modes.filter{!$0.readings.isEmpty})}
    var untimedModes:[SpeedModeGroup] {orderedModes(modes.filter{$0.readings.isEmpty && !$0.responseDates.isEmpty})}
    var summaryTitle:String {"Effort " + effortTitle(effort)}
    var selectedReadingCount:Int {modes.flatMap(\.readings).filter(\.usesSelected).count}
    var fallbackReadingCount:Int {modes.flatMap(\.readings).filter{!$0.usesSelected}.count}
    var attributionLabel:String? {
        if fallbackReadingCount>0 {return selectedReadingCount>0 ? "Includes fallback" : "Reported fallback"}
        return modes.contains{$0.mismatchCount>0} ? "Effort notes" : nil
    }
}
struct SpeedTierRow:Identifiable {
    let effort:SpeedEffortGroup
    let group:SpeedModeGroup
    var id:String {effort.effort+"|"+group.mode}
}
// Overview identity is still model → effective effort → tier. The effort is
// shown on each row (in its order) instead of as a header per group, so
// single-tier efforts don't cost a header each. Provenance stays per reading.
// MARK: - Usual (same effort + tier, same clock window on past days) and ▲/▼ markers
// Usual = middle (median) of daily averages over the same clock window on each of
// the past 14 days, for this exact effort and tier. A day counts with 3+ responses;
// needs 5+ such days. Normal range = 10th–90th percentile of those daily averages.
// A ▲/▼ marker needs 10+ responses now and must sit 10%+ beyond the normal range.
struct UsualBaseline {
    let median:Double
    let lo:Double
    let hi:Double
    let days:Int
    let dayMeans:[Double]
}
let usualMinDays=5
let usualMinDayResponses=3
let markerMinResponses=10
let markerMargin=0.10
func usualBaseline(_ history:[SpeedReading],start:Date,now:Date,lookbackDays:Int=14,calendar:Calendar = .current)->(baseline:UsualBaseline?,days:Int) {
    let today=calendar.startOfDay(for:now)
    var means:[Double]=[]
    for k in 1...lookbackDays {
        guard let a=calendar.date(byAdding:.day,value:-k,to:start),let b=calendar.date(byAdding:.day,value:-k,to:now) else{continue}
        let rs=history.filter {$0.date>=a && $0.date<=b && $0.date<today && $0.speed.isFinite}
        guard rs.count>=usualMinDayResponses else{continue}
        means.append(rs.reduce(0) {$0+$1.speed}/Double(rs.count))
    }
    means.sort()
    guard means.count>=usualMinDays else{return (nil,means.count)}
    return (UsualBaseline(median:percentile(means,0.5),lo:percentile(means,0.1),hi:percentile(means,0.9),days:means.count,dayMeans:means),means.count)
}
// First-output wait vs estimated generating speed. Wait = middle (median) wait; generating =
// total tokens ÷ total residual time after subtracting reported wait (per-reply rates blow up when
// the wait is most of a short reply).
let timingMethodExplanation="First output wait uses Codex’s reported first-output timing, not verified first-token latency. Generating (est.) divides output tokens by response duration minus that wait."
struct TimingSplit {
    let wait:Double
    let generating:Double
    var responses:Int=0
}
func timingSplit(_ rs:[SpeedReading])->TimingSplit? {
    let timed=rs.filter {$0.waitSeconds != nil}
    guard !timed.isEmpty else{return nil}
    let seconds=timed.reduce(0.0) {$0+($1.generatingSeconds ?? 0)}
    guard seconds.isFinite,seconds>0 else{return nil}
    let tokens=timed.reduce(0.0) {$0+Double($1.outputTokens)}
    let rate=tokens/seconds
    guard rate.isFinite,rate>=0 else{return nil}
    return TimingSplit(wait:percentile(timed.compactMap(\.waitSeconds).sorted(),0.5),generating:rate,responses:timed.count)
}
// Usual wait and generating speed over the same clock window on past days,
// with the same day rules as the usual speed.
struct UsualTiming {
    let wait:Double
    let waitLo:Double
    let waitHi:Double
    let generating:Double
    let generatingLo:Double
    let generatingHi:Double
    let days:Int
}
func usualTiming(_ history:[SpeedReading],start:Date,now:Date,lookbackDays:Int=14,calendar:Calendar = .current)->UsualTiming? {
    let today=calendar.startOfDay(for:now)
    var waits:[Double]=[],gens:[Double]=[]
    for k in 1...lookbackDays {
        guard let a=calendar.date(byAdding:.day,value:-k,to:start),let b=calendar.date(byAdding:.day,value:-k,to:now) else{continue}
        let rs=history.filter {$0.date>=a && $0.date<=b && $0.date<today && $0.waitSeconds != nil}
        guard rs.count>=usualMinDayResponses,let t=timingSplit(rs) else{continue}
        waits.append(t.wait);gens.append(t.generating)
    }
    guard waits.count>=usualMinDays else{return nil}
    waits.sort();gens.sort()
    return UsualTiming(wait:percentile(waits,0.5),waitLo:percentile(waits,0.1),waitHi:percentile(waits,0.9),generating:percentile(gens,0.5),generatingLo:percentile(gens,0.1),generatingHi:percentile(gens,0.9),days:waits.count)
}
// Same rule as the ▲/▼ marker: 10%+ beyond the normal range. For the wait, longer is slower.
func timingMarker(_ value:Double,lo:Double,hi:Double,longerIsSlower:Bool,responses:Int=markerMinResponses)->SpeedMarker? {
    guard responses>=markerMinResponses else{return nil}
    if value>hi*(1+markerMargin) {return longerIsSlower ? .slower : .faster}
    if value<lo*(1-markerMargin) {return longerIsSlower ? .faster : .slower}
    return nil
}
// "22% slower than usual", "1.8× usual", "about usual". Wait: longer is worse.
func timingCompareText(_ value:Double,usual:Double,longerIsSlower:Bool)->String {
    guard usual>0,value.isFinite else{return "no usual yet"}
    let r=value/usual
    if abs(r-1)<0.05 {return "about usual"}
    if longerIsSlower && r>=1.5 {return String(format:"%.1f× usual",r)}
    let p=Int((abs(r-1)*100).rounded())
    if longerIsSlower {return "\(p)% \(r>1 ? "longer" : "shorter") than usual"}
    return "\(p)% \(r<1 ? "slower" : "faster") than usual"
}
// Where a window's time went vs the usual: "generating 22% slower than usual · wait about usual".
func timingReason(_ t:TimingSplit,_ u:UsualTiming)->String {
    "generating "+timingCompareText(t.generating,usual:u.generating,longerIsSlower:false)+" · wait "+timingCompareText(t.wait,usual:u.wait,longerIsSlower:true)
}
enum SpeedMarker {case faster,slower}
func speedMarker(_ window:[SpeedReading],baseline:UsualBaseline?)->SpeedMarker? {
    guard let b=baseline,window.count>=markerMinResponses else{return nil}
    let x=window.reduce(0) {$0+$1.speed}/Double(window.count)
    if x>b.hi*(1+markerMargin) {return .faster}
    if x<b.lo*(1-markerMargin) {return .slower}
    return nil
}
// Markers compare like-for-like clock windows, so they only make sense up to 12h.
func showsMarkers(_ range:SpeedTimeRange)->Bool {range.seconds<=43200}
func detailWindowTitle(_ range:SpeedTimeRange)->String {
    switch range {case .hour:return "Last hour";case .fourHours:return "Last 4h";case .twelveHours:return "Last 12h";default:return "Today"}
}
func markerColor(_ m:SpeedMarker)->Color {m == .faster ? SpeedTheme.faster : SpeedTheme.slowerYellow}
func markerWord(_ m:SpeedMarker)->String {m == .faster ? "Faster than usual" : "Slower than usual"}
struct SpeedMarkerGlyph:View {
    let marker:SpeedMarker
    var size:CGFloat=9
    var body:some View {
        Text(marker == .faster ? "▲" : "▼").font(.system(size:size)).foregroundStyle(markerColor(marker)).accessibilityHidden(true)
    }
}
// A long-range average is "rough" when its likely range is wide (±15%+ of the
// average), has no margin at all, or comes from fewer than 3 hours/days.
func isRoughAverage(mean:Double?,margin:Double?,clusters:Int)->Bool {
    guard let mean,mean>0 else{return true}
    guard let margin,clusters>=3 else{return true}
    return margin/mean>=0.15
}
// Everything a cell shows, worked out outside the view body so SwiftUI type-checks fast.
struct SpeedCellModel {
    let mean:Double?
    let responses:Int
    let loggedResponses:Int
    let tokens:Int64
    let margin:Double?
    let baseline:UsualBaseline?
    let pastDays:Int
    let marker:SpeedMarker?
    let comparable:Bool
    let rough:Bool   // long ranges only: average is shaky (wide margin or little spread of data)
    var reason:String?=nil   // when ▲/▼ shows: generating vs wait against the usual
    // Generating first (4 Nov): tokens ÷ time after output starts, pooled over the window,
    // compared with the usual generating speed at these hours. Overall stays as the fallback.
    var gen:TimingSplit?=nil
    var genUsual:UsualTiming?=nil
    var genMarker:SpeedMarker?=nil
    var displayMarker:SpeedMarker? {gen != nil ? genMarker : marker}
    var displayNumber:String {gen.map {(rough ? "~" : "")+wholeSpeed($0.generating)} ?? number}
    init(group:SpeedModeGroup,range:SpeedTimeRange,history:[SpeedReading],now:Date) {
        let rs=group.readings
        mean=group.stats().mean
        responses=rs.count
        loggedResponses=max(group.responseDates.count,rs.count)
        tokens=rs.reduce(Int64(0)) {$0+$1.outputTokens}
        let cm=clusteredMargin(rs,by:range.seconds<=86400 ? .hour : .day)
        margin=cm.margin
        comparable=showsMarkers(range)
        rough = !comparable && isRoughAverage(mean:mean,margin:cm.margin,clusters:cm.clusters)
        if comparable {
            let u=usualBaseline(history,start:now.addingTimeInterval(-range.seconds),now:now)
            baseline=u.baseline;pastDays=u.days
        } else {baseline=nil;pastDays=0}
        marker=speedMarker(rs,baseline:baseline)
        if let t=timingSplit(rs) {
            gen=t
            if comparable,let u=usualTiming(history,start:now.addingTimeInterval(-range.seconds),now:now) {
                genUsual=u
                genMarker=timingMarker(t.generating,lo:u.generatingLo,hi:u.generatingHi,longerIsSlower:false,responses:t.responses)
                if genMarker != nil {reason=timingReason(t,u)}
            }
        }
    }
    var detail:String {responses>0 ? responseCount(responses) : "\(loggedResponses.formatted()) logged"}
    var displayDetail:String {
        if let gen {return gen.responses<responses ? "\(gen.responses)/\(responses) timed" : detail}
        return mean == nil ? detail : "overall · "+detail
    }
    // Same as displayDetail, with counts shortened for the tile.
    var compactDetail:String {
        let base=responses>0 ? compactReplies(responses) : "\(compactCount(loggedResponses)) logged"
        if let gen {return gen.responses<responses ? "\(compactCount(gen.responses))/\(compactCount(responses)) timed" : base}
        return mean == nil ? base : "overall · "+base
    }
    var number:String {(mean != nil && rough ? "~" : "")+wholeSpeed(mean)}
    var tooltip:String {
        guard responses>0 else{return "\(responseCount(loggedResponses)) logged; speed unavailable because none meet the measurement rules. Timing may be missing or ambiguous, or replies may be below 100 output tokens."}
        var t=responseCount(responses)+" · "+tokens.formatted()+" output tokens"
        if let g=gen {t += " · generating (est.) "+wholeSpeed(g.generating)+" t/s, wait "+String(format:"%.1f",g.wait)+" s, overall "+wholeSpeed(mean)+" t/s"}
        if let u=genUsual {t += " · usual generating "+wholeSpeed(u.generating)+" t/s"+(genMarker.map {" · "+markerWord($0).lowercased()+(reason.map {": "+$0} ?? "")} ?? "")}
        if let margin,let mean {t += " · overall likely "+wholeSpeed(max(0,mean-margin))+"–"+wholeSpeed(mean+margin)+" t/s"}
        if rough {t += " · rough: little data"}
        guard comparable else{return t}
        if let b=baseline {
            t += " · overall usual at these hours "+wholeSpeed(b.median)+" t/s, usual range "+wholeSpeed(b.lo)+"–"+wholeSpeed(b.hi)+" ("+String(b.days)+" days)"
            if gen==nil,let marker {t += " · overall "+markerWord(marker).lowercased()+(reason.map {": "+$0} ?? "")}
            else if responses<markerMinResponses {t += " · too few responses to compare (needs \(markerMinResponses))"}
        } else {t += " · no usual yet ("+String(pastDays)+" of "+String(usualMinDays)+" days at these hours)"}
        return t
    }
    var accessibleValue:String {
        guard let mean else{return "\(responseCount(loggedResponses)) logged; speed unavailable"}
        var t=(rough ? "about " : "")+wholeSpeed(gen?.generating ?? mean)+" tokens per second "+(gen == nil ? "overall" : "generating, estimated")+", "+(gen == nil ? detail : displayDetail)
        if let marker=displayMarker {t += ", "+markerWord(marker).lowercased()+(reason.map {": "+$0} ?? "")}
        return t
    }
}
// Cell values are reused until the minute, range or the group's data changes, so
// menu-bar redraws (hover, scrolling) don't recompute usual baselines. Main thread only.
final class SpeedCellCache {
    static let shared=SpeedCellCache()
    private var store:[String:SpeedCellModel]=[:]
    private var generation=""
    func model(key:String,range:SpeedTimeRange,now:Date,stamp:Date?,make:()->SpeedCellModel)->SpeedCellModel {
        let generation="\(range.rawValue)|\(Int(now.timeIntervalSince1970/60))|\(stamp?.timeIntervalSince1970.description ?? "fixture")"
        if generation != self.generation {store.removeAll(keepingCapacity:true);self.generation=generation}
        if let hit=store[key] {return hit}
        let m=make();store[key]=m;return m
    }
}
// Shared extra breathing room for number/detail stacks, including empty equivalents.
let numberStackExtraSpacing:CGFloat=2
struct SpeedCell:View {
    let group:SpeedModeGroup?
    let label:String
    var range:SpeedTimeRange = .day
    var history:[SpeedReading]=[]
    var now:Date=Date()
    var cacheStamp:Date?=nil
    let action:()->Void
    @State private var hovering=false
    var body:some View {
        if let group,!group.responseDates.isEmpty {
            let m=SpeedCellCache.shared.model(key:"\(label)|\(group.readings.count)|\(group.latestResponse.timeIntervalSince1970)|\(history.count)",range:range,now:now,stamp:cacheStamp) {
                SpeedCellModel(group:group,range:range,history:history,now:now)
            }
            Button(action:action) {
                VStack(alignment:.trailing,spacing:-3+numberStackExtraSpacing) {
                    HStack(alignment:.firstTextBaseline,spacing:2) {
                        if let marker=m.displayMarker {SpeedMarkerGlyph(marker:marker).padding(.trailing,3)}
                        Text(m.displayNumber).font(.system(size:19,weight:.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6).foregroundStyle(m.mean==nil ? SpeedTheme.tertiary : (m.rough ? SpeedTheme.secondary : SpeedTheme.primary))
                        if m.mean != nil {Text("t/s").font(.system(size:11)).foregroundStyle(SpeedTheme.secondary)}
                    }
                    Text(m.compactDetail).font(.system(size:11)).monospacedDigit().foregroundStyle(SpeedTheme.secondary).lineLimit(2).minimumScaleFactor(0.8)
                }
                .padding(.horizontal,12).frame(maxWidth:.infinity,minHeight:56,alignment:.trailing)
                .background(RoundedRectangle(cornerRadius:8).fill(hovering ? SpeedTheme.tileHover : SpeedTheme.tile))
                // Flagged tiles carry their marker color; hover only brightens.
                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(m.displayMarker.map {markerColor($0).opacity(hovering ? 0.8 : 0.5)} ?? Color.white.opacity(hovering ? 0.28 : 0.12),lineWidth:1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).onHover {hovering=$0}.pointingHand().help(m.tooltip)
            .accessibilityElement(children:.ignore).accessibilityLabel(label).accessibilityValue(m.accessibleValue).accessibilityAddTraits(.isButton)
        } else {
            VStack(alignment:.trailing,spacing:-2+numberStackExtraSpacing) {
                Text("—").font(.system(size:15)).foregroundStyle(SpeedTheme.quiet)
                Text("not used").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary)
            }
            .padding(.horizontal,12).frame(maxWidth:.infinity,minHeight:56,alignment:.trailing)
            .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.white.opacity(0.1),style:StrokeStyle(lineWidth:1,dash:[3,3])))
            .accessibilityElement(children:.ignore).accessibilityLabel("\(label): no replies")
        }
    }
}
// One line per ▲/▼ tile saying what changed; opens that tile's details.
struct FlaggedCellRow:View {
    let model:String
    let effort:String
    let tier:String
    let cell:SpeedCellModel
    let action:()->Void
    @State private var hovering=false
    var body:some View {
        let marker=cell.displayMarker ?? .slower
        let color=markerColor(marker)
        Button(action:action) {
            HStack(spacing:8) {
                SpeedMarkerGlyph(marker:marker,size:10)
                (Text("\(modeTitle(tier)) · \(effortShortTitle(effort)): ").foregroundColor(SpeedTheme.primary)
                 + Text(cell.reason ?? "\(marker == .faster ? "faster" : "slower") than usual at these hours").foregroundColor(SpeedTheme.secondary))
                    .font(.system(size:12)).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
                Image(systemName:"chevron.right").font(.system(size:10,weight:.semibold)).foregroundStyle(hovering ? SpeedTheme.primary : SpeedTheme.tertiary)
            }
            .padding(.horizontal,12).padding(.vertical,8).frame(minHeight:40)
            .background(RoundedRectangle(cornerRadius:12).fill(hovering ? SpeedTheme.tileHover : SpeedTheme.card))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(color.opacity(hovering ? 0.6 : 0.35),lineWidth:1))
            .contentShape(RoundedRectangle(cornerRadius:12))
        }
        .buttonStyle(.plain).onHover {hovering=$0}.pointingHand()
        .accessibilityLabel("\(modeTitle(tier)), \(effortShortTitle(effort)) effort, \(marker == .faster ? "faster" : "slower") than usual")
        .accessibilityHint("Opens details")
    }
}
// Overview identity is model → effective effort → tier, shown as a table:
// efforts are rows; columns are always Standard, Fast, Ultrafast (plus any
// unfamiliar tier this model used), with a dash where nothing ran.
// Provenance stays per reading and never splits cells.
// Shared by the column header and every model's rows so all columns line up.
let effortColumnWidth:CGFloat=66
func overviewTiers(_ models:[SpeedModelGroup])->[String] {
    let used=Set(models.flatMap {m in m.efforts.flatMap {e in e.modes.filter {!$0.responseDates.isEmpty}.map(\.mode)}})
    return fixedTierColumns+tierOrder(Array(used.subtracting(fixedTierColumns)))
}
// One column header for the whole overview (it stays put while the list scrolls).
// Its insets mirror ModelEffortSections so labels sit exactly over the tiles.
struct TierColumnHeader:View {
    let tiers:[String]
    var body:some View {
        HStack(spacing:8) {
            ForEach(tiers,id:\.self) {tier in
                Text(modeTitle(tier).uppercased()).font(.system(size:10,design:.monospaced)).tracking(0.8).foregroundStyle(SpeedTheme.tertiary)
                    .lineLimit(1).padding(.trailing,12).frame(maxWidth:.infinity,alignment:.trailing)
            }
        }
        .padding(.horizontal,12)
        .accessibilityHidden(true)
    }
}
// A model is one card: a header strip with its name, then a row of tiles per effort.
struct ModelEffortSections:View {
    let model:SpeedModelGroup
    let now:Date
    let compact:Bool
    var range:SpeedTimeRange = .day
    var tiers:[String]=fixedTierColumns
    var cacheStamp:Date?=nil
    var history:(String,String)->[SpeedReading]={_,_ in []}   // (effort, tier) → all readings, for the usual
    let open:(SpeedEffortGroup,String)->Void
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(model.model.uppercased()).font(.system(size:10,weight:.medium,design:.monospaced)).tracking(0.8).foregroundStyle(SpeedTheme.primary)
                .lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment:.leading,spacing:16) {
                ForEach(model.efforts) {effort in
                    VStack(alignment:.leading,spacing:8) {
                        Text(effortShortTitle(effort.effort).uppercased()).font(.system(size:10,design:.monospaced)).tracking(0.8).foregroundStyle(SpeedTheme.tertiary)
                            .lineLimit(1)
                        HStack(spacing:8) {
                            ForEach(tiers,id:\.self) {tier in
                                SpeedCell(group:effort.modes.first {$0.mode==tier},label:"\(model.model), \(effortShortTitle(effort.effort)) effort, \(modeTitle(tier))",range:range,history:history(effort.effort,tier),now:now,cacheStamp:cacheStamp) {open(effort,tier)}
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal,12).padding(.top,16).padding(.bottom,12)
        .background(SpeedTheme.card,in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(SpeedTheme.cardStroke,lineWidth:1))
        .accessibilityElement(children:.contain)
    }
}

// MARK: - Detail
struct SpeedTrendChart:View {
    let bins:[SpeedBin]
    let average:Double?
    let start:Date
    let end:Date
    let range:SpeedTimeRange
    let latest:Date?
    var axisMax:Double {
        let peak=max(bins.map(\.p75).max() ?? 0,bins.map(\.mean).max() ?? 0,average ?? 0)
        let step=niceCeiling(max(peak,1)/3)
        return max(step,(peak/step).rounded(.up)*step)
    }
    var body:some View {
        let ceiling=axisMax
        Canvas {ctx,size in
            let left:CGFloat=32,right=size.width-4,plotTop:CGFloat=8,plotBottom=size.height-18
            let span=max(end.timeIntervalSince(start),1)
            func x(_ d:Date)->CGFloat {left+CGFloat(d.timeIntervalSince(start)/span)*(right-left)}
            func y(_ v:Double)->CGFloat {plotBottom-CGFloat(v/ceiling)*(plotBottom-plotTop)}
            let step=ceiling/3
            for i in 0...3 {
                let v=step*Double(i),yy=y(v)
                var grid=Path();grid.move(to:CGPoint(x:left,y:yy));grid.addLine(to:CGPoint(x:right,y:yy))
                ctx.stroke(grid,with:.color(Color.white.opacity(i==0 ? 0.14 : 0.07)),lineWidth:1)
                ctx.draw(Text(wholeSpeed(v)).font(.system(size:11)).foregroundColor(SpeedTheme.tertiary),at:CGPoint(x:left-6,y:yy),anchor:.trailing)
            }
            let offset=Double(TimeZone.current.secondsFromGMT(for:start)),stepT=range.axisStep
            var tick=((start.timeIntervalSince1970+offset)/stepT).rounded(.up)*stepT-offset
            while tick<=end.timeIntervalSince1970 {
                let d=Date(timeIntervalSince1970:tick),tx=x(d)
                if tx>left+14 && tx<right-14 {ctx.draw(Text(axisTime(d,range:range)).font(.system(size:11)).foregroundColor(SpeedTheme.tertiary),at:CGPoint(x:tx,y:size.height),anchor:.bottom)}
                tick+=stepT
            }
            let segments=Dictionary(grouping:bins,by:\.segment).values.map {$0.sorted {$0.id<$1.id}}.sorted {$0[0].id<$1[0].id}
            for seg in segments where seg.count>1 {
                let upper=seg.map {CGPoint(x:x($0.date),y:y($0.p75))},lower=seg.reversed().map {CGPoint(x:x($0.date),y:y($0.p25))}
                var band=Path();appendSmooth(upper,to:&band,move:true);appendSmooth(lower,to:&band,move:false);band.closeSubpath()
                ctx.fill(band,with:.color(SpeedTheme.accent.opacity(0.2)))
            }
            if let average {
                let ya=y(average)
                var rule=Path();rule.move(to:CGPoint(x:left,y:ya));rule.addLine(to:CGPoint(x:right,y:ya))
                ctx.stroke(rule,with:.color(Color.white.opacity(0.45)),style:StrokeStyle(lineWidth:1,dash:[3,3]))
                ctx.draw(Text("avg \(wholeSpeed(average))").font(.system(size:11,weight:.semibold)).foregroundColor(Color(white:0.78)),at:CGPoint(x:right,y:max(ya-3,plotTop+14)),anchor:.bottomTrailing)
            }
            for seg in segments {
                var line=Path()
                if seg.count==1 {
                    let p=CGPoint(x:x(seg[0].date),y:y(seg[0].mean))
                    line.move(to:CGPoint(x:p.x-3,y:p.y));line.addLine(to:CGPoint(x:p.x+3,y:p.y))
                } else {appendSmooth(seg.map {CGPoint(x:x($0.date),y:y($0.mean))},to:&line,move:true)}
                ctx.stroke(line,with:.color(SpeedTheme.accent),style:StrokeStyle(lineWidth:2,lineCap:.round,lineJoin:.round))
            }
            if let latest,end.timeIntervalSince(latest)>span*0.15,right-x(latest)>56 {
                let cx=x(latest)+(right-x(latest))/2,cy=(plotTop+plotBottom)/2+16
                ctx.draw(Text("None since").font(.system(size:11)).foregroundColor(SpeedTheme.tertiary),at:CGPoint(x:cx,y:cy),anchor:.bottom)
                ctx.draw(Text(axisTime(latest,range:range)).font(.system(size:11)).foregroundColor(SpeedTheme.tertiary),at:CGPoint(x:cx,y:cy+2),anchor:.top)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Average speed per \(range.chartBins.label), \(range.label.lowercased())")
        .accessibilityValue(average.map {"Overall average \(wholeSpeed($0)) tokens per second"} ?? "No timed responses")
    }
}
// MARK: - Browser
private struct SpeedPinnedHeightKey:PreferenceKey {
    static let defaultValue:CGFloat=0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) {value=max(value,nextValue())}
}
struct SpeedBrowser:View {
    let report:RecentSpeedReport
    let now:Date
    let compact:Bool
    let refresh: () -> Void
    @AppStorage("speedTimeRange") private var rangeRaw=SpeedTimeRange.day.rawValue
    @AppStorage("clockStyle") private var clockStyle="system"   // re-renders times when the clock setting changes
    @State private var overviewHeaderHeight:CGFloat=0
    @State private var overviewScrolled=false
    @State private var navigation:SpeedNavigation
    init(report:RecentSpeedReport,now:Date,compact:Bool,initialSelection:SpeedSelection?=nil,refresh:@escaping () -> Void = {}) {
        self.refresh=refresh
        self.report=report;self.now=now;self.compact=compact;_navigation=State(initialValue:SpeedNavigation(selection:initialSelection))
    }
    var range:SpeedTimeRange {SpeedTimeRange(rawValue:rangeRaw) ?? .day}
    var selectedGroup:SpeedModeGroup {
        guard let s=navigation.selection else{return SpeedModeGroup(mode:"unknown")}
        return report.todayGroup(for:s,now:now)
    }
    var visibleModels:[SpeedModelGroup] {report.filtered(range:range,now:now).models}
    var overviewList:some View {
        let tiers=overviewTiers(visibleModels)
        return VStack(alignment:.leading,spacing:16) {
            ForEach(Array(visibleModels.enumerated()),id:\.element.id) {index,model in
                ModelEffortSections(model:model,now:now,compact:compact,range:range,tiers:tiers,cacheStamp:report.checkedAt ?? report.snapshotAt,history:{effort,tier in report.effortReadings(model:model.model,effort:effort,mode:tier)}) {effort,mode in
                    navigation.open(model:model.model,effort:effort.effort,mode:mode)
                }
            }
            ForEach(Array(flaggedCells.prefix(3).enumerated()),id:\.offset) {_,f in
                FlaggedCellRow(model:f.model,effort:f.effort.effort,tier:f.tier,cell:f.cell) {navigation.open(model:f.model,effort:f.effort.effort,mode:f.tier)}
            }
            if visibleModels.isEmpty {
                VStack(alignment:.leading,spacing:8) {
                    Text(report.error != nil ? "Couldn’t load recent replies." : report.checkedAt == nil ? "Loading recent replies…" : "No replies in the \(range.label.lowercased()).").font(.system(size:13)).foregroundStyle(SpeedTheme.primary)
                    if report.checkedAt != nil, report.error == nil, let next=SpeedTimeRange.allCases.drop(while:{$0 != range}).dropFirst().first {
                        Button("Try \(next.title) ›") {rangeRaw=next.rawValue}.buttonStyle(ChipButtonStyle())
                    }
                }
                .padding(12).frame(maxWidth:.infinity,alignment:.leading)
                .background(SpeedTheme.card,in:RoundedRectangle(cornerRadius:12))
                .overlay(RoundedRectangle(cornerRadius:12).stroke(SpeedTheme.cardStroke,lineWidth:1))
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,16).padding(.top,0).padding(.bottom,16)
    }
    // Cells showing ▲/▼, read from the same cache the tiles fill (no extra work).
    var flaggedCells:[(model:String,effort:SpeedEffortGroup,tier:String,cell:SpeedCellModel)] {
        guard showsMarkers(range) else{return []}
        let tiers=overviewTiers(visibleModels)
        var out:[(model:String,effort:SpeedEffortGroup,tier:String,cell:SpeedCellModel)]=[]
        for model in visibleModels {
            for effort in model.efforts {
                for tier in tiers {
                    guard let group=effort.modes.first(where:{$0.mode==tier}),!group.responseDates.isEmpty else{continue}
                    let label="\(model.model), \(effortShortTitle(effort.effort)) effort, \(modeTitle(tier))"
                    let history=report.effortReadings(model:model.model,effort:effort.effort,mode:tier)
                    let m=SpeedCellCache.shared.model(key:"\(label)|\(group.readings.count)|\(group.latestResponse.timeIntervalSince1970)|\(history.count)",range:range,now:now,stamp:report.checkedAt ?? report.snapshotAt) {
                        SpeedCellModel(group:group,range:range,history:history,now:now)
                    }
                    if m.displayMarker != nil {out.append((model.model,effort,tier,m))}
                }
            }
        }
        return out
    }
    @ViewBuilder func scrolling<Content:View>(@ViewBuilder _ content:@escaping ()->Content)->some View {
        if compact {FittingScroll(maxHeight:min(520,max(80,min(760,(NSScreen.main?.visibleFrame.height ?? 860)-64)-44-overviewHeaderHeight)),scrolled:$overviewScrolled,content:content)} else {ScrollView {content()}}
    }
    var overviewHeader:some View {
        VStack(alignment:.leading,spacing:0) {
                HStack(spacing:8) {
                    Text((compact ? "Token speed" : "Speed by model & effort").uppercased()).font(.system(size:12,weight:.bold,design:.monospaced)).tracking(1.6).foregroundStyle(SpeedTheme.primary)
                        .accessibilityAddTraits(.isHeader)
                    if compact {MonitorRefreshLink(refresh:refresh)}
                    Spacer(minLength:8)
                    if compact {
                        MonitorCloseButton().frame(width:28,height:24)
                    } else {
                        Text("Generating t/s (est.)").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1)
                        SpeedInfoButton()
                    }
                }.padding(.horizontal,16).padding(.top,compact ? 12 : 0).padding(.bottom,12)
                .overlay(alignment:.bottom) {Rectangle().fill(SpeedTheme.hairline).frame(height:1)}
                SpeedRangeControl(value:$rangeRaw).padding(.horizontal,16).padding(.top,16)
                CoverageCaption(report:report,range:range,now:now)
                if let error=report.error {Text(error).font(.system(size:12)).foregroundStyle(Color.orange).padding(.horizontal,16).padding(.top,6)}
                if !visibleModels.isEmpty {TierColumnHeader(tiers:overviewTiers(visibleModels)).padding(.horizontal,16).padding(.top,24).padding(.bottom,8)}
        }
        // A divider shows once the cards scroll up under the column labels.
        .overlay(alignment:.bottom) {Rectangle().fill(Color.white.opacity(overviewScrolled ? 0.12 : 0)).frame(height:1)}
        .background(GeometryReader {g in Color.clear.preference(key:SpeedPinnedHeightKey.self,value:g.size.height)})
        .onPreferenceChange(SpeedPinnedHeightKey.self) {overviewHeaderHeight=$0}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            if let s=navigation.selection {
                HStack(spacing:8) {
                    VisibleBackButton {navigation.back()}
                    VStack(alignment:.leading,spacing:0) {
                        Text("\(s.model) · \(effortShortTitle(s.effort)) effort").font(.system(size:12)).foregroundStyle(SpeedTheme.secondary).lineLimit(1)
                        Text(modeTitle(s.mode)).font(.system(size:17,weight:.semibold)).foregroundStyle(SpeedTheme.primary).accessibilityAddTraits(.isHeader)
                    }
                    if compact {MonitorRefreshLink(refresh:refresh)}
                    Spacer(minLength:0)
                    if compact {MonitorCloseButton().frame(width:28,height:24)}
                }.padding(.leading,10).padding(.trailing,16).padding(.top,compact ? 10 : 0).padding(.bottom,6)
                .overlay(alignment:.bottom) {Rectangle().fill(SpeedTheme.hairline).frame(height:1)}
                if let error=report.error {Text(error).font(.system(size:12)).foregroundStyle(Color.orange).padding(.horizontal,16).padding(.bottom,6)}
                // The top card matches the cell that was opened (last 1h/4h/12h, or
                // Today for longer ranges); the chart and response list are Today.
                let group=selectedGroup
                let dayStart=Calendar.current.startOfDay(for:now)
                let windowStart=showsMarkers(range) ? now.addingTimeInterval(-range.seconds) : dayStart
                let allGroup=report.models.first{$0.model==s.model}?.efforts.first{$0.effort==s.effort}?.modes.first{$0.mode==s.mode} ?? group
                let detail=TierReadingDetail(responseDates:allGroup.responseDates,readings:group.readings.filter {$0.date>=dayStart},history:report.effortReadings(model:s.model,effort:s.effort,mode:s.mode),effortLabel:"\(effortShortTitle(s.effort)) · \(modeTitle(s.mode))",windowStart:windowStart,windowTitle:detailWindowTitle(range),excluded:group.excludedDates.filter {$0>=dayStart}.count,now:now,compact:compact)
                // A fade at the bottom shows there's more to scroll.
                if compact {
                    ScrollView {detail}.frame(height:540)
                        .overlay(alignment:.bottom) {LinearGradient(colors:[SpeedTheme.surface.opacity(0),SpeedTheme.surface],startPoint:.top,endPoint:.bottom).frame(height:32).allowsHitTesting(false)}
                } else {ScrollView {detail}}
            } else {
                overviewHeader
                scrolling {overviewList}
            }
        }.frame(maxWidth:.infinity,alignment:.topLeading)
    }
}
struct CompactSpeedContent:View {
    let report:RecentSpeedReport
    let now:Date
    var initialSelection:SpeedSelection?=nil
    var refresh: () -> Void = {}
    var body:some View {SpeedBrowser(report:report,now:now,compact:true,initialSelection:initialSelection,refresh:refresh)}
}
struct RecentModelSpeedView:View {
    let report:RecentSpeedReport
    let now:Date
    var initialSelection:SpeedSelection?=nil
    // Capped width so table cells don't stretch across a wide report window.
    var body:some View {SpeedBrowser(report:report,now:now,compact:false,initialSelection:initialSelection).frame(maxWidth:760,alignment:.topLeading).frame(maxWidth:.infinity,alignment:.topLeading)}
}

// MARK: - Clustered uncertainty and matched-clock historical comparisons
// Keep the displayed response-weighted arithmetic mean. Treat hour/day groups
// as clusters and use the cluster score sums for its intercept-only variance.
// This is approximate, not a promise that adjacent buckets are independent.
enum SpeedCluster {case hour,day}
func clusterKey(_ date:Date,_ unit:SpeedCluster,calendar:Calendar = .current)->Date {
    unit == .day ? calendar.startOfDay(for:date) : calendar.dateInterval(of:.hour,for:date)!.start
}
func tCriticalAnyDF(_ df:Int)->Double {
    switch df {case ...1:return 12.706;case 2:return 4.303;case 3:return 3.182;default:return tCritical(df)}
}
func clusteredMargin(_ readings:[SpeedReading],by unit:SpeedCluster,calendar:Calendar = .current,calendarIndex:ReplyCalendarIndex?=nil)->(margin:Double?,clusters:Int) {
    let index=calendarIndex?.matching(calendar)
    let rs=readings.filter{$0.speed.isFinite}
    let groups=Dictionary(grouping:rs){unit == .day ? (index?.day($0.date) ?? clusterKey($0.date,unit,calendar:calendar)) : clusterKey($0.date,unit,calendar:calendar)}
    let g=groups.count
    guard g>=3,!rs.isEmpty else{return (nil,g)}
    let n=Double(rs.count),mean=rs.reduce(0){$0+$1.speed}/n
    let scores=groups.values.map{$0.reduce(0){$0+$1.speed-mean}}
    let variance=Double(g)/Double(g-1)*scores.reduce(0){$0+$1*$1}/(n*n)
    return (tCriticalAnyDF(g-1)*sqrt(variance),g)
}
func historyStart(_ now:Date,days:Int=14,calendar:Calendar = .current)->Date {
    calendar.date(byAdding:.day,value:-days,to:calendar.startOfDay(for:now))!
}
func dayMeans(_ readings:[SpeedReading],hours:Set<Int>,before:Date,calendar:Calendar = .current)->[Double] {
    let rs=readings.filter{$0.date<before && $0.speed.isFinite && hours.contains(calendar.component(.hour,from:$0.date))}
    return Dictionary(grouping:rs){calendar.startOfDay(for:$0.date)}.values.compactMap {day in
        let g=Dictionary(grouping:day){calendar.component(.hour,from:$0.date)}
        guard Set(g.keys)==hours else{return nil}
        return g.values.reduce(0){$0+$1.reduce(0){$0+$1.speed}/Double($1.count)}/Double(hours.count)
    }.sorted()
}
// Each comparison shifts the actual clock interval into a completed past day.
// Require every currently observed clock-hour slice in each baseline day;
// weight those slices by today's/current window's response counts in BOTH
// means. Exact minute cutoffs exclude later data in a partial current hour.
// Skip DST shifts whose wall clock/duration cannot be matched unambiguously.
func matchedDayMeans(_ window:[SpeedReading],history:[SpeedReading],start:Date,now:Date,calendar:Calendar = .current)->[Double] {
    let current=window.filter{$0.date>=start && $0.date<=now && $0.speed.isFinite}
    guard !current.isEmpty,start<=now else{return []}
    let weights=Dictionary(grouping:current){calendar.component(.hour,from:$0.date)}.mapValues(\.count)
    let dayStart=calendar.startOfDay(for:now),n=Double(current.count)
    let fields:Set<Calendar.Component>=[.hour,.minute,.second]
    var result:[Double]=[]
    for offset in 1...14 {
        guard let a=calendar.date(byAdding:.day,value:-offset,to:start),let b=calendar.date(byAdding:.day,value:-offset,to:now),b<=dayStart,b<=start,
          calendar.dateComponents(fields,from:a)==calendar.dateComponents(fields,from:start),calendar.dateComponents(fields,from:b)==calendar.dateComponents(fields,from:now),abs(b.timeIntervalSince(a)-now.timeIntervalSince(start))<0.5 else{continue}
        let rs=history.filter{$0.date>=a && $0.date<=b && $0.date<dayStart && $0.speed.isFinite && weights[calendar.component(.hour,from:$0.date)] != nil}
        let groups=Dictionary(grouping:rs){calendar.component(.hour,from:$0.date)}
        guard Set(groups.keys)==Set(weights.keys) else{continue}
        let mean=groups.reduce(0.0) {sum,item in
            let avg=item.value.reduce(0){$0+$1.speed}/Double(item.value.count)
            return sum+avg*Double(weights[item.key]!)/n
        }
        result.append(mean)
    }
    return result.sorted()
}
struct UsualComparison {
    let delta:Double
    let days:Int
    let median:Double
    let outside:Bool
}
func compareToUsual(_ window:[SpeedReading],history:[SpeedReading],now:Date=Date(),range:SpeedTimeRange = .hour,calendar:Calendar = .current)->UsualComparison? {
    guard range.seconds<=43200 else{return nil}
    let start=now.addingTimeInterval(-range.seconds)
    let rs=window.filter{$0.date>=start && $0.date<=now && $0.speed.isFinite}
    let past=matchedDayMeans(rs,history:history,start:start,now:now,calendar:calendar)
    guard !rs.isEmpty,past.count>=5 else{return nil}
    let x=rs.reduce(0){$0+$1.speed}/Double(rs.count),median=percentile(past,0.5)
    guard median>0 else{return nil}
    return UsualComparison(delta:x/median-1,days:past.count,median:median,outside:x<percentile(past,0.1) || x>percentile(past,0.9))
}
extension RecentSpeedReport {
    func tierReadings(model:String,mode:String)->[SpeedReading] {
        models.first{$0.model==model}?.efforts.flatMap{$0.modes.filter{$0.mode==mode}.flatMap(\.readings)} ?? []
    }
    func effortReadings(model:String,effort:String,mode:String)->[SpeedReading] {
        models.first{$0.model==model}?.efforts.first{$0.effort==effort}?.modes.first{$0.mode==mode}?.readings ?? []
    }
    func todayGroup(for selection:SpeedSelection,now:Date,calendar:Calendar = .current)->SpeedModeGroup {
        let original=models.first{$0.model==selection.model}?.efforts.first{$0.effort==selection.effort}?.modes.first{$0.mode==selection.mode} ?? SpeedModeGroup(mode:selection.mode)
        let start=calendar.startOfDay(for:now)
        var g=original
        g.readings=original.readings.filter{$0.date>=start && $0.date<=now}
        g.responseDates=original.responseDates.filter{$0>=start && $0<=now}
        g.excludedDates=original.excludedDates.filter{$0>=start && $0<=now};g.excluded=g.excludedDates.count
        g.effortEvidence=original.effortEvidence.filter{$0.date>=start && $0.date<=now}
        g.latestResponse=g.responseDates.first ?? .distantPast
        return g
    }
    // The model · effort · tier with the most responses in the period (report default).
    func busiestPair(since start:Date,until end:Date)->(model:String,effort:String,tier:String)? {
        var best:(model:String,effort:String,tier:String,n:Int)?
        for m in models {for e in m.efforts {for g in e.modes {
            let n=g.readings.filter {$0.date>=start && $0.date<end}.count
            if n>0 && (best==nil || n>best!.n) {best=(m.model,e.effort,g.mode,n)}
        }}}
        guard let b=best else{return nil}
        return (model:b.model,effort:b.effort,tier:b.tier)
    }
    func busiestModel(since start:Date,until end:Date)->String? {
        let counts=models.map{m in (m.model,m.efforts.flatMap(\.modes).flatMap(\.readings).filter{$0.date>=start && $0.date<end}.count)}.filter{$0.1>0}
        return counts.sorted{$0.1 == $1.1 ? $0.0<$1.0 : $0.1>$1.1}.first?.0
    }
}
let speedBlockLabels=["00:00–03:00","03:00–06:00","06:00–09:00","09:00–12:00","12:00–15:00","15:00–18:00","18:00–21:00","21:00–24:00"]
let speedBlockLabels12=["12–3am","3–6am","6–9am","9am–12pm","12–3pm","3–6pm","6–9pm","9pm–12am"]
let speedBlockStarts12=["12am","3am","6am","9am","12pm","3pm","6pm","9pm"]
func blockLabel(_ block:Int,twentyFour:Bool=clockIs24Hour())->String {(twentyFour ? speedBlockLabels : speedBlockLabels12)[max(0,min(7,block))]}
func blockStart(_ block:Int,twentyFour:Bool=clockIs24Hour())->String {(twentyFour ? speedBlockStarts : speedBlockStarts12)[max(0,min(7,block))]}
let speedBlockStarts=["00:00","03:00","06:00","09:00","12:00","15:00","18:00","21:00"]
func hasStrongRank(_ count:Int,days:Int)->Bool {days>=10 && count<=days && Double(count)/Double(days)>=0.9}
func tierColor(_ tier:String)->Color {
    switch tier {case "standard":return Color(red:0.682,green:0.682,blue:0.698);case "fast":return Color(red:0.392,green:0.824,blue:1.0);case "ultrafast":return SpeedTheme.accent;default:return SpeedTheme.tertiary}
}
// MARK: - Detail
struct HourBand {
    let hour:Int
    let lo:Double
    let mid:Double
    let hi:Double
}
struct HourPoint {
    let hour:Int
    let mean:Double
    var count:Int=1
    var timing:TimingSplit?=nil
}
// Usual range per hour, drawn only where the hour meets the same rule as the usual:
// 5+ past days, each with 3+ responses in that hour.
func pastHourBands(_ history:[SpeedReading],now:Date,minDays:Int=usualMinDays,minDayResponses:Int=usualMinDayResponses,generating:Bool=false,calendar:Calendar = .current)->[HourBand] {
    let day=calendar.startOfDay(for:now),start=historyStart(now,calendar:calendar)
    let currentHour=calendar.component(.hour,from:now)
    func clockSeconds(_ d:Date)->Int {calendar.component(.minute,from:d)*60+calendar.component(.second,from:d)}
    var byHour:[Int:[Date:[SpeedReading]]]=[:]
    for r in history where r.date>=start && r.date<day && r.speed.isFinite && (!generating || r.waitSeconds != nil) {
        let h=calendar.component(.hour,from:r.date)
        if h==currentHour && clockSeconds(r.date)>clockSeconds(now) {continue}
        byHour[h,default:[:]][calendar.startOfDay(for:r.date),default:[]].append(r)
    }
    return (0..<24).compactMap {h in
        let means=(byHour[h] ?? [:]).values.filter {$0.count>=minDayResponses}
            .compactMap {rs->Double? in generating ? timingSplit(rs)?.generating : Optional(rs.reduce(0) {$0+$1.speed}/Double(rs.count))}.sorted()
        guard means.count>=minDays else{return nil}
        return HourBand(hour:h,lo:percentile(means,0.1),mid:percentile(means,0.5),hi:percentile(means,0.9))
    }
}
// Five gridlines (four steps) at a round step: 77 → 0/20/40/60/80, 100 → 0/25/…/100.
func chartStep(_ peak:Double)->Double {
    for s in [5.0,10,20,25,40,50,100,200,250,400,500,1000] where s*4>=peak {return s}
    return niceCeiling(peak/4)
}
enum ChartLabelKind {case now,high,low}
// Always-visible labels: the hour in progress, today's high and today's low (no duplicates).
func chartLabels(_ today:[HourPoint],currentHour:Int)->[(hour:Int,kind:ChartLabelKind)] {
    guard !today.isEmpty else{return []}
    var out:[(hour:Int,kind:ChartLabelKind)]=[]
    if today.contains(where:{$0.hour==currentHour}) {out.append((currentHour,.now))}
    let high=today.max {$0.mean<$1.mean}!.hour,low=today.min {$0.mean<$1.mean}!.hour
    if !out.contains(where:{$0.hour==high}) {out.append((high,.high))}
    if !out.contains(where:{$0.hour==low}) {out.append((low,.low))}
    return out
}
struct HourChartLayout {
    let size:CGSize
    let ceiling:Double
    var left:CGFloat {30}
    var right:CGFloat {size.width-6}
    var top:CGFloat {10}
    var bottom:CGFloat {size.height-20}
    func x(_ h:Int)->CGFloat {left+CGFloat((Double(h)+0.5)/24)*(right-left)}
    func edge(_ h:Int)->CGFloat {left+CGFloat(Double(h)/24)*(right-left)}
    func y(_ v:Double)->CGFloat {bottom-CGFloat(v/ceiling)*(bottom-top)}
    func hour(at px:CGFloat)->Int {max(0,min(23,Int(((px-left)/max(1,right-left)*24).rounded(.down))))}
}
struct TodayVsUsualChart:View {
    let bands:[HourBand]
    let today:[HourPoint]
    let currentHour:Int
    var generating=false
    @State private var hoverHour:Int?=nil
    @State private var pinnedHour:Int?=nil
    var activeHour:Int? {pinnedHour ?? hoverHour}
    var ceiling:Double {
        let peak=max(bands.map(\.hi).max() ?? 0,today.map(\.mean).max() ?? 0,1)
        let step=chartStep(peak)
        return max(step,(peak/step).rounded(.up)*step)
    }
    var runs:[[HourBand]] {
        var out:[[HourBand]]=[]
        for b in bands {
            if let last=out.last?.last,last.hour+1==b.hour {out[out.count-1].append(b)} else {out.append([b])}
        }
        return out
    }
    func readoutLines(_ h:Int)->[String] {
        let band=bands.first {$0.hour==h}
        let usual=band.map {"usual \(wholeSpeed($0.mid)) · usual range \(wholeSpeed($0.lo))–\(wholeSpeed($0.hi))"} ?? "no usual for this hour yet"
        guard let p=today.first(where:{$0.hour==h}) else{return [hourClock(h)+(generating ? " · no timed responses" : " · no responses"),usual]}
        var lines=[hourClock(h)+" · \(wholeSpeed(p.mean)) t/s "+(generating ? "generating (est.)" : "overall")+" · \(responseCount(p.count))"]
        if let t=p.timing {lines.append("First output wait "+String(format:"%.1f",t.wait)+" s");lines.append("Generating (est.) "+wholeSpeed(t.generating)+" t/s")}
        lines.append(usual)
        return lines
    }
    func step(_ d:Int) {
        let start=activeHour ?? today.last?.hour ?? currentHour
        pinnedHour=max(0,min(23,start+d))
    }
    func draw(_ ctx:GraphicsContext,_ lay:HourChartLayout) {
        let step=chartStep(ceiling)
        let lines=Int((ceiling/step).rounded())
        for i in 0...max(1,lines) {
            let v=step*Double(i),yy=lay.y(v)
            var grid=Path();grid.move(to:CGPoint(x:lay.left,y:yy));grid.addLine(to:CGPoint(x:lay.right,y:yy))
            ctx.stroke(grid,with:.color(Color.white.opacity(i==0 ? 0.14 : 0.07)),lineWidth:1)
            ctx.draw(Text(wholeSpeed(v)).font(.system(size:11)).foregroundColor(SpeedTheme.secondary),at:CGPoint(x:lay.left-6,y:yy),anchor:.trailing)
        }
        for h in stride(from:0,to:24,by:3) {
            var tick=Path();tick.move(to:CGPoint(x:lay.edge(h),y:lay.bottom));tick.addLine(to:CGPoint(x:lay.edge(h),y:lay.bottom+4))
            ctx.stroke(tick,with:.color(Color.white.opacity(h%6==0 ? 0.30 : 0.14)),lineWidth:1)
            if h%6==0 {ctx.draw(Text(hourClock(h)).font(.system(size:11)).foregroundColor(SpeedTheme.secondary),at:CGPoint(x:lay.edge(h),y:lay.size.height),anchor:h==0 ? .bottomLeading : .bottom)}
        }
        let bandFill=Color(white:0.20),midStroke=Color(white:0.55)
        for run in runs {
            if run.count==1 {
                let b=run[0],half=(lay.right-lay.left)/48
                ctx.fill(Path(CGRect(x:lay.x(b.hour)-half,y:lay.y(b.hi),width:half*2,height:max(1,lay.y(b.lo)-lay.y(b.hi)))),with:.color(bandFill))
                var mid=Path();mid.move(to:CGPoint(x:lay.x(b.hour)-half,y:lay.y(b.mid)));mid.addLine(to:CGPoint(x:lay.x(b.hour)+half,y:lay.y(b.mid)))
                ctx.stroke(mid,with:.color(midStroke),style:StrokeStyle(lineWidth:1,dash:[3,3]))
                continue
            }
            var band=Path()
            band.move(to:CGPoint(x:lay.x(run[0].hour),y:lay.y(run[0].hi)))
            for b in run.dropFirst() {band.addLine(to:CGPoint(x:lay.x(b.hour),y:lay.y(b.hi)))}
            for b in run.reversed() {band.addLine(to:CGPoint(x:lay.x(b.hour),y:lay.y(b.lo)))}
            band.closeSubpath()
            ctx.fill(band,with:.color(bandFill))
            var mid=Path()
            mid.move(to:CGPoint(x:lay.x(run[0].hour),y:lay.y(run[0].mid)))
            for b in run.dropFirst() {mid.addLine(to:CGPoint(x:lay.x(b.hour),y:lay.y(b.mid)))}
            ctx.stroke(mid,with:.color(midStroke),style:StrokeStyle(lineWidth:1,dash:[3,3]))
        }
        for (a,b) in zip(today,today.dropFirst()) where b.hour==a.hour+1 {
            var line=Path();line.move(to:CGPoint(x:lay.x(a.hour),y:lay.y(a.mean)));line.addLine(to:CGPoint(x:lay.x(b.hour),y:lay.y(b.mean)))
            ctx.stroke(line,with:.color(SpeedTheme.chartLine),style:StrokeStyle(lineWidth:1.5,lineCap:.round,lineJoin:.round))
        }
        if let h=activeHour {
            var rule=Path();rule.move(to:CGPoint(x:lay.x(h),y:lay.top-4));rule.addLine(to:CGPoint(x:lay.x(h),y:lay.bottom))
            ctx.stroke(rule,with:.color(Color.white.opacity(0.55)),lineWidth:1)
        }
        for p in today {
            let r:CGFloat=p.hour==activeHour ? 4 : 3
            let dot=Path(ellipseIn:CGRect(x:lay.x(p.hour)-r,y:lay.y(p.mean)-r,width:r*2,height:r*2))
            let band=bands.first {$0.hour==p.hour}
            let tone:Color=band.map {p.mean<$0.lo ? SpeedTheme.slowerYellow : (p.mean>$0.hi ? SpeedTheme.faster : SpeedTheme.chartLine)} ?? SpeedTheme.chartLine
            if p.hour==currentHour {
                ctx.fill(dot,with:.color(SpeedTheme.card))
                ctx.stroke(dot,with:.color(tone),lineWidth:1.5)
            } else {ctx.fill(dot,with:.color(tone))}
        }
        for label in chartLabels(today,currentHour:currentHour) where label.hour != activeHour {
            guard let p=today.first(where:{$0.hour==label.hour}) else{continue}
            let x=lay.x(p.hour),y=lay.y(p.mean)
            let font=Font.system(size:11,weight:.semibold)
            switch label.kind {
            case .now:
                let flip=x>lay.right-48
                ctx.draw(Text(wholeSpeed(p.mean)+" now").font(font).foregroundColor(SpeedTheme.primary),at:CGPoint(x:flip ? x-7 : x+7,y:y),anchor:flip ? .trailing : .leading)
            case .high: ctx.draw(Text(wholeSpeed(p.mean)).font(font).foregroundColor(SpeedTheme.primary),at:CGPoint(x:x,y:max(lay.top,y-6)),anchor:.bottom)
            case .low: ctx.draw(Text(wholeSpeed(p.mean)).font(font).foregroundColor(SpeedTheme.primary),at:CGPoint(x:x,y:y+6),anchor:.top)
            }
        }
    }
    var body:some View {
        let ceiling=self.ceiling
        return GeometryReader {g in
            let lay=HourChartLayout(size:g.size,ceiling:ceiling)
            ZStack(alignment:.topLeading) {
                Canvas {ctx,size in draw(ctx,HourChartLayout(size:size,ceiling:ceiling))}
                if let h=activeHour {
                    let lines=readoutLines(h)
                    let cardWidth:CGFloat=186
                    let dotY=today.first(where:{$0.hour==h}).map {lay.y($0.mean)} ?? lay.bottom
                    VStack(alignment:.leading,spacing:1) {
                        ForEach(Array(lines.enumerated()),id:\.offset) {i,line in
                            Text(line).font(.system(size:11,weight:i==0 ? .semibold : .regular)).foregroundStyle(i==0 ? SpeedTheme.primary : SpeedTheme.secondary)
                        }
                    }
                    .lineLimit(1).padding(.horizontal,8).padding(.vertical,5)
                    .frame(width:cardWidth,alignment:.leading)
                    .background(Color(white:0.23),in:RoundedRectangle(cornerRadius:6))
                    .shadow(color:.black.opacity(0.45),radius:6,y:2)
                    .offset(x:min(max(0,lay.x(h)-cardWidth/2),g.size.width-cardWidth),y:dotY<66 ? dotY+10 : -6)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover {phase in
                switch phase {
                case .active(let p):hoverHour=lay.hour(at:p.x);if !UserDefaults.standard.bool(forKey:"chartHintSeen") {UserDefaults.standard.set(true,forKey:"chartHintSeen")}
                case .ended:hoverHour=nil
                }
            }
            .onTapGesture(coordinateSpace:.local) {p in
                let h=lay.hour(at:p.x)
                pinnedHour = pinnedHour==h ? nil : h
            }
        }
        .focusable()
        .onKeyPress(.leftArrow) {step(-1);return .handled}
        .onKeyPress(.rightArrow) {step(1);return .handled}
        .onKeyPress(.escape) {
            guard pinnedHour != nil else{return .ignored}
            pinnedHour=nil;return .handled
        }
        .accessibilityElement()
        .accessibilityLabel("Today's speed by hour against your usual range")
        .accessibilityValue(activeHour.map {readoutLines($0).joined(separator:", ")} ?? summary)
        .accessibilityAdjustableAction {d in step(d == .increment ? 1 : -1)}
    }
    var summary:String {
        today.map {p in
            let band=bands.first {$0.hour==p.hour}
            let where_=band.map {p.mean<$0.lo ? "below usual" : p.mean>$0.hi ? "above usual" : "within usual"} ?? "no usual yet"
            return hourClock(p.hour)+", "+wholeSpeed(p.mean)+" tokens per second, "+where_
        }.joined(separator:"; ")
    }
}
struct TierReadingDetail:View {
    let responseDates:[Date]
    let readings:[SpeedReading]   // this model · effort · tier, today
    let history:[SpeedReading]    // this model · effort · tier, all loaded days (efforts are never pooled)
    var effortLabel:String="this effort"
    let windowStart:Date          // the top card's window: matches the cell that was opened
    var windowTitle:String="Today"
    var excluded:Int=0
    let now:Date
    var compact=false
    @State private var extra=0
    @State private var showAbout=false
    @State private var expanded:Set<String>=[]
    @State private var hoveredRow:String?=nil
    @AppStorage("chartHintSeen") private var chartHintSeen=false
    var dayStart:Date {Calendar.current.startOfDay(for:now)}
    init(responseDates:[Date]=[],readings:[SpeedReading],history:[SpeedReading],effortLabel:String="this effort",windowStart:Date?=nil,windowTitle:String="Today",excluded:Int=0,now:Date,compact:Bool=false) {
        let start=Calendar.current.startOfDay(for:now)
        self.responseDates=responseDates.isEmpty ? history.map(\.date) : responseDates
        self.readings=readings.filter{$0.date>=start && $0.date<=now && $0.speed.isFinite}
        self.history=history;self.effortLabel=effortLabel;self.excluded=excluded;self.now=now;self.compact=compact
        self.windowStart=windowStart ?? start;self.windowTitle=windowTitle
    }
    // Readings in the top card's window (Today uses today's readings directly).
    var window:[SpeedReading] {
        windowStart==dayStart ? readings : history.filter {$0.date>=windowStart && $0.date<=now && $0.speed.isFinite}
    }
    var windowTotalReplies:Int {max(window.count,responseDates.filter{$0>=windowStart && $0<=now}.count)}
    // The chart plots generating speed (est.) when today's replies carry timing.
    var chartGenerating:Bool {readings.contains {$0.waitSeconds != nil}}
    var bands:[HourBand] {pastHourBands(history,now:now,generating:chartGenerating)}
    var todayHours:[HourPoint] {
        let cal=Calendar.current
        let groups=Dictionary(grouping:readings) {cal.component(.hour,from:$0.date)}
        let gen=chartGenerating
        return groups.keys.sorted().compactMap {h->HourPoint? in
            let rs=groups[h]!,t=timingSplit(rs)
            let value:Double?=gen ? t?.generating : Optional(rs.reduce(0) {$0+$1.speed}/Double(rs.count))
            return value.map {HourPoint(hour:h,mean:$0,count:gen ? (t?.responses ?? 0) : rs.count,timing:t)}
        }
    }
    func evidence(_ r:SpeedReading)->String {
        var parts:[String]=[]
        if let w=r.waitSeconds,let g=r.generatingSpeed {parts.append("First output wait "+String(format:"%.1f",w)+" s · Generating (est.) "+wholeSpeed(g)+" t/s")}
        else {parts.append("No first-output timing for this response")}
        // Effort only when it isn't simply the one you selected.
        let sel=normalizedEffort(r.selectedEffort),rep=normalizedEffort(r.reportedEffort)
        if r.usesSelected,let sel,let rep,sel != rep {parts.append("Ran at \(effortShortTitle(rep)) (\(effortShortTitle(sel)) selected)")}
        else if !r.usesSelected,let rep {parts.append("Effort as reported: \(effortShortTitle(rep))")}
        if r.selectedEffortConflict {parts.append("selected-effort conflict")}
        if r.identityConflict {parts.append("identity conflict")}
        return parts.joined(separator:" · ")
    }
    var usualRules:[Text] {
        let em:(String)->Text={Text(verbatim:$0).foregroundColor(SpeedTheme.primary)}
        let up:Text=Text(verbatim:"▲").foregroundColor(SpeedTheme.faster)
        let down:Text=Text(verbatim:"▼").foregroundColor(SpeedTheme.slowerYellow)
        let gate:String=" only with \(markerMinResponses)+ responses and \(Int((markerMargin*100).rounded()))%+ outside the range"
        return [em("Usual")+Text(verbatim:" = the middle day"),
                em("Normal range")+Text(verbatim:" = where most days fall"),
                up+Text(verbatim:" / ")+down+Text(verbatim:gate)]
    }
    var aboutLines:[String] {
        var lines=["Past days = the last 14, each counted when it had \(usualMinDayResponses)+ responses at these hours; a usual needs \(usualMinDays) such days. The chart's usual range uses the same rule hour by hour."]
        let n=readings.count,selected=readings.filter(\.usesSelected).count
        if n>0 && selected<n {lines.append(selected==0 ? "The effort you selected wasn't captured for today's responses, so they're grouped by the effort they reported." : "\(selected) of \(n) responses confirm the effort you selected; the rest are grouped by the effort they reported.")}
        let mismatches=readings.filter {r in r.usesSelected && normalizedEffort(r.selectedEffort) != normalizedEffort(r.reportedEffort) && normalizedEffort(r.reportedEffort) != nil}.count
        if mismatches>0 {lines.append("\(responseCount(mismatches)) reported a different effort from the one you selected; select a response for details.")}
        lines.append(replyMeasurementExplanation)
        if windowTotalReplies>window.count {lines.append("\(replyCoverageText(window.count,windowTotalReplies)) used in this window; the rest are unmeasured or below 100 output tokens.")}
        lines.append(timingMethodExplanation)
        return lines
    }
    @ViewBuilder func usualExplainer(baseline:UsualBaseline?,marker:SpeedMarker?,windowMean:Double?,usualDays:Int)->some View {
        VStack(alignment:.leading,spacing:8) {
            if let b=baseline {
                Text("Your \(effortLabel) overall speed, wait included, over the same hours on each past day. One dot per day.").font(.system(size:12)).foregroundStyle(SpeedTheme.secondary).fixedSize(horizontal:false,vertical:true)
                UsualStrip(baseline:b,today:windowMean,marker:marker,nowLabel:windowTitle.lowercased())
            } else {
                Text("A usual appears once you've used \(effortLabel) at these hours on \(usualMinDays) days with \(usualMinDayResponses)+ responses (\(usualDays) so far).").font(.system(size:12)).foregroundStyle(SpeedTheme.secondary).fixedSize(horizontal:false,vertical:true)
            }
            VStack(alignment:.leading,spacing:3) {
                ForEach(0..<usualRules.count,id:\.self) {i in usualRules[i]}
            }.font(.system(size:12)).foregroundStyle(SpeedTheme.secondary)
            ForEach(aboutLines,id:\.self) {line in
                Text(line).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).fixedSize(horizontal:false,vertical:true)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).padding(.bottom,10)
    }
    @ViewBuilder func responseRow(_ r:SpeedReading)->some View {
        let open=expanded.contains(r.id)
        VStack(alignment:.leading,spacing:0) {
            Button {
                withAnimation(.easeInOut(duration:0.15)) {if open {expanded.remove(r.id)} else {expanded.insert(r.id)}}
            } label: {
                HStack(spacing:12) {
                    Text(listTime(r.date,now:now)).font(.system(size:12)).monospacedDigit().foregroundStyle(SpeedTheme.secondary).lineLimit(1).fixedSize().frame(width:responseTimeWidth,alignment:.leading)
                    Text("\(r.outputTokens.formatted()) tokens in \(String(format:"%.1f",r.durationMS/1000)) s").font(.system(size:12)).foregroundStyle(SpeedTheme.secondary).lineLimit(1)
                    Spacer(minLength:8)
                    Text(wholeSpeed(r.generatingSpeed ?? r.speed)+(r.generatingSpeed == nil ? " overall" : "")).font(.system(size:13,weight:.semibold)).monospacedDigit().foregroundStyle(r.generatingSpeed == nil ? SpeedTheme.secondary : SpeedTheme.primary)
                        .accessibilityLabel("\(wholeSpeed(r.generatingSpeed ?? r.speed)) tokens per second\(r.generatingSpeed == nil ? ", overall" : " generating")")
                    Image(systemName:open ? "chevron.down" : "chevron.right").font(.system(size:9,weight:.semibold))
                        .foregroundStyle(hoveredRow==r.id ? SpeedTheme.primary : SpeedTheme.quiet).frame(width:10)
                }
                .frame(height:30).padding(.horizontal,8)
                .background(RoundedRectangle(cornerRadius:6).fill(hoveredRow==r.id ? Color.white.opacity(0.08) : Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal,-8)
            .onHover {inside in hoveredRow=inside ? r.id : (hoveredRow==r.id ? nil : hoveredRow)}
            .pointingHand()
            .accessibilityElement(children:.combine)
            .accessibilityHint(open ? "Hide details" : "Show details")
            if open {
                Text(evidence(r)).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).fixedSize(horizontal:false,vertical:true)
                    .padding(.leading,responseTimeWidth+12).padding(.bottom,6)
            }
        }
    }
    var body:some View {
        let win=window
        let windowMean:Double? = win.isEmpty ? nil : win.reduce(0) {$0+$1.speed}/Double(win.count)
        let sorted=readings.sorted {$0.date>$1.date}
        let visible=Array(sorted.prefix(6+extra))
        let usual=usualBaseline(history,start:windowStart,now:now)
        let baseline=usual.baseline
        let marker=speedMarker(win,baseline:baseline)
        let bands=self.bands
        ScrollViewReader {proxy in
        VStack(alignment:.leading,spacing:0) {
            TodayUsualSlots(title:windowTitle,todayMean:windowMean,responses:win.count,marker:marker,baseline:baseline,pastDays:usual.days,timing:timingSplit(win),usualTiming:usualTiming(history,start:windowStart,now:now),
                            coverage:timingCoverageText(timed:timingSplit(win)?.responses ?? 0,measured:win.count,total:windowTotalReplies))
            HStack(alignment:.center,spacing:8) {
                SectionLabel(text:chartGenerating ? "Generating by hour" : "Today by hour")
                if !chartHintSeen {Text("Hover a point · click to pin").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).fixedSize()}
            }.padding(.top,32)
            TodayVsUsualChart(bands:bands,today:todayHours,currentHour:Calendar.current.component(.hour,from:now),generating:chartGenerating)
                .frame(height:176).padding(.top,16)
            HStack(spacing:16) {
                HStack(spacing:6) {RoundedRectangle(cornerRadius:1).fill(SpeedTheme.chartLine).frame(width:14,height:2);Text("Today")}
                if !bands.isEmpty {HStack(spacing:6) {RoundedRectangle(cornerRadius:2).fill(Color(white:0.20)).frame(width:14,height:10);Text("Usual range")}}
                if !bands.isEmpty {HStack(spacing:4) {SpeedMarkerGlyph(marker:.slower,size:9);Text("below")}}
                if !bands.isEmpty {HStack(spacing:4) {SpeedMarkerGlyph(marker:.faster,size:9);Text("above")}}
                HStack(spacing:6) {Circle().stroke(SpeedTheme.chartLine,lineWidth:1.5).frame(width:8,height:8);Text("Now")}
            }.font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).padding(.top,16).accessibilityHidden(true)
            SectionLabel(text:readings.isEmpty ? "Today’s replies" : "Today’s replies · \(visible.count) of \(readings.count)").padding(.top,32).padding(.bottom,8)
            if readings.isEmpty {
                Text("No timed replies for this tier today yet.").font(.system(size:12)).foregroundStyle(SpeedTheme.secondary)
            } else {
                HStack(spacing:12) {
                    Text("TIME").frame(width:responseTimeWidth,alignment:.leading)
                    Text("REPLY")
                    Spacer(minLength:8)
                    Text("GEN. T/S").padding(.trailing,22)
                }.font(.system(size:10,design:.monospaced)).tracking(0.8).foregroundStyle(SpeedTheme.tertiary).frame(height:20).accessibilityHidden(true)
                Rectangle().fill(SpeedTheme.hairline).frame(height:1)
            }
            ForEach(visible) {r in responseRow(r)}
            if visible.count<readings.count {
                Button("Show \(min(20,readings.count-visible.count)) more") {extra+=20}
                    .buttonStyle(ChipButtonStyle()).padding(.top,16)
            }
            Rectangle().fill(SpeedTheme.divider).frame(height:1).padding(.top,24)
            // Whole row toggles (a DisclosureGroup on macOS only reacts to its chevron),
            // and opening scrolls the explainer into view.
            Button {withAnimation(.easeInOut(duration:0.2)) {showAbout.toggle()}} label: {
                HStack(spacing:8) {
                    Image(systemName:"chevron.right").font(.system(size:11,weight:.semibold)).foregroundStyle(SpeedTheme.tertiary)
                        .rotationEffect(.degrees(showAbout ? 90 : 0))
                    Text("How “usual” is worked out").font(.system(size:13,weight:.medium)).foregroundStyle(SpeedTheme.primary)
                    Spacer(minLength:0)
                }.frame(maxWidth:.infinity,minHeight:38,alignment:.leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHand().id("usualExplainer")
            .accessibilityValue(showAbout ? "Expanded" : "Collapsed")
            if showAbout {usualExplainer(baseline:baseline,marker:marker,windowMean:windowMean,usualDays:usual.days)}
        }
        .padding(.horizontal,16).padding(.top,12).padding(.bottom,8)
        .frame(maxWidth:compact ? 400 : .infinity,alignment:.leading)
        .onChange(of:showAbout) {_,open in
            guard open else{return}
            DispatchQueue.main.asyncAfter(deadline:.now()+0.05) {withAnimation(.easeInOut(duration:0.25)) {proxy.scrollTo("usualExplainer",anchor:.top)}}
        }
        }
    }
}


func timingCoverageText(timed:Int,measured:Int,total:Int)->String {
    let coverage=timed>0 ? "Generating: \(timed) of \(total) replies · Overall: \(measured) of \(total)." : "Overall: \(measured) of \(total) replies · first-output timing unavailable."
    return coverage+" Replies under 100 tokens or without reliable duration aren’t counted."
}

// MARK: - Detail: window vs Usual
struct TodayUsualSlots:View {
    var title:String="Today"
    let todayMean:Double?
    let responses:Int
    let marker:SpeedMarker?
    let baseline:UsualBaseline?
    let pastDays:Int
    var timing:TimingSplit?=nil
    var usualTiming:UsualTiming?=nil
    var coverage:String?=nil
    func timingRow(_ label:String,_ value:String,_ color:Color)->some View {
        HStack(spacing:6) {
            Text(label).foregroundStyle(SpeedTheme.tertiary)
            Spacer(minLength:4)
            Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(color)
        }.font(.system(size:11)).lineLimit(1)
    }
    // Today's values use the same rule as ▲/▼ (10%+ beyond the normal range).
    var todayTiming:some View {
        let waitMark=timing.flatMap {t in usualTiming.flatMap {timingMarker(t.wait,lo:$0.waitLo,hi:$0.waitHi,longerIsSlower:true,responses:t.responses)}}
        let genMark=timing.flatMap {t in usualTiming.flatMap {timingMarker(t.generating,lo:$0.generatingLo,hi:$0.generatingHi,longerIsSlower:false,responses:t.responses)}}
        return VStack(spacing:2) {
            timingRow("First output wait",timing.map {String(format:"%.1f s",$0.wait)} ?? "—",waitMark.map(markerColor) ?? (timing==nil ? SpeedTheme.quiet : SpeedTheme.primary))
            timingRow("Generating (est.)",timing.map {wholeSpeed($0.generating)+" t/s"} ?? "—",genMark.map(markerColor) ?? (timing==nil ? SpeedTheme.quiet : SpeedTheme.primary))
        }
    }
    @ViewBuilder var usualTimingView:some View {
        if usualTiming==nil {
            Text("Appears with the usual").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).frame(maxWidth:.infinity,alignment:.leading)
        } else {
        VStack(spacing:2) {
            timingRow("First output wait",usualTiming.map {String(format:"%.1f s",$0.wait)} ?? "—",usualTiming==nil ? SpeedTheme.quiet : SpeedTheme.primary)
            timingRow("Generating (est.)",usualTiming.map {wholeSpeed($0.generating)+" t/s"} ?? "—",usualTiming==nil ? SpeedTheme.quiet : SpeedTheme.primary)
        }
        }
    }
    // Wait and generating lead: they say where the time went. Overall t/s is the footer.
    // The clicked number leads (overall t/s, one badge); "where the time went" explains it.
    func splitColumn(_ label:String,value:String,detail:String,mark:SpeedMarker?)->some View {
        VStack(alignment:.leading,spacing:4) {
            Text(label).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1)
            Text(value).font(.system(size:17,weight:.semibold)).monospacedDigit().foregroundStyle(mark.map(markerColor) ?? SpeedTheme.primary)
            Text(detail).font(.system(size:11)).foregroundStyle(mark.map(markerColor) ?? SpeedTheme.tertiary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,16).padding(.vertical,16)
    }
    // Generating leads (4 Nov); wait and overall show where the rest of the time went.
    func splitCard(_ t:TimingSplit)->some View {
        let u=usualTiming
        let waitMark=u.flatMap {timingMarker(t.wait,lo:$0.waitLo,hi:$0.waitHi,longerIsSlower:true,responses:t.responses)}
        let genMark=u.flatMap {timingMarker(t.generating,lo:$0.generatingLo,hi:$0.generatingHi,longerIsSlower:false,responses:t.responses)}
        var badge:(String,BadgeTone)?=nil
        if let m=genMark,let uu=u {
            let p=Int((abs(t.generating/max(uu.generating,0.0001)-1)*100).rounded())
            badge=("\(p)% \(m == .faster ? "faster" : "slower")",m == .faster ? BadgeTone.faster : BadgeTone.slower)
        }
        return VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:8) {
                SectionLabel(text:"\(title) · \(responseCount(responses))",rule:false)
                HStack(alignment:.firstTextBaseline,spacing:8) {
                    HStack(alignment:.firstTextBaseline,spacing:4) {
                        if let genMark {SpeedMarkerGlyph(marker:genMark,size:12)}
                        Text(wholeSpeed(t.generating)).font(.system(size:28,weight:.semibold)).monospacedDigit().foregroundStyle(SpeedTheme.primary)
                        Text("t/s generating (est.)").font(.system(size:13)).foregroundStyle(SpeedTheme.secondary)
                    }
                    Spacer(minLength:0)
                    if let badge {VerdictBadge(text:badge.0,tone:badge.1)}
                }
                if let u {
                    Text("Usual at these hours \(wholeSpeed(u.generating)) · usual range \(wholeSpeed(u.generatingLo))–\(wholeSpeed(u.generatingHi))").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary)
                } else {
                    Text("No generating usual yet · needs \(usualMinDays) days with timing").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary)
                }
            }.padding(16)
            Rectangle().fill(SpeedTheme.hairline).frame(height:1)
            HStack(alignment:.top,spacing:0) {
                splitColumn("Wait before output",value:String(format:"%.1f s",t.wait),
                            detail:u.map {timingCompareText(t.wait,usual:$0.wait,longerIsSlower:true)+String(format:" · usual %.1f s",$0.wait)} ?? "usual appears after \(usualMinDays) days",mark:waitMark)
                Rectangle().fill(SpeedTheme.hairline).frame(width:1)
                splitColumn("Overall, wait included",value:wholeSpeed(todayMean)+" t/s",
                            detail:baseline.map {"usual \(wholeSpeed($0.median)) · range \(wholeSpeed($0.lo))–\(wholeSpeed($0.hi))"} ?? "usual appears after \(usualMinDays) days",mark:marker)
            }.fixedSize(horizontal:false,vertical:true)
            if let coverage {
                Rectangle().fill(SpeedTheme.hairline).frame(height:1)
                Text(coverage).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).fixedSize(horizontal:false,vertical:true)
                    .padding(.horizontal,16).padding(.vertical,12)
            }
        }
    }
    var body:some View {
        Group {
            if let t=timing {splitCard(t)} else {overallCard}
        }
        .background(SpeedTheme.card,in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(SpeedTheme.cardStroke,lineWidth:1))
        .accessibilityElement(children:.combine)
    }
    // Replies without first-output timing: the overall speed is all there is.
    var overallCard:some View {
        VStack(spacing:0) {
        HStack(alignment:.top,spacing:0) {
            VStack(alignment:.leading,spacing:2) {
                Text("\(title) · \(responseCount(responses))").font(.system(size:12)).foregroundStyle(SpeedTheme.secondary).lineLimit(1).minimumScaleFactor(0.8)
                HStack(alignment:.firstTextBaseline,spacing:4) {
                    if let marker {SpeedMarkerGlyph(marker:marker,size:11)}
                    Text(wholeSpeed(todayMean)).font(.system(size:30,weight:.semibold)).monospacedDigit().foregroundStyle(todayMean==nil ? SpeedTheme.quiet : SpeedTheme.primary)
                    if todayMean != nil {Text("t/s overall").font(.system(size:13)).foregroundStyle(SpeedTheme.secondary)}
                }
                if let marker {
                    Text(markerWord(marker)).font(.system(size:11)).foregroundStyle(markerColor(marker))
                } else if baseline != nil && responses>0 && responses<markerMinResponses {
                    Text("Too few to compare (needs \(markerMinResponses))").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary)
                }
            }
            .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,10)
            Rectangle().fill(SpeedTheme.hairline).frame(width:1)
            VStack(alignment:.leading,spacing:2) {
                Text("Usual · same hours").font(.system(size:12)).foregroundStyle(SpeedTheme.secondary)
                if let b=baseline {
                    HStack(alignment:.firstTextBaseline,spacing:4) {
                        Text(wholeSpeed(b.median)).font(.system(size:30,weight:.semibold)).monospacedDigit().foregroundStyle(SpeedTheme.primary)
                        Text("t/s").font(.system(size:13)).foregroundStyle(SpeedTheme.secondary)
                    }
                    Text("usual range \(wholeSpeed(b.lo))–\(wholeSpeed(b.hi)) · \(b.days) days").font(.system(size:11)).foregroundStyle(SpeedTheme.secondary)
                } else {
                    Text("No usual yet").font(.system(size:15,weight:.semibold)).foregroundStyle(SpeedTheme.secondary).padding(.top,8)
                    Text("Needs \(usualMinDays) days · \(pastDays) so far").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary)
                }
            }
            .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.vertical,10)
        }
        .fixedSize(horizontal:false,vertical:true)
        if timing != nil || usualTiming != nil {
            Rectangle().fill(SpeedTheme.hairline).frame(height:1)
            HStack(alignment:.top,spacing:0) {
                todayTiming.padding(.horizontal,12).padding(.vertical,8).frame(maxWidth:.infinity)
                Rectangle().fill(SpeedTheme.hairline).frame(width:1)
                usualTimingView.padding(.horizontal,12).padding(.vertical,8).frame(maxWidth:.infinity)
            }.fixedSize(horizontal:false,vertical:true)
        }
        if let coverage {
            Rectangle().fill(SpeedTheme.hairline).frame(height:1)
            Text(coverage).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).fixedSize(horizontal:false,vertical:true)
                .padding(.horizontal,16).padding(.vertical,12)
        }
        }
    }
}
// One dot per past day, the normal range as a band, usual as a tick, now as ▲/▼ (or ◆).
struct UsualStrip:View {
    let baseline:UsualBaseline
    let today:Double?
    let marker:SpeedMarker?
    var nowLabel:String="today"
    var spokenSummary:String {
        var t="Usual "+wholeSpeed(baseline.median)+", usual range "+wholeSpeed(baseline.lo)+" to "+wholeSpeed(baseline.hi)+" from "+String(baseline.days)+" days"
        if let today {t += ", "+nowLabel+" "+wholeSpeed(today)}
        return t
    }
    var body:some View {
        let values=baseline.dayMeans+(today.map {[$0]} ?? [])
        let lo=(values.min() ?? 0)*0.9
        let hi=max((values.max() ?? 1)*1.1,lo+1)
        return Canvas {ctx,size in
            let left:CGFloat=12,right=size.width-12,mid:CGFloat=36
            func x(_ v:Double)->CGFloat {left+CGFloat((v-lo)/(hi-lo))*(right-left)}
            var axis=Path();axis.move(to:CGPoint(x:left,y:mid));axis.addLine(to:CGPoint(x:right,y:mid))
            ctx.stroke(axis,with:.color(Color.white.opacity(0.14)),lineWidth:1)
            let band=CGRect(x:x(baseline.lo),y:mid-10,width:max(2,x(baseline.hi)-x(baseline.lo)),height:20)
            ctx.fill(Path(roundedRect:band,cornerRadius:4),with:.color(Color(white:0.23)))
            for d in baseline.dayMeans {ctx.fill(Path(ellipseIn:CGRect(x:x(d)-4,y:mid-4,width:8,height:8)),with:.color(Color(white:0.78)))}
            var tick=Path();tick.move(to:CGPoint(x:x(baseline.median),y:mid-16));tick.addLine(to:CGPoint(x:x(baseline.median),y:mid+16))
            ctx.stroke(tick,with:.color(SpeedTheme.primary),lineWidth:2)
            ctx.draw(Text("usual \(wholeSpeed(baseline.median))").font(.system(size:11,weight:.semibold)).foregroundColor(SpeedTheme.primary),at:CGPoint(x:x(baseline.median),y:10),anchor:.center)
            ctx.draw(Text("usual range \(wholeSpeed(baseline.lo))–\(wholeSpeed(baseline.hi))").font(.system(size:11)).foregroundColor(SpeedTheme.secondary),at:CGPoint(x:x(baseline.lo),y:size.height-6),anchor:.leading)
            if let today {
                let color=marker.map(markerColor) ?? SpeedTheme.link
                let glyph=marker == .faster ? "▲" : marker == .slower ? "▼" : "◆"
                ctx.draw(Text(glyph).font(.system(size:13)).foregroundColor(color),at:CGPoint(x:x(today),y:mid),anchor:.center)
                ctx.draw(Text("\(nowLabel) \(wholeSpeed(today))").font(.system(size:11,weight:.semibold)).foregroundColor(color),at:CGPoint(x:x(today),y:10),anchor:.center)
            }
        }
        .frame(height:76)
        .accessibilityElement()
        .accessibilityLabel("Past daily averages at these hours")
        .accessibilityValue(spokenSummary)
    }
}

// MARK: - Congestion grid (report window)
// One effort + tier only. Each cell = one hour on one day; colored against this
// tier's normal speed (median of its hourly averages over the period).
struct CongestionCell {
    let mean:Double
    let count:Int
    var wait:Double?=nil      // median first output wait (s) in that hour, when logged
    var generating:Double?=nil // estimated generating t/s after the wait (3+ timed replies)
}
let congestionMinResponses=3
let congestionTypicalMinDays=3
let weekdayViewMinDays=28
enum CongestionLevel {case muchSlower,slower,normal,faster}
func congestionLevel(_ value:Double,baseline:Double)->CongestionLevel {
    guard baseline>0 else{return .normal}
    let ratio=value/baseline
    if ratio <= 0.75 {return .muchSlower}
    if ratio <= 0.90 {return .slower}
    if ratio >= 1.10 {return .faster}
    return .normal
}
func congestionFill(_ level:CongestionLevel)->Color {
    switch level {
    case .muchSlower:return SpeedTheme.slowerYellow.opacity(0.90)
    case .slower:return SpeedTheme.slowerYellow.opacity(0.38)
    case .normal:return Color.white.opacity(0.12)
    case .faster:return SpeedTheme.faster.opacity(0.42)
    }
}
func congestionText(_ level:CongestionLevel)->Color {level == .muchSlower ? SpeedTheme.surface : SpeedTheme.primary}
// Two faster steps to mirror the two slower ones: 25%+ above usual is a stronger green.
let muchFasterFill=SpeedTheme.faster.opacity(0.72)
func gridFill(_ level:CongestionLevel,ratio:Double)->Color {level == .faster && ratio>=1.25 ? muchFasterFill : congestionFill(level)}
func gridText(_ level:CongestionLevel,ratio:Double)->Color {level == .faster && ratio>=1.25 ? SpeedTheme.surface : congestionText(level)}
struct CongestionGrid {
    let days:[Date]                       // newest first; included days since this tier was first used (max 14)
    let cells:[Date:[Int:CongestionCell]]
    let typical:[Int:Double]              // "Usual": middle of past included days at each hour (today not counted)
    let baseline:Double?
    let daysSoFar:Int                     // calendar days since this effort + tier was first seen
    let pastDays:Int                      // past included days with any response in the window
    var dayScores:[Date:Double]=[:]       // that day vs usual for the hours it used (1 = usual)
    var typicalDays:[Int:Int]=[:]         // past days behind each hour's usual speed
    var typicalWait:[Int:Double]=[:]      // usual first output wait (s) at each hour, same 3-day rule
    var typicalGenerating:[Int:Double]=[:] // usual generating t/s at each hour, same 3-day rule
    var normalGenerating:Double?=nil      // middle generating t/s across solid hours
    var typicalGenDays:[Int:Int]=[:]      // past days behind each hour's usual generating speed
    var genDayScores:[Date:Double]=[:]    // that day's generating vs usual at the hours it used (1 = usual)
    var normalWait:Double?=nil            // middle wait across solid hours
    var typicalCount:[Int:Double]=[:]     // average replies at that hour per past day with any use
    var maxCount:Int=0                    // most replies in any one cell
    func cell(_ day:Date,_ hour:Int)->CongestionCell? {cells[day]?[hour]}
}
// A day counts with 3+ replies spread over 3+ hours; each reply is compared with the
// usual for its 3-hour block, so days aren't judged by which hours you happened to work.
let dayScoreMinHours=3
func dayScores(_ readings:[SpeedReading],calendar:Calendar = .current,calendarIndex:ReplyCalendarIndex?=nil)->[Date:Double] {
    let index=calendarIndex?.matching(calendar)
    var byBlock:[Int:[Date:[Double]]]=[:]
    for r in readings where r.speed.isFinite {byBlock[(index?.hour(r.date) ?? calendar.component(.hour,from:r.date))/3,default:[:]][(index?.day(r.date) ?? calendar.startOfDay(for:r.date)),default:[]].append(r.speed)}
    let normal=byBlock.compactMapValues {days->Double? in
        let means=days.values.filter {$0.count>=congestionMinResponses}.map {$0.reduce(0,+)/Double($0.count)}.sorted()
        return means.isEmpty ? nil : percentile(means,0.5)
    }
    var ratios:[Date:[Double]]=[:],hours:[Date:Set<Int>]=[:]
    for r in readings where r.speed.isFinite {
        let h=(index?.hour(r.date) ?? calendar.component(.hour,from:r.date))
        guard let n=normal[h/3],n>0 else{continue}
        let day=(index?.day(r.date) ?? calendar.startOfDay(for:r.date))
        ratios[day,default:[]].append(r.speed/n);hours[day,default:[]].insert(h)
    }
    return ratios.filter {$0.value.count>=congestionMinResponses && (hours[$0.key]?.count ?? 0)>=dayScoreMinHours}.mapValues {$0.reduce(0,+)/Double($0.count)}
}
func congestionGrid(_ readings:[SpeedReading],now:Date,days:Int=14,include:(Date)->Bool={_ in true},calendar:Calendar = .current,calendarIndex:ReplyCalendarIndex?=nil)->CongestionGrid {
    let index=calendarIndex?.matching(calendar)
    let today=calendar.startOfDay(for:now)
    let list=(0..<days).compactMap {calendar.date(byAdding:.day,value:-$0,to:today)}.filter(include)
    let first=calendar.date(byAdding:.day,value:-(days-1),to:today) ?? today
    let window=readings.filter {$0.date>=first && $0.date<=now && $0.speed.isFinite && include((index?.day($0.date) ?? calendar.startOfDay(for:$0.date)))}
    var buckets:[Date:[Int:[Double]]]=[:],waitBuckets:[Date:[Int:[Double]]]=[:],timedBuckets:[Date:[Int:[SpeedReading]]]=[:]
    for r in window {
        let day=(index?.day(r.date) ?? calendar.startOfDay(for:r.date)),h=(index?.hour(r.date) ?? calendar.component(.hour,from:r.date))
        buckets[day,default:[:]][h,default:[]].append(r.speed)
        if let w=r.waitSeconds {waitBuckets[day,default:[:]][h,default:[]].append(w);timedBuckets[day,default:[:]][h,default:[]].append(r)}
    }
    var cells:[Date:[Int:CongestionCell]]=[:]
    for (day,hours) in buckets {
        for (h,v) in hours {
            let w=(waitBuckets[day]?[h] ?? []).sorted()
            let timed=timedBuckets[day]?[h] ?? []
            cells[day,default:[:]][h]=CongestionCell(mean:v.reduce(0,+)/Double(v.count),count:v.count,wait:w.count>=congestionMinResponses ? percentile(w,0.5) : nil,
                                                     generating:timed.count>=congestionMinResponses ? timingSplit(timed)?.generating : nil)
        }
    }
    let solid=cells.values.flatMap {$0.values}.filter {$0.count>=congestionMinResponses}.map(\.mean).sorted()
    let past=list.filter {$0<today}
    var typical:[Int:Double]=[:],typicalDays:[Int:Int]=[:],typicalWait:[Int:Double]=[:],typicalCount:[Int:Double]=[:],typicalGenerating:[Int:Double]=[:],typicalGenDays:[Int:Int]=[:]
    let usedPast=past.filter {buckets[$0] != nil}
    for h in 0..<24 {
        let solidCells=past.compactMap {cells[$0]?[h]}.filter {$0.count>=congestionMinResponses}
        let means=solidCells.map(\.mean).sorted()
        if means.count>=congestionTypicalMinDays {typical[h]=percentile(means,0.5);typicalDays[h]=means.count}
        let waits=solidCells.compactMap(\.wait).sorted()
        if waits.count>=congestionTypicalMinDays {typicalWait[h]=percentile(waits,0.5)}
        let gens=solidCells.compactMap(\.generating).sorted()
        if gens.count>=congestionTypicalMinDays {typicalGenerating[h]=percentile(gens,0.5);typicalGenDays[h]=gens.count}
        let counts=usedPast.map {cells[$0]?[h]?.count ?? 0}
        if !usedPast.isEmpty && counts.contains(where:{$0>0}) {typicalCount[h]=Double(counts.reduce(0,+))/Double(usedPast.count)}
    }
    let solidWaits=cells.values.flatMap {$0.values}.filter {$0.count>=congestionMinResponses}.compactMap(\.wait).sorted()
    let solidGens=cells.values.flatMap {$0.values}.compactMap(\.generating).sorted()
    let shown=buckets.keys.min().map {firstDay in list.filter {$0>=firstDay}} ?? []
    let earliest=readings.filter {$0.speed.isFinite}.map(\.date).min()
    let span=earliest.map {(calendar.dateComponents([.day],from:calendar.startOfDay(for:$0),to:today).day ?? 0)+1} ?? 0
    var grid=CongestionGrid(days:shown,cells:cells,typical:typical,baseline:solid.isEmpty ? nil : percentile(solid,0.5),daysSoFar:span,pastDays:past.filter {buckets[$0] != nil}.count)
    grid.dayScores=dayScores(window,calendar:calendar,calendarIndex:index)
    grid.typicalDays=typicalDays;grid.typicalWait=typicalWait;grid.typicalCount=typicalCount
    grid.normalWait=solidWaits.isEmpty ? nil : percentile(solidWaits,0.5)
    grid.typicalGenerating=typicalGenerating
    grid.typicalGenDays=typicalGenDays
    var genScores:[Date:Double]=[:]
    for (day,hours) in cells {
        let ratios=hours.compactMap {entry->Double? in
            guard let g=entry.value.generating,let u=typicalGenerating[entry.key],u>0 else{return nil}
            return g/u
        }
        if ratios.count>=dayScoreMinHours {genScores[day]=ratios.reduce(0,+)/Double(ratios.count)}
    }
    grid.genDayScores=genScores
    grid.normalGenerating=solidGens.isEmpty ? nil : percentile(solidGens,0.5)
    grid.maxCount=cells.values.flatMap {$0.values}.map(\.count).max() ?? 0
    return grid
}
// Wait colors run the other way: a longer wait is worse.
func waitLevel(_ wait:Double,normal:Double)->CongestionLevel {
    guard normal>0 else{return .normal}
    let ratio=wait/normal
    if ratio >= 1.25 {return .muchSlower}
    if ratio >= 1.10 {return .slower}
    if ratio <= 0.90 {return .faster}
    return .normal
}
// MARK: Hours insight
// Usual hours are classed against the normal speed (≤ 0.9 slow, ≥ 1.1 fast) and runs of
// neighbouring hours are merged, wrapping past midnight (11pm–1am is one run).
struct HourRun:Equatable {
    let start:Int
    let length:Int
    var hours:[Int] {(0..<length).map {(start+$0)%24}}
    var label:String {length==1 ? hourClock(start) : hourClock(start)+"–"+hourClock((start+length)%24)}
}
func hourRuns(_ marked:Set<Int>)->[HourRun] {
    if marked.count>=24 {return [HourRun(start:0,length:24)]}
    var runs:[HourRun]=[]
    for h in 0..<24 where marked.contains(h) && !marked.contains((h+23)%24) {
        var n=1
        while marked.contains((h+n)%24) {n+=1}
        runs.append(HourRun(start:h,length:n))
    }
    return runs.sorted {$0.start<$1.start}
}
struct InsightBox {
    let title:String
    let value:String
    let sub:String
    var tone:CongestionLevel?=nil
}
struct HoursInsight {
    let now:InsightBox
    let slowest:InsightBox
    let fastest:InsightBox
    let answer:String?
    let waitNote:String?
}
func partOfDay(_ h:Int,plural:Bool=false)->String {
    switch h {
    case 5..<12:return plural ? "mornings" : "the morning"
    case 12..<17:return plural ? "afternoons" : "the afternoon"
    case 17..<21:return plural ? "evenings" : "the evening"
    default:return plural ? "late nights" : "late at night"
    }
}
func hoursInsight(_ grid:CongestionGrid,now:Date,tier:String,calendar:Calendar = .current)->HoursInsight? {
    guard let base=grid.baseline,base>0,!grid.typical.isEmpty else{return nil}
    let name=modeTitle(tier)
    let ratio=grid.typical.mapValues {$0/base}
    func pct(_ r:Double)->Int {Int((abs(r-1)*100).rounded())}
    func pctRange(_ hours:[Int],_ word:String)->String {
        let ps=hours.compactMap {ratio[$0]}.map(pct)
        guard let lo=ps.min(),let hi=ps.max() else{return ""}
        return lo==hi ? "\(lo)% \(word)" : "\(lo)–\(hi)% \(word)"
    }
    func daysText(_ hours:[Int])->String {
        let ds=hours.compactMap {grid.typicalDays[$0]}
        guard let lo=ds.min(),let hi=ds.max() else{return ""}
        return "from \(lo==hi ? String(lo) : "\(lo)–\(hi)") past days per hour"+(hi<5 ? " · early pattern" : "")
    }
    func mean(_ run:HourRun)->Double {let v=run.hours.compactMap {ratio[$0]};return v.reduce(0,+)/Double(max(1,v.count))}
    let slowRuns=hourRuns(Set(ratio.filter {$0.value<=0.9}.keys)),fastRuns=hourRuns(Set(ratio.filter {$0.value>=1.1}.keys))
    // Right now
    let nowHour=calendar.component(.hour,from:now)
    let nowBox:InsightBox
    if let r=ratio[nowHour],let u=grid.typical[nowHour] {
        let level=congestionLevel(r*100,baseline:100)
        nowBox=InsightBox(title:"This hour, usually · \(hourClock(nowHour))",value:level == .normal ? "An average hour" : "Usually \(pct(r))% \(r<1 ? "slower" : "faster") now",
                          sub:"usually \(wholeSpeed(u)) t/s · \(modeTitle(tier))’s usual is \(wholeSpeed(base))",tone:level == .normal ? nil : level)
    } else {
        nowBox=InsightBox(title:"This hour, usually · \(hourClock(nowHour))",value:"No usual for this hour yet",sub:"needs \(congestionTypicalMinDays) past days at \(hourClock(nowHour))")
    }
    // Slowest hours: the slowest run.
    let slowBox:InsightBox
    if let slow=slowRuns.min(by:{mean($0)<mean($1)}) {
        slowBox=InsightBox(title:"Slowest hours",value:"\(slow.label) · \(pctRange(slow.hours,"slower"))",sub:daysText(slow.hours),tone:mean(slow)<=0.75 ? .muchSlower : .slower)
    } else {
        slowBox=InsightBox(title:"Slowest hours",value:"No slow hours",sub:"every hour with a usual is within 10% of this tier’s usual")
    }
    // Fastest hours: the best one or two runs, in clock order.
    let fastBox:InsightBox
    let top=Array(fastRuns.sorted {mean($0)>mean($1)}.prefix(2)).sorted {$0.start<$1.start}
    if !top.isEmpty {
        let left=fastRuns.flatMap(\.hours).filter {$0>=nowHour}
        let sub:String
        if fastRuns.contains(where:{$0.hours.contains(nowHour)}) {sub="you’re in one now"}
        else if let best=left.max(by:{ratio[$0]==ratio[$1] ? $0>$1 : (ratio[$0] ?? 0)<(ratio[$1] ?? 0)}) {sub="best window left today: \(hourClock(best))"}
        else {sub="none left today · next from \(hourClock(top[0].start))"}
        fastBox=InsightBox(title:"Fastest hours",value:top.map(\.label).joined(separator:" and ")+" · "+pctRange(top.flatMap(\.hours),"faster"),sub:sub,tone:.faster)
    } else {
        fastBox=InsightBox(title:"Fastest hours",value:"No fast hours",sub:"no hour usually runs 10%+ above this tier’s usual")
    }
    // The answer line: the quickest and slowest usual hours.
    var answer:String?=nil
    if !slowRuns.isEmpty && !fastRuns.isEmpty,
       let lo=grid.typical.min(by:{$0.value<$1.value || ($0.value==$1.value && $0.key<$1.key)}),
       let hi=grid.typical.max(by:{$0.value<$1.value || ($0.value==$1.value && $0.key>$1.key)}),lo.value>0 {
        let quicker=Int(((hi.value/lo.value-1)*100).rounded())
        answer="Plan heavy work for \(partOfDay(hi.key)): \(name) usually runs \(wholeSpeed(hi.value)) t/s at \(hourClock(hi.key)) vs \(wholeSpeed(lo.value)) t/s at \(hourClock(lo.key)), about \(quicker)% quicker."
    }
    // Why the slow hours are slow: the wait, or generation itself.
    var waitNote:String?=nil
    if let slow=slowRuns.min(by:{mean($0)<mean($1)}),let normalWait=grid.normalWait,normalWait>0 {
        let waits=grid.typicalWait.filter {grid.typical[$0.key] != nil}.map(\.value)
        let slowWaits=slow.hours.compactMap {grid.typicalWait[$0]}
        let part=partOfDay((slow.start+slow.length/2)%24,plural:true)
        if waits.count>=2,let lo=waits.min(),let hi=waits.max(),!slowWaits.isEmpty {
            let slowWait=slowWaits.reduce(0,+)/Double(slowWaits.count)
            if slowWait>=normalWait*1.3 {
                waitNote="Slow \(part) also show a longer first output wait (\(String(format:"%.1f",slowWait)) s vs \(String(format:"%.1f",normalWait)) s overall)."
            } else if hi<=lo*1.6 || hi-lo<1 {
                let a=String(format:"%.1f",lo),b=String(format:"%.1f",hi)
                waitNote="Slow \(part) show similar first output waits (\(a==b ? "about \(a)" : "\(a)–\(b)") s). This does not establish whether generating (est.) is slower."
            }
        }
    }
    return HoursInsight(now:nowBox,slowest:slowBox,fastest:fastBox,answer:answer,waitNote:waitNote)
}
// By day of week: middle of that weekday's day scores; plus weekdays vs weekends.
struct WeekdayScore {
    let label:String
    let score:Double?
    let days:Int
    let weekend:Bool
}
func weekdayScores(_ scores:[Date:Double],calendar:Calendar = .current)->(days:[WeekdayScore],weekdays:WeekdayScore,weekends:WeekdayScore) {
    let order=[2,3,4,5,6,7,1],names=["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
    func summary(_ v:[Double])->Double? {v.isEmpty ? nil : percentile(v.sorted(),0.5)}
    let days=order.enumerated().map {i,wd->WeekdayScore in
        let v=scores.filter {calendar.component(.weekday,from:$0.key)==wd}.map(\.value)
        return WeekdayScore(label:names[i],score:summary(v),days:v.count,weekend:wd==1 || wd==7)
    }
    let we=scores.filter {calendar.isDateInWeekend($0.key)}.map(\.value),wk=scores.filter {!calendar.isDateInWeekend($0.key)}.map(\.value)
    return (days,WeekdayScore(label:"Weekdays",score:summary(wk),days:wk.count,weekend:false),WeekdayScore(label:"Weekends",score:summary(we),days:we.count,weekend:true))
}
func percentText(_ ratio:Double)->String {
    let p=Int(((ratio-1)*100).rounded())
    return p==0 ? "0%" : (p>0 ? "+\(p)%" : "−\(-p)%")
}
// Weekday × hour over the last 4 weeks: median of that weekday-hour's daily
// averages (each with 3+ responses); needs 3+ such days.
func weekdayCongestion(_ readings:[SpeedReading],now:Date,weeks:Int=4,calendar:Calendar = .current,calendarIndex:ReplyCalendarIndex?=nil)->[Int:[Int:Double]] {
    let index=calendarIndex?.matching(calendar)
    let today=calendar.startOfDay(for:now)
    guard let start=calendar.date(byAdding:.day,value:-(weeks*7-1),to:today) else{return [:]}
    var buckets:[Date:[Int:[Double]]]=[:]
    for r in readings where r.date>=start && r.date<=now && r.speed.isFinite {
        buckets[(index?.day(r.date) ?? calendar.startOfDay(for:r.date)),default:[:]][(index?.hour(r.date) ?? calendar.component(.hour,from:r.date)),default:[]].append(r.speed)
    }
    var byWeekday:[Int:[Int:[Double]]]=[:]
    for (day,hours) in buckets {
        let wd=calendar.component(.weekday,from:day)
        for (h,v) in hours where v.count>=congestionMinResponses {byWeekday[wd,default:[:]][h,default:[]].append(v.reduce(0,+)/Double(v.count))}
    }
    return byWeekday.mapValues {hours in hours.filter {$0.value.count>=congestionTypicalMinDays}.mapValues {percentile($0.sorted(),0.5)}}
}
func congestionDayLabel(_ day:Date,now:Date,calendar:Calendar = .current)->String {
    if calendar.isDate(day,inSameDayAs:now) {return "Today"}
    let f=DateFormatter();f.timeZone=calendar.timeZone;f.dateFormat="EEE d MMM";return f.string(from:day)
}
enum GridMetric:String,CaseIterable {
    case speed,generating,wait,replies
    var title:String {switch self {case .speed:return "Overall";case .generating:return "Generating";case .wait:return "Wait";case .replies:return "Replies"}}
}
// The three answers above the grid: right now, slowest hours, fastest hours.
struct HoursInsightStrip:View {
    let insight:HoursInsight
    func color(_ t:CongestionLevel?)->Color {
        guard let t else{return SpeedTheme.primary}
        return t == .faster ? SpeedTheme.faster : SpeedTheme.slowerYellow
    }
    func box(_ b:InsightBox)->some View {
        // Weak evidence looks weak: an early pattern gets "~" and is faded.
        let early=b.sub.contains("early pattern")
        return VStack(alignment:.leading,spacing:Space.s1) {
            SectionLabel(text:b.title,rule:false)
            Text((early ? "~ " : "")+b.value).font(.system(size:15,weight:.semibold)).foregroundStyle(color(b.tone)).opacity(early ? 0.6 : 1).lineLimit(1).minimumScaleFactor(0.8)
            Text(b.sub).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1)
        }
        .padding(.horizontal,Space.s3).padding(.vertical,Space.s2+4)
        .frame(maxWidth:.infinity,alignment:.leading)
        .accessibilityElement(children:.combine)
    }
    var body:some View {
        HStack(spacing:0) {
            box(insight.now)
            Rectangle().fill(SpeedTheme.hairline).frame(width:1)
            box(insight.slowest)
            Rectangle().fill(SpeedTheme.hairline).frame(width:1)
            box(insight.fastest)
        }
        .fixedSize(horizontal:false,vertical:true)
        .background(SpeedTheme.card,in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(SpeedTheme.cardStroke,lineWidth:1))
    }
}
// A small outlined ⋯ button that opens a list of actions (the visible twin of a right-click menu).
struct MoreActionsButton:View {
    let actions:[(String,()->Void)]
    @Binding var open:Bool
    var body:some View {
        Button {open.toggle()} label: {Image(systemName:"ellipsis").font(.system(size:10,weight:.semibold)).frame(width:12)}
            .buttonStyle(OutlineButtonStyle(compact:true))
            .accessibilityLabel("More actions")
            .popover(isPresented:$open,arrowEdge:.bottom) {
                VStack(alignment:.leading,spacing:2) {
                    ForEach(Array(actions.enumerated()),id:\.offset) {_,a in
                        Button {a.1();open=false} label: {
                            Text(a.0).font(.system(size:12)).padding(.horizontal,8).frame(minWidth:160,minHeight:24,alignment:.leading).contentShape(Rectangle())
                        }.buttonStyle(MenuRowStyle())
                    }
                }.padding(4)
            }
    }
}
private struct PopulatedGridHeightKey:PreferenceKey {
    static var defaultValue:CGFloat=0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) {value=max(value,nextValue())}
}
struct CongestionGridView:View {
    let grid:CongestionGrid                 // precomputed in PatternsData
    let weekday:[Int:[Int:Double]]
    var tierName:String="this tier"
    let now:Date
    var metric:GridMetric = .speed
    var embedded=false                      // inside the report's chart card: no card of its own
    var onExclude:(Date)->Void={_ in}
    @State private var byWeekday=false
    @State private var populatedGridHeight:CGFloat=160
    @State private var hover:(day:Date?,hour:Int,label:String)?=nil
    @State private var hoverRow:Date?=nil
    @State private var menuDay:Date?=nil
    let labelWidth:CGFloat=96
    let dayWidth:CGFloat=56
    var nowHour:Int {Calendar.current.component(.hour,from:now)}
    // MARK: metric values
    func waitText(_ w:Double)->String {String(format:w<10 ? "%.1f" : "%.0f",w)}
    func level(speed v:Double?,count:Int)->CongestionLevel? {
        guard let v,count>=congestionMinResponses,let b=grid.baseline else{return nil}
        return congestionLevel(v,baseline:b)
    }
    func level(wait w:Double?)->CongestionLevel? {
        guard let w,let n=grid.normalWait else{return nil}
        return waitLevel(w,normal:n)
    }
    func replyFill(_ n:Double)->Color {
        let top=Double(max(1,grid.maxCount))
        return Color.white.opacity(n<=0 ? 0.03 : 0.06+0.34*min(1,n/top))
    }
    // Rows are HStacks of equal flexible cells so the grid always fits the window.
    // Dotted = too few replies to color; dashed = an hour later today.
    func tileBody(text:String,fill:Color,textColor:Color,bold:Bool,hour:Int,hovered:Bool,dotted:Bool=false,later:Bool=false)->some View {
        // A number only when it fits the cell; narrow cells stay color-only (hover shows the value).
        ViewThatFits(in:.horizontal) {
            Text(text)
                .font(.system(size:11,weight:bold ? .semibold : .regular)).monospacedDigit()
                .lineLimit(1).fixedSize()
                .foregroundStyle(textColor)
            Color.clear.frame(width:1,height:1)
        }
            .frame(minWidth:0,maxWidth:.infinity,minHeight:24)
            .background(RoundedRectangle(cornerRadius:4).fill(later ? Color.clear : fill))
            .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(Color.white.opacity(dotted ? 0.28 : (later ? 0.10 : 0)),style:StrokeStyle(lineWidth:1,dash:dotted ? [1.5,2] : [3,3])))
            .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(Color.white.opacity(hour==nowHour ? 0.6 : 0),lineWidth:1))
            .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(SpeedTheme.primary.opacity(hovered ? 1 : 0),lineWidth:2))
    }
    @ViewBuilder func cellTile(_ c:CongestionCell?,day:Date,hour:Int,label:String)->some View {
        let hovered=hover?.day==day && hover?.hour==hour
        let later=Calendar.current.isDate(day,inSameDayAs:now) && hour>nowHour
        Group {
            switch metric {
            case .speed:
                let lv=level(speed:c?.mean,count:c?.count ?? 0)
                let ratio=(c?.mean ?? 0)/max(grid.baseline ?? 1,0.0001)
                tileBody(text:c.map {wholeSpeed($0.mean)} ?? "",fill:lv.map {gridFill($0,ratio:ratio)} ?? Color.white.opacity(0.03),textColor:lv.map {gridText($0,ratio:ratio)} ?? SpeedTheme.tertiary,bold:lv != nil,hour:hour,hovered:hovered,dotted:c != nil && lv==nil,later:later)
            case .generating:
                let lv:CongestionLevel?=c?.generating.flatMap {g in grid.normalGenerating.map {congestionLevel(g,baseline:$0)}}
                let ratio=(c?.generating ?? 0)/max(grid.normalGenerating ?? 1,0.0001)
                tileBody(text:c?.generating.map {wholeSpeed($0)} ?? "",fill:lv.map {gridFill($0,ratio:ratio)} ?? Color.white.opacity(0.03),textColor:lv.map {gridText($0,ratio:ratio)} ?? SpeedTheme.tertiary,bold:lv != nil,hour:hour,hovered:hovered,later:later)
            case .wait:
                let lv=level(wait:c?.wait)
                tileBody(text:c?.wait.map(waitText) ?? "",fill:lv.map(congestionFill) ?? Color.white.opacity(0.03),textColor:lv.map(congestionText) ?? SpeedTheme.quiet,bold:lv != nil,hour:hour,hovered:hovered)
            case .replies:
                tileBody(text:c.map {String($0.count)} ?? "",fill:replyFill(Double(c?.count ?? 0)),textColor:SpeedTheme.primary,bold:false,hour:hour,hovered:hovered)
            }
        }
        .onHover {inside in
            if inside {hover=(day,hour,label)} else if hover?.day==day && hover?.hour==hour {hover=nil}
        }
        .accessibilityLabel(readout(day:day,hour:hour,label:label).map {$0.0+($0.1.isEmpty ? "" : ", "+$0.1)} ?? "")
    }
    // MARK: hover readout
    // (main text, comparison, comparison tone)
    func readout(day:Date?,hour:Int,label:String)->(String,String,CongestionLevel?)? {
        let head="\(label) · \(hourClock(hour))"
        guard let day else{
            let v=weekday[[2,3,4,5,6,7,1][max(0,["Mon","Tue","Wed","Thu","Fri","Sat","Sun"].firstIndex(of:label) ?? 0)]]?[hour]
            return (head+(v.map {" · \(wholeSpeed($0)) t/s"} ?? " · not enough days"),"",nil)
        }
        guard let c=grid.cell(day,hour) else{return (head+" · no replies","",nil)}
        let replies=" · \(c.count) repl\(c.count==1 ? "y" : "ies")"
        switch metric {
        case .speed:
            var text=head+" · \(wholeSpeed(c.mean)) t/s"+replies
            guard let u=grid.typical[hour],u>0 else{return (text+" · no usual for this hour yet","",nil)}
            text+=" · usual at \(hourClock(hour)) is \(wholeSpeed(u))"
            if c.count<congestionMinResponses {return (text,"too few replies to compare",nil)}
            let r=c.mean/u,lv=congestionLevel(r*100,baseline:100),p=Int((abs(r-1)*100).rounded())
            return (text,lv == .normal ? "about usual for this hour" : "\(p)% \(r<1 ? "slower" : "faster") than usual for this hour",lv == .normal ? nil : lv)
        case .generating:
            guard let g=c.generating else{return (head+replies+" · generating needs \(congestionMinResponses)+ timed replies","",nil)}
            var text=head+" · generating \(wholeSpeed(g)) t/s (est.)"+(c.wait.map {" · wait "+waitText($0)+" s"} ?? "")+" · overall \(wholeSpeed(c.mean))"+replies
            guard let u=grid.typicalGenerating[hour],u>0 else{return (text,"",nil)}
            text+=" · usual at \(hourClock(hour)) is \(wholeSpeed(u))"
            let lv=congestionLevel(g,baseline:u)
            return (text,timingCompareText(g,usual:u,longerIsSlower:false),lv == .normal ? nil : lv)
        case .wait:
            guard let w=c.wait else{return (head+replies+" · wait needs \(congestionMinResponses)+ timed replies","",nil)}
            var text=head+" · \(waitText(w)) s first output wait"+replies
            guard let u=grid.typicalWait[hour],u>0 else{return (text,"",nil)}
            text+=" · usual at \(hourClock(hour)) is \(waitText(u)) s"
            let lv=waitLevel(w,normal:u),p=Int((abs(w/u-1)*100).rounded())
            return (text,lv == .normal ? "about usual" : "\(p)% \(w>u ? "longer" : "shorter") than usual",lv == .normal ? nil : lv)
        case .replies:
            let u=grid.typicalCount[hour].map {" · usually \(String(format:$0<10 ? "%.1f" : "%.0f",$0)) a day at this hour"} ?? ""
            return (head+replies+u,"",nil)
        }
    }
    var readoutBar:some View {
        let r=hover.flatMap {readout(day:$0.day,hour:$0.hour,label:$0.label)}
        return HStack(spacing:Space.s1) {
            if let r {
                Text(r.0).foregroundStyle(SpeedTheme.primary)
                if !r.1.isEmpty {
                    Text("·").foregroundStyle(SpeedTheme.tertiary)
                    Text(r.1).foregroundStyle(r.2.map {$0 == .faster ? SpeedTheme.faster : SpeedTheme.slowerYellow} ?? SpeedTheme.secondary)
                }
            } else {
                Text(byWeekday ? "Hover an hour for details. The outlined column is now." : "Hover an hour for details. The outlined column is now. Hover a day to leave it out.").foregroundStyle(SpeedTheme.tertiary)
            }
            Spacer(minLength:0)
        }
        .font(.system(size:11)).lineLimit(1).truncationMode(.tail)
        .frame(height:24)
        .accessibilityHidden(true)
    }
    // MARK: rows
    var hourHeader:some View {
        HStack(spacing:Space.s1) {
            Color.clear.frame(width:labelWidth,height:1)
            ForEach(0..<24,id:\.self) {h in
                Text(h==nowHour ? "now" : (h%3==0 ? hourTick(h) : "")).font(.system(size:11,weight:h==nowHour ? .semibold : .regular))
                    .foregroundStyle(h==nowHour ? SpeedTheme.primary : SpeedTheme.tertiary).lineLimit(1).fixedSize()
                    .frame(minWidth:0,maxWidth:.infinity,alignment:.leading)
            }
            Text(metric == .wait ? "" : "Day").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).frame(width:dayWidth)
        }.accessibilityHidden(true)
    }
    // "Usual by hour": one bar per hour, aligned to the grid columns; the now hour is outlined.
    var usualBars:some View {
        let values:[Int:Double]={switch metric {case .speed:return grid.typical;case .generating:return grid.typicalGenerating;case .wait:return grid.typicalWait;case .replies:return grid.typicalCount}}()
        let top=max(values.values.max() ?? 1,0.0001)
        return HStack(alignment:.bottom,spacing:Space.s1) {
            Text("Usual by hour").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).frame(width:labelWidth,alignment:.leading).padding(.bottom,2)
            if values.isEmpty {
                Text(metric == .replies ? "Appears after a past day with replies" : "Appears after \(congestionTypicalMinDays) past days at an hour · \(grid.pastDays) so far")
                    .font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1)
                    .frame(maxWidth:.infinity,minHeight:24,alignment:.leading)
            } else {
                ForEach(0..<24,id:\.self) {h in
                    let v=values[h]
                    VStack(spacing:2) {
                        if let v {
                            Text(metric == .wait ? waitText(v) : (metric == .replies ? String(format:v<10 ? "%.1f" : "%.0f",v) : wholeSpeed(v)))
                                .font(.system(size:10)).monospacedDigit().foregroundStyle(SpeedTheme.secondary).lineLimit(1).minimumScaleFactor(0.6)
                            UnevenRoundedRectangle(topLeadingRadius:3,topTrailingRadius:3)
                                .fill(barFill(v)).frame(height:max(4,48*v/top))
                        } else {
                            Rectangle().fill(Color.white.opacity(0.08)).frame(height:2)
                        }
                    }
                    .frame(minWidth:0,maxWidth:.infinity,maxHeight:.infinity,alignment:.bottom)
                    .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(SpeedTheme.primary.opacity(h==nowHour ? 0.9 : 0),lineWidth:1).padding(-2))
                    .help(v.map {_ in "Usual at \(hourClock(h))"} ?? "Usual at \(hourClock(h)) · needs \(congestionTypicalMinDays) past days")
                }
            }
            Color.clear.frame(width:dayWidth,height:1)
        }
        .frame(height:values.isEmpty ? 24 : 72)
    }
    func barFill(_ v:Double)->Color {
        switch metric {
        case .speed:return grid.baseline.map {congestionFill(congestionLevel(v,baseline:$0))} ?? Color.white.opacity(0.12)
        case .generating:return grid.normalGenerating.map {congestionFill(congestionLevel(v,baseline:$0))} ?? Color.white.opacity(0.12)
        case .wait:return grid.normalWait.map {congestionFill(waitLevel(v,normal:$0))} ?? Color.white.opacity(0.12)
        case .replies:return Color.white.opacity(0.24)
        }
    }
    @ViewBuilder func dayTile(_ day:Date,label:String)->some View {
        switch metric {
        case .speed,.generating:
            let score=(metric == .generating ? grid.genDayScores : grid.dayScores)[day]
            let lv:CongestionLevel?=score.map {congestionLevel($0*100,baseline:100)}
            Text(score.map(percentText) ?? "")
                .font(.system(size:11,weight:.semibold)).monospacedDigit()
                .foregroundStyle(lv.map(congestionText) ?? SpeedTheme.quiet)
                .frame(width:dayWidth,height:24)
                .background(RoundedRectangle(cornerRadius:4).fill(lv.map(congestionFill) ?? Color.white.opacity(0.03)))
                .help(score.map {"\(label): \(percentText($0)) vs usual for the hours used"} ?? "\(label): needs \(dayScoreMinHours)+ hours of use to score")
        case .wait:
            Color.clear.frame(width:dayWidth,height:24)
        case .replies:
            let total=(grid.cells[day] ?? [:]).values.reduce(0) {$0+$1.count}
            Text(total==0 ? "" : String(total)).font(.system(size:11,weight:.semibold)).monospacedDigit().foregroundStyle(SpeedTheme.secondary)
                .frame(width:dayWidth,height:24)
                .background(RoundedRectangle(cornerRadius:4).fill(Color.white.opacity(0.03)))
                .help("\(label): \(total) repl\(total==1 ? "y" : "ies")")
        }
    }
    var displayedMetric:GridMetric {byWeekday && grid.daysSoFar>=weekdayViewMinDays ? .speed : metric}
    var hasData:Bool {
        switch displayedMetric {
        case .speed:return grid.baseline != nil
        case .generating:return grid.normalGenerating != nil
        case .wait:return grid.normalWait != nil
        case .replies:return grid.maxCount>0
        }
    }
    var body:some View {
        let canWeekday=grid.daysSoFar>=weekdayViewMinDays
        VStack(alignment:.leading,spacing:Space.s3) {
            // Header strip: hint at rest, the hovered hour's details on hover.
            HStack(spacing:Space.s2) {
                readoutBar
                if canWeekday {
                    Picker("Rows",selection:$byWeekday) {Text("By date").tag(false);Text("By weekday").tag(true)}
                        .pickerStyle(.segmented).labelsHidden().frame(width:176)
                }
            }
            Rectangle().fill(SpeedTheme.hairline).frame(height:1).padding(.horizontal,embedded ? 0 : -Space.s4)
            if !hasData {
                Text(emptyText).font(.system(size:12)).foregroundStyle(SpeedTheme.secondary)
                    .frame(maxWidth:.infinity,minHeight:populatedGridHeight,alignment:.topLeading)
            } else {
                VStack(alignment:.leading,spacing:Space.s3) {
                    if canWeekday && byWeekday {
                        if metric != .speed {Text("By weekday shows overall speed.").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary)}
                        weekdayGrid(baseline:grid.baseline ?? 1)
                    } else {
                        dayGrid
                    }
                    legend
                }
                .background(GeometryReader {g in
                    Color.clear.preference(key:PopulatedGridHeightKey.self,value:g.size.height)
                })
            }
        }
        .padding(.horizontal,embedded ? 0 : Space.s4).padding(.vertical,embedded ? 0 : Space.s3)
        .background(embedded ? Color.clear : SpeedTheme.card,in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(SpeedTheme.cardStroke.opacity(embedded ? 0 : 1),lineWidth:1))
        .onPreferenceChange(PopulatedGridHeightKey.self) {height in
            if hasData && height>0 {populatedGridHeight=max(160,height)}
        }
    }
    var emptyText:String {
        switch displayedMetric {
        case .speed:return "No hour with \(congestionMinResponses)+ replies in these days for \(tierName)."
        case .wait,.generating:return "No hour with \(congestionMinResponses)+ timed replies in these days for \(tierName)."
        case .replies:return "No \(tierName) replies in these days."
        }
    }
    var dayGrid:some View {
        let cal=Calendar.current
        return VStack(alignment:.leading,spacing:Space.s1) {
            usualBars
            hourHeader.padding(.top,Space.s2)
            ForEach(grid.days,id:\.self) {day in
                let label=congestionDayLabel(day,now:now)
                let showMore=hoverRow==day || menuDay==day
                HStack(spacing:Space.s1) {
                    HStack(spacing:Space.s1) {
                        Text(label).font(.system(size:12,weight:label=="Today" ? .semibold : .regular)).foregroundStyle(label=="Today" ? SpeedTheme.primary : SpeedTheme.secondary)
                            .lineLimit(1)
                        Spacer(minLength:0)
                        MoreActionsButton(actions:[("Leave out \(label)",{onExclude(day)})],open:Binding(get:{menuDay==day},set:{menuDay=$0 ? day : (menuDay==day ? nil : menuDay)}))
                            .opacity(showMore ? 1 : 0).allowsHitTesting(showMore)
                    }.frame(width:labelWidth,alignment:.leading)
                    ForEach(0..<24,id:\.self) {h in cellTile(grid.cell(day,h),day:day,hour:h,label:label)}
                    dayTile(day,label:label)
                }
                .contentShape(Rectangle())
                .onHover {inside in if inside {hoverRow=day} else if hoverRow==day {hoverRow=nil}}
                .contextMenu {Button("Leave out \(label)") {onExclude(day)}}
                // A gap between weeks (newest first, so after each Monday).
                if cal.component(.weekday,from:day)==2 && day != grid.days.last {Color.clear.frame(height:Space.s1)}
            }
        }
    }
    func weekdayGrid(baseline:Double)->some View {
        let names=["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],order=[2,3,4,5,6,7,1]
        return VStack(alignment:.leading,spacing:Space.s1) {
            hourHeader
            ForEach(0..<7,id:\.self) {i in
                HStack(spacing:Space.s1) {
                    Text(names[i]).font(.system(size:12)).foregroundStyle(SpeedTheme.secondary).frame(width:labelWidth,alignment:.leading)
                    ForEach(0..<24,id:\.self) {h in
                        let v=weekday[order[i]]?[h]
                        let lv=v.map {congestionLevel($0,baseline:baseline)}
                        let hovered=hover?.day==nil && hover?.label==names[i] && hover?.hour==h
                        tileBody(text:v.map {wholeSpeed($0)} ?? "",fill:lv.map(congestionFill) ?? Color.white.opacity(0.03),textColor:lv.map(congestionText) ?? SpeedTheme.quiet,bold:lv != nil,hour:h,hovered:hovered)
                            .onHover {inside in if inside {hover=(nil,h,names[i])} else if hovered {hover=nil}}
                            .accessibilityLabel("\(names[i]) \(hourClock(h)) · "+(v.map {"\(wholeSpeed($0)) t/s"} ?? "not enough days"))
                    }
                    Color.clear.frame(width:dayWidth,height:24)
                }
            }
        }
    }
    func swatch(_ c:Color,_ t:String)->some View {
        HStack(spacing:Space.s2) {RoundedRectangle(cornerRadius:2).fill(c).frame(width:16,height:8);Text(t)}
    }
    func outlineSwatch(_ t:String,dash:[CGFloat])->some View {
        HStack(spacing:Space.s2) {RoundedRectangle(cornerRadius:2).strokeBorder(Color.white.opacity(0.35),style:StrokeStyle(lineWidth:1,dash:dash)).frame(width:16,height:10);Text(t)}
    }
    var legend:some View {
        HStack(spacing:Space.s3) {
            switch byWeekday && grid.daysSoFar>=weekdayViewMinDays ? .speed : metric {
            case .speed:
                let b=grid.baseline ?? 0
                swatch(congestionFill(.muchSlower),"25%+ slower")
                swatch(congestionFill(.slower),"10–25% slower")
                swatch(congestionFill(.normal),"Usual range \(wholeSpeed(b*0.9))–\(wholeSpeed(b*1.1)) t/s")
                swatch(congestionFill(.faster),"10–25% faster")
                swatch(muchFasterFill,"25%+ faster")
                outlineSwatch("Under \(congestionMinResponses) replies",dash:[1.5,2])
                outlineSwatch("Later today",dash:[3,3])
            case .generating:
                let g=grid.normalGenerating ?? 0
                swatch(congestionFill(.muchSlower),"25%+ slower")
                swatch(congestionFill(.slower),"10–25% slower")
                swatch(congestionFill(.normal),"Usual range \(wholeSpeed(g*0.9))–\(wholeSpeed(g*1.1)) t/s")
                swatch(congestionFill(.faster),"10–25% faster")
                swatch(muchFasterFill,"25%+ faster")
                Text("Speed after output starts (est.)").foregroundStyle(SpeedTheme.tertiary)
            case .wait:
                let n=grid.normalWait ?? 0
                swatch(congestionFill(.muchSlower),"25%+ longer wait")
                swatch(congestionFill(.slower),"10–25% longer")
                swatch(congestionFill(.normal),"Usual ≈ \(waitText(n)) s")
                swatch(congestionFill(.faster),"10%+ shorter")
                Text("Seconds to first output").foregroundStyle(SpeedTheme.tertiary)
            case .replies:
                swatch(replyFill(1),"Few")
                swatch(replyFill(Double(grid.maxCount)),"Most · \(grid.maxCount) in one hour")
                Text("Replies per hour").foregroundStyle(SpeedTheme.tertiary)
            }
            Spacer(minLength:0)
        }.font(.system(size:11)).foregroundStyle(SpeedTheme.secondary).lineLimit(1).minimumScaleFactor(0.8).padding(.top,Space.s1)
    }
}

// MARK: - Is a faster tier worth it? (report window)
// Tiers are only compared inside "matched windows": same model + effort, same day,
// same 3-hour block, same reply-length band and context band (under/over 200k),
// with 3+ responses on each tier. Efforts are never pooled.
// Usage on plan as of Oct 2026 (purchased credits: 1× · 2× · 6×).
let tierUsageMultiplier:[String:Double]=["standard":1,"fast":2.5,"ultrafast":8]
let replyLengthBandNames=["100–300","300–1k","1k–3k","3k+"]
func replyLengthBand(_ tokens:Int64)->Int {tokens<300 ? 0 : tokens<1000 ? 1 : tokens<3000 ? 2 : 3}
let comparisonMinPerTier=3
enum ComparisonStrength:Int {case noWindows=0,notEnough,mixed,early,solid
    var label:String {switch self {case .noWindows:return "—";case .notEnough:return "Not enough yet";case .mixed:return "No clear winner";case .early:return "Early sign";case .solid:return "Solid"}}
}
// Solid = 5+ windows on 3+ days with the same tier ahead in 4 of 5; Early sign = 3+
// windows on 2+ days (one day can be luck); otherwise say what's missing.
func comparisonStrength(windows:Int,days:Int,wins:Int,from:String,to:String)->(ComparisonStrength,String) {
    guard windows>0 else{return (.noWindows,"Never used both in the same 3 hours")}
    let leader=wins*2>=windows ? to : from,ahead=max(wins,windows-wins)
    let agree=Double(ahead)/Double(windows)>=0.8
    let summary="\(modeTitle(leader)) ahead in \(ahead) of \(windows) · \(days) day\(days==1 ? "" : "s")"
    if windows>=5 && days>=3 {return agree ? (.solid,summary) : (.mixed,"\(modeTitle(to)) ahead in \(wins) of \(windows) · \(days) days")}
    if windows>=3 && days>=2 && agree {return (.early,summary)}
    if windows<3 {return (.notEnough,"Needs 3 windows · \(windows) so far")}
    if days<2 {return (.notEnough,"Needs 2 days · 1 so far")}
    return (.notEnough,"Mixed so far · \(wins) of \(windows)")
}
struct TierComparison {
    let from:String
    let to:String
    let windows:Int
    let days:Int
    let wins:Int                     // windows where `to` was faster
    let speedRatio:Double?           // middle of the per-window ratios (to ÷ from)
    let fromSpeed:Double?
    let toSpeed:Double?
    let generatingRatio:Double?
    let fromTiming:TimingSplit?
    let toTiming:TimingSplit?
    let responses:Int
    let fromContext:Double?
    let toContext:Double?
    let byLength:[(band:Int,ratio:Double,windows:Int)]
    var fromWindows:[[SpeedReading]]=[]   // the `from` tier's responses in each matched window (for time-saved ranges)
    var cost:Double {(tierUsageMultiplier[to] ?? 1)/(tierUsageMultiplier[from] ?? 1)}
    var strength:(ComparisonStrength,String) {comparisonStrength(windows:windows,days:days,wins:wins,from:from,to:to)}
}
func tierComparison(_ readings:(String)->[SpeedReading],from:String,to:String,start:Date,end:Date,calendar:Calendar = .current,calendarIndex:ReplyCalendarIndex?=nil)->TierComparison {
    let index=calendarIndex?.matching(calendar)
    struct Key:Hashable {let day:Date;let block:Int;let length:Int;let bigContext:Int}
    func bucket(_ tier:String)->[Key:[SpeedReading]] {
        var out:[Key:[SpeedReading]]=[:]
        for r in readings(tier) where r.date>=start && r.date<end && r.speed.isFinite {
            let k=Key(day:(index?.day(r.date) ?? calendar.startOfDay(for:r.date)),block:(index?.hour(r.date) ?? calendar.component(.hour,from:r.date))/3,length:replyLengthBand(r.outputTokens),bigContext:r.inputTokens.map {$0>=200_000 ? 1 : 0} ?? -1)
            out[k,default:[]].append(r)
        }
        return out
    }
    func mean(_ rs:[SpeedReading])->Double {rs.reduce(0) {$0+$1.speed}/Double(rs.count)}
    let a=bucket(from),b=bucket(to)
    let keys=Set(a.keys).intersection(b.keys).filter {a[$0]!.count>=comparisonMinPerTier && b[$0]!.count>=comparisonMinPerTier}.sorted {
        if $0.day != $1.day {return $0.day<$1.day}
        if $0.block != $1.block {return $0.block<$1.block}
        if $0.length != $1.length {return $0.length<$1.length}
        return $0.bigContext<$1.bigContext
    }
    let ratios=keys.map {mean(b[$0]!)/mean(a[$0]!)}
    let genRatios=keys.compactMap {k->Double? in
        guard let x=timingSplit(a[k]!),let y=timingSplit(b[k]!),x.generating>0 else{return nil}
        return y.generating/x.generating
    }
    let allA=keys.flatMap {a[$0]!},allB=keys.flatMap {b[$0]!}
    var byLength:[(band:Int,ratio:Double,windows:Int)]=[]
    for band in 0..<4 {
        let rs=zip(keys,ratios).filter {$0.0.length==band}.map(\.1).sorted()
        if !rs.isEmpty {byLength.append((band,percentile(rs,0.5),rs.count))}
    }
    func median(_ v:[Double])->Double? {v.isEmpty ? nil : percentile(v.sorted(),0.5)}
    var result=TierComparison(from:from,to:to,windows:keys.count,days:Set(keys.map(\.day)).count,wins:ratios.filter {$0>1}.count,
        speedRatio:median(ratios),fromSpeed:allA.isEmpty ? nil : mean(allA),toSpeed:allB.isEmpty ? nil : mean(allB),
        generatingRatio:median(genRatios),fromTiming:timingSplit(allA),toTiming:timingSplit(allB),responses:allA.count+allB.count,
        fromContext:median(allA.compactMap {$0.inputTokens.map(Double.init)}),toContext:median(allB.compactMap {$0.inputTokens.map(Double.init)}),byLength:byLength)
    result.fromWindows=keys.map {a[$0]!}
    return result
}
func typicalReplyTokens(_ readings:[SpeedReading])->Int {
    guard !readings.isEmpty else{return 750}
    return max(50,Int((percentile(readings.map {Double($0.outputTokens)}.sorted(),0.5)/50).rounded())*50)
}
func typicalReplySeconds(_ t:TimingSplit,tokens:Int)->Double {t.wait+Double(tokens)/max(t.generating,0.001)}
func speedRatioText(_ x:Double)->String {
    if abs(x-1)<0.05 {return "Same speed"}
    return x>1 ? String(format:"%.1f× faster",x) : String(format:"%.1f× slower",1/x)
}
func multiplierText(_ x:Double)->String {abs(x-x.rounded())<0.001 ? "\(Int(x.rounded()))×" : String(format:"%.1f×",x)}
func secondsPairText(_ a:Double,_ b:Double)->String {
    a.rounded()==b.rounded() ? String(format:"%.1f s → %.1f s",a,b) : String(format:"%.0f s → %.0f s",a,b)
}
// Where a typical reply's time saving comes from.
func gainSource(from:TimingSplit,to:TimingSplit,tokens:Int)->String {
    let waitSaved=from.wait-to.wait
    let genSaved=Double(tokens)/max(from.generating,0.001)-Double(tokens)/max(to.generating,0.001)
    let total=waitSaved+genSaved
    if total<=0 {return genSaved<0 ? "slower generating (est.)" : "longer first output wait"}
    if waitSaved<0 {return "faster generating (est.), longer first output wait"}
    let share=genSaved/total
    return share>=0.7 ? "mostly faster generating (est.)" : share<=0.3 ? "mostly shorter first output wait" : "faster generating (est.) and shorter first output wait"
}
// Verdicts: every tier is judged against Standard, the way usage is priced
// (Fast 2.5×, Ultrafast 8×). Value = speed gained ÷ usage spent.
enum ValueGrade {case poor,fair,good
    var label:String {switch self {case .poor:return "poor value";case .fair:return "fair value";case .good:return "good value"}}
}
func valueGrade(speed:Double,usage:Double)->ValueGrade {
    let e=speed/max(usage,0.001)
    return e<0.75 ? .poor : e<=1.25 ? .fair : .good
}
// "½ as efficient" style: nearest simple fraction of Standard's speed-per-usage.
func efficiencyText(_ e:Double)->String {
    let options:[(Double,String)]=[(0.125,"⅛"),(0.25,"¼"),(1.0/3,"⅓"),(0.5,"½"),(2.0/3,"⅔"),(0.75,"¾"),(1,"Same")]
    if let best=options.min(by:{abs($0.0-e)<abs($1.0-e)}),abs(best.0-e)<=0.07 {return best.1}
    return String(format:"%.1f×",e)
}
func speedWord(_ r:Double)->String {r>=1.5 ? "Much faster" : r>=1.1 ? "Faster" : r>=0.95 ? "About the same" : "Slower"}
func settled(_ s:ComparisonStrength)->Bool {s == .early || s == .solid}
func verdictChip(_ c:TierComparison)->String {
    let s=c.strength.0
    guard s != .noWindows,let r=c.speedRatio else{return "Not compared yet"}
    let word=settled(s) ? speedWord(r) : "Probably "+speedWord(r).lowercased()
    return c.from=="standard" ? word+" · "+valueGrade(speed:r,usage:c.cost).label : word+" than \(modeTitle(c.from))"
}
func worthSentence(_ c:TierComparison,tokens:Int)->String {
    let tier=modeTitle(c.to),usage=multiplierText(c.cost)
    guard let r=c.speedRatio,c.strength.0 != .noWindows else{return "No answer yet. Use \(tier) and Standard within the same hour to compare them."}
    var seconds=""
    if let f=c.fromTiming,let t=c.toTiming {
        seconds="\(wholeSpeed(typicalReplySeconds(t,tokens:tokens))) s instead of \(wholeSpeed(typicalReplySeconds(f,tokens:tokens))) s"
    }
    if !settled(c.strength.0) {
        let why=c.strength.0 == .mixed || c.strength.1.hasPrefix("Mixed") ? "it wasn’t faster consistently" : "there isn’t enough side-by-side data yet"
        return "Not settled. It looks \(speedRatioText(r).lowercased()) for \(usage) the usage, but \(why)."
    }
    if r<1.1 {return "Not worth it. It isn’t meaningfully faster than Standard, and uses \(usage) the usage."}
    switch valueGrade(speed:r,usage:c.cost) {
    case .poor:return "Worth it only when you’re waiting on the answer."+(seconds.isEmpty ? "" : " A typical reply takes \(seconds),")+" but every reply uses \(usage) the usage."
    case .fair,.good:return "Worth it."+(seconds.isEmpty ? "" : " A typical reply takes \(seconds),")+" for \(usage) the usage."
    }
}
// The headline that answers "is it worth it?" for every faster tier at once.
func tierHeadline(_ vsStandard:[TierComparison])->String {
    let parts=vsStandard.map {c->String in
        let tier=modeTitle(c.to)
        guard c.strength.0 != .noWindows,let r=c.speedRatio else{return "\(tier) hasn’t been compared with Standard yet"}
        guard settled(c.strength.0) else{return "\(tier) isn’t clearly faster yet"}
        if r<1.1 {return "\(tier) isn’t meaningfully faster than Standard"}
        let grade=valueGrade(speed:r,usage:c.cost)
        return "\(tier) is \(speedWord(r).lowercased()) "+(grade == .poor ? "but poor value" : "and \(grade.label)")
    }
    return parts.joined(separator:". ")+"."
}
// MARK: Time saved vs Standard
// For each reply you ran on a faster tier: estimated Standard time (Standard's first output
// wait + the reply's tokens at Standard's estimated generating speed, from side-by-side hours)
// minus its real duration. The range is the middle 80% of 300 resampled estimates.
struct SavedTime {
    let seconds:Double
    let lo:Double
    let hi:Double
    let replies:Int
    var bootstrapEstimates:[Double]=[]
}
struct SeededGenerator:RandomNumberGenerator {
    var state:UInt64
    mutating func next()->UInt64 {state=state &* 6364136223846793005 &+ 1442695040888963407;return state}
}
func standardEstimateSeconds(_ r:SpeedReading,standard:TimingSplit)->Double {standard.wait+Double(r.outputTokens)/max(standard.generating,0.001)}
func savedSeconds(_ replies:[SpeedReading],standard:TimingSplit)->Double {
    replies.reduce(0.0) {$0+standardEstimateSeconds($1,standard:standard)-$1.durationMS/1000}
}
let timeSavedMinWindows=3
func savedTime(_ replies:[SpeedReading],standardWindows:[[SpeedReading]],draws:Int=300,seed:UInt64=42)->SavedTime? {
    guard standardWindows.count>=timeSavedMinWindows,let base=timingSplit(standardWindows.flatMap {$0}) else{return nil}
    let point=savedSeconds(replies,standard:base)
    var rng=SeededGenerator(state:seed)
    var sims:[Double]=[]
    for _ in 0..<draws {
        let sample=(0..<standardWindows.count).flatMap {_ in standardWindows[Int.random(in:0..<standardWindows.count,using:&rng)]}
        if let t=timingSplit(sample) {sims.append(savedSeconds(replies,standard:t))}
    }
    sims.sort()
    return SavedTime(seconds:point,lo:sims.isEmpty ? point : percentile(sims,0.1),hi:sims.isEmpty ? point : percentile(sims,0.9),replies:replies.count,bootstrapEstimates:sims)
}
struct SavedTimeComponent {
    let replies:[SpeedReading]
    let standardWindows:[[SpeedReading]]
}
// Keep each tier's matched-window population and point estimate unchanged.
// Windows with the same exact Standard response IDs are one shared unit. Resample
// each membership pool at its original size: shared units feed every participating
// tier in the same draw; units unique to a tier are drawn separately, never paired.
func combinedSavedTime(_ components:[SavedTimeComponent],draws:Int=300,seed:UInt64=42)->SavedTime? {
    let eligible=components.filter {!$0.replies.isEmpty && $0.standardWindows.count>=timeSavedMinWindows && timingSplit($0.standardWindows.flatMap {$0}) != nil}
    guard !eligible.isEmpty else{return nil}
    let point=eligible.reduce(0.0) {$0+savedSeconds($1.replies,standard:timingSplit($1.standardWindows.flatMap {$0})!)}
    struct Unit {let readings:[SpeedReading];var members:Set<Int>}
    var units:[[String]:Unit]=[:]
    for (index,c) in eligible.enumerated() {
        for window in c.standardWindows {
            let key=window.map(\.id).sorted()
            if var unit=units[key] {unit.members.insert(index);units[key]=unit}
            else {units[key]=Unit(readings:window,members:[index])}
        }
    }
    var pools:[[Int]:[[String]]]=[:]
    for key in units.keys.sorted(by:{$0.lexicographicallyPrecedes($1)}) {
        pools[units[key]!.members.sorted(),default:[]].append(key)
    }
    let memberships=pools.keys.sorted {$0.lexicographicallyPrecedes($1)}
    var rng=SeededGenerator(state:seed),sims:[Double]=[]
    for _ in 0..<draws {
        var samples=Array(repeating:[SpeedReading](),count:eligible.count)
        for members in memberships {
            let pool=pools[members]!
            for _ in 0..<pool.count {
                let unit=units[pool[Int.random(in:0..<pool.count,using:&rng)]]!
                for index in members {samples[index].append(contentsOf:unit.readings)}
            }
        }
        var total=0.0,valid=true
        for (index,c) in eligible.enumerated() {
            guard let standard=timingSplit(samples[index]) else{valid=false;break}
            total += savedSeconds(c.replies,standard:standard)
        }
        if valid {sims.append(total)}
    }
    sims.sort()
    return SavedTime(seconds:point,lo:sims.isEmpty ? point : percentile(sims,0.1),hi:sims.isEmpty ? point : percentile(sims,0.9),replies:eligible.reduce(0){$0+$1.replies.count},bootstrapEstimates:sims)
}
// "46 min", "1 h 12 min", "40 s".
func durationText(_ seconds:Double)->String {
    let s=abs(seconds)
    if s<60 {return "\(Int(s.rounded())) s"}
    let m=Int((s/60).rounded())
    return m<60 ? "\(m) min" : "\(m/60) h \(m%60) min"
}
func durationRangeText(_ lo:Double,_ hi:Double)->String {
    let a=min(lo,hi),b=max(lo,hi)
    if b<0 {return durationRangeText(-b,-a)+" added"}
    if a<0 && b>0 {return "between \(durationText(a)) lost and \(durationText(b)) saved"}
    if b<60 {return "\(durationText(a))–\(durationText(b))"}
    if a>=7200 {return "\(Int((a/3600).rounded()))–\(Int((b/3600).rounded())) h"}
    let ma=Int((abs(a)/60).rounded()),mb=Int((abs(b)/60).rounded())
    return (ma<60 && mb<60) ? "\(min(ma,mb))–\(max(ma,mb)) min" : "\(durationText(a))–\(durationText(b))"
}
// Usage of these replies relative to running them all on Standard (weighted by tokens).
func usageVersusStandard(_ replies:[SpeedReading],tier:(SpeedReading)->String)->Double? {
    let tokens=replies.reduce(0.0) {$0+Double($1.outputTokens)}
    guard tokens>0 else{return nil}
    return replies.reduce(0.0) {$0+Double($1.outputTokens)*(tierUsageMultiplier[tier($1)] ?? 1)}/tokens
}
// MARK: - Speed pattern helpers
// Time-of-day and day-level patterns for the busiest model, last 14 days.
// Margins cluster by local day; finding grades describe observational coverage.
struct SpeedBlockStat {
    let mean:Double?
    let n:Int
    let days:Int
    let margin:Double?
}
func speedBlockStat(_ rs:[SpeedReading],calendarIndex:ReplyCalendarIndex?=nil)->SpeedBlockStat {
    let cm=clusteredMargin(rs,by:.day,calendarIndex:calendarIndex)
    return SpeedBlockStat(mean:rs.isEmpty ? nil : rs.reduce(0) {$0+$1.speed}/Double(rs.count),n:rs.count,days:cm.clusters,margin:cm.margin)
}
struct PairedTierComparison {
    let firstMean:Double
    let secondMean:Double
    let cells:Int
    let days:Int
}
func pairedTierComparison(_ report:RecentSpeedReport,model:String,effort only:String?=nil,start:Date,end:Date,calendar:Calendar = .current)->PairedTierComparison? {
    struct Key:Hashable {let effort:String;let day:Date;let block:Int}
    guard let m=report.models.first(where:{$0.model==model}) else{return nil}
    func cells(_ tier:String)->[Key:[Double]] {
        var result:[Key:[Double]]=[:]
        for effort in m.efforts where only==nil || effort.effort==only {
            for r in effort.modes.filter({$0.mode==tier}).flatMap(\.readings) where r.date>=start && r.date<end && r.speed.isFinite {
                let k=Key(effort:effort.effort,day:calendar.startOfDay(for:r.date),block:calendar.component(.hour,from:r.date)/3)
                result[k,default:[]].append(r.speed)
            }
        }
        return result.filter{$0.value.count>=5}
    }
    let first=cells("ultrafast"),second=cells("fast"),keys=Set(first.keys).intersection(second.keys)
    guard !keys.isEmpty else{return nil}
    let a=keys.reduce(0.0){$0+first[$1]!.reduce(0,+)/Double(first[$1]!.count)}/Double(keys.count)
    let b=keys.reduce(0.0){$0+second[$1]!.reduce(0,+)/Double(second[$1]!.count)}/Double(keys.count)
    return PairedTierComparison(firstMean:a,secondMean:b,cells:keys.count,days:Set(keys.map(\.day)).count)
}
// MARK: - Speed patterns (report window)
// Three questions, one table component, 8-pt spacing. Everything is computed once per
// key in the background (PatternsWorker); views only draw the result.
enum Space {
    static let s1:CGFloat=4    // text stacks (title→answer, value→sub), grid cell gaps
    static let s2:CGFloat=8    // header rows, controls, cell vertical padding
    static let s3:CGFloat=16   // cell horizontal padding, title→content, legend gaps
    static let s4:CGFloat=24   // page gutter, top of content
    static let s5:CGFloat=32   // between sections
    static let s6:CGFloat=48   // before the footer
}
enum DayFilter:String,CaseIterable {
    case all,weekdays,weekends
    var title:String {switch self {case .all:return "All days";case .weekdays:return "Weekdays";case .weekends:return "Weekends"}}
    func includes(_ day:Date,calendar:Calendar = .current)->Bool {
        switch self {case .all:return true;case .weekdays:return !calendar.isDateInWeekend(day);case .weekends:return calendar.isDateInWeekend(day)}
    }
}
enum CellTone {case faster,slower}
struct TierCell {
    let value:String
    let sub:String
    var dim=false
    var tone:CellTone?=nil
}
struct TierRow {
    let label:String
    let help:String
    let cells:[TierCell]        // Standard, Fast, Ultrafast
    var tall=false              // verdict row: two lines reserved for the sentence
}
// MARK: - Report: chart first, then the hours you pick, then the day-by-hour grid
enum PatternsRange:String,CaseIterable {
    case day="24h",week="7d",fortnight="14d",month="30d"
    var days:Int {switch self {case .day:return 1;case .week:return 7;case .fortnight:return 14;case .month:return 30}}
    var label:String {switch self {case .day:return "Last 24 hours";case .week:return "Last 7 days";case .fortnight:return "Last 14 days";case .month:return "Last 30 days"}}
    var gridDays:Int {self == .day ? 14 : days}
}
enum PatternsChartMode:String {case history,hour,grid}
// MARK: Day × hour: your own replies in 3-hour blocks, colored against your normal
struct WeekGridCell {
    let value:Double   // pooled generating t/s in that block
    let count:Int      // timed replies
}
struct GridSpot:Equatable {
    let day:Date
    let block:Int
}
struct WeekGrid {
    let days:[Date]                                  // newest first
    let cells:[String:[Date:[Int:WeekGridCell]]]     // tier → day → block (0–7)
    let normal:[String:Double]                       // pooled generating t/s over the last 14 days
    let normalReplies:[String:Int]
    let normalDays:[String:Int]
    let today:Date
    let nowBlock:Int
    func cell(_ tier:String,_ day:Date,_ block:Int)->WeekGridCell? {cells[tier]?[day]?[block]}
    func isFuture(_ day:Date,_ block:Int)->Bool {day==today && block>nowBlock}
    func blocks(_ tier:String)->[(day:Date,block:Int,cell:WeekGridCell)] {
        days.flatMap {d in (0..<8).compactMap {b in cell(tier,d,b).map {(day:d,block:b,cell:$0)}}}
    }
    // Blocks that have happened in the range (today's later blocks don't count).
    var pastBlocks:Int {days.count*8-(days.contains(today) ? 7-nowBlock : 0)}
}
let weekGridNormalDays=14
// Readings must carry timing (generating speed); left-out days are already removed.
func buildWeekGrid(_ timed:[String:[SpeedReading]],days:Int,now:Date,calendar:Calendar = .current)->WeekGrid {
    let today=calendar.startOfDay(for:now)
    let list=(0..<max(1,days)).compactMap {calendar.date(byAdding:.day,value:-$0,to:today)}
    let first=list.last ?? today
    let normalFrom=calendar.date(byAdding:.day,value:-(weekGridNormalDays-1),to:today) ?? today
    var cells:[String:[Date:[Int:WeekGridCell]]]=[:],normal:[String:Double]=[:],replies:[String:Int]=[:],normalDays:[String:Int]=[:]
    for (tier,rs) in timed {
        let usable=rs.filter {$0.generatingSpeed != nil && $0.date<=now}
        let recent=usable.filter {$0.date>=normalFrom}
        if let t=timingSplit(recent) {
            normal[tier]=t.generating;replies[tier]=t.responses
            normalDays[tier]=Set(recent.map {calendar.startOfDay(for:$0.date)}).count
        }
        var byCell:[Date:[Int:[SpeedReading]]]=[:]
        for r in usable where r.date>=first {
            byCell[calendar.startOfDay(for:r.date),default:[:]][calendar.component(.hour,from:r.date)/3,default:[]].append(r)
        }
        for (day,blocks) in byCell {
            for (b,rs) in blocks {
                if let t=timingSplit(rs) {cells[tier,default:[:]][day,default:[:]][b]=WeekGridCell(value:t.generating,count:t.responses)}
            }
        }
    }
    return WeekGrid(days:list,cells:cells,normal:normal,normalReplies:replies,normalDays:normalDays,today:today,nowBlock:calendar.component(.hour,from:now)/3)
}
func gridBlockTitle(_ day:Date,_ block:Int)->String {clockFormatter("EEE d MMM").string(from:day)+", "+blockLabel(block)}
// "Fast was slowest on Tue 27 Oct, 3–6am, at 33 t/s against your normal of 49."
func weekGridAnswer(_ g:WeekGrid,tier:String)->String {
    let name=modeTitle(tier)
    let blocks=g.blocks(tier)
    let blank=" Blank blocks are times you didn’t use \(name)."
    guard !blocks.isEmpty else{return "No timed \(name) replies in this range."}
    guard let normal=g.normal[tier],normal>0 else{return "No normal for \(name) yet: it needs timed replies in the last 14 days."}
    let solid=blocks.filter {$0.cell.count>=congestionMinResponses}
    guard let slow=solid.min(by:{$0.cell.value<$1.cell.value}) else{return "Only a few \(name) replies per block in this range, too few to compare."+blank}
    if slow.cell.value>=normal*0.9 {return "\(name) stayed near your normal of \(wholeSpeed(normal)) t/s in this range."+blank}
    return "\(name) was slowest on \(gridBlockTitle(slow.day,slow.block)), at \(wholeSpeed(slow.cell.value)) t/s against your normal of \(wholeSpeed(normal))."+blank
}
func gridReadout(_ g:WeekGrid,tier:String,spot:GridSpot?)->String {
    guard let spot else{return "Hover a block for its replies"}
    let title=gridBlockTitle(spot.day,spot.block),name=modeTitle(tier)
    guard let c=g.cell(tier,spot.day,spot.block) else{return title+" · no timed \(name) replies"}
    var line=title+" · \(name) \(wholeSpeed(c.value)) t/s · "+responseCount(c.count)
    if c.count<congestionMinResponses {return line+" · too few to compare"}
    if let n=g.normal[tier],n>0 {
        let pct=Int((abs(c.value/n-1)*100).rounded())
        line += pct==0 ? " · at your normal" : " · \(pct)% \(c.value<n ? "under" : "over") your normal"
    }
    return line
}
func gridEdge(_ level:CongestionLevel)->Color {
    switch level {
    case .muchSlower,.slower:return SpeedTheme.slowerYellow.opacity(0.9)
    case .faster:return SpeedTheme.faster.opacity(0.9)
    case .normal:return Color.white.opacity(0.35)
    }
}
// Hatching = no data here. Shading only: never clickable.
struct HatchCell:View {
    var body:some View {
        Canvas {ctx,size in
            var p=Path()
            var x:CGFloat = -size.height
            while x<size.width {p.move(to:CGPoint(x:x,y:size.height));p.addLine(to:CGPoint(x:x+size.height,y:0));x+=6}
            ctx.stroke(p,with:.color(Color.white.opacity(0.07)),lineWidth:2)
        }
        .clipShape(RoundedRectangle(cornerRadius:4))
        .overlay(RoundedRectangle(cornerRadius:4).strokeBorder(Color.white.opacity(0.06),lineWidth:1))
    }
}
struct WeekGridView:View {
    let grid:WeekGrid
    let tier:String
    @Binding var hover:GridSpot?
    var compact:Bool {grid.days.count>14}
    var rowHeight:CGFloat {compact ? 16 : 26}
    func dayLabel(_ d:Date)->String {grid.today==d ? "Today" : clockFormatter(compact ? "EEE d" : "EEE d MMM").string(from:d)}
    @ViewBuilder func cellView(_ day:Date,_ block:Int)->some View {
        let spot=GridSpot(day:day,block:block)
        let edge=RoundedRectangle(cornerRadius:4).stroke(Color.white.opacity(hover==spot ? 1 : 0),lineWidth:1.5)
        if grid.isFuture(day,block) {
            Color.clear.frame(height:rowHeight).frame(maxWidth:.infinity)
        } else if let c=grid.cell(tier,day,block) {
            let ratio=grid.normal[tier].map {$0>0 ? c.value/$0 : 1} ?? 1
            let level=congestionLevel(ratio*100,baseline:100)
            let thin=c.count<congestionMinResponses
            ZStack {
                if thin {
                    RoundedRectangle(cornerRadius:4).strokeBorder(gridEdge(level),style:StrokeStyle(lineWidth:1,dash:[3,2]))
                } else {
                    RoundedRectangle(cornerRadius:4).fill(gridFill(level,ratio:ratio))
                }
                if !compact {
                    Text(wholeSpeed(c.value)).font(.system(size:11)).monospacedDigit()
                        .foregroundStyle(thin ? SpeedTheme.secondary : gridText(level,ratio:ratio))
                }
            }
            .frame(height:rowHeight).frame(maxWidth:.infinity)
            .overlay(edge)
            .contentShape(Rectangle())
            .onHover {inside in if inside {hover=spot} else if hover==spot {hover=nil}}
            .accessibilityElement().accessibilityLabel(gridReadout(grid,tier:tier,spot:spot))
        } else {
            HatchCell().frame(height:rowHeight).frame(maxWidth:.infinity)
                .overlay(edge)
                .contentShape(Rectangle())
                .onHover {inside in if inside {hover=spot} else if hover==spot {hover=nil}}
                .accessibilityElement().accessibilityLabel(gridReadout(grid,tier:tier,spot:spot))
        }
    }
    func swatch(_ fill:Color)->some View {RoundedRectangle(cornerRadius:2).fill(fill).frame(width:12,height:10)}
    var body:some View {
        VStack(alignment:.leading,spacing:3) {
            ForEach(grid.days,id:\.self) {day in
                HStack(spacing:3) {
                    Text(dayLabel(day)).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1).frame(width:84,alignment:.leading)
                    ForEach(0..<8,id:\.self) {b in cellView(day,b)}
                }
            }
            HStack(spacing:3) {
                Color.clear.frame(width:84,height:1)
                ForEach(0..<8,id:\.self) {b in
                    Text(blockLabel(b)).font(.system(size:10)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth:.infinity)
                }
            }.padding(.top,4)
            HStack(spacing:Space.s3) {
                HStack(spacing:6) {swatch(congestionFill(.muchSlower));Text("Slower than your normal")}
                HStack(spacing:6) {swatch(congestionFill(.slower));Text("A bit slower")}
                HStack(spacing:6) {swatch(congestionFill(.normal));Text("Normal")}
                HStack(spacing:6) {swatch(congestionFill(.faster));Text("Faster")}
                HStack(spacing:6) {HatchCell().frame(width:12,height:10);Text("No replies")}
                Text("dashed = 1–2 replies")
            }
            .font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1).padding(.top,12)
        }
        .onHover {inside in if !inside {hover=nil}}
    }
}
struct GridSummaryPanel:View {
    let grid:WeekGrid
    let tier:String
    let scope:String
    func row(_ label:String,_ value:String)->some View {
        (Text(label+" ").fontWeight(.semibold).foregroundColor(SpeedTheme.primary)+Text(value).foregroundColor(SpeedTheme.secondary))
            .font(.system(size:13)).fixedSize(horizontal:false,vertical:true).padding(.top,6)
    }
    var body:some View {
        let name=modeTitle(tier)
        let blocks=grid.blocks(tier)
        let solid=blocks.filter {$0.cell.count>=congestionMinResponses}
        let slow=solid.min {$0.cell.value<$1.cell.value},fast=solid.max {$0.cell.value<$1.cell.value}
        return VStack(alignment:.leading,spacing:0) {
            SectionLabel(text:"Your \(name) · \(scope)",rule:false)
            if let n=grid.normal[tier] {
                Text("Normal \(wholeSpeed(n)) t/s").font(.system(size:20,weight:.semibold)).foregroundStyle(SpeedTheme.primary).padding(.top,8)
                Text("\(responseCount(grid.normalReplies[tier] ?? 0)) over \(grid.normalDays[tier] ?? 0) day\((grid.normalDays[tier] ?? 0)==1 ? "" : "s") · last 14 days").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary)
            } else {
                Text("No normal yet").font(.system(size:20,weight:.semibold)).foregroundStyle(SpeedTheme.secondary).padding(.top,8)
                Text("no timed \(name) replies in the last 14 days").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary)
            }
            Rectangle().fill(SpeedTheme.hairline).frame(height:1).padding(.top,12).padding(.bottom,4)
            if let slow {row("Slowest:",gridBlockTitle(slow.day,slow.block)+" · \(wholeSpeed(slow.cell.value)) t/s")}
            if let fast,solid.count>1 {row("Fastest:",gridBlockTitle(fast.day,fast.block)+" · \(wholeSpeed(fast.cell.value)) t/s")}
            row("Blocks with \(name) replies:","\(blocks.count) of \(grid.pastBlocks)")
            Text("Your own replies only. Colors compare each block with your normal, so a big project can look like a slow hour.")
                .font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).fixedSize(horizontal:false,vertical:true).padding(.top,16)
        }
        .padding(.horizontal,Space.s4).padding(.vertical,20)
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .background(SpeedTheme.card,in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(SpeedTheme.cardStroke,lineWidth:1))
    }
}
enum HourPick:String,CaseIterable {
    case all,morning,afternoon,evening,night
    var title:String {switch self {case .all:return "All day";case .morning:return "Morning";case .afternoon:return "Afternoon";case .evening:return "Evening";case .night:return "Night"}}
    var hours:Range<Int> {switch self {case .all:return 0..<24;case .night:return 0..<6;case .morning:return 6..<12;case .afternoon:return 12..<18;case .evening:return 18..<24}}
    var span:String {self == .all ? "" : hourClock(hours.lowerBound)+" – "+hourClock(hours.upperBound%24)}
}
// One chart bucket: pooled generating speed (output tokens ÷ time after output starts).
struct ChartPoint {
    let value:Double
    let count:Int          // timed replies
    var days:Int=1         // distinct days behind an hour-of-day point
    var lo:Double?=nil     // middle half of single replies, when 8+
    var hi:Double?=nil
    var perDay:[Double]=[]  // hour of day: each day's speed at that hour, oldest first
}
struct TierSeries {
    let tier:String
    let points:[ChartPoint?]
    var replies:Int {points.reduce(0) {$0+($1?.count ?? 0)}}
}
struct PanelTier {
    let tier:String
    let value:Double?
    let replies:Int
    let days:Int
}
// A tier against Standard, only in windows where both ran: same day, same 3-hour block.
struct MatchedTier {
    let windows:Int
    let days:Int
    let wins:Int
    let ratio:Double       // median of the windows' ratios
    let standard:Double    // median Standard speed in those windows
    let other:Double
    var clear:Bool {windows>=3 && days>=2 && wins*5>=windows*4}
    var savedPer1000:Double {1000/max(standard,0.001)-1000/max(other,0.001)}
}
struct HoursPanel {
    let observed:[PanelTier]
    let matched:[String:MatchedTier]
}
func patternsTierColor(_ tier:String)->Color {
    switch tier {
    case "standard":return SpeedTheme.secondary
    case "fast":return Color(red:0.376,green:0.647,blue:0.980)       // #60A5FA
    case "ultrafast":return Color(red:0.957,green:0.447,blue:0.714)  // #F472B6
    default:return SpeedTheme.chartLine
    }
}
func planUsageText(_ tier:String)->String {tier=="fast" ? "2.5×" : (tier=="ultrafast" ? "8×" : "1×")}
// The range's buckets: the last 24 clock hours, 3-hour slots over 7 days, or calendar days.
func patternsWindow(_ range:PatternsRange,now:Date,calendar:Calendar = .current)->(start:Date,buckets:[Date],step:Int) {
    if range == .day {
        let current=calendar.dateInterval(of:.hour,for:now)?.start ?? now
        let buckets=(0..<24).map {current.addingTimeInterval(Double($0-23)*3600)}
        return (buckets[0],buckets,1)
    }
    let today=calendar.startOfDay(for:now)
    let days=(0..<range.days).compactMap {calendar.date(byAdding:.day,value:$0-(range.days-1),to:today)}
    if range == .week {
        // Fixed wall-clock blocks match chartHistoryPoints' hour / 3 grouping.
        // Adding elapsed hours drifts after a DST transition. Resolve each clock
        // boundary independently; nonexistent times move forward within the day,
        // and repeated boundaries use their first occurrence.
        let buckets=days.flatMap {d in (0..<8).compactMap {
            calendar.date(bySettingHour:$0*3,minute:0,second:0,of:d,
                          matchingPolicy:.nextTime,repeatedTimePolicy:.first,direction:.forward)
        }}
        return (days.first ?? today,buckets,3)
    }
    return (days.first ?? today,days,24)
}
func chartHourPoints(_ readings:[SpeedReading],calendar:Calendar = .current)->[ChartPoint?] {
    let byHour=Dictionary(grouping:readings.filter {$0.generatingSpeed != nil}) {calendar.component(.hour,from:$0.date)}
    return (0..<24).map {h->ChartPoint? in
        guard let group=byHour[h],let t=timingSplit(group) else{return nil}
        let speeds=group.compactMap(\.generatingSpeed).sorted()
        let byDay=Dictionary(grouping:group) {calendar.startOfDay(for:$0.date)}
        let perDay=byDay.keys.sorted().compactMap {timingSplit(byDay[$0] ?? [])?.generating}
        return ChartPoint(value:t.generating,count:t.responses,days:byDay.count,
                          lo:speeds.count>=8 ? percentile(speeds,0.25) : nil,hi:speeds.count>=8 ? percentile(speeds,0.75) : nil,perDay:perDay)
    }
}
func chartHistoryPoints(_ readings:[SpeedReading],buckets:[Date],step:Int,calendar:Calendar = .current)->[ChartPoint?] {
    guard let first=buckets.first else{return []}
    let dayIndex=Dictionary(buckets.enumerated().map {($0.element,$0.offset)},uniquingKeysWith:{a,_ in a})
    let dayStarts=Dictionary(stride(from:0,to:buckets.count,by:8).map {(buckets[$0],$0)},uniquingKeysWith:{a,_ in a})
    var groups:[Int:[SpeedReading]]=[:]
    for r in readings where r.generatingSpeed != nil {
        let slot:Int?
        if step==1 {
            let k=Int(floor(r.date.timeIntervalSince(first)/3600))
            slot=k>=0 && k<buckets.count ? k : nil
        } else if step==3 {
            slot=dayStarts[calendar.startOfDay(for:r.date)].map {$0+calendar.component(.hour,from:r.date)/3}
        } else {slot=dayIndex[calendar.startOfDay(for:r.date)]}
        if let slot,slot<buckets.count {groups[slot,default:[]].append(r)}
    }
    return buckets.indices.map {i->ChartPoint? in
        guard let g=groups[i],let t=timingSplit(g) else{return nil}
        return ChartPoint(value:t.generating,count:t.responses)
    }
}
func matchedGenerating(_ standard:[SpeedReading],_ other:[SpeedReading],hours:Range<Int>,calendar:Calendar = .current)->MatchedTier? {
    func key(_ r:SpeedReading)->String? {
        let h=calendar.component(.hour,from:r.date)
        guard hours.contains(h),r.generatingSpeed != nil else{return nil}
        return "\(Int(calendar.startOfDay(for:r.date).timeIntervalSince1970))|\(h/3)"
    }
    var a:[String:[SpeedReading]]=[:],b:[String:[SpeedReading]]=[:]
    for r in standard {if let k=key(r) {a[k,default:[]].append(r)}}
    for r in other {if let k=key(r) {b[k,default:[]].append(r)}}
    var ratios:[Double]=[],stds:[Double]=[],others:[Double]=[],days=Set<String>(),wins=0
    for (k,sa) in a {
        guard let sb=b[k],let ta=timingSplit(sa),let tb=timingSplit(sb),ta.responses>=comparisonMinPerTier,tb.responses>=comparisonMinPerTier,ta.generating>0 else{continue}
        ratios.append(tb.generating/ta.generating);stds.append(ta.generating);others.append(tb.generating)
        days.insert(String(k.split(separator:"|").first ?? ""))
        if tb.generating>ta.generating {wins+=1}
    }
    guard !ratios.isEmpty else{return nil}
    return MatchedTier(windows:ratios.count,days:days.count,wins:wins,ratio:percentile(ratios.sorted(),0.5),standard:percentile(stds.sorted(),0.5),other:percentile(others.sorted(),0.5))
}
func chartHoursPanels(_ timed:[String:[SpeedReading]],calendar:Calendar = .current)->[HourPick:HoursPanel] {
    var out:[HourPick:HoursPanel]=[:]
    for pick in HourPick.allCases {
        let scoped=timed.mapValues {$0.filter {pick.hours.contains(calendar.component(.hour,from:$0.date))}}
        let observed=fixedTierColumns.map {t->PanelTier in
            let rs=scoped[t] ?? []
            return PanelTier(tier:t,value:timingSplit(rs)?.generating,replies:rs.count,days:Set(rs.map {calendar.startOfDay(for:$0.date)}).count)
        }
        var matched:[String:MatchedTier]=[:]
        for t in ["fast","ultrafast"] {
            if let m=matchedGenerating(scoped["standard"] ?? [],scoped[t] ?? [],hours:pick.hours,calendar:calendar) {matched[t]=m}
        }
        out[pick]=HoursPanel(observed:observed,matched:matched)
    }
    return out
}
// Runs of neighbouring buckets that pass a test (lines only join neighbours).
func consecutiveRuns(_ points:[ChartPoint?],where keep:(ChartPoint)->Bool)->[[(index:Int,point:ChartPoint)]] {
    var runs:[[(index:Int,point:ChartPoint)]]=[],current:[(index:Int,point:ChartPoint)]=[]
    for i in points.indices {
        if let p=points[i],keep(p) {current.append((index:i,point:p))}
        else if !current.isEmpty {runs.append(current);current=[]}
    }
    if !current.isEmpty {runs.append(current)}
    return runs
}
// One sentence that follows the evidence: no daily pattern claimed from too few days.
func chartHourAnswer(_ series:[TierSeries])->String {
    guard let lead=series.filter({$0.replies>0}).max(by:{$0.replies<$1.replies}) else{return "No timed replies in this range yet."}
    let name=modeTitle(lead.tier)
    let solid=lead.points.indices.compactMap {i->(index:Int,point:ChartPoint)? in
        guard let p=lead.points[i],p.count>=5 else{return nil}
        return (index:i,point:p)
    }
    guard solid.count>=6,let hi=solid.max(by:{$0.point.value<$1.point.value}),let lo=solid.min(by:{$0.point.value<$1.point.value}) else{
        return "Not enough replies yet to show how \(name) changes through the day."
    }
    let dayCounts=solid.map {$0.point.days}.sorted()
    let fewest=dayCounts.first ?? 0,most=dayCounts.last ?? 0
    let caveat=dayCounts[dayCounts.count/2]<usualMinDays ? " Only \(fewest==most ? "\(most)" : "\(fewest)–\(most)") day\(most==1 ? "" : "s") per hour so far, so it’s a lead, not a pattern yet." : ""
    if hi.point.value<lo.point.value*1.2 {
        return "\(name) held steady through the day: about \(wholeSpeed(lo.point.value))–\(wholeSpeed(hi.point.value)) t/s."+caveat
    }
    return "\(name) ran fastest around \(hourClock(hi.index)): about \(wholeSpeed(hi.point.value)) t/s vs \(wholeSpeed(lo.point.value)) around \(hourClock(lo.index))."+caveat
}
func chartHistoryAnswer(_ series:[TierSeries],overall:[String:Double?],buckets:[Date],step:Int,calendar:Calendar = .current)->String {
    let hourly=step==1
    guard let lead=series.filter({$0.replies>0}).max(by:{$0.replies<$1.replies}) else{return "No timed replies in this range yet."}
    let name=modeTitle(lead.tier)
    let pooled=wholeSpeed(overall[lead.tier] ?? nil)
    var others=""
    for s in series where s.tier != lead.tier {
        let active=Set(s.points.indices.filter {s.points[$0] != nil && $0<buckets.count}.map {calendar.startOfDay(for:buckets[$0])}).count
        if s.replies==0 {others += " You didn’t use \(modeTitle(s.tier))."}
        else if hourly {others += " \(modeTitle(s.tier)) had \(responseCount(s.replies))."}
        else if active<=2 {others += " \(modeTitle(s.tier)) was only used on \(active) day\(active==1 ? "" : "s"), so it has no trend yet."}
    }
    if hourly {return "\(name) averaged \(pooled) t/s over the last 24 hours."+others}
    let pts=lead.points.indices.compactMap {i->(index:Int,point:ChartPoint)? in
        guard let p=lead.points[i],p.count>=3 else{return nil}
        return (index:i,point:p)
    }
    guard pts.count>=3,let last=pts.last,last.index<buckets.count else{return "\(name) averaged \(pooled) t/s: not enough days yet to show a trend."+others}
    let third=max(1,pts.count/3)
    func average(_ xs:ArraySlice<(index:Int,point:ChartPoint)>)->Double {
        let n=xs.reduce(0) {$0+$1.point.count}
        let time=xs.reduce(0.0) {$0+Double($1.point.count)/max($1.point.value,0.001)}
        return time>0 ? Double(n)/time : 0
    }
    let early=average(pts.prefix(third)),late=average(pts.suffix(third))
    let lastDay=clockFormatter("d MMM").string(from:buckets[last.index])
    if late<=early*0.85 {return "\(name) slowed over this range: about \(wholeSpeed(early)) t/s at first, about \(wholeSpeed(late)) by \(lastDay)."+others}
    if late>=early*1.15 {return "\(name) sped up over this range: about \(wholeSpeed(early)) t/s at first, about \(wholeSpeed(late)) by \(lastDay)."+others}
    return "\(name) held steady over this range: about \(pooled) t/s."+others
}
// MARK: Report controls
// A small (?) right beside the thing it explains; click opens the explanation there, anchored to it.
struct InfoPopoverButton:View {
    let title:String
    let lines:[String]
    @State private var open=false
    @State private var hovering=false
    var body:some View {
        Button {open.toggle()} label: {
            Image(systemName:"questionmark.circle").font(.system(size:12,weight:.medium))
                .foregroundStyle(hovering || open ? SpeedTheme.primary : SpeedTheme.tertiary)
                .frame(width:16,height:16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .onHover {hovering=$0}
        .help(title)
        .accessibilityLabel(title)
        .popover(isPresented:$open,arrowEdge:.bottom) {
            VStack(alignment:.leading,spacing:8) {
                Text(title.uppercased()).font(.system(size:10,weight:.medium,design:.monospaced)).tracking(0.8).foregroundStyle(SpeedTheme.primary)
                ForEach(lines.indices,id:\.self) {i in
                    Text(lines[i]).font(.system(size:12)).foregroundStyle(i==0 ? SpeedTheme.primary : SpeedTheme.secondary)
                        .fixedSize(horizontal:false,vertical:true)
                }
            }
            .frame(width:320,alignment:.leading)
            .padding(16)
            .background(SpeedTheme.surface)
            .preferredColorScheme(.dark)
        }
    }
}
let measurementHelp=["Generating speed: output tokens ÷ the time after output starts. Replies without first-output timing aren’t counted.",
                     "A reply counts when it has valid, unambiguous timing and at least 100 output tokens; there’s no minimum duration.",
                     timingMethodExplanation,
                     "Leaving a day out (click its point in History, then Leave out) removes it from every number on this page."]
let comparisonHelp=["Only windows where you used both tiers: the same day and the same 3 hours, with \(comparisonMinPerTier)+ timed replies each. The ratio is the middle of those windows.",
                    "A clear answer needs 3+ shared windows on 2+ days, with the faster tier ahead in 4 of 5. Until then the ratio is dimmed and marked too few to call.",
                    "Usage on plan: Standard 1× · Fast 2.5× · Ultrafast 8× (purchased credits: 1× · 2× · 6×)."]
let timeSavedHelp=["1,000 tokens ÷ Standard’s speed, minus 1,000 tokens ÷ the other tier’s speed, both from the shared windows above.",
                   "It’s generating time only; the wait before output isn’t included."]
struct PatternsSegment:View {
    let options:[(id:String,title:String)]
    @Binding var value:String
    var disabled:Set<String>=[]
    var help:[String:String]=[:]
    var body:some View {
        HStack(spacing:2) {
            ForEach(options.indices,id:\.self) {i in
                let option=options[i]
                ExplicitSegmentButton(title:option.title,selected:value==option.id) {value=option.id}
                    .disabled(disabled.contains(option.id)).opacity(disabled.contains(option.id) ? 0.4 : 1)
                    .help(help[option.id] ?? "")
            }
        }
        .padding(2).background(SpeedTheme.track,in:RoundedRectangle(cornerRadius:8))
        .accessibilityElement(children:.contain)
    }
}
// One of a set: selected = purple outline and tint; the others are quiet outlines.
struct PickButtonStyle:ButtonStyle {
    let selected:Bool
    func makeBody(configuration:Configuration)->some View {PickButtonBody(configuration:configuration,selected:selected)}
}
private struct PickButtonBody:View {
    let configuration:ButtonStyle.Configuration
    let selected:Bool
    @State private var hovering=false
    var body:some View {
        configuration.label
            .font(.system(size:12,weight:selected ? .semibold : .regular))
            .foregroundStyle(selected ? SpeedTheme.accent : SpeedTheme.secondary)
            .padding(.horizontal,10).frame(minHeight:24)
            .background(RoundedRectangle(cornerRadius:6).fill(selected ? SpeedTheme.accent.opacity(0.12) : Color.white.opacity(hovering ? 0.06 : 0)))
            .overlay(RoundedRectangle(cornerRadius:6).strokeBorder(selected ? SpeedTheme.accent.opacity(0.55) : Color.white.opacity(hovering ? 0.28 : 0.14),lineWidth:1))
            .contentShape(RoundedRectangle(cornerRadius:6))
            .onHover {hovering=$0}
            .pointingHand()
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
// Tier lines on one scale. Gaps stay gaps; weak hours are dashed; 1–2 replies are hollow dots.
struct PatternsChart:View {
    let series:[TierSeries]
    let labels:[(index:Int,text:String)]
    var band:Range<Int>?=nil
    var bandLabel:String=""
    var weakBelowDays:Int=0
    var bandTier:String?=nil
    var pinned:Int?=nil
    var onTap:()->Void={}
    @Binding var hover:Int?
    var count:Int {series.first?.points.count ?? 0}
    var axisMax:Double {
        // Scale to the solid points; when every bucket is thin (a quiet 24 hours), scale to what there is.
        let all=series.flatMap {$0.points.compactMap {$0}}
        let solid=all.filter {$0.count>=3}
        let peak=(solid.isEmpty ? all : solid).map {max($0.value,$0.hi ?? 0)}.max() ?? 0
        let step=niceCeiling(max(peak,1)/4)
        return max(step,(peak/step).rounded(.up)*step)
    }
    var body:some View {
        let ceiling=axisMax,n=max(count,1)
        let left:CGFloat=36,top:CGFloat=20
        GeometryReader {g in
            Canvas {ctx,size in
                let right=size.width-8,bottom=size.height-24
                let step=(right-left)/CGFloat(n)
                func x(_ i:Int)->CGFloat {left+(CGFloat(i)+0.5)*step}
                func edge(_ i:Int)->CGFloat {left+CGFloat(i)*step}
                func y(_ v:Double)->CGFloat {bottom-CGFloat(min(max(v,0),ceiling)/ceiling)*(bottom-top)}
                if let band,band.lowerBound<band.upperBound {
                    let r=CGRect(x:edge(band.lowerBound),y:top,width:edge(band.upperBound)-edge(band.lowerBound),height:bottom-top)
                    ctx.fill(Path(r),with:.color(SpeedTheme.accent.opacity(0.08)))
                    for bx in [r.minX,r.maxX] {
                        var p=Path();p.move(to:CGPoint(x:bx,y:top));p.addLine(to:CGPoint(x:bx,y:bottom))
                        ctx.stroke(p,with:.color(SpeedTheme.accent.opacity(0.6)),style:StrokeStyle(lineWidth:1,dash:[3,3]))
                    }
                    ctx.draw(Text(bandLabel).font(.system(size:11,weight:.medium)).foregroundColor(SpeedTheme.accent),at:CGPoint(x:r.midX,y:top-4),anchor:.bottom)
                }
                for i in 0...4 {
                    let v=ceiling*Double(i)/4,yy=y(v)
                    var grid=Path();grid.move(to:CGPoint(x:left,y:yy));grid.addLine(to:CGPoint(x:right,y:yy))
                    ctx.stroke(grid,with:.color(Color.white.opacity(i==0 ? 0.14 : 0.06)),lineWidth:1)
                    ctx.draw(Text(wholeSpeed(v)).font(.system(size:11)).foregroundColor(SpeedTheme.tertiary),at:CGPoint(x:left-8,y:yy),anchor:.trailing)
                }
                ctx.draw(Text("t/s").font(.system(size:10)).foregroundColor(SpeedTheme.tertiary),at:CGPoint(x:left-8,y:top-4),anchor:.bottomTrailing)
                for label in labels where label.index<n {
                    ctx.draw(Text(label.text).font(.system(size:11)).foregroundColor(SpeedTheme.tertiary),at:CGPoint(x:x(label.index),y:size.height),anchor:.bottom)
                }
                if let h=pinned ?? hover,h>=0,h<n {
                    ctx.fill(Path(CGRect(x:edge(h),y:top,width:step,height:bottom-top)),with:.color(Color.white.opacity(pinned == nil ? 0.05 : 0.08)))
                }
                for s in series {
                    let color=patternsTierColor(s.tier)
                    if s.tier==bandTier {
                        for run in consecutiveRuns(s.points,where:{$0.lo != nil && $0.hi != nil && $0.days>=weakBelowDays}) where run.count>1 {
                            var area=Path()
                            area.move(to:CGPoint(x:x(run[0].index),y:y(run[0].point.hi ?? run[0].point.value)))
                            for e in run.dropFirst() {area.addLine(to:CGPoint(x:x(e.index),y:y(e.point.hi ?? e.point.value)))}
                            for e in run.reversed() {area.addLine(to:CGPoint(x:x(e.index),y:y(e.point.lo ?? e.point.value)))}
                            area.closeSubpath()
                            ctx.fill(area,with:.color(color.opacity(0.10)))
                        }
                    }
                    for run in consecutiveRuns(s.points,where:{$0.count>=3}) {
                        if run.count==1 {
                            let e=run[0]
                            let dot=CGRect(x:x(e.index)-3,y:y(e.point.value)-3,width:6,height:6)
                            ctx.fill(Path(ellipseIn:dot),with:.color(color.opacity(e.point.days<weakBelowDays ? 0.7 : 1)))
                            continue
                        }
                        for k in 1..<run.count {
                            let a=run[k-1],b=run[k]
                            var seg=Path();seg.move(to:CGPoint(x:x(a.index),y:y(a.point.value)));seg.addLine(to:CGPoint(x:x(b.index),y:y(b.point.value)))
                            let weak=a.point.days<weakBelowDays || b.point.days<weakBelowDays
                            ctx.stroke(seg,with:.color(color.opacity(weak ? 0.75 : 1)),style:StrokeStyle(lineWidth:2,lineCap:.round,dash:weak ? [4,4] : []))
                        }
                    }
                    for i in s.points.indices {
                        guard let p=s.points[i],p.count>0,p.count<3,p.value<=ceiling else{continue}
                        let ring=CGRect(x:x(i)-2.5,y:y(p.value)-2.5,width:5,height:5)
                        ctx.stroke(Path(ellipseIn:ring),with:.color(color.opacity(0.6)),lineWidth:1)
                    }
                    if let h=pinned ?? hover,h<s.points.count,let p=s.points[h] {
                        let dot=CGRect(x:x(h)-4,y:y(p.value)-4,width:8,height:8)
                        ctx.fill(Path(ellipseIn:dot),with:.color(color))
                    }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover {phase in
                switch phase {
                case .active(let point):
                    let right=g.size.width-8
                    let i=Int(((point.x-left)/max(1,right-left)*CGFloat(n)).rounded(.down))
                    hover=i>=0 && i<n ? i : nil
                case .ended:
                    hover=nil
                }
            }
            .onTapGesture {onTap()}
        }
        .accessibilityElement()
        .accessibilityLabel("Generating speed by tier")
        .accessibilityValue(series.map {"\(modeTitle($0.tier)): \(responseCount($0.replies))"}.joined(separator:", "))
    }
}
// The hours picked under the chart: each tier's speed, then the fair comparison with Standard.
struct SelectedHoursPanel:View {
    let pick:HourPick
    let scope:String
    let panel:HoursPanel?
    func tierRow(_ t:PanelTier)->some View {
        let weak=t.replies<30 || t.days<3
        return HStack(alignment:.firstTextBaseline,spacing:8) {
            VStack(alignment:.leading,spacing:2) {
                HStack(spacing:8) {
                    RoundedRectangle(cornerRadius:2).fill(patternsTierColor(t.tier)).frame(width:16,height:3)
                    Text(modeTitle(t.tier)).font(.system(size:13,weight:.semibold)).foregroundStyle(SpeedTheme.primary)
                }
                Text(t.replies==0 ? "not used" : "\(responseCount(t.replies)) · \(t.days) day\(t.days==1 ? "" : "s")")
                    .font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).padding(.leading,24)
            }
            Spacer(minLength:8)
            if let v=t.value {
                (Text(wholeSpeed(v)).font(.system(size:17,weight:.semibold)).foregroundColor(weak ? SpeedTheme.secondary : SpeedTheme.primary)
                 + Text(" t/s").font(.system(size:11)).foregroundColor(SpeedTheme.tertiary)).monospacedDigit()
            } else {
                Text("—").font(.system(size:15)).foregroundStyle(SpeedTheme.quiet)
            }
        }
        .padding(.vertical,8)
        .accessibilityElement(children:.combine)
    }
    func matchRow(_ tier:String)->some View {
        let m=panel?.matched[tier]
        let detail=m.map {"\($0.windows) window\($0.windows==1 ? "" : "s") · \($0.days) day\($0.days==1 ? "" : "s") · \(planUsageText(tier)) usage"} ?? "never used with Standard in the same 3 hours"
        return HStack(alignment:.firstTextBaseline,spacing:8) {
            VStack(alignment:.leading,spacing:2) {
                Text(modeTitle(tier)).font(.system(size:13,weight:.semibold)).foregroundStyle(SpeedTheme.primary)
                Text(detail).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).fixedSize(horizontal:false,vertical:true)
            }
            Spacer(minLength:8)
            if let m {
                VStack(alignment:.trailing,spacing:4) {
                    (Text(String(format:"%.1f× ",m.ratio)).font(.system(size:17,weight:.semibold)).foregroundColor(m.clear ? SpeedTheme.primary : SpeedTheme.secondary)
                     + Text("speed").font(.system(size:11)).foregroundColor(SpeedTheme.tertiary)).monospacedDigit()
                    if !m.clear {
                        Text("TOO FEW TO CALL").font(.system(size:9,weight:.bold,design:.monospaced)).tracking(0.8).foregroundStyle(SpeedTheme.tertiary)
                            .padding(.horizontal,6).frame(height:18).background(Color.white.opacity(0.06),in:RoundedRectangle(cornerRadius:4))
                    }
                }
            } else {
                Text("—").font(.system(size:15)).foregroundStyle(SpeedTheme.quiet)
            }
        }
        .padding(.vertical,8)
        .accessibilityElement(children:.combine)
    }
    func savedRow(_ tier:String)->some View {
        let m=panel?.matched[tier]
        let text:String={
            guard let m else{return "—"}
            let s=m.savedPer1000
            if s>=0.5 {return "≈\(Int(s.rounded())) s"}
            if s <= -0.5 {return "\(Int((-s).rounded())) s slower"}
            return "about the same"
        }()
        return HStack {
            Text(modeTitle(tier)).font(.system(size:13)).foregroundStyle(SpeedTheme.primary)
            Spacer(minLength:8)
            Text(text).font(.system(size:13,weight:.semibold)).monospacedDigit().foregroundStyle(m?.clear == true ? SpeedTheme.primary : SpeedTheme.secondary)
        }
        .padding(.vertical,4)
    }
    var note:String {
        guard let panel else{return ""}
        if (panel.observed.first(where:{$0.tier=="standard"})?.replies ?? 0)==0 {return "Standard wasn’t used in these hours, so there’s nothing to compare against."}
        return ["fast","ultrafast"].compactMap {t->String? in
            if let m=panel.matched[t] {
                return m.clear ? nil : "\(modeTitle(t)) shared only \(m.windows) window\(m.windows==1 ? "" : "s") with Standard here, too few to call."
            }
            return (panel.observed.first(where:{$0.tier==t})?.replies ?? 0)>0 ? "\(modeTitle(t)) and Standard never ran in the same 3 hours here." : nil
        }.joined(separator:" ")
    }
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            SectionLabel(text:"Selected hours",rule:false)
            Text(pick == .all ? pick.title : "\(pick.title) · \(pick.span)").font(.system(size:20,weight:.semibold)).foregroundStyle(SpeedTheme.primary).padding(.top,8)
            Text(scope).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary)
            VStack(spacing:0) {ForEach(panel?.observed ?? [],id:\.tier) {tierRow($0)}}.padding(.top,12)
            Rectangle().fill(SpeedTheme.hairline).frame(height:1).padding(.top,8)
            HStack(spacing:6) {
                SectionLabel(text:"vs Standard · same day, same 3 hours",rule:false)
                InfoPopoverButton(title:"How tiers are compared",lines:comparisonHelp)
            }.padding(.top,16)
            matchRow("fast")
            matchRow("ultrafast")
            Rectangle().fill(SpeedTheme.hairline).frame(height:1).padding(.top,8)
            HStack(spacing:6) {
                SectionLabel(text:"Generating time saved",rule:false)
                InfoPopoverButton(title:"How time saved is worked out",lines:timeSavedHelp)
            }.padding(.top,16)
            Text("per 1,000 output tokens, vs Standard").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).padding(.bottom,4)
            savedRow("fast")
            savedRow("ultrafast")
            if !note.isEmpty {
                Text(note).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).fixedSize(horizontal:false,vertical:true).padding(.top,12)
            }
        }
        .padding(.horizontal,Space.s4).padding(.vertical,20)
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .background(SpeedTheme.card,in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(SpeedTheme.cardStroke,lineWidth:1))
    }
}
struct PatternsKey:Equatable {
    let model:String
    let effort:String
    let tier:String
    let minute:Int
    let stamp:Date?
    let clock:String
    var days:String="all"
    var excluded:[Date]=[]
    var range:String=PatternsRange.fortnight.rawValue
    // Old values can remain during a data/minute refresh, but never under a
    // different model, effort, tier, clock or day/exclusion selection.
    func sameSelection(as other:Self)->Bool {
        model==other.model && effort==other.effort && tier==other.tier && clock==other.clock && days==other.days && excluded==other.excluded && range==other.range && environment==other.environment
    }
    // Invalidate when the system clock format or calendar/time zone changes too.
    var environment:String=String(describing:Calendar.current.identifier)+"|"+TimeZone.current.identifier+"|"+String(clockIs24Hour())
}
// One worker serializes synchronous analytics. A cancelled request waiting behind
// another calculation is skipped; an in-flight result is never published after cancellation.
actor PatternsWorker {
    static let shared=PatternsWorker()
    private let calculate:(RecentSpeedReport,PatternsKey,Date)->PatternsData
    init(calculate:@escaping (RecentSpeedReport,PatternsKey,Date)->PatternsData = {PatternsData.build(report:$0,key:$1,now:$2)}) {self.calculate=calculate}
    func build(report:RecentSpeedReport,key:PatternsKey,now:Date)->PatternsData? {
        guard !Task.isCancelled else{return nil}
        let result=calculate(report,key,now)
        return Task.isCancelled ? nil : result
    }
}
struct PatternsData {
    let key:PatternsKey
    let primaryTier:String
    let speedAnswer:String
    let speedRows:[TierRow]
    let worthAnswer:String
    let worthRows:[TierRow]
    let hoursAnswer:String
    let fast:TierComparison
    let ultrafast:TierComparison
    let fastToUltrafast:TierComparison
    let typicalTokens:Int
    let savedFastWeek:SavedTime?
    let savedUltraWeek:SavedTime?
    let grid:CongestionGrid
    var insight:HoursInsight?=nil
    let weekday:[Int:[Int:Double]]
    let weekdayStrip:(days:[WeekdayScore],weekdays:WeekdayScore,weekends:WeekdayScore)
    // Chart-first report
    var range:PatternsRange = .fortnight
    var hourSeries:[TierSeries]=[]
    var historySeries:[TierSeries]=[]
    var historyBuckets:[Date]=[]
    var historyHourly=false     // buckets shorter than a day
    var historyStepHours=24
    var panels:[HourPick:HoursPanel]=[:]
    var hourAnswer=""
    var historyAnswer=""
    var coverage=""
    var weekGrid:WeekGrid?=nil
    var gridAnswers:[String:String]=[:]
    static func build(report:RecentSpeedReport,key:PatternsKey,now:Date,calendar:Calendar = .current)->PatternsData {
        let tiers=fixedTierColumns
        let start=historyStart(now,calendar:calendar),todayStart=calendar.startOfDay(for:now)
        let filter=DayFilter(rawValue:key.days) ?? .all
        let excluded=Set(key.excluded.map {calendar.startOfDay(for:$0)})
        let source=Dictionary(uniqueKeysWithValues:tiers.map {($0,report.effortReadings(model:key.model,effort:key.effort,mode:$0))})
        let index=report.calendarIndex?.matching(calendar) ?? ReplyCalendarIndex(dates:source.values.flatMap {$0.map(\.date)},calendar:calendar)
        var includedDays:[Date:Bool]=[:]
        func include(_ day:Date)->Bool {
            if let hit=includedDays[day] {return hit}
            let value=filter.includes(day,calendar:calendar) && !excluded.contains(day)
            includedDays[day]=value;return value
        }
        // Explicit exclusions apply everywhere, including Today and its usual baseline.
        // The Days filter is local to "Slow and fast hours": it only scopes the grid,
        // day scores, weekday strip and that section's answer line.
        let raw=source.mapValues {rs in excluded.isEmpty ? rs : rs.filter {!excluded.contains(index.day($0.date))}}
        let all=raw
        let effortGroup=report.models.first{$0.model==key.model}?.efforts.first{$0.effort==key.effort}
        func counts(_ tier:String,_ from:Date,_ until:Date,hoursOnly:Bool=false)->(Int,Int) {
            func kept(_ d:Date)->Bool {d>=from && d<until && d<=now && !excluded.contains(index.day(d)) && (!hoursOnly || include(index.day(d)))}
            let measured=(all[tier] ?? []).filter{kept($0.date)}.count
            let total=effortGroup?.modes.first{$0.mode==tier}?.responseDates.filter(kept).count ?? measured
            return (measured,max(measured,total))
        }
        let completed=all.mapValues {$0.filter {$0.date>=start && $0.date<todayStart}}
        let hoursSet=raw.mapValues {$0.filter {include(index.day($0.date))}}
        let end=now.addingTimeInterval(1)
        let fast=tierComparison({all[$0] ?? []},from:"standard",to:"fast",start:start,end:end,calendar:calendar,calendarIndex:index)
        let ultra=tierComparison({all[$0] ?? []},from:"standard",to:"ultrafast",start:start,end:end,calendar:calendar,calendarIndex:index)
        let f2u=tierComparison({all[$0] ?? []},from:"fast",to:"ultrafast",start:start,end:end,calendar:calendar,calendarIndex:index)
        let weekFrom=calendar.date(byAdding:.day,value:-7,to:todayStart) ?? todayStart
        let fastWeek=(all["fast"] ?? []).filter {$0.date>=weekFrom && $0.date<todayStart}
        let ultraWeek=(all["ultrafast"] ?? []).filter {$0.date>=weekFrom && $0.date<todayStart}
        // Ranges only for settled comparisons (the only ones shown with a range).
        let sf=savedTime(fastWeek,standardWindows:fast.fromWindows,draws:settled(fast.strength.0) ? 300 : 0)
        let su=savedTime(ultraWeek,standardWindows:ultra.fromWindows,draws:settled(ultra.strength.0) ? 300 : 0)
        let tokens=typicalReplyTokens(tiers.flatMap {all[$0] ?? []}.filter {$0.date>=start})
        let totals=Dictionary(uniqueKeysWithValues:tiers.map {($0,(today:counts($0,todayStart,end).1,history:counts($0,start,todayStart).1))})
        let speed=speedSection(raw:raw,completed:completed,todayExcluded:excluded.contains(todayStart),coverage:totals,now:now,calendar:calendar,calendarIndex:index)
        let worth=worthSection(fast:fast,ultrafast:ultra,fastToUltrafast:f2u,savedFast:sf,savedUltra:su,usedFast:counts("fast",weekFrom,todayStart).1>0,usedUltra:counts("ultrafast",weekFrom,todayStart).1>0,tokens:tokens)
        let range=PatternsRange(rawValue:key.range) ?? .fortnight
        let grid=congestionGrid(hoursSet[key.tier] ?? [],now:now,days:range.gridDays,include:include,calendar:calendar,calendarIndex:index)
        let hoursCompleted=(hoursSet[key.tier] ?? []).filter {$0.date>=start && $0.date<todayStart}
        // Hours insight on generating speed when the grid has it (overall otherwise).
        var insightGrid=grid
        if let ng=grid.normalGenerating {
            insightGrid=CongestionGrid(days:grid.days,cells:grid.cells,typical:grid.typicalGenerating,baseline:ng,daysSoFar:grid.daysSoFar,pastDays:grid.pastDays)
            insightGrid.typicalDays=grid.typicalGenDays;insightGrid.typicalWait=grid.typicalWait;insightGrid.normalWait=grid.normalWait
        }
        let insight=hoursInsight(insightGrid,now:now,tier:key.tier,calendar:calendar)
        let hoursLine=insight?.answer ?? (grid.normalGenerating != nil ? "Not enough generating history yet to compare slow and fast hours." : hoursPatternAnswer(hoursCompleted,tier:key.tier,calendar:calendar,calendarIndex:index))
        var result=PatternsData(key:key,primaryTier:key.tier,speedAnswer:speed.answer,speedRows:speed.rows,worthAnswer:worth.answer,worthRows:worth.rows,
                            hoursAnswer:filter == .all ? hoursLine : "\(filter.title) only. "+hoursLine,
                            fast:fast,ultrafast:ultra,fastToUltrafast:f2u,typicalTokens:tokens,savedFastWeek:sf,savedUltraWeek:su,
                            grid:grid,insight:insight,weekday:weekdayCongestion(hoursSet[key.tier] ?? [],now:now,calendar:calendar,calendarIndex:index),weekdayStrip:weekdayScores(grid.normalGenerating == nil ? grid.dayScores : grid.genDayScores,calendar:calendar))
        // Chart, selected hours and coverage: generating speed only, inside the chosen range.
        let window=patternsWindow(range,now:now,calendar:calendar)
        let inRange=raw.mapValues {$0.filter {$0.date>=window.start && $0.date<=now}}
        let timed=inRange.mapValues {$0.filter {$0.generatingSpeed != nil}}
        result.range=range
        result.hourSeries=tiers.map {TierSeries(tier:$0,points:chartHourPoints(timed[$0] ?? [],calendar:calendar))}
        result.historySeries=tiers.map {TierSeries(tier:$0,points:chartHistoryPoints(timed[$0] ?? [],buckets:window.buckets,step:window.step,calendar:calendar))}
        result.historyBuckets=window.buckets
        result.historyHourly=window.step<24
        result.historyStepHours=window.step
        result.panels=chartHoursPanels(timed,calendar:calendar)
        result.hourAnswer=chartHourAnswer(result.hourSeries)
        result.historyAnswer=chartHistoryAnswer(result.historySeries,overall:timed.mapValues {timingSplit($0)?.generating},buckets:window.buckets,step:window.step,calendar:calendar)
        let wg=buildWeekGrid(raw.mapValues {$0.filter {$0.generatingSpeed != nil}},days:range == .day ? 7 : range.days,now:now,calendar:calendar)
        result.weekGrid=wg
        result.gridAnswers=Dictionary(uniqueKeysWithValues:tiers.map {($0,weekGridAnswer(wg,tier:$0))})
        let activeDays=Set(inRange.values.flatMap {$0.map {index.day($0.date)}}).count
        let leftOut=excluded.filter {$0>=calendar.startOfDay(for:window.start) && $0<=now}.count
        let replies=inRange.values.reduce(0) {$0+$1.count}
        let base:String=range == .day ? range.label+" · "+responseCount(replies) : "\(range.label) · data on \(activeDays) of \(range.days) days"
        result.coverage=base+(leftOut>0 ? " · \(leftOut) left out" : "")
        return result
    }
}
// MARK: Your speed
func todayCell(_ readings:[SpeedReading],totalReplies:Int?=nil,now:Date,calendar:Calendar = .current)->(cell:TierCell,marker:SpeedMarker?,compared:Bool) {
    let todayStart=calendar.startOfDay(for:now)
    let today=readings.filter {$0.date>=todayStart && $0.date<=now && $0.speed.isFinite}
    guard !today.isEmpty else{return (TierCell(value:"—",sub:(totalReplies ?? 0)>0 ? "no qualifying replies" : "not used today",dim:true),nil,false)}
    let mean=today.reduce(0) {$0+$1.speed}/Double(today.count)
    let u=usualBaseline(readings,start:todayStart,now:now,calendar:calendar)
    guard let b=u.baseline else{return (TierCell(value:"\(wholeSpeed(mean)) t/s",sub:"no usual yet · \(u.days) of \(usualMinDays) days"),nil,false)}
    if let m=speedMarker(today,baseline:b) {
        let pct=Int((abs(mean/b.median-1)*100).rounded())
        return (TierCell(value:"\(m == .faster ? "▲" : "▼") \(wholeSpeed(mean)) t/s",sub:"\(pct)% \(m == .faster ? "faster" : "slower") than usual (\(wholeSpeed(b.median)))",tone:m == .faster ? .faster : .slower),m,true)
    }
    if today.count<markerMinResponses {return (TierCell(value:"\(wholeSpeed(mean)) t/s",sub:"usual \(wholeSpeed(b.lo))–\(wholeSpeed(b.hi)) · too few replies to compare"),nil,false)}
    return (TierCell(value:"\(wholeSpeed(mean)) t/s",sub:"as usual · usual range \(wholeSpeed(b.lo))–\(wholeSpeed(b.hi))"),nil,true)
}
// Generating-first Today cell; nil when today's replies carry no timing (falls back to overall).
func generatingTodayCell(_ readings:[SpeedReading],now:Date,calendar:Calendar = .current)->(cell:TierCell,marker:SpeedMarker?,compared:Bool)? {
    let todayStart=calendar.startOfDay(for:now)
    guard let t=timingSplit(readings.filter {$0.date>=todayStart && $0.date<=now && $0.speed.isFinite}) else{return nil}
    let value="\(wholeSpeed(t.generating)) t/s"
    let measured=readings.filter {$0.date>=todayStart && $0.date<=now && $0.speed.isFinite}.count
    let coverage=t.responses<measured ? " · \(t.responses)/\(measured) timed" : ""
    guard let u=usualTiming(readings,start:todayStart,now:now,calendar:calendar) else{return (TierCell(value:value,sub:"no usual yet"+coverage),nil,false)}
    if let m=timingMarker(t.generating,lo:u.generatingLo,hi:u.generatingHi,longerIsSlower:false,responses:t.responses) {
        return (TierCell(value:"\(m == .faster ? "▲" : "▼") "+value,sub:timingCompareText(t.generating,usual:u.generating,longerIsSlower:false)+" (\(wholeSpeed(u.generating)))"+coverage,tone:m == .faster ? .faster : .slower),m,true)
    }
    if t.responses<markerMinResponses {return (TierCell(value:value,sub:"usual \(wholeSpeed(u.generatingLo))–\(wholeSpeed(u.generatingHi)) · too few replies to compare"+coverage),nil,false)}
    return (TierCell(value:value,sub:"as usual · usual range \(wholeSpeed(u.generatingLo))–\(wholeSpeed(u.generatingHi))"+coverage),nil,true)
}
// This week vs last on generating speed: each day's pooled rate, then the two weeks' means.
func generatingTrend(_ rs:[SpeedReading],weekStart:Date,prevStart:Date,calendar:Calendar = .current)->TierCell? {
    let timed=rs.filter {$0.waitSeconds != nil}
    guard !timed.isEmpty else{return nil}
    func daily(_ x:[SpeedReading])->[Double] {
        Dictionary(grouping:x) {calendar.startOfDay(for:$0.date)}.values.filter {$0.count>=usualMinDayResponses}.compactMap {timingSplit($0)?.generating}
    }
    let last=daily(timed.filter {$0.date>=weekStart}),prev=daily(timed.filter {$0.date>=prevStart && $0.date<weekStart})
    guard !last.isEmpty || !prev.isEmpty else{return nil}
    if prev.isEmpty {return TierCell(value:"Too new to tell",sub:"no timed days to compare last week",dim:true)}
    if last.isEmpty {return TierCell(value:"No timed days this week",sub:"\(wholeSpeed(prev.reduce(0,+)/Double(prev.count))) t/s the week before",dim:true)}
    func stat(_ v:[Double])->(mean:Double,margin:Double?) {
        let m=v.reduce(0,+)/Double(v.count)
        guard v.count>=2 else{return (m,nil)}
        let sd=sqrt(v.reduce(0) {$0+($1-m)*($1-m)}/Double(v.count-1))
        return (m,1.96*sd/sqrt(Double(v.count)))
    }
    let a=stat(last),b=stat(prev)
    let counts="\(wholeSpeed(a.mean)) vs \(wholeSpeed(b.mean)) t/s"
    guard let ae=a.margin,let be=b.margin,b.mean>0 else{return TierCell(value:"Too little data",sub:counts+" · \(min(last.count,prev.count)) day\(min(last.count,prev.count)==1 ? "" : "s") to compare",dim:true)}
    if a.mean+ae>=b.mean-be && b.mean+be>=a.mean-ae {return TierCell(value:"No clear change",sub:counts+" · days vary too much to tell",dim:true)}
    let change=a.mean/b.mean-1
    return TierCell(value:"\(Int(abs(change*100).rounded()))% \(change<0 ? "slower" : "faster")",sub:counts,tone:change<0 ? .slower : .faster)
}
func speedSection(raw:[String:[SpeedReading]],completed:[String:[SpeedReading]],todayExcluded:Bool=false,coverage:[String:(today:Int,history:Int)]=[:],now:Date,calendar:Calendar = .current,calendarIndex:ReplyCalendarIndex?=nil)->(answer:String,rows:[TierRow]) {
    let index=calendarIndex?.matching(calendar)
    let tiers=fixedTierColumns
    let start=historyStart(now,calendar:calendar),today=calendar.startOfDay(for:now)
    func shortDate(_ d:Date)->String {clockFormatter("d MMM").string(from:d)}
    let todays=tiers.map {tier -> (cell:TierCell,marker:SpeedMarker?,compared:Bool) in
        todayExcluded ? (TierCell(value:"Left out",sub:"",dim:true),nil,false) : (generatingTodayCell(raw[tier] ?? [],now:now,calendar:calendar) ?? {
            let result=todayCell(raw[tier] ?? [],totalReplies:coverage[tier]?.today,now:now,calendar:calendar)
            let old=result.cell
            let cell=TierCell(value:old.value,sub:(old.value == "—" ? "" : "overall · ")+old.sub,dim:old.dim,tone:old.tone)
            return (cell,result.marker,result.compared)
        }())
    }
    var phrases:[String]=[]
    for (t,r) in zip(tiers,todays).reversed() where r.compared {
        phrases.append(r.marker.map {"\(modeTitle(t)) is \($0 == .faster ? "faster" : "slower") than usual"} ?? "\(modeTitle(t)) is running as usual")
    }
    let usedToday=todays.contains {$0.cell.value != "—"}
    let answer=todayExcluded ? "" : phrases.isEmpty ? (usedToday ? "Not enough history yet to say whether today is usual." : (coverage.values.contains{$0.today>0} ? "Replies logged today, but none meet the measurement rules." : "No replies yet today."))
        : phrases.enumerated().map {$0.offset==0 ? $0.element+" today" : $0.element}.joined(separator:". ")+"."
    let average=tiers.map {t->TierCell in
        let rs=completed[t] ?? []
        guard !rs.isEmpty else{return TierCell(value:"—",sub:(coverage[t]?.history ?? 0)>0 ? "no qualifying replies" : "no replies",dim:true)}
        let timed=timingSplit(rs)
        let m=timed?.generating ?? rs.reduce(0) {$0+$1.speed}/Double(rs.count)
        let first=rs.map(\.date).min()!
        let since=calendar.startOfDay(for:first)>(calendar.date(byAdding:.day,value:1,to:start) ?? start) ? " · since \(shortDate(first))" : ""
        return TierCell(value:"\(wholeSpeed(m)) t/s",sub:(timed.map {$0.responses<rs.count ? "\($0.responses)/\(rs.count) timed" : responseCount(rs.count)} ?? "overall · "+responseCount(rs.count))+since)
    }
    let weekStart=calendar.date(byAdding:.day,value:-7,to:today)!,prevStart=calendar.date(byAdding:.day,value:-14,to:today)!
    let trend=tiers.map {t->TierCell in
        let rs=completed[t] ?? []
        if let g=generatingTrend(rs,weekStart:weekStart,prevStart:prevStart,calendar:calendar) {return g}
        let last=speedBlockStat(rs.filter {$0.date>=weekStart},calendarIndex:index),prev=speedBlockStat(rs.filter {$0.date>=prevStart && $0.date<weekStart},calendarIndex:index)
        if last.n==0 && prev.n==0 {return TierCell(value:"—",sub:(coverage[t]?.history ?? 0)>0 ? "no measured replies in 2 weeks" : "not used in 2 weeks",dim:true)}
        if prev.n==0,let first=rs.map(\.date).min() {return TierCell(value:"Too new to tell",sub:"first used \(shortDate(first))",dim:true)}
        if last.n==0 {return TierCell(value:"Not used this week",sub:"overall · \(wholeSpeed(prev.mean)) t/s the week before",dim:true)}
        let counts="overall · \(wholeSpeed(last.mean)) vs \(wholeSpeed(prev.mean)) t/s"
        guard let lm=last.mean,let pm=prev.mean,let le=last.margin,let pe=prev.margin,pm>0 else{return TierCell(value:"Too little data",sub:counts,dim:true)}
        if lm+le>=pm-pe && pm+pe>=lm-le {return TierCell(value:"No clear change",sub:counts,dim:true)}
        let change=lm/pm-1
        return TierCell(value:"\(Int(abs(change*100).rounded()))% \(change<0 ? "slower" : "faster")",sub:counts)
    }
    return (answer,[
        TierRow(label:"Today",help:"vs usual at these hours",cells:todays.map(\.cell)),
        TierRow(label:"Last 14 days",help:"complete days",cells:average),
        TierRow(label:"Trend",help:"this week vs last",cells:trend),
    ])
}
// MARK: Are Fast and Ultrafast worth it?
// "~10 h", "~2½ h", "~25 min".
func approxDuration(_ seconds:Double)->String {
    let s=abs(seconds)
    if s<60 {return "~\(Int(s.rounded())) s"}
    if s<3600 {return "~\(Int((s/60).rounded())) min"}
    let halves=Int((s/1800).rounded()),whole=halves/2
    return halves%2==0 ? "~\(whole) h" : "~\(whole == 0 ? "" : String(whole))½ h"
}
func worthSection(fast:TierComparison,ultrafast:TierComparison,fastToUltrafast:TierComparison,savedFast:SavedTime?,savedUltra:SavedTime?,usedFast:Bool,usedUltra:Bool,tokens:Int)->(answer:String,rows:[TierRow]) {
    let pairs=[(fast,savedFast,usedFast,nil as TierComparison?),(ultrafast,savedUltra,usedUltra,fastToUltrafast)]
    func verdict(_ c:TierComparison)->TierCell {
        guard c.strength.0 != .noWindows,let r=c.speedRatio else{return TierCell(value:"Not compared yet",sub:"Use it and Standard in the same hours to compare.",dim:true)}
        if !settled(c.strength.0) {
            let why=c.strength.0 == .mixed || c.strength.1.hasPrefix("Mixed") ? "but not consistently." : "but there’s too little side-by-side data."
            return TierCell(value:"Not clear yet",sub:"Looks \(speedRatioText(r).lowercased()), \(why)",dim:true)
        }
        if r<1.1 {return TierCell(value:"Not faster",sub:"Not meaningfully faster than Standard.")}
        let grade=valueGrade(speed:r,usage:c.cost)
        return TierCell(value:"\(speedWord(r)) · \(grade.label)",sub:grade == .poor ? "Worth it when you’re waiting on the answer." : "Worth it for most work.")
    }
    let stdTimes=[fast.fromTiming,ultrafast.fromTiming].compactMap {$0}.map {typicalReplySeconds($0,tokens:tokens)}
    let stdTypical:TierCell=stdTimes.isEmpty ? TierCell(value:"—",sub:"no side-by-side hours yet",dim:true)
        : (stdTimes.map {Int($0.rounded())}.min()==stdTimes.map {Int($0.rounded())}.max() ? TierCell(value:"\(wholeSpeed(stdTimes[0])) s",sub:"in the hours compared")
           : TierCell(value:"\(wholeSpeed(stdTimes.min()!))–\(wholeSpeed(stdTimes.max()!)) s",sub:"depends on the hours compared"))
    func typical(_ c:TierComparison)->TierCell {
        guard let f=c.fromTiming,let t=c.toTiming else{return TierCell(value:"—",sub:"needs side-by-side hours",dim:true)}
        let a=typicalReplySeconds(f,tokens:tokens),b=typicalReplySeconds(t,tokens:tokens),d=a-b
        return TierCell(value:"\(wholeSpeed(b)) s",sub:"\(wholeSpeed(abs(d))) s \(d>=0 ? "sooner" : "slower") than \(wholeSpeed(a)) s on Standard",dim:!settled(c.strength.0))
    }
    func usage(_ c:TierComparison)->TierCell {
        guard let r=c.speedRatio,c.strength.0 != .noWindows else{return TierCell(value:"? for \(multiplierText(c.cost))",sub:"speed not compared yet",dim:true)}
        let e=efficiencyText(r/c.cost)
        return TierCell(value:"\(String(format:"%.1f",r))× for \(multiplierText(c.cost))",sub:e=="Same" ? "about the same value" : "about \(e) the value",dim:!settled(c.strength.0))
    }
    func saved(_ c:TierComparison,_ s:SavedTime?,_ used:Bool)->TierCell {
        guard used else{return TierCell(value:"—",sub:"not used in the last 7 days",dim:true)}
        guard let s else{return TierCell(value:"—",sub:"needs side-by-side hours with Standard",dim:true)}
        let sign=s.seconds<0 ? " lost" : ""
        if !settled(c.strength.0) {return TierCell(value:approxDuration(s.seconds)+sign,sub:"not clear yet",dim:true)}
        return TierCell(value:approxDuration(s.seconds)+sign,sub:"likely \(durationRangeText(s.lo,s.hi))")
    }
    func sure(_ c:TierComparison,_ vsFast:TierComparison?)->TierCell {
        guard c.windows>0 else{return TierCell(value:"—",sub:"never used with Standard in the same 3 hours",dim:true)}
        var sub=settled(c.strength.0) ? "\(c.days) day\(c.days==1 ? "" : "s")" : "use both in the same hours a few more days"
        if let f=vsFast,f.windows>0 {sub += " · faster than Fast \(f.wins) of \(f.windows)"}
        return TierCell(value:"\(c.wins) of \(c.windows) faster",sub:sub,dim:!settled(c.strength.0))
    }
    let rows=[
        TierRow(label:"Verdict",help:"vs Standard",cells:[TierCell(value:"Baseline",sub:"The cheapest tier: 1× usage.")]+pairs.map {verdict($0.0)},tall:true),
        TierRow(label:"Typical reply",help:"\(tokens.formatted()) tokens",cells:[stdTypical]+pairs.map {typical($0.0)}),
        TierRow(label:"Speed for the usage",help:"vs Standard",cells:[TierCell(value:"1× for 1×",sub:"the reference")]+pairs.map {usage($0.0)}),
        TierRow(label:"Reply time saved",help:"last 7 days",cells:[TierCell(value:"—",sub:"the reference")]+pairs.map {saved($0.0,$0.1,$0.2)}),
        TierRow(label:"How sure",help:"matched hours",cells:[TierCell(value:"—",sub:"")]+pairs.map {sure($0.0,$0.3)}),
    ]
    return (tierHeadline([fast,ultrafast]),rows)
}
// MARK: Slow and fast hours
func hoursPatternAnswer(_ readings:[SpeedReading],tier:String,calendar:Calendar = .current,calendarIndex:ReplyCalendarIndex?=nil)->String {
    let index=calendarIndex?.matching(calendar)
    let byBlock=Dictionary(grouping:readings) {(index?.hour($0.date) ?? calendar.component(.hour,from:$0.date))/3}
    let days=Set(readings.map {(index?.day($0.date) ?? calendar.startOfDay(for:$0.date))}).count
    let stats=byBlock.mapValues {speedBlockStat($0,calendarIndex:index)}.filter {$0.value.days>=3 && $0.value.mean != nil}
    let name=modeTitle(tier)
    guard stats.count>=2,let slow=stats.min(by:{$0.value.mean! < $1.value.mean!}),let quick=stats.max(by:{$0.value.mean! < $1.value.mean!}),quick.value.mean! > slow.value.mean! * 1.1 else{
        return readings.isEmpty ? "No \(name) replies in this period." : "No steady pattern yet for \(name): \(days) day\(days==1 ? "" : "s") of data."
    }
    let early=stats.values.map(\.days).max() ?? 0 < 5
    return "\(name) is usually slowest \(blockLabel(slow.key)) and fastest \(blockLabel(quick.key))."+(early ? " Early pattern: \(days) days of data." : "")
}
struct SpeedPatternsView:View {
    let report:RecentSpeedReport
    let now:Date
    @State private var pickedModel:String?=nil
    @State private var pickedEffort:String?=nil
    @State private var pickedTier:String?=nil
    @State private var excludedDays:Set<Date>=[]
    @State private var data:PatternsData?=nil
    @State private var scrolled=false
    @State private var showMethod=false
    @AppStorage("clockStyle") private var clockStyle="system"
    @AppStorage("patternsDays") private var daysRaw=DayFilter.all.rawValue
    @AppStorage("patternsRange") private var rangeRaw=PatternsRange.fortnight.rawValue
    @AppStorage("patternsChart") private var chartModeRaw=PatternsChartMode.hour.rawValue
    @AppStorage("patternsHours") private var hourPickRaw=HourPick.all.rawValue
    @State private var chartHover:Int?=nil
    @State private var chartPin:Int?=nil     // clicked point: holds the readout so its action can be reached
    @State private var gridHover:GridSpot?=nil
    @State private var gridTier:String?=nil
    // Explicit so other files can build it (private @State would make the memberwise init private).
    init(report:RecentSpeedReport,now:Date) {self.report=report;self.now=now}
    var start:Date {historyStart(now)}
    var choiceStart:Date {historyStart(now,days:30)}
    var patternsRange:PatternsRange {PatternsRange(rawValue:rangeRaw) ?? .fortnight}
    var hourPick:HourPick {HourPick(rawValue:hourPickRaw) ?? .all}
    var todayStart:Date {Calendar.current.startOfDay(for:now)}
    var tiers:[String] {fixedTierColumns}
    var dayFilter:DayFilter {DayFilter(rawValue:daysRaw) ?? .all}
    var busiest:(model:String,effort:String,tier:String)? {report.busiestPair(since:start,until:now)}
    var modelChoices:[String] {report.models.filter {m in m.efforts.contains {e in e.modes.contains {g in g.readings.contains {$0.date>=choiceStart}}}}.map(\.model)}
    func effortChoices(_ model:String)->[String] {
        guard let m=report.models.first(where:{$0.model==model}) else{return []}
        return m.efforts.filter {e in e.modes.contains {g in g.readings.contains {$0.date>=choiceStart}}}.map(\.effort)
    }
    func selection()->(model:String,effort:String,tier:String)? {
        let b=busiest,models=modelChoices
        guard let model=(pickedModel.flatMap {models.contains($0) ? $0 : nil}) ?? b?.model ?? models.first else{return nil}
        let efforts=effortChoices(model)
        func count(_ e:String)->Int {tiers.reduce(0) {$0+report.effortReadings(model:model,effort:e,mode:$1).count}}
        guard let effort=(pickedEffort.flatMap {efforts.contains($0) ? $0 : nil}) ?? (b.flatMap {$0.model==model && efforts.contains($0.effort) ? $0.effort : nil}) ?? efforts.max(by:{count($0)<count($1)}) else{return nil}
        let tier=(pickedTier.flatMap {tiers.contains($0) ? $0 : nil}) ?? (b.flatMap {$0.model==model && $0.effort==effort ? $0.tier : nil}) ?? tiers.max(by:{report.effortReadings(model:model,effort:effort,mode:$0).count<report.effortReadings(model:model,effort:effort,mode:$1).count}) ?? "fast"
        return (model,effort,tier)
    }
    var body:some View {
        let sel=selection()
        let key=sel.map {PatternsKey(model:$0.model,effort:$0.effort,tier:$0.tier,minute:Int(now.timeIntervalSince1970/60),stamp:report.snapshotAt ?? report.checkedAt,clock:clockStyle,days:DayFilter.all.rawValue,excluded:excludedDays.sorted(),range:rangeRaw)}
        return VStack(alignment:.leading,spacing:0) {
            // Sticky header: stays put while the sections scroll underneath.
            if let sel {header(sel,updating:data?.key != key,coverage:data.flatMap {$0.key.range==rangeRaw ? $0.coverage : nil} ?? patternsRange.label)}
            ScrollView {
                VStack(alignment:.leading,spacing:56) {
                    if let error=report.error {Text(error).font(.system(size:12)).foregroundStyle(Color.orange)}
                    if let sel {
                        // Same model and effort: keep the page in place, dimming what's being
                        // recalculated, so changing tier or days never resets the scroll.
                        if let data,let key,data.key.sameSelection(as:key) || (data.key.model==key.model && data.key.effort==key.effort) {
                            let fresh=data.key.sameSelection(as:key)
                            let topFresh=fresh || (data.key.excluded==key.excluded && data.key.clock==key.clock && data.key.environment==key.environment && data.key.range==key.range)
                            content(data,sel:sel,staleTop:!topFresh,staleHours:!fresh)
                        } else {
                            HStack(spacing:Space.s2) {ProgressView().controlSize(.small);Text("Working out patterns…").font(.system(size:12)).foregroundStyle(SpeedTheme.secondary)}.padding(.vertical,Space.s6)
                        }
                    } else {
                        Text("No measured replies in the last 14 days.").font(.system(size:13)).foregroundStyle(SpeedTheme.secondary).padding(.vertical,Space.s6)
                    }
                }
                .padding(.top,Space.s4).padding(.bottom,Space.s6)
                .background(GeometryReader {g in Color.clear.preference(key:PatternsScrollKey.self,value:g.frame(in:.named("patternsScroll")).minY)})
                .frame(maxWidth:1200,alignment:.leading).frame(maxWidth:.infinity,alignment:.leading)
            }
            .coordinateSpace(name:"patternsScroll")
            .onPreferenceChange(PatternsScrollKey.self) {y in if (y < -1) != scrolled {scrolled = y < -1}}
        }
        .task(id:key) {
            guard let key else{data=nil;return}
            let snapshot=report,moment=now
            let built=await PatternsWorker.shared.build(report:snapshot,key:key,now:moment)
            if let built {
                await MainActor.run {if !Task.isCancelled {data=built}}
            }
        }
    }
    func chip(_ title:String,_ options:[(String,String)],select:@escaping (String)->Void)->some View {
        MenuButton(title:title,options:options.map {(id:$0.0,label:$0.1)},select:select).fixedSize()
    }
    var clockMenu:some View {
        // Preferences live behind ⋯, not in the reading area.
        Menu {
            Picker("Clock",selection:$clockStyle) {Text("System clock").tag("system");Text("12-hour").tag("12");Text("24-hour").tag("24")}
                .pickerStyle(.inline)
        } label: {
            Image(systemName:"ellipsis").font(.system(size:12,weight:.medium))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width:28,height:28)
        .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(Color.white.opacity(0.18),lineWidth:1))
        .help("Clock format")
        .accessibilityLabel("More options")
    }
    func header(_ sel:(model:String,effort:String,tier:String),updating:Bool,coverage:String)->some View {
        VStack(alignment:.leading,spacing:Space.s3) {
            HStack(spacing:Space.s3) {
                HStack(alignment:.firstTextBaseline,spacing:12) {
                    Text("SPEED PATTERNS").font(.system(size:12,weight:.bold,design:.monospaced)).tracking(1.6).foregroundStyle(SpeedTheme.primary).accessibilityAddTraits(.isHeader)
                    Text("Generating speed (est.) · the wait before output isn’t included").font(.system(size:12)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1)
                    InfoPopoverButton(title:"How speed is measured",lines:measurementHelp).alignmentGuide(.firstTextBaseline) {$0[VerticalAlignment.center]+4}
                }
                Spacer(minLength:Space.s3)
                Text(TimeZone.current.localizedName(for:.generic,locale:.current) ?? TimeZone.current.identifier).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1)
                clockMenu
            }
            HStack(spacing:Space.s2) {
                chip(sel.model,modelChoices.map {($0,$0)}) {pickedModel=$0;pickedEffort=nil;pickedTier=nil}
                chip(effortShortTitle(sel.effort),effortChoices(sel.model).map {($0,effortShortTitle($0))}) {pickedEffort=$0;pickedTier=nil}
                Rectangle().fill(SpeedTheme.hairline).frame(width:1,height:24).padding(.horizontal,Space.s2)
                PatternsSegment(options:PatternsRange.allCases.map {(id:$0.rawValue,title:$0.rawValue)},value:Binding(get:{rangeRaw},set:{rangeRaw=$0;chartPin=nil})).frame(width:216)
                Text(coverage).font(.system(size:12)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1).padding(.leading,Space.s2)
                if updating {ProgressView().controlSize(.small).accessibilityLabel("Updating")}
                Spacer(minLength:Space.s3)
                if !excludedDays.isEmpty {
                    Button("\(excludedDays.count) day\(excludedDays.count==1 ? "" : "s") left out · Show all") {excludedDays=[]}
                        .buttonStyle(ChipButtonStyle())
                }
            }
        }
        .padding(.bottom,Space.s3)
        .frame(maxWidth:.infinity,alignment:.leading)
        .background(reportBackground)
        .overlay(alignment:.bottom) {Rectangle().fill(Color.white.opacity(scrolled ? 0.14 : 0.08)).frame(height:1)}
        .shadow(color:.black.opacity(scrolled ? 0.6 : 0),radius:scrolled ? 4 : 0,y:scrolled ? 4 : 0)
        .zIndex(1)
    }
    @ViewBuilder func content(_ data:PatternsData,sel:(model:String,effort:String,tier:String),staleTop:Bool=false,staleHours:Bool=false)->some View {
        VStack(alignment:.leading,spacing:Space.s3) {
            HStack(alignment:.top,spacing:Space.s3) {
                chartCard(data)
                if chartMode(data) == .grid,let g=data.weekGrid {
                    GridSummaryPanel(grid:g,tier:gridTierFor(data),scope:data.range.label.lowercased()).frame(width:344)
                } else {
                    SelectedHoursPanel(pick:hourPick,scope:data.range == .day ? data.range.label : "Across the "+data.range.label.lowercased(),panel:data.panels[hourPick])
                        .frame(width:344)
                }
            }
            .fixedSize(horizontal:false,vertical:true)
            .opacity(staleTop ? 0.5 : 1)
        }
    }
    // History is the only view a single day supports.
    func chartMode(_ data:PatternsData)->PatternsChartMode {data.range == .day ? .history : (PatternsChartMode(rawValue:chartModeRaw) ?? .hour)}
    // The grid shows one tier: the one you pick, else the report's main tier.
    func gridTierFor(_ data:PatternsData)->String {gridTier.flatMap {tiers.contains($0) ? $0 : nil} ?? data.primaryTier}
    func chartLabels(_ data:PatternsData,hourly:Bool)->[(index:Int,text:String)] {
        if hourly {return stride(from:0,to:24,by:4).map {(index:$0,text:hourClock($0))}}
        let b=data.historyBuckets
        switch data.historyStepHours {
        case 1:return stride(from:0,to:b.count,by:4).map {(index:$0,text:hourClock(Calendar.current.component(.hour,from:b[$0])))}
        case 3:
            let f=clockFormatter("EEE d")
            return stride(from:0,to:b.count,by:8).map {(index:$0,text:f.string(from:b[$0]))}
        default:
            let step=b.count<=7 ? 1 : (b.count<=14 ? 2 : 5)
            let f=clockFormatter("d MMM")
            return stride(from:0,to:b.count,by:step).map {(index:$0,text:f.string(from:b[$0]))}
        }
    }
    func bucketTitle(_ i:Int,data:PatternsData,hourly:Bool)->String {
        if hourly {return hourClock(i)+"–"+hourClock((i+1)%24)}
        guard i<data.historyBuckets.count else{return ""}
        let d=data.historyBuckets[i]
        switch data.historyStepHours {
        case 1:return clockTime(d)
        case 3:
            // The slot denotes a wall-clock range, even if its first clock
            // instant was skipped by a timezone transition.
            let h=(i % 8)*3
            return clockFormatter("EEE d MMM").string(from:d)+" · "+hourClock(h)+"–"+hourClock((h+3)%24)
        default:return clockFormatter("EEE d MMM").string(from:d)
        }
    }
    // Hour of day lists the days behind an hour, so one bad day can't pass for a pattern.
    func readout(_ data:PatternsData,series:[TierSeries],hourly:Bool,index:Int?)->String {
        guard let i=index else{return "Hover the chart for exact values · click a point to pin it"}
        let parts=series.compactMap {s->String? in
            guard i<s.points.count,let p=s.points[i] else{return nil}
            var days=""
            if hourly && p.perDay.count>1 {
                days=p.perDay.count<=7 ? ", \(p.perDay.count) days: "+p.perDay.map {wholeSpeed($0)}.joined(separator:", ")
                    : ", \(p.perDay.count) days, \(wholeSpeed(p.perDay.min()))–\(wholeSpeed(p.perDay.max()))"
            }
            return "\(modeTitle(s.tier)) \(wholeSpeed(p.value)) t/s (\(responseCount(p.count))\(days))"
        }
        return bucketTitle(i,data:data,hourly:hourly)+" · "+(parts.isEmpty ? "no timed replies" : parts.joined(separator:" · "))
    }
    func pinnedDay(_ data:PatternsData)->Date? {
        guard let i=chartPin,i<data.historyBuckets.count else{return nil}
        return Calendar.current.startOfDay(for:data.historyBuckets[i])
    }
    func tierLegend(_ series:[TierSeries])->some View {
        HStack(spacing:Space.s3) {
            ForEach(series,id:\.tier) {s in
                HStack(spacing:6) {
                    RoundedRectangle(cornerRadius:2).fill(s.replies>0 ? patternsTierColor(s.tier) : SpeedTheme.quiet).frame(width:16,height:3)
                    Text(modeTitle(s.tier)).font(.system(size:12)).foregroundStyle(s.replies>0 ? SpeedTheme.primary : SpeedTheme.quiet)
                    Text(s.replies>0 ? s.replies.formatted() : "not used").font(.system(size:12)).monospacedDigit().foregroundStyle(SpeedTheme.tertiary)
                }
                .lineLimit(1).fixedSize()
            }
        }
    }
    func chartCard(_ data:PatternsData)->some View {
        let mode=chartMode(data)
        let isGrid=mode == .grid && data.weekGrid != nil
        let gTier=gridTierFor(data)
        let hourly=mode == .hour
        let series=hourly ? data.hourSeries : data.historySeries
        let lead=series.filter {$0.replies>0}.max {$0.replies<$1.replies}?.tier
        let pin=chartPin.flatMap {$0<(series.first?.points.count ?? 0) ? $0 : nil}
        let leaveOut=hourly ? nil : pinnedDay(data)
        let foot:String={
            if isGrid {return "Each block: your generating speed (est.) on \(modeTitle(gTier)) in those 3 hours, colored against your normal (last 14 days) · dashed = 1–2 replies · hatched = no replies · hover a block for its replies"}
            if hourly {return "Solid line = 3+ days at that hour · dashed = fewer days, a lead not a pattern · ○ = 1–2 replies · gaps = no replies · hover an hour to see the days behind it"}
            switch data.historyStepHours {
            case 1:return "One point per hour · click a point to pin it, then leave its day out · ○ = 1–2 replies · gaps = no replies"
            case 3:return "One point per 3 hours · click a point to pin it, then leave its day out · ○ = 1–2 replies · gaps = no replies"
            default:return "One point per day · click a day to pin it or leave it out · ○ = 1–2 replies · gaps = days you didn’t use that tier"
            }
        }()
        let singleDay=data.range == .day
        return VStack(alignment:.leading,spacing:0) {
            HStack(spacing:Space.s3) {
                PatternsSegment(options:[(id:PatternsChartMode.history.rawValue,title:"History"),(id:PatternsChartMode.hour.rawValue,title:"Hour of day"),(id:PatternsChartMode.grid.rawValue,title:"Day × hour")],
                                value:Binding(get:{mode.rawValue},set:{chartModeRaw=$0;chartPin=nil;gridHover=nil}),
                                disabled:singleDay ? [PatternsChartMode.hour.rawValue,PatternsChartMode.grid.rawValue] : [],
                                help:singleDay ? [PatternsChartMode.hour.rawValue:"Needs a 7-day or longer range",PatternsChartMode.grid.rawValue:"Needs a 7-day or longer range"] : [:])
                    .frame(width:300)
                Spacer(minLength:Space.s3)
                if !isGrid {tierLegend(series)}
            }
            if isGrid {
                HStack(spacing:Space.s3) {
                    PatternsSegment(options:tiers.map {(id:$0,title:modeTitle($0))},value:Binding(get:{gTier},set:{gridTier=$0;gridHover=nil})).frame(width:252)
                    Text("your \(modeTitle(gTier)) replies, in 3-hour blocks").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1)
                }.padding(.top,12)
            }
            answerText(isGrid ? (data.gridAnswers[gTier] ?? "") : (hourly ? data.hourAnswer : data.historyAnswer)).font(.system(size:17)).fixedSize(horizontal:false,vertical:true).padding(.top,20)
            HStack(spacing:Space.s2) {
                Text(isGrid ? gridReadout(data.weekGrid!,tier:gTier,spot:gridHover) : readout(data,series:series,hourly:hourly,index:pin ?? chartHover)).font(.system(size:11)).monospacedDigit()
                    .foregroundStyle((isGrid ? gridHover == nil : pin == nil && chartHover == nil) ? SpeedTheme.tertiary : SpeedTheme.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength:Space.s2)
                if pin != nil && !isGrid {
                    if let day=leaveOut {
                        Button("Leave out "+clockFormatter("EEE d MMM").string(from:day)) {excludedDays.insert(day);chartPin=nil}
                            .buttonStyle(ChipButtonStyle())
                    }
                    Button {chartPin=nil} label: {
                        Image(systemName:"xmark").font(.system(size:10,weight:.semibold)).foregroundStyle(SpeedTheme.tertiary).frame(width:20,height:20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointingHand().help("Unpin").accessibilityLabel("Unpin")
                }
            }
            .frame(height:24).padding(.top,12)
            if isGrid,let g=data.weekGrid {
                WeekGridView(grid:g,tier:gTier,hover:$gridHover).padding(.top,8)
            } else {
                PatternsChart(series:series,labels:chartLabels(data,hourly:hourly),band:hourly && hourPick != .all ? hourPick.hours : nil,bandLabel:hourPick.span,
                              weakBelowDays:hourly ? 3 : 0,bandTier:lead,pinned:pin,onTap:{chartPin=(chartHover == nil || chartHover == chartPin) ? nil : chartHover},hover:$chartHover)
                    .frame(height:260).padding(.top,8)
                HStack(spacing:Space.s2) {
                    ForEach(HourPick.allCases,id:\.self) {p in
                        Button(p.title) {hourPickRaw=p.rawValue}.buttonStyle(PickButtonStyle(selected:p == hourPick))
                    }
                    Text("Pick the hours to compare").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).padding(.leading,Space.s1)
                }
                .padding(.top,Space.s3)
            }
            Rectangle().fill(SpeedTheme.hairline).frame(height:1).padding(.top,Space.s3)
            Text(foot).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).fixedSize(horizontal:false,vertical:true).padding(.top,12)
        }
        .padding(.horizontal,Space.s4).padding(.vertical,20)
        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .background(SpeedTheme.card,in:RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(SpeedTheme.cardStroke,lineWidth:1))
    }
    func hoursFoot(_ data:PatternsData)->String {
        data.grid.normalGenerating != nil
            ? "Each cell is one hour’s generating speed (est.), colored against \(modeTitle(data.primaryTier))’s usual. Day = that day vs usual for the hours you used. Hover a cell for its wait, overall speed and replies."
            : "Each cell is one hour’s overall t/s, wait included, colored against \(modeTitle(data.primaryTier))’s usual. Day = that day vs usual for the hours you used."
    }
    // The answer's first clause (to the first ": " or ". ") reads as the headline.
    func answerText(_ answer:String)->Text {
        let cut=[": ",". "].compactMap {answer.range(of:$0)}.min {$0.lowerBound<$1.lowerBound}
        guard let cut else{return Text(answer).foregroundColor(SpeedTheme.secondary)}
        let lead=String(answer[..<cut.upperBound]),rest=String(answer[cut.upperBound...])
        return Text(lead).fontWeight(.semibold).foregroundColor(SpeedTheme.primary)+Text(rest).foregroundColor(SpeedTheme.secondary)
    }
    func section<Content:View>(_ title:String,_ answer:String,foot:String?,@ViewBuilder _ content:()->Content)->some View {
        VStack(alignment:.leading,spacing:0) {
            SectionLabel(text:title)
            answerText(answer).font(.system(size:17)).fixedSize(horizontal:false,vertical:true).padding(.top,12)
            content().padding(.top,Space.s4)
            if let foot {Text(foot).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).fixedSize(horizontal:false,vertical:true).padding(.top,Space.s3)}
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
private struct PatternsScrollKey:PreferenceKey {
    static let defaultValue:CGFloat=0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) {value=nextValue()}
}
// One table component for every tier comparison: fixed Standard → Fast → Ultrafast
// columns, so rows (and "cards") are equal height by construction.
// Every row gets exactly the same tier widths, regardless of its text's intrinsic size.
struct TierColumnLayout:Layout {
    let labelWidth:CGFloat
    var maxTierWidth:CGFloat=264   // wide windows keep columns close enough to compare
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ())->CGSize {
        let width=proposal.width ?? 1040
        let tierWidth=min(maxTierWidth,max(0,width-labelWidth)/CGFloat(max(1,subviews.count-1)))
        let height=subviews.enumerated().map {index,view in
            view.sizeThatFits(ProposedViewSize(width:index==0 ? labelWidth : tierWidth,height:proposal.height)).height
        }.max() ?? 0
        return CGSize(width:width,height:height)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        let tierWidth=min(maxTierWidth,max(0,bounds.width-labelWidth)/CGFloat(max(1,subviews.count-1)))
        var x=bounds.minX
        for (index,view) in subviews.enumerated() {
            let width=index==0 ? labelWidth : tierWidth
            view.place(at:CGPoint(x:x,y:bounds.minY),anchor:.topLeading,proposal:ProposedViewSize(width:width,height:bounds.height))
            x+=width
        }
    }
}
struct TierTable:View {
    let rows:[TierRow]
    var foot:String?=nil                 // the table's note, as its last row
    var footLink:String?=nil
    var footAction:(()->Void)?=nil
    let labelWidth:CGFloat=208
    func valueColor(_ c:TierCell)->Color {
        if let t=c.tone {return t == .faster ? SpeedTheme.faster : SpeedTheme.slowerYellow}
        return c.dim ? SpeedTheme.secondary : SpeedTheme.primary
    }
    // A dimmed verdict with no number ("Too new to tell") reads as a quiet status, not data.
    func isWordStatus(_ c:TierCell)->Bool {
        c.dim && c.tone == nil && c.value != "—" && c.value.rangeOfCharacter(from:.decimalDigits) == nil
    }
    @ViewBuilder func valueText(_ cell:TierCell)->some View {
        if isWordStatus(cell) {
            Text(cell.value.uppercased()).font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(0.8)
                .foregroundStyle(SpeedTheme.secondary).lineLimit(1).truncationMode(.tail)
                .frame(minHeight:20,alignment:.leading)
        } else {
            Text(cell.value).font(.system(size:17,weight:.semibold)).monospacedDigit().foregroundStyle(valueColor(cell))
                .lineLimit(1).truncationMode(.tail).frame(minHeight:20,alignment:.leading)
        }
    }
    var body:some View {
        VStack(spacing:0) {
            TierColumnLayout(labelWidth:labelWidth) {
                Color.clear.frame(width:labelWidth,height:1)
                ForEach(fixedTierColumns,id:\.self) {t in
                    Text(modeTitle(t).uppercased()).font(.system(size:10,design:.monospaced)).tracking(0.8).foregroundStyle(SpeedTheme.tertiary)
                        .padding(.horizontal,Space.s4).frame(maxWidth:.infinity,alignment:.leading)
                }
            }.frame(height:40)
            ForEach(Array(rows.enumerated()),id:\.offset) {_,row in
                Rectangle().fill(SpeedTheme.hairline).frame(height:1)
                TierColumnLayout(labelWidth:labelWidth) {
                    VStack(alignment:.leading,spacing:2) {
                        Text(row.label).font(.system(size:13,weight:.semibold)).foregroundStyle(SpeedTheme.primary).lineLimit(1)
                            .frame(minHeight:20,alignment:.leading)
                        Text(row.help).font(.system(size:12)).foregroundStyle(SpeedTheme.tertiary).lineLimit(2).fixedSize(horizontal:false,vertical:true)
                    }.padding(.horizontal,Space.s4).padding(.vertical,Space.s3).frame(width:labelWidth,alignment:.topLeading)
                    ForEach(Array(row.cells.enumerated()),id:\.offset) {j,cell in
                        VStack(alignment:.leading,spacing:2+numberStackExtraSpacing) {
                            valueText(cell)
                            Text(cell.sub).font(.system(size:12)).foregroundStyle(SpeedTheme.tertiary)
                                .lineLimit(row.tall ? 2 : 1).truncationMode(.tail)
                                .frame(minHeight:row.tall ? CGFloat(30) : nil,alignment:.topLeading)
                                .help(cell.sub)
                        }
                        .padding(.horizontal,Space.s4).padding(.vertical,Space.s3)
                        .frame(maxWidth:.infinity,alignment:.leading)
                        .accessibilityElement(children:.combine)
                        .accessibilityLabel("\(row.label), \(modeTitle(fixedTierColumns[min(j,2)]))")
                    }
                }
            }
            if foot != nil || footLink != nil {
                Rectangle().fill(SpeedTheme.hairline).frame(height:1)
                HStack(alignment:.firstTextBaseline,spacing:Space.s1) {
                    if let foot {Text(foot).font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).fixedSize(horizontal:false,vertical:true)}
                    if let footLink,let footAction {Button(footLink,action:footAction).buttonStyle(LinkTextButtonStyle()).font(.system(size:11))}
                    Spacer(minLength:0)
                }
                .padding(.horizontal,Space.s4).padding(.vertical,Space.s3-4)
                .frame(maxWidth:.infinity,alignment:.leading)
            }
        }
        .background(SpeedTheme.card,in:RoundedRectangle(cornerRadius:12))
        .clipShape(RoundedRectangle(cornerRadius:12))
        .overlay(RoundedRectangle(cornerRadius:12).stroke(SpeedTheme.cardStroke,lineWidth:1))
    }
}
// By day of week: how each weekday ran vs usual for the hours you used.
struct WeekdayStrip:View {
    let strip:(days:[WeekdayScore],weekdays:WeekdayScore,weekends:WeekdayScore)
    let filter:DayFilter
    var generating=true
    func box(_ w:WeekdayScore,summary:Bool=false)->some View {
        let level:CongestionLevel?=w.score.map {congestionLevel($0*100,baseline:100)}
        let included=summary || filter == .all || (filter == .weekends) == w.weekend
        let faded=w.days<congestionTypicalMinDays
        return VStack(alignment:.leading,spacing:0) {
            Text(w.label).font(.system(size:11)).foregroundStyle(level.map(congestionText) ?? SpeedTheme.tertiary).opacity(0.8)
            Text(w.score.map(percentText) ?? "—").font(.system(size:15,weight:.semibold)).monospacedDigit().foregroundStyle(level.map(congestionText) ?? SpeedTheme.quiet)
            Text(w.days==0 ? "no days" : "\(w.days) day\(w.days==1 ? "" : "s")"+(summary && faded && w.days>0 ? " · too few" : "")).font(.system(size:11)).foregroundStyle(level.map(congestionText) ?? SpeedTheme.tertiary).opacity(0.8)
        }
        .padding(Space.s2).frame(maxWidth:.infinity,alignment:.leading)
        .background(RoundedRectangle(cornerRadius:4).fill(level.map(congestionFill) ?? Color.white.opacity(0.03)))
        .opacity(included ? (faded ? 0.55 : 1) : 0.25)
        .accessibilityElement(children:.combine)
    }
    var body:some View {
        VStack(alignment:.leading,spacing:Space.s2) {
            HStack(alignment:.firstTextBaseline,spacing:Space.s2) {
                Text("By day of week").font(.system(size:12,weight:.medium)).foregroundStyle(SpeedTheme.primary)
                Text("\(generating ? "generating" : "overall") speed vs usual for the hours you used · a day counts with \(dayScoreMinHours)+ hours of use · faded = fewer than \(congestionTypicalMinDays) days").font(.system(size:11)).foregroundStyle(SpeedTheme.tertiary).lineLimit(1)
            }
            HStack(spacing:Space.s1) {
                ForEach(Array(strip.days.enumerated()),id:\.offset) {_,d in box(d)}
                Color.clear.frame(width:Space.s3,height:1)
                box(strip.weekdays,summary:true).frame(maxWidth:.infinity)
                box(strip.weekends,summary:true).frame(maxWidth:.infinity)
            }.fixedSize(horizontal:false,vertical:true)
        }
        .padding(Space.s3)
        .background(SpeedTheme.card,in:RoundedRectangle(cornerRadius:12))
    }
}
