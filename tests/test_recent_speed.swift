import SwiftUI
import SQLite3
import AppKit

final class RenderFeed:ObservableObject {
    @Published var report:RecentSpeedReport
    @Published var now=Date()
    init(_ report:RecentSpeedReport) {self.report=report}
    func refresh() {var next=report;next.checkedAt=Date();report=next;now=Date()}
}
struct RenderSurface:View {
    @ObservedObject var feed:RenderFeed
    let compact:Bool
    let selection:SpeedSelection?
    let snapshot:Snapshot
    var body:some View {
        Group {
            if compact {
                VStack(spacing:0) {CompactSpeedContent(report:feed.report,now:feed.now,initialSelection:selection);Rectangle().fill(SpeedTheme.divider).frame(height:1);WidgetFooter(snapshot:snapshot,scope:"today",updated:feed.report.snapshotAt ?? feed.report.checkedAt) {feed.refresh()}}
                    .frame(width:400).background(SpeedTheme.surface).foregroundStyle(SpeedTheme.primary).preferredColorScheme(.dark)
            } else {
                RecentModelSpeedView(report:feed.report,now:feed.now,initialSelection:selection).padding(24).frame(width:1100,height:900).background(widgetBackground).environment(\.colorScheme,.dark)
            }
        }
    }
}

@main struct Checks {
    @MainActor static func main() throws {
        do {
            _ = NSApplication.shared
            let close = MonitorCloseButton.makeButton()
            precondition(close.action == #selector(NSApplication.terminate(_:)) && close.target === NSApp)
            precondition(close.toolTip == "Quit Codex Speed Monitor" && close.image != nil)
            precondition(close.contentTintColor != nil && close.appearance?.name == .darkAqua)
            var refreshes = 0
            let link = MonitorRefreshLink { refreshes += 1 }
            link.refresh()
            precondition(refreshes == 1)
            print("PASS exposed close targets native app termination; refresh text action invokes supplied callback")
        }
        if CommandLine.arguments.contains("--render-controls") {
            let content = VStack(spacing:0) {
                CompactSpeedContent(report:RecentSpeedReport(),now:Date())
                Rectangle().fill(SpeedTheme.divider).frame(height:1)
                WidgetFooter(snapshot:Snapshot(),scope:"today",updated:Date()) {}
            }.frame(width:400).background(SpeedTheme.surface).foregroundStyle(SpeedTheme.primary).preferredColorScheme(.dark)
            let host = NSHostingView(rootView:content)
            host.frame=NSRect(x:0,y:0,width:400,height:200)
            let window=NSWindow(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:false)
            window.contentView=host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until:Date().addingTimeInterval(0.2))
            let size=host.fittingSize
            host.frame.size=size; window.setContentSize(size); host.layoutSubtreeIfNeeded()
            let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds)!
            host.cacheDisplay(in:host.bounds,to:rep)
            try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/tmp/codex-panel-controls.png"))
            print("PASS synthetic panel controls rendered",size)
        }
        // The hover hint must dismiss promptly, while crossing its gap or
        // re-entering cancels stale dismissal tasks instead of flickering.
        do {
            func tick(_ seconds:Double) {RunLoop.main.run(until:Date().addingTimeInterval(seconds))}
            let hint=SpeedInfoHoverState()
            hint.triggerHover(true);precondition(hint.isPresented)
            hint.triggerHover(false);tick(0.03);precondition(hint.isPresented)
            hint.triggerHover(true);tick(0.13);precondition(hint.isPresented)
            hint.triggerHover(false);tick(0.03);hint.contentHover(true)
            tick(0.13);precondition(hint.isPresented)
            hint.contentHover(false);tick(0.16);precondition(!hint.isPresented)
            hint.toggle();precondition(hint.isPresented)
            hint.dismiss();tick(0.12);precondition(!hint.isPresented)
            hint.triggerHover(true);hint.setPresented(false);precondition(!hint.isPresented)
            print("PASS hint opens on hover/click; 80 ms exit grace; trigger re-entry and content entry cancel stale closes; content exit and explicit dismissal close")
        }
        if CommandLine.arguments.contains("--async-checks") {
            final class Probe:@unchecked Sendable {
                let lock=NSLock(),gate=DispatchSemaphore(value:0)
                var names:[String]=[],active=0,maximum=0
                func begin(_ name:String) {lock.lock();names.append(name);active+=1;maximum=max(maximum,active);lock.unlock()}
                func end() {lock.lock();active-=1;lock.unlock()}
                var started:Int {lock.lock();defer{lock.unlock()};return names.count}
            }
            let probe=Probe(),report=RecentSpeedReport(),now=Date()
            let base=PatternsKey(model:"A",effort:"high",tier:"fast",minute:1,stamp:nil,clock:"24")
            let prepared=PatternsData.build(report:report,key:base,now:now)
            let worker=PatternsWorker {_,key,_ in
                precondition(!Thread.isMainThread)
                probe.begin(key.model)
                if key.model=="A" {precondition(probe.gate.wait(timeout:.now()+5) == .success)}
                Thread.sleep(forTimeInterval:0.15)
                probe.end()
                return prepared
            }
            var finished=0,published:[String]=[]
            func request(_ name:String)->Task<Void,Never> {
                Task {
                    let key=PatternsKey(model:name,effort:"high",tier:"fast",minute:1,stamp:nil,clock:"24")
                    if let _=await worker.build(report:report,key:key,now:now),!Task.isCancelled {published.append(name)}
                    finished+=1
                }
            }
            func wait(_ predicate:()->Bool) {
                let end=Date().addingTimeInterval(8)
                while !predicate() && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005))}
                precondition(predicate(),"async worker timeout")
            }
            let first=request("A");wait {probe.started==1}
            let cancelled=request("B"),latest=request("C")
            RunLoop.main.run(until:Date().addingTimeInterval(0.05))
            first.cancel();cancelled.cancel();probe.gate.signal()
            var ticks=0
            let end=Date().addingTimeInterval(5)
            while finished<3 && Date()<end {RunLoop.main.run(until:Date().addingTimeInterval(0.005));ticks+=1}
            precondition(finished==3 && published==["C"] && probe.names==["A","C"] && probe.maximum==1 && ticks>=20)
            _=latest
            print("PASS serial background analytics; queued cancelled work skipped; stale publication rejected; main run-loop responsive (\(ticks) ticks)")
            return
        }
        if CommandLine.arguments.contains("--store") {
            let store=TelemetryStore()
            func wait(_ predicate:()->Bool) { let end=Date().addingTimeInterval(30);while !predicate() && Date()<end { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) };precondition(predicate(),"store refresh timeout") }
            wait {store.speedReport.checkedAt != nil}
            let first=store.speedReport.checkedAt!,ids=store.speedReport.models.map(\.model)
            store.setScope("7d");wait {(store.speedReport.checkedAt ?? .distantPast)>first}
            precondition(store.speedReport.models.map(\.model)==ids)
            let next=store.speedReport.checkedAt!;store.refresh(scope:"7d",force:true);wait {(store.speedReport.checkedAt ?? .distantPast)>next}
            precondition(store.speedReport.error==nil)
            print("PASS store refresh, forced refresh, scope-independent grouping and stable order");return
        }
        if CommandLine.arguments.contains("--export") {
            let store=TelemetryStore()
            try store.exportTrustedCSV(to:URL(fileURLWithPath:CommandLine.arguments[2]),scope:"7d")
            print("PASS CSV export request");return
        }
        if CommandLine.arguments.contains("--verify-live") {
            var db:OpaquePointer?;let path=CommandLine.arguments[2];let now=Date()
            precondition(sqlite3_open_v2(path,&db,SQLITE_OPEN_READONLY,nil)==SQLITE_OK);defer{sqlite3_close(db)}
            let report=RecentSpeedReport.read(db,usageTable:"trusted_turn_cache",speedTable:"trusted_turn_cache",cached:true,path:path,now:now)
            precondition(report.error==nil)
            let g=report.group(for:SpeedSelection(model:"gpt-6.1-sol",effort:"xhigh",mode:"standard"),range:.day,now:now)
            let example=g.readings.first{$0.id=="otel_response_stream:188568:0"}!
            precondition(example.selectedEffort=="xhigh" && example.reportedEffort=="high" && example.effortSource=="parent_turn")
            precondition(abs(example.speed-646.0/(14784.092315/1000))<0.00000001 && g.mismatchCount>0)
            var q:OpaquePointer?;defer{sqlite3_finalize(q)}
            let sql="SELECT count(*),avg(output_tokens_per_second) FROM trusted_turn_cache WHERE model='gpt-6.1-sol' AND (CASE WHEN json_extract(raw_json,'$.selected_effort_source') IN ('parent_turn','retained_parent_turn') AND coalesce(json_extract(raw_json,'$.selected_effort_conflict'),0)=0 AND json_extract(raw_json,'$.matching_streams')=1 AND json_extract(raw_json,'$.matching_completions')=1 AND coalesce(json_extract(raw_json,'$.identity_conflict'),0)=0 AND json_extract(raw_json,'$.selected_reasoning_effort') IN ('minimal','low','medium','high','xhigh','max','ultra') THEN json_extract(raw_json,'$.selected_reasoning_effort') ELSE lower(trim(coalesce(json_extract(raw_json,'$.reported_reasoning_effort'),reasoning_effort,'unknown'))) END) IN ('xhigh','extra high','extra-high','extra_high','extrahigh','x-high','x_high') AND coalesce(nullif(service_tier_served,''),nullif(service_tier_requested,''),nullif(mode,''),'unknown') IN ('standard','default') AND (speed_eligible=1 OR (json_extract(raw_json,'$.matching_streams')=1 AND json_extract(raw_json,'$.matching_completions')=1)) AND duration_ms>0 AND output_tokens>=100 AND julianday(completed_at)>=julianday(?,'unixepoch') AND julianday(completed_at)<=julianday(?,'unixepoch')"
            precondition(sqlite3_prepare_v2(db,sql,-1,&q,nil)==SQLITE_OK)
            sqlite3_bind_double(q,1,now.timeIntervalSince1970-86400);sqlite3_bind_double(q,2,now.timeIntervalSince1970)
            precondition(sqlite3_step(q)==SQLITE_ROW)
            precondition(Int(sqlite3_column_int(q,0))==g.readings.count)
            precondition(abs(sqlite3_column_double(q,1)-g.stats().mean!)<0.000001)
            print("PASS real selected xhigh/reported high exact response 188568:0",example.speed,"and effective-effort SQL mean/count",g.readings.count,g.stats().mean!,"mismatches",g.mismatchCount);return
        }
        if CommandLine.arguments.contains("--verify-overview") {
            var db:OpaquePointer?;let path=CommandLine.arguments[2],now=Date()
            precondition(sqlite3_open_v2(path,&db,SQLITE_OPEN_READONLY,nil)==SQLITE_OK);defer{sqlite3_close(db)}
            let report=RecentSpeedReport.read(db,usageTable:"trusted_turn_cache",speedTable:"trusted_turn_cache",cached:true,path:path,now:now).filtered(range:.week,now:now)
            precondition(report.error==nil)
            let cte="""
            WITH attrs AS (
              SELECT *, CASE WHEN json_valid(raw_json) THEN raw_json ELSE '{}' END AS j FROM trusted_turn_cache
            ), raw_choice AS (
              SELECT *, CASE WHEN json_extract(j,'$.selected_effort_source') IN ('parent_turn','retained_parent_turn')
                 AND coalesce(json_extract(j,'$.selected_effort_conflict'),0)=0 AND coalesce(json_extract(j,'$.identity_conflict'),0)=0
                 AND json_extract(j,'$.matching_streams')=1 AND json_extract(j,'$.matching_completions')=1
                 AND lower(trim(json_extract(j,'$.selected_reasoning_effort'))) IN ('minimal','low','medium','high','xhigh','max','ultra','extra high','extra-high','extra_high','extrahigh','x-high','x_high')
                THEN 1 ELSE 0 END AS selected_flag
              FROM attrs
            ), normalized AS (
              SELECT coalesce(nullif(trim(model),''),'Unknown model') AS grouped_model,
                CASE WHEN selected_flag=1 THEN json_extract(j,'$.selected_reasoning_effort')
                     ELSE coalesce(json_extract(j,'$.reported_reasoning_effort'),reasoning_effort,'unknown') END AS effort_value,
                lower(trim(coalesce(nullif(trim(service_tier_served),''),nullif(trim(service_tier_requested),''),nullif(trim(mode),''),'unknown'))) AS tier_value,
                selected_flag,output_tokens_per_second
              FROM raw_choice WHERE (speed_eligible=1 OR (json_extract(j,'$.matching_streams')=1 AND json_extract(j,'$.matching_completions')=1)) AND coalesce(json_extract(j,'$.identity_conflict'),0)=0
                AND duration_ms>0 AND output_tokens>=100 AND output_tokens_per_second IS NOT NULL AND output_tokens_per_second>=0
                AND julianday(completed_at)>=julianday(?,'unixepoch') AND julianday(completed_at)<=julianday(?,'unixepoch')
            ), effective AS (
              SELECT *, CASE lower(trim(effort_value))
                WHEN '' THEN 'unknown' WHEN 'unspecified' THEN 'unknown' WHEN 'unknown' THEN 'unknown' WHEN 'null' THEN 'unknown' WHEN 'n/a' THEN 'unknown'
                WHEN 'extra high' THEN 'xhigh' WHEN 'extra-high' THEN 'xhigh' WHEN 'extra_high' THEN 'xhigh' WHEN 'extrahigh' THEN 'xhigh' WHEN 'x-high' THEN 'xhigh' WHEN 'x_high' THEN 'xhigh'
                ELSE lower(trim(effort_value)) END AS grouped_effort,
                CASE tier_value WHEN 'priority' THEN 'fast' WHEN 'default' THEN 'standard' ELSE tier_value END AS grouped_tier
              FROM normalized
            )
            """
            var q:OpaquePointer?;precondition(sqlite3_prepare_v2(db,cte+" SELECT count(*),avg(output_tokens_per_second),coalesce(sum(selected_flag),0) FROM effective WHERE grouped_model=? AND grouped_effort=? AND grouped_tier=?",-1,&q,nil)==SQLITE_OK);defer{sqlite3_finalize(q)}
            var total=0
            for model in report.models {
                precondition(Set(model.efforts.map(\.effort)).count==model.efforts.count)
                for effort in model.efforts {for group in effort.modes {
                    sqlite3_reset(q);sqlite3_clear_bindings(q);sqlite3_bind_double(q,1,now.timeIntervalSince1970-SpeedTimeRange.week.seconds);sqlite3_bind_double(q,2,now.timeIntervalSince1970)
                    for (offset,value) in [model.model,effort.effort,group.mode].enumerated() {sqlite3_bind_text(q,Int32(offset+3),value,-1,unsafeBitCast(-1,to:sqlite3_destructor_type.self))}
                    precondition(sqlite3_step(q)==SQLITE_ROW)
                    let count=Int(sqlite3_column_int(q,0));precondition(count==group.readings.count)
                    precondition(Int(sqlite3_column_int(q,2))==group.readings.filter(\.usesSelected).count)
                    if let mean=group.stats().mean {precondition(abs(sqlite3_column_double(q,1)-mean)<0.0000001)}else{precondition(sqlite3_column_type(q,1)==SQLITE_NULL)}
                    total+=count
                    if model.model=="gpt-6.1-sol" {print("PASS 7d SQL merged group",effort.effort,group.mode,"count",count,"mean",group.stats().mean as Any,"selected",group.readings.filter(\.usesSelected).count,"fallback",group.readings.filter{!$0.usesSelected}.count)}
                }}
            }
            var all:OpaquePointer?;precondition(sqlite3_prepare_v2(db,cte+" SELECT count(*) FROM effective",-1,&all,nil)==SQLITE_OK);defer{sqlite3_finalize(all)}
            sqlite3_bind_double(all,1,now.timeIntervalSince1970-SpeedTimeRange.week.seconds);sqlite3_bind_double(all,2,now.timeIntervalSince1970);precondition(sqlite3_step(all)==SQLITE_ROW && total==Int(sqlite3_column_int(all,0)))
            print("PASS all live 7d effective groups have unique effort identity and SQL-equal means/counts/provenance totals; no lost or duplicated readings",total);return
        }
        if CommandLine.arguments.contains("--render") {
            var db:OpaquePointer?;let path=CommandLine.arguments[2]
            precondition(sqlite3_open_v2(path,&db,SQLITE_OPEN_READONLY,nil)==SQLITE_OK)
            let range=CommandLine.arguments.first(where:{$0.hasPrefix("--range=")}).flatMap {SpeedTimeRange(rawValue:String($0.dropFirst(8)))} ?? (CommandLine.arguments.contains("--week") ? .week : .day)
            let suite="dev.codexspeedmonitor.tests."+UUID().uuidString
            let defaults=UserDefaults(suiteName:suite)!
            defaults.register(defaults:["speedTimeRange":range.rawValue,"reportSpeedView":"patterns"])
            if CommandLine.arguments.contains("--report-table") || CommandLine.arguments.contains("--click-patterns") {defaults.set("table",forKey:"reportSpeedView")}
            defer {defaults.removePersistentDomain(forName:suite)}
            var report=RecentSpeedReport.read(db,usageTable:"trusted_turn_cache",speedTable:"trusted_turn_cache",cached:true,path:path);sqlite3_close(db)
            precondition(report.error==nil)
            if CommandLine.arguments.contains("--fixture-ultra") {
                let date=Date().addingTimeInterval(-60)
                let modes=["standard","fast","ultrafast"].enumerated().map {i,mode in SpeedModeGroup(mode:mode,readings:[SpeedReading(id:mode,date:date,speed:Double(i+1)*50,outputTokens:500,durationMS:10000)],excluded:0,responseDates:[date],excludedDates:[],latestResponse:date)}
                report.models=[SpeedModelGroup(model:"TEST FIXTURE · three distinct tiers",efforts:[SpeedEffortGroup(effort:"xhigh",modes:modes)],latestResponse:date)]
            }
            if CommandLine.arguments.contains("--fixture-table") {
                let d=Date().addingTimeInterval(-60)
                func mode(_ name:String,_ n:Int,_ zero:Bool=false)->SpeedModeGroup {
                    let readings=(0..<n).map {i in SpeedReading(id:name+String(i),date:d.addingTimeInterval(-Double(i)*300),speed:zero ? 0 : Double(100+i),outputTokens:25000,durationMS:10000)}
                    return SpeedModeGroup(mode:name,readings:readings,excluded:n==0 ? 1 : 0,responseDates:readings.isEmpty ? [d] : readings.map(\.date),excludedDates:n==0 ? [d] : [],latestResponse:d)
                }
                let efforts=[SpeedEffortGroup(effort:"high",modes:[mode("ultrafast",12),mode("fast",4),mode("standard",0)]),SpeedEffortGroup(effort:"xhigh",modes:[mode("fast",5,true)])]
                let m=SpeedModelGroup(model:"TEST FIXTURE · table cases",efforts:efforts,latestResponse:d)
                precondition(overviewTiers([m])==["standard","fast","ultrafast"])
                report.models=[m]
            }
            if CommandLine.arguments.contains("--fixture-hierarchy") {
                let date=Date().addingTimeInterval(-60)
                func efforts(_ names:[String])->[SpeedEffortGroup] {names.map {effort in
                    SpeedEffortGroup(effort:effort,modes:["standard","fast","ultrafast"].enumerated().map {i,mode in SpeedModeGroup(mode:mode,readings:[SpeedReading(id:effort+mode,date:date,speed:Double(i+1)*50,outputTokens:500,durationMS:10000)],excluded:0,responseDates:[date],excludedDates:[],latestResponse:date)})
                }}
                report.models=[SpeedModelGroup(model:"TEST FIXTURE · Model A",efforts:efforts(["high","xhigh"]),latestResponse:date),SpeedModelGroup(model:"TEST FIXTURE · Model B",efforts:efforts(["max"]),latestResponse:date)]
            }
            if CommandLine.arguments.contains("--fixture-sparse") || CommandLine.arguments.contains("--fixture-empty") {
                let now=Date()
                let empty=CommandLine.arguments.contains("--fixture-empty")
                let times=[now.addingTimeInterval(-23*3600),now.addingTimeInterval(-22*3600),now.addingTimeInterval(-3600),now.addingTimeInterval(-60)]
                let readings=empty ? [] : times.enumerated().map {i,d in SpeedReading(id:String(i),date:d,speed:Double(i+1)*30,outputTokens:300,durationMS:10000)}
                let group=SpeedModeGroup(mode:"ultrafast",readings:readings.reversed(),excluded:empty ? 1 : 0,responseDates:[now],excludedDates:empty ? [now] : [],latestResponse:now)
                report.models=[SpeedModelGroup(model:"TEST FIXTURE · sparse/empty",efforts:[SpeedEffortGroup(effort:"xhigh",modes:[group])],latestResponse:now)]
                report.oldestAvailable=now.addingTimeInterval(-14*86400)
            }
            if CommandLine.arguments.contains("--fixture-single") {
                let d=Date().addingTimeInterval(-300)
                let g=SpeedModeGroup(mode:"ultrafast",readings:[SpeedReading(id:"single",date:d,speed:0,outputTokens:100,durationMS:10000)],responseDates:[d],latestResponse:d)
                report.models=[SpeedModelGroup(model:"TEST FIXTURE · single zero",efforts:[SpeedEffortGroup(effort:"xhigh",modes:[g])],latestResponse:d)]
            }
            if CommandLine.arguments.contains("--fixture-effort") {
                let d=Date().addingTimeInterval(-120)
                let r=SpeedReading(id:"mismatch",date:d,speed:43.7,outputTokens:646,durationMS:14784,selectedEffort:"xhigh",reportedEffort:"high",effortSource:"parent_turn")
                let g=SpeedModeGroup(mode:"ultrafast",readings:[r],responseDates:[d],effortEvidence:[EffortEvidence(date:d,selected:"xhigh",reported:"high",source:"parent_turn")],latestResponse:d)
                report.models=[SpeedModelGroup(model:"TEST FIXTURE · selected effort",efforts:[SpeedEffortGroup(effort:"xhigh",modes:[g])],latestResponse:d)]
            }
            if CommandLine.arguments.contains("--fixture-inprogress") {
                let d=Date().addingTimeInterval(-60)
                let rr=(0..<48).map {i in SpeedReading(id:"ongoing-\(i)",date:d.addingTimeInterval(Double(-i*30)),speed:40,outputTokens:400,durationMS:10000,selectedEffort:nil,reportedEffort:"high",effortSource:"unresolved")}
                var fast=SpeedModeGroup(mode:"fast",readings:rr,responseDates:rr.map(\.date),effortEvidence:rr.map{EffortEvidence(date:$0.date,selected:nil,reported:"high",source:"unresolved")},latestResponse:d)
                var empty=SpeedModeGroup(mode:"ultrafast",excluded:1,responseDates:[d],excludedDates:[d],latestResponse:d)
                var extraModes:[SpeedModeGroup]=[]
                if CommandLine.arguments.contains("--fixture-mixed") {
                    let exact=[10.0,30.0].enumerated().map {i,v in SpeedReading(id:"exact-\(i)",date:d,speed:v,outputTokens:Int64(v*10),durationMS:10000,selectedEffort:"high",reportedEffort:"high",effortSource:"parent_turn")}
                    fast.readings+=exact;fast.responseDates+=exact.map(\.date);fast.effortEvidence+=exact.map{EffortEvidence(date:$0.date,selected:"high",reported:"high",source:"parent_turn")}
                    let u=SpeedReading(id:"ultrafast",date:d,speed:120,outputTokens:1200,durationMS:10000,selectedEffort:"high",reportedEffort:"high",effortSource:"parent_turn")
                    empty=SpeedModeGroup(mode:"ultrafast",readings:[u],responseDates:[d],effortEvidence:[EffortEvidence(date:d,selected:"high",reported:"high",source:"parent_turn")],latestResponse:d)
                    let standard=SpeedReading(id:"standard",date:d,speed:30,outputTokens:300,durationMS:10000,reportedEffort:"high")
                    extraModes=[SpeedModeGroup(mode:"standard",readings:[standard],responseDates:[d],effortEvidence:[EffortEvidence(date:d,selected:nil,reported:"high",source:"unresolved")],latestResponse:d)]
                }
                let mismatch=SpeedReading(id:"verified-xhigh",date:d,speed:43.7,outputTokens:646,durationMS:14784,selectedEffort:"xhigh",reportedEffort:"high",effortSource:"parent_turn")
                let selected=SpeedModeGroup(mode:"standard",readings:[mismatch],responseDates:[d],effortEvidence:[EffortEvidence(date:d,selected:"xhigh",reported:"high",source:"parent_turn")],latestResponse:d)
                report.models=[SpeedModelGroup(model:"TEST FIXTURE · ongoing turn",efforts:[SpeedEffortGroup(effort:"high",modes:[empty,fast]+extraModes),SpeedEffortGroup(effort:"xhigh",modes:[selected])],latestResponse:d)]
            }
            if CommandLine.arguments.contains("--focus-evidence") {
                // Scope real snapshot records for visual inspection; no synthetic values.
                report.models=report.models.filter{$0.model=="gpt-6.1-sol"}.map {m in
                    SpeedModelGroup(model:m.model,efforts:m.efforts.filter{$0.effort=="xhigh"},latestResponse:m.latestResponse)
                }
                print("VISUAL CHECK scoped to real selected xhigh gpt-6.1-sol records")
            }
            if CommandLine.arguments.contains("--fixture-analytics") {
                let cal=Calendar.current,now=Date(),today=cal.startOfDay(for:now)
                let modes=fixedTierColumns.enumerated().map {index,tier -> SpeedModeGroup in
                    var rows:[SpeedReading]=[]
                    for offset in 1...14 {
                        let day=cal.date(byAdding:.day,value:-offset,to:today)!
                        for hour in 0..<24 {for j in 0..<5 {
                            let date=cal.date(bySettingHour:hour,minute:j,second:0,of:day)!
                            let rate=Double((index+1)*40+hour+j)
                            rows.append(SpeedReading(id:"\(tier)-\(offset)-\(hour)-\(j)",date:date,speed:rate,outputTokens:Int64(rate*10),durationMS:10000))
                        }}
                    }
                    for j in 0..<5 {
                        let date=now.addingTimeInterval(-Double(j+1))
                        rows.append(SpeedReading(id:"today-\(tier)-\(j)",date:date,speed:250,outputTokens:2500,durationMS:10000))
                    }
                    rows.sort{$0.date>$1.date}
                    return SpeedModeGroup(mode:tier,readings:rows,responseDates:rows.map(\.date),latestResponse:rows.first!.date)
                }
                report.models=[SpeedModelGroup(model:"TEST FIXTURE · analytics",efforts:[SpeedEffortGroup(effort:"high",modes:modes)],latestResponse:now)]
                report.oldestAvailable=cal.date(byAdding:.day,value:-14,to:today)
            }
            if CommandLine.arguments.contains("--fixture-many-cards"),let first=report.models.first {
                report.models=(1...8).map {i in SpeedModelGroup(model:"TEST FIXTURE · Model \(i)",efforts:first.efforts,latestResponse:first.latestResponse)}
            }
            for m in report.models {for e in m.efforts {for g in e.modes {let s=g.stats();print(m.model,e.effort,g.mode,s.readings.count,speedText(s.mean),"latest",s.latest.map(readingTime) ?? "none", "excluded",g.excluded)}}}
            let compact=CommandLine.arguments.contains("--compact"),detail=CommandLine.arguments.contains("--detail")
            let selection=detail ? report.filtered(range:range,now:Date()).models.first.flatMap { m in m.efforts.first.flatMap {e in (e.measuredModes.isEmpty ? e.untimedModes : e.measuredModes).first.map {SpeedSelection(model:m.model,effort:e.effort,mode:$0.mode)}} } : nil
            let store=TelemetryStore();store.speedReport=report
            let feed=RenderFeed(report)
            let content=AnyView(Group {
                if CommandLine.arguments.contains("--patterns-only") {SpeedPatternsView(report:feed.report,now:feed.now).padding(24).frame(width:1100,height:900).background(widgetBackground).preferredColorScheme(.dark)}
                else if CommandLine.arguments.contains("--full-report") {ReportView(store:store).frame(width:1100,height:900)}
                else {RenderSurface(feed:feed,compact:compact,selection:selection,snapshot:store.snapshot)}
            }.defaultAppStorage(defaults))
            // Render the real AppKit-hosted SwiftUI hierarchy, including native
            // scroll/disclosure controls, in this test process only.
            _=NSApplication.shared
            NSApp.appearance=NSAppearance(named:CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
            let controller=NSHostingController(rootView:content)
            let host=controller.view
            var size=NSSize(width:compact ? 400 : 1100,height:compact ? 700 : 900)
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:CommandLine.arguments.contains("--full-report") ? [.titled,.closable] : .borderless,backing:.buffered,defer:false)
            window.contentViewController=controller;host.frame=NSRect(origin:.zero,size:size)
            host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.2));host.layoutSubtreeIfNeeded()
            func fitCompact() {
                guard compact else{return}
                for _ in 0..<3 {
                    size=NSSize(width:400,height:host.fittingSize.height)
                    precondition(size.height>100 && size.height<800,"Compact fitting height out of bounds: \(size)")
                    window.setContentSize(size);host.frame=NSRect(origin:.zero,size:size)
                    host.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.1))
                }
            }
            fitCompact()
            func click(_ x:CGFloat,_ yFromTop:CGFloat) {
                for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                    let e=NSEvent.mouseEvent(with:type,location:NSPoint(x:x,y:size.height-yFromTop),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
                    if type == .leftMouseDown {host.mouseDown(with:e)} else {host.mouseUp(with:e)}
                }
                RunLoop.main.run(until:Date().addingTimeInterval(0.2));host.layoutSubtreeIfNeeded();fitCompact()
            }
            if CommandLine.arguments.contains("--hover-cell") {
                let e=NSEvent.enterExitEvent(with:.mouseEntered,location:NSPoint(x:130,y:size.height-205),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,trackingNumber:0,userData:nil)!
                host.mouseEntered(with:e)
                RunLoop.main.run(until:Date().addingTimeInterval(0.2));host.layoutSubtreeIfNeeded()
                print("Sent own-host mouseEntered at first Standard tile; compare render to baseline")
            }
            if CommandLine.arguments.contains("--click-empty") {click(330,253);print("Clicked never-run combination; inspect retained overview")}
            if CommandLine.arguments.contains("--click-untimed") {click(130,205);print("Clicked observed untimed Standard cell; inspect exact untimed detail")}
            if CommandLine.arguments.contains("--click-back") {
                for cycle in 0..<3 {click(24,24);if cycle<2 {click(330,205)}}
                print("Sent 3 own-view tier-open/Back cycles; inspect final summary render")
            }
            if let tier=CommandLine.arguments.first(where:{$0.hasPrefix("--click-tier=")}).map({String($0.dropFirst(13))}) {
                click(compact ? (tier=="standard" ? 130 : tier=="fast" ? 230 : 330) : (tier=="standard" ? 270 : tier=="fast" ? 580 : 900),205)
                print("Sent own-view tier bar click:",tier)
            }
            if CommandLine.arguments.contains("--range-refresh-back") {
                click(24,24) // Today detail has no range selector: return to the overview first.
                click(353,54)
                precondition(defaults.string(forKey:"speedTimeRange")=="month")
                click(330,230)
                precondition(size.height>600 && size.height<700,"Expected fixed-height Today detail")
                let before=feed.report.checkedAt
                click(292,size.height-22)
                precondition(feed.report.checkedAt != before && defaults.string(forKey:"speedTimeRange")=="month")
                click(24,24)
                precondition(defaults.string(forKey:"speedTimeRange")=="month")
                print("PASS own-view month selection on overview, Today-only detail, Refresh publication and Back preserve the overview range")
            }
            if CommandLine.arguments.contains("--patterns-toggle") {
                func segmented(_ v:NSView)->NSSegmentedControl? {(v as? NSSegmentedControl) ?? v.subviews.compactMap{segmented($0)}.first}
                func choose(_ index:Int) {
                    guard let control=segmented(host) else {fatalError("Native report segmented picker not found")}
                    precondition(control.segmentCount==2)
                    control.selectedSegment=index
                    precondition(control.sendAction(control.action,to:control.target))
                    RunLoop.main.run(until:Date().addingTimeInterval(0.2));host.layoutSubtreeIfNeeded()
                }
                choose(1);precondition(defaults.string(forKey:"reportSpeedView")=="table")
                if let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) {host.cacheDisplay(in:host.bounds,to:rep);try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[3]+".by-model.png"))}
                choose(0);precondition(defaults.string(forKey:"reportSpeedView")=="patterns")
                print("PASS report native segmented-control target/actions switch Patterns/By model both directions")
            }
            if CommandLine.arguments.contains("--click-patterns") {
                click(340,98)
                precondition(defaults.string(forKey:"reportSpeedView")=="patterns")
                print("PASS compact Patterns link explicitly selects Patterns before requesting the report scene; actual scene opening not hosted here")
            }
            if CommandLine.arguments.contains("--scroll-bottom") {
                func scrollViews(_ view:NSView)->[NSScrollView] {(view as? NSScrollView).map{[$0]} ?? view.subviews.flatMap{scrollViews($0)}}
                let candidates=scrollViews(host)
                for scroll in candidates {
                    guard let doc=scroll.documentView else {continue}
                    scroll.contentView.scroll(to:NSPoint(x:0,y:max(0,doc.bounds.height-scroll.contentView.bounds.height)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                RunLoop.main.run(until:Date().addingTimeInterval(0.2));host.layoutSubtreeIfNeeded()
                print("Scrolled own-view scroll containers to final content:",candidates.count)
            }
            if CommandLine.arguments.contains("--load-more") {
                click(200,466)
                func scrollAll(_ v:NSView) {
                    if let s=v as? NSScrollView,let d=s.documentView {s.contentView.scroll(to:NSPoint(x:0,y:max(0,d.bounds.height-s.contentView.bounds.height)));s.reflectScrolledClipView(s.contentView)}
                    for child in v.subviews {scrollAll(child)}
                }
                host.layoutSubtreeIfNeeded();scrollAll(host);RunLoop.main.run(until:Date().addingTimeInterval(0.2));host.layoutSubtreeIfNeeded()
                print("Clicked Show more and scrolled own view to new final page; inspect remaining count")
            }
            if CommandLine.arguments.contains("--history-roundtrip") {
                click(900,862)
                if let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) {
                    host.cacheDisplay(in:host.bounds,to:rep)
                    try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[3]+".history.png"))
                }
                click(50,40)
                print("Sent own-report History and pinned Back clicks; inspect History and returned speed renders")
            }
            guard let rep=host.bitmapImageRepForCachingDisplay(in:host.bounds) else {fatalError("No bitmap")}
            host.cacheDisplay(in:host.bounds,to:rep)
            guard let png=rep.representation(using:.png,properties:[:]) else {fatalError("No PNG")}
            try png.write(to:URL(fileURLWithPath:CommandLine.arguments[3]))
            print("PASS AppKit-hosted SwiftUI component render",size,"fitting",host.fittingSize);return
        }
        // A same-count, same-latest correction must invalidate a cached cell on refresh.
        do {
            let now=Date(),r=SpeedReading(id:"same",date:Date(),speed:40,outputTokens:200,durationMS:5000)
            let group=SpeedModeGroup(mode:"fast",readings:[r],responseDates:[r.date],latestResponse:r.date)
            let cache=SpeedCellCache();var builds=0
            func value(_ range:SpeedTimeRange,_ moment:Date,_ stamp:Date,_ speed:Double)->Double? {
                cache.model(key:"exact-model-effort-tier",range:range,now:moment,stamp:stamp) {
                    builds+=1;var corrected=group
                    corrected.readings=[SpeedReading(id:r.id,date:r.date,speed:speed,outputTokens:r.outputTokens,durationMS:r.durationMS)]
                    return SpeedCellModel(group:corrected,range:range,history:[],now:moment)
                }.mean
            }
            precondition(value(.day,now,now,40)==40 && value(.day,now,now,80)==40 && builds==1)
            precondition(value(.day,now,now.addingTimeInterval(1),80)==80 && builds==2)
            _=value(.week,now,now.addingTimeInterval(1),80);precondition(builds==3)
            _=value(.week,now.addingTimeInterval(60),now.addingTimeInterval(1),80);precondition(builds==4)
            let a=PatternsKey(model:"M",effort:"high",tier:"fast",minute:1,stamp:now,clock:"24",environment:"zone A")
            let b=PatternsKey(model:"M",effort:"high",tier:"fast",minute:1,stamp:now,clock:"24",environment:"zone B")
            precondition(a != b && !a.sameSelection(as:b))
            var changed=a
            changed.days="weekends";precondition(!a.sameSelection(as:changed))
            changed=a;changed.excluded=[now];precondition(!a.sameSelection(as:changed))
            changed=a;changed=PatternsKey(model:"M",effort:"high",tier:"ultrafast",minute:1,stamp:now,clock:"24",environment:"zone A");precondition(!a.sameSelection(as:changed))
            changed=a;changed=PatternsKey(model:"M",effort:"high",tier:"fast",minute:2,stamp:now.addingTimeInterval(1),clock:"24",environment:"zone A");precondition(a.sameSelection(as:changed))
            print("PASS menu-cell reuse and refresh correction, range/minute invalidation, calendar/clock environment keys")
        }
        // Snapshot sidecar is bounded by unique retained dates and never changes a reply.
        do {
            let dates=["2026-03-08T06:59:59.999Z","2026-03-08T07:00:00Z","2026-11-01T05:30:00Z","2026-11-01T06:30:00Z","2026-10-03T15:29:59Z","2026-10-03T15:30:00Z","2026-11-02T04:59:59.125Z","2026-11-02T05:00:00Z"].map{parseISO($0)!}
            var ny=Calendar(identifier:.gregorian);ny.timeZone=TimeZone(identifier:"America/New_York")!
            let index=ReplyCalendarIndex(dates:dates+dates,calendar:ny)
            precondition(index.fields.count==Set(dates).count && index.matching(ny) === index)
            let zones=["America/New_York","UTC","Asia/Kathmandu","Australia/Lord_Howe","America/Los_Angeles"]
            let readings=dates.enumerated().map {i,date in SpeedReading(id:"same-\(i)",date:date,speed:Double(i+1)*10,outputTokens:300,durationMS:9000,selectedEffort:"xhigh",reportedEffort:"high",effortSource:"parent_turn",ttftMS:1000,inputTokens:300_000)}
            for zone in zones {
                var cal=ny;cal.timeZone=TimeZone(identifier:zone)!
                let prepared=ReplyCalendarIndex(dates:dates,calendar:cal)
                for date in dates {precondition(prepared.day(date)==cal.startOfDay(for:date) && prepared.hour(date)==cal.component(.hour,from:date))}
                if cal != ny {precondition(index.matching(cal)==nil)}
                let a=dayScores(readings,calendar:cal),b=dayScores(readings,calendar:cal,calendarIndex:index),c=dayScores(readings,calendar:cal,calendarIndex:prepared)
                precondition(a==b && b==c)
                let base=clusteredMargin(readings,by:.day,calendar:cal),cached=clusteredMargin(readings,by:.day,calendar:cal,calendarIndex:prepared)
                precondition(base.clusters==cached.clusters && (base.margin==nil ? cached.margin==nil : abs(base.margin!-cached.margin!)<1e-9))
                let hour=clusteredMargin(readings,by:.hour,calendar:cal),hourCached=clusteredMargin(readings,by:.hour,calendar:cal,calendarIndex:prepared)
                precondition(hour.clusters==hourCached.clusters && (hour.margin==nil ? hourCached.margin==nil : abs(hour.margin!-hourCached.margin!)<1e-9))
            }
            var settings=ny;settings.firstWeekday=2;settings.minimumDaysInFirstWeek=4;settings.locale=Locale(identifier:"en_GB")
            let configured=ReplyCalendarIndex(dates:dates,calendar:settings)
            precondition(configured.matching(settings) === configured)
            let newDate=dates[0].addingTimeInterval(91_234.125)
            precondition(index.day(newDate)==ny.startOfDay(for:newDate) && index.hour(newDate)==ny.component(.hour,from:newDate) && index.fields.count==Set(dates).count)
            let updated=ReplyCalendarIndex(dates:[newDate],calendar:ny);precondition(updated.fields.count==1 && updated.fields[dates[0]]==nil)
            _=clockTime(dates[0],twentyFour:true);_=clockTime(dates[0],twentyFour:false)
            precondition(index.matching(ny) === index)
            let calendarForThreads=ny
            DispatchQueue.concurrentPerform(iterations:50) {i in let date=dates[i%dates.count];precondition(index.day(date)==calendarForThreads.startOfDay(for:date) && index.hour(date)==calendarForThreads.component(.hour,from:date))}
            print("PASS bounded immutable calendar sidecar; exact/fractional timestamps; zone/settings invalidation and missing/new-date fallback; spring/fall/half-hour DST; unchanged hourly clustering and clock formatting; concurrent reads")
        }
        // Reference critical values from NIST .975 column, not a speed-spread statistic.
        precondition(abs(tCritical(4)-2.776)<0.00001 && abs(tCritical(11)-2.201)<0.00001)
        precondition(abs(tCritical(31)-2.039513)<0.00001 && abs(tCritical(40)-2.021075)<0.00001 && abs(tCritical(194)-1.9723)<0.0001)
        precondition(marginOfError([])==nil && marginOfError([1,2,3,4])==nil && marginOfError([1,2,3,4,.nan])==nil)
        precondition(abs(marginOfError([10,20,30,40,50])!-2.776*sqrt(250.0)/sqrt(5.0))<0.000001)
        precondition(marginOfError(Array(repeating:50,count:5))==0 && marginText(0)=="±0" && marginText(0.2)=="±<1")
        precondition(tokenText(999)=="999" && tokenText(1000)=="1k" && tokenText(100_000)=="100k" && tokenText(1_000_000)=="1.0M")
        precondition(responseCount(1234)=="1,234 replies" && responseCount(1)=="1 reply" && tierOrder(["standard","weird","fast","ultrafast"])==["standard","fast","ultrafast","weird"])
        print("PASS approximate 95% mean-margin formula/units, NIST critical values, sparse/nonfinite/zero samples, count/token formatting and observed-tier order")
        let columnsNow=Date(timeIntervalSince1970:1800000000)
        let newTier=SpeedModeGroup(mode:"experimental",responseDates:[columnsNow],latestResponse:columnsNow)
        let newModel=SpeedModelGroup(model:"Columns",efforts:[SpeedEffortGroup(effort:"high",modes:[newTier])],latestResponse:columnsNow)
        precondition(overviewTiers([])==["standard","fast","ultrafast"])
        precondition(overviewTiers([newModel,newModel])==["standard","fast","ultrafast","experimental"])
        let oldReport=RecentSpeedReport(models:[newModel]).filtered(range:.hour,now:columnsNow.addingTimeInterval(3601))
        precondition(overviewTiers(oldReport.models)==fixedTierColumns)
        print("PASS shared Standard/Fast/Ultrafast columns; unfamiliar observed tiers preserved once; out-of-window unfamiliar tiers removed")
        var analyticsCal=Calendar(identifier:.gregorian);analyticsCal.timeZone=TimeZone(identifier:"America/New_York")!
        func local(_ month:Int,_ day:Int,_ hour:Int,_ minute:Int=0)->Date {analyticsCal.date(from:DateComponents(year:2026,month:month,day:day,hour:hour,minute:minute))!}
        func analyticReading(_ date:Date,_ speed:Double,_ id:String=UUID().uuidString)->SpeedReading {SpeedReading(id:id,date:date,speed:speed,outputTokens:100,durationMS:10000)}
        let analyticNow=local(10,31,12,30)
        let busyHour=(0..<100).map {i in analyticReading(local(10,31,9).addingTimeInterval(Double(i)),100)}+[analyticReading(local(10,31,10),0),analyticReading(local(10,31,11),0)]
        let robust=clusteredMargin(busyHour,by:.hour,calendar:analyticsCal)
        let mu=10000.0/102.0,score=100*(100-mu),expectedRobust=4.303*sqrt(1.5*(score*score+2*mu*mu)/(102*102))
        precondition(robust.clusters==3 && abs(robust.margin!-expectedRobust)<0.000001 && robust.margin!<20)
        precondition(clusteredMargin(Array(busyHour.prefix(100)),by:.hour,calendar:analyticsCal).margin==nil)
        let todayWindow=[analyticReading(local(10,31,10,45),100),analyticReading(local(10,31,12,15),200)]
        var matchedHistory:[SpeedReading]=[]
        for d in 1...5 {
            matchedHistory += [analyticReading(local(10,31-d,10,45),100),analyticReading(local(10,31-d,12,15),200),analyticReading(local(10,31-d,12,45),99999)]
        }
        matchedHistory += [analyticReading(analyticNow.addingTimeInterval(60),999999),analyticReading(local(10,31,10,45),999999),analyticReading(local(10,1,10,45),999999)]
        let matched=compareToUsual(todayWindow,history:matchedHistory,now:analyticNow,range:.fourHours,calendar:analyticsCal)!
        precondition(matched.days==5 && matched.median==150 && matched.delta==0 && !matched.outside)
        let fourDays=matchedHistory.filter {analyticsCal.component(.day,from:$0.date) != 30}
        precondition(compareToUsual(todayWindow,history:fourDays,now:analyticNow,range:.fourHours,calendar:analyticsCal)==nil)
        let missingHour=matchedHistory.filter {!($0.date==local(10,30,12,15))}
        precondition(compareToUsual(todayWindow,history:missingHour,now:analyticNow,range:.fourHours,calendar:analyticsCal)==nil)
        precondition(compareToUsual(todayWindow,history:matchedHistory,now:analyticNow,range:.day,calendar:analyticsCal)==nil)
        let slowPast=matchedHistory.map {r in analyticReading(r.date,r.speed/2,r.id)}
        precondition(compareToUsual(todayWindow,history:slowPast,now:analyticNow,range:.fourHours,calendar:analyticsCal)!.outside)
        let midnightNow=local(10,31,0,30),midnightWindow=[analyticReading(local(10,30,23,45),10),analyticReading(local(10,31,0,15),30)]
        var midnightHistory:[SpeedReading]=[]
        for d in 1...5 {midnightHistory += [analyticReading(analyticsCal.date(byAdding:.day,value:-d,to:local(10,30,23,45))!,10),analyticReading(analyticsCal.date(byAdding:.day,value:-d,to:local(10,31,0,15))!,30)]}
        let midnight=compareToUsual(midnightWindow,history:midnightHistory,now:midnightNow,range:.hour,calendar:analyticsCal)!
        precondition(midnight.days==5 && midnight.median==20)
        let firstFall=parseISO("2026-11-01T05:30:00Z")!,secondFall=parseISO("2026-11-01T06:30:00Z")!
        precondition(analyticsCal.component(.hour,from:firstFall)==1 && analyticsCal.component(.hour,from:secondFall)==1)
        precondition(clusterKey(firstFall,.hour,calendar:analyticsCal) != clusterKey(secondFall,.hour,calendar:analyticsCal))
        precondition(clusterKey(firstFall,.day,calendar:analyticsCal)==clusterKey(secondFall,.day,calendar:analyticsCal))
        precondition(local(11,2,0).timeIntervalSince(local(11,1,0))==90000 && local(3,9,0).timeIntervalSince(local(3,8,0))==82800)
        let fallRows=[analyticReading(local(11,1,0,15),10),analyticReading(firstFall,20),analyticReading(secondFall,30),analyticReading(local(11,1,23,40),40),analyticReading(local(11,2,0,5),999)]
        let fallMode=SpeedModeGroup(mode:"fast",readings:fallRows,responseDates:fallRows.map(\.date),latestResponse:fallRows.last!.date)
        let fallModel=SpeedModelGroup(model:"DST",efforts:[SpeedEffortGroup(effort:"xhigh",modes:[fallMode])],latestResponse:fallRows.last!.date)
        let fallReport=RecentSpeedReport(models:[fallModel])
        let selectedToday=fallReport.todayGroup(for:SpeedSelection(model:"DST",effort:"xhigh",mode:"fast"),now:local(11,1,23,45),calendar:analyticsCal)
        precondition(selectedToday.readings.count==4 && selectedToday.stats().mean==25)
        precondition(fallReport.busiestModel(since:local(12,1,0),until:local(12,2,0))==nil)
        let pairDate=local(10,30,10)
        func modeRows(_ mode:String,_ speed:Double)->SpeedModeGroup {let rs=(0..<5).map {i in analyticReading(pairDate.addingTimeInterval(Double(i)),speed)};return SpeedModeGroup(mode:mode,readings:rs,responseDates:rs.map(\.date),latestResponse:pairDate)}
        let highFast=SpeedEffortGroup(effort:"high",modes:[modeRows("fast",10)])
        let extraUltra=SpeedEffortGroup(effort:"xhigh",modes:[modeRows("ultrafast",999)])
        let mismatchedModel=SpeedModelGroup(model:"Pair",efforts:[highFast,extraUltra],latestResponse:pairDate)
        precondition(pairedTierComparison(RecentSpeedReport(models:[mismatchedModel]),model:"Pair",start:local(10,17,0),end:local(10,31,0),calendar:analyticsCal)==nil)
        let matchedHigh=SpeedEffortGroup(effort:"high",modes:[modeRows("fast",10),modeRows("ultrafast",20)])
        let pairedReport=RecentSpeedReport(models:[SpeedModelGroup(model:"Pair",efforts:[matchedHigh,extraUltra],latestResponse:pairDate)])
        let pair=pairedTierComparison(pairedReport,model:"Pair",start:local(10,17,0),end:local(10,31,0),calendar:analyticsCal)!
        precondition(pair.cells==1 && pair.days==1 && pair.firstMean==20 && pair.secondMean==10)
        precondition(pairedTierComparison(pairedReport,model:"Pair",effort:"high",start:local(10,17,0),end:local(10,31,0),calendar:analyticsCal) != nil)
        precondition(pairedTierComparison(pairedReport,model:"Pair",effort:"xhigh",start:local(10,17,0),end:local(10,31,0),calendar:analyticsCal)==nil)
        let busy=pairedReport.busiestPair(since:local(10,17,0),until:local(10,31,0))!
        precondition(busy.model=="Pair" && busy.effort=="high" && busy.tier=="fast")
        precondition(pairedReport.effortReadings(model:"Pair",effort:"high",mode:"ultrafast").allSatisfy{$0.speed==20})
        // Usual bands follow the usual's rule: 5+ past days, each with 3+ responses in that hour.
        precondition(pastHourBands(matchedHistory,now:analyticNow,calendar:analyticsCal).isEmpty)
        var bandHistory:[SpeedReading]=[]
        for d in 1...5 {bandHistory += (0..<3).map {i in analyticReading(local(10,31-d,10,5+i*10),Double(90+d*2))}+(0..<3).map {i in analyticReading(local(10,31-d,11,5+i*10),50)}}
        bandHistory += (0..<3).map {i in analyticReading(local(10,25,11,5+i*10),50)}   // 6th day only for 11:00
        let bands=pastHourBands(bandHistory,now:analyticNow,calendar:analyticsCal)
        precondition(bands.count==2 && bands.first{$0.hour==10}!.mid==96 && bands.first{$0.hour==11}!.mid==50)
        precondition(pastHourBands(bandHistory.filter {analyticsCal.component(.day,from:$0.date) != 30},now:analyticNow,calendar:analyticsCal).map(\.hour)==[11])
        // Chart: 5 gridlines at round steps; high / low / now labels without duplicates.
        precondition(chartStep(77)==20 && chartStep(100)==25 && chartStep(150)==40 && chartStep(18)==5)
        let pts=[HourPoint(hour:0,mean:72),HourPoint(hour:10,mean:54),HourPoint(hour:16,mean:47),HourPoint(hour:19,mean:55)]
        let labels=chartLabels(pts,currentHour:19)
        precondition(labels.count==3 && labels[0].hour==19 && labels[0].kind == .now && labels[1].hour==0 && labels[1].kind == .high && labels[2].hour==16 && labels[2].kind == .low)
        precondition(chartLabels([HourPoint(hour:3,mean:40)],currentHour:9).count==1 && chartLabels([],currentHour:9).isEmpty)
        precondition(chartLabels([HourPoint(hour:9,mean:70),HourPoint(hour:10,mean:40)],currentHour:9).count==2)
        let lay=HourChartLayout(size:CGSize(width:270,height:180),ceiling:80)
        precondition(lay.hour(at:30)==0 && lay.hour(at:29+240) == 23 && lay.hour(at:30+10*10+1)==10 && lay.hour(at:-50)==0 && lay.y(0)==160 && lay.y(80)==10)
        precondition(hourClock(7,twentyFour:true)=="07:00" && hourClock(7,twentyFour:false)=="7am" && hourClock(0,twentyFour:false)=="12am" && hourClock(12,twentyFour:false)=="12pm" && hourClock(18,twentyFour:false)=="6pm")
        precondition(hourTick(3,twentyFour:true)=="03" && hourTick(15,twentyFour:false)=="3p" && hourTick(0,twentyFour:false)=="12a")
        precondition(!clockIs24Hour("12") && clockIs24Hour("24") && !clockIs24Hour("system",locale:Locale(identifier:"en_US")) && clockIs24Hour("system",locale:Locale(identifier:"en_GB")))
        precondition(clockPattern(seconds:true,twentyFour:false)=="h:mm:ss a" && clockPattern(seconds:false,twentyFour:true)=="HH:mm")
        precondition(detailWindowTitle(.fourHours)=="Last 4h" && detailWindowTitle(.day)=="Today")
        // "~ rough": wide margin (15%+), no margin, or fewer than 3 hours/days.
        precondition(!isRoughAverage(mean:41,margin:6,clusters:5) && isRoughAverage(mean:39,margin:7,clusters:5))
        precondition(isRoughAverage(mean:100,margin:nil,clusters:5) && isRoughAverage(mean:100,margin:1,clusters:2) && isRoughAverage(mean:nil,margin:1,clusters:9))
        // Usual: same clock window on each past day, day counts with 3+ responses, needs 5+ days.
        var uHistory:[SpeedReading]=[]
        for (d,speed) in [(1,80.0),(2,90.0),(3,100.0),(4,110.0),(5,120.0)] {
            let base=analyticsCal.date(byAdding:.day,value:-d,to:analyticNow)!
            uHistory += (1...3).map {i in analyticReading(base.addingTimeInterval(-Double(i)*600),speed)}
            uHistory.append(analyticReading(base.addingTimeInterval(-7200),9999))   // outside the 1h window
        }
        let sixth=analyticsCal.date(byAdding:.day,value:-6,to:analyticNow)!
        uHistory += [analyticReading(sixth.addingTimeInterval(-600),9999),analyticReading(sixth.addingTimeInterval(-900),9999)]   // only 2 responses
        uHistory.append(analyticReading(analyticNow.addingTimeInterval(-300),9999))   // today never counts
        let u=usualBaseline(uHistory,start:analyticNow.addingTimeInterval(-3600),now:analyticNow,calendar:analyticsCal)
        precondition(u.days==5 && u.baseline!.median==100 && abs(u.baseline!.lo-84)<1e-9 && abs(u.baseline!.hi-116)<1e-9)
        let fourUsualDays=usualBaseline(Array(uHistory.prefix(16)),start:analyticNow.addingTimeInterval(-3600),now:analyticNow,calendar:analyticsCal)
        precondition(fourUsualDays.baseline==nil && fourUsualDays.days==4)
        // ▲/▼: 10+ responses now and 10%+ beyond the normal range (84–116 → above 127.6 / below 75.6).
        let now10=(0..<10).map {i in analyticReading(analyticNow.addingTimeInterval(-Double(i)*60),128)}
        precondition(speedMarker(now10,baseline:u.baseline) == .faster)
        precondition(speedMarker(now10.map {analyticReading($0.date,127)},baseline:u.baseline)==nil)
        precondition(speedMarker(Array(now10.prefix(9)),baseline:u.baseline)==nil)
        precondition(speedMarker(now10.map {analyticReading($0.date,75)},baseline:u.baseline) == .slower)
        precondition(speedMarker(now10.map {analyticReading($0.date,76)},baseline:u.baseline)==nil)
        precondition(speedMarker(now10,baseline:nil)==nil)
        precondition(showsMarkers(.hour) && showsMarkers(.fourHours) && showsMarkers(.twelveHours) && !showsMarkers(.day) && !showsMarkers(.week))
        precondition(!hasStrongRank(5,days:5) && !hasStrongRank(8,days:10) && hasStrongRank(9,days:10) && !hasStrongRank(0,days:0))
        precondition(Set(speedBlockStarts).count==8 && speedBlockStarts[0]=="00:00" && speedBlockStarts[4]=="12:00" && blockLabel(7,twentyFour:true)=="21:00–24:00" && blockLabel(0,twentyFour:false)=="12–3am" && blockStart(4,twentyFour:false)=="12pm")
        // First-output wait vs estimated generating speed: wait = median, generating = total tokens ÷ residual time.
        func timed(_ date:Date,_ speed:Double,out:Int64,dur:Double,ttft:Double?,input:Int64?=100_000)->SpeedReading {var r=SpeedReading(id:UUID().uuidString,date:date,speed:speed,outputTokens:out,durationMS:dur);r.ttftMS=ttft;r.inputTokens=input;return r}
        let t1=timed(local(10,27,9),80,out:400,dur:5000,ttft:1000),t2=timed(local(10,27,9,5),33,out:100,dur:3000,ttft:2000)
        precondition(t1.waitSeconds==1 && t1.generatingSeconds==4 && t1.generatingSpeed==100 && timed(local(10,27,9),1,out:100,dur:5000,ttft:nil).waitSeconds==nil && timed(local(10,27,9),1,out:100,dur:5000,ttft:6000).generatingSeconds==nil)
        let split=timingSplit([t1,t2])!
        precondition(split.wait==1.5 && split.generating==100 && timingSplit([timed(local(10,27,9),1,out:100,dur:5000,ttft:nil)])==nil)
        precondition(split.responses==2)
        let partialTiming=timingSplit([timed(local(10,27,9),40,out:200,dur:5000,ttft:1000)]+(0..<20).map {_ in timed(local(10,27,9),40,out:200,dur:5000,ttft:nil)})!
        precondition(partialTiming.responses==1 && timingMarker(partialTiming.generating,lo:10,hi:20,longerIsSlower:false,responses:partialTiming.responses)==nil)
        let enoughTiming=timingSplit((0..<markerMinResponses).map {_ in timed(local(10,27,9),40,out:200,dur:5000,ttft:1000)})!
        precondition(enoughTiming.responses==markerMinResponses && timingMarker(enoughTiming.generating,lo:10,hi:20,longerIsSlower:false,responses:enoughTiming.responses) == .faster)

        var timingHistory:[SpeedReading]=[]
        for d in 1...5 {timingHistory += (0..<3).map {i in timed(local(10,31-d,11,i*10),50,out:500,dur:Double(5000+d*1000),ttft:Double(1000+d*100))}}
        let ut=usualTiming(timingHistory,start:local(10,31,10),now:local(10,31,12),calendar:analyticsCal)!
        precondition(ut.days==5 && abs(ut.wait-1.3)<1e-9 && usualTiming(Array(timingHistory.prefix(12)),start:local(10,31,10),now:local(10,31,12),calendar:analyticsCal)==nil)
        precondition(timingMarker(2.0,lo:1.2,hi:1.7,longerIsSlower:true) == .slower && timingMarker(1.8,lo:1.2,hi:1.7,longerIsSlower:true)==nil && timingMarker(30,lo:41,hi:72,longerIsSlower:false) == .slower && timingMarker(80,lo:41,hi:72,longerIsSlower:false) == .faster)
        // Tier comparison: matched windows only (same day, 3-hour block, reply-length band, context band), 3+ per tier.
        precondition(replyLengthBand(299)==0 && replyLengthBand(300)==1 && replyLengthBand(999)==1 && replyLengthBand(1000)==2 && replyLengthBand(3000)==3)
        // Timing colors obey the same current-response minimum as the main marker.
        precondition(timingMarker(2.0,lo:1.2,hi:1.7,longerIsSlower:true,responses:9)==nil)
        precondition(timingMarker(2.0,lo:1.2,hi:1.7,longerIsSlower:true,responses:10) == .slower)
        precondition(timingMarker(80,lo:41,hi:72,longerIsSlower:false,responses:9)==nil)
        precondition(timingMarker(80,lo:41,hi:72,longerIsSlower:false,responses:10) == .faster)
        precondition(comparisonStrength(windows:0,days:0,wins:0,from:"standard",to:"fast").0 == .noWindows)
        precondition(comparisonStrength(windows:2,days:2,wins:2,from:"standard",to:"fast")==(.notEnough,"Needs 3 windows · 2 so far"))
        precondition(comparisonStrength(windows:3,days:1,wins:3,from:"fast",to:"ultrafast")==(.notEnough,"Needs 2 days · 1 so far"))
        precondition(comparisonStrength(windows:3,days:2,wins:3,from:"fast",to:"ultrafast")==(.early,"Ultrafast ahead in 3 of 3 · 2 days"))
        precondition(comparisonStrength(windows:3,days:2,wins:2,from:"standard",to:"fast")==(.notEnough,"Mixed so far · 2 of 3"))
        precondition(comparisonStrength(windows:5,days:3,wins:5,from:"standard",to:"fast").0 == .solid && comparisonStrength(windows:5,days:3,wins:3,from:"standard",to:"fast").0 == .mixed)
        precondition(comparisonStrength(windows:5,days:3,wins:0,from:"standard",to:"fast")==(.solid,"Standard ahead in 5 of 5 · 3 days"))
        var stdRows:[SpeedReading]=[],fastRows:[SpeedReading]=[]
        for d in 1...3 {
            stdRows += (0..<3).map {i in timed(local(10,27-d,9,i*10),40,out:500,dur:12500,ttft:2500)}
            fastRows += (0..<3).map {i in timed(local(10,27-d,10,i*10),50,out:500,dur:10000,ttft:1500)}
        }
        stdRows += (0..<3).map {i in timed(local(10,20,15,i*10),40,out:500,dur:12500,ttft:2500)}
        fastRows += (0..<3).map {i in timed(local(10,20,16,i*10),99,out:500,dur:10000,ttft:1500,input:300_000)}   // different context: not matched
        fastRows += (0..<3).map {i in timed(local(10,24,10,i*10),99,out:2000,dur:10000,ttft:1500)}              // longer replies: not matched
        let cmp=tierComparison({$0=="standard" ? stdRows : fastRows},from:"standard",to:"fast",start:local(10,17,0),end:local(10,31,0),calendar:analyticsCal)
        precondition(cmp.windows==3 && cmp.days==3 && cmp.wins==3 && cmp.speedRatio==1.25 && cmp.fromSpeed==40 && cmp.toSpeed==50 && cmp.cost==2.5 && cmp.responses==18)
        precondition(cmp.strength.0 == .early && cmp.fromTiming!.wait==2.5 && cmp.fromTiming!.generating==50 && cmp.toTiming!.wait==1.5 && cmp.byLength.count==1 && cmp.byLength[0].band==1 && cmp.fromContext==100_000)
        precondition(typicalReplySeconds(cmp.fromTiming!,tokens:500)==12.5 && abs(typicalReplySeconds(cmp.toTiming!,tokens:500)-10)<1e-9)
        precondition(gainSource(from:cmp.fromTiming!,to:cmp.toTiming!,tokens:500)=="faster generating (est.) and shorter first output wait")
        precondition(gainSource(from:TimingSplit(wait:1.5,generating:60),to:TimingSplit(wait:2.5,generating:140),tokens:750)=="faster generating (est.), longer first output wait")
        precondition(gainSource(from:TimingSplit(wait:2.5,generating:60),to:TimingSplit(wait:2.4,generating:140),tokens:750)=="mostly faster generating (est.)")
        precondition(tierComparison({_ in []},from:"fast",to:"ultrafast",start:local(10,17,0),end:local(10,31,0),calendar:analyticsCal).strength.0 == .noWindows)
        // "Is it worth it?": every tier judged against Standard; value = speed ÷ usage.
        precondition(valueGrade(speed:1.4,usage:2.5) == .poor && valueGrade(speed:2.6,usage:2.5) == .fair && valueGrade(speed:4,usage:2.5) == .good)
        precondition(efficiencyText(0.56)=="½" && efficiencyText(0.25)=="¼" && efficiencyText(0.42)=="0.4×" && efficiencyText(1.02)=="Same")
        precondition(speedWord(2.0)=="Much faster" && speedWord(1.2)=="Faster" && speedWord(1.0)=="About the same" && speedWord(0.9)=="Slower")
        precondition(verdictChip(cmp)=="Faster · poor value" && tierHeadline([cmp])=="Fast is faster but poor value.")
        let worth=worthSentence(cmp,tokens:500)
        precondition(worth.hasPrefix("Worth it only when you’re waiting on the answer. A typical reply takes 10 s instead of") && worth.hasSuffix("but every reply uses 2.5× the usage."))
        let noStd=tierComparison({_ in []},from:"standard",to:"ultrafast",start:local(10,17,0),end:local(10,31,0),calendar:analyticsCal)
        precondition(verdictChip(noStd)=="Not compared yet" && tierHeadline([noStd])=="Ultrafast hasn’t been compared with Standard yet." && worthSentence(noStd,tokens:800)=="No answer yet. Use Ultrafast and Standard within the same hour to compare them.")
        // Time saved vs Standard: estimated Standard time (wait + tokens ÷ generating) minus real time; 80% range by re-drawing windows.
        precondition(cmp.fromWindows.count==3 && standardEstimateSeconds(fastRows[0],standard:cmp.fromTiming!)==12.5)
        let saved=savedTime(Array(fastRows.prefix(9)),standardWindows:cmp.fromWindows)!
        precondition(saved.seconds==22.5 && saved.lo==22.5 && saved.hi==22.5 && saved.replies==9)
        precondition(savedTime(fastRows,standardWindows:Array(cmp.fromWindows.prefix(2)))==nil)
        // Combined ranges are quantiles of draw totals, never sums of marginal quantiles.
        func bootstrapWindow(_ id:String,_ seconds:Double)->[SpeedReading] {
            (0..<3).map {i in SpeedReading(id:id+"-"+String(i),date:local(10,27,9,i*10),speed:1000/seconds,outputTokens:1000,durationMS:seconds*1000,ttftMS:1000,inputTokens:100_000)}
        }
        let bw=[bootstrapWindow("s0",10),bootstrapWindow("s1",20),bootstrapWindow("s2",40)]
        let otherBW=[bootstrapWindow("t0",10),bootstrapWindow("t1",20),bootstrapWindow("t2",40)]
        let br=[timed(local(10,27,9),100,out:500,dur:5000,ttft:1000)]
        let component=SavedTimeComponent(replies:br,standardWindows:bw)
        let marginal=savedTime(br,standardWindows:bw)!
        let shared=combinedSavedTime([component,component])!
        let sharedReference=savedTime(br+br,standardWindows:bw)!
        precondition(shared.seconds==marginal.seconds+marginal.seconds && shared.replies==2)
        precondition(shared.bootstrapEstimates.count==300 && abs(shared.lo-sharedReference.lo)<1e-9 && abs(shared.hi-sharedReference.hi)<1e-9)
        let independent=combinedSavedTime([component,SavedTimeComponent(replies:br,standardWindows:otherBW)])!
        precondition(independent.seconds==shared.seconds && independent.replies==shared.replies)
        precondition(independent.lo==percentile(independent.bootstrapEstimates,0.1) && independent.hi==percentile(independent.bootstrapEstimates,0.9))
        precondition(abs(independent.lo-2*marginal.lo)>1e-6 || abs(independent.hi-2*marginal.hi)>1e-6)
        precondition(independent.bootstrapEstimates != shared.bootstrapEstimates)
        let one=combinedSavedTime([component])!
        precondition(one.seconds==marginal.seconds && one.lo==marginal.lo && one.hi==marginal.hi)
        let repeated=combinedSavedTime([component,SavedTimeComponent(replies:br,standardWindows:otherBW)])!
        precondition(repeated.bootstrapEstimates==independent.bootstrapEstimates)
        let partial=SavedTimeComponent(replies:br,standardWindows:[bw[0],bw[1],otherBW[2]])
        let overlap=combinedSavedTime([component,partial])!
        precondition(overlap.seconds==marginal.seconds+savedTime(br,standardWindows:partial.standardWindows)!.seconds && overlap.bootstrapEstimates.count==300)
        let reversed=combinedSavedTime([SavedTimeComponent(replies:br,standardWindows:Array(bw.reversed())),partial])!
        precondition(reversed.bootstrapEstimates==overlap.bootstrapEstimates)
        let added=combinedSavedTime([SavedTimeComponent(replies:[timed(local(10,27,9),10,out:500,dur:100_000,ttft:1000)],standardWindows:bw)])!
        precondition(added.seconds<0 && added.lo<0 && added.hi<0)
        precondition(combinedSavedTime([])==nil && combinedSavedTime([SavedTimeComponent(replies:[],standardWindows:bw)])==nil)
        precondition(combinedSavedTime([SavedTimeComponent(replies:br,standardWindows:Array(bw.prefix(2)))])==nil)
        let eligibleOnly=combinedSavedTime([component,SavedTimeComponent(replies:br,standardWindows:[])])!
        precondition(eligibleOnly.seconds==marginal.seconds && eligibleOnly.replies==1)
        precondition(durationText(40)=="40 s" && durationText(2760)=="46 min" && durationText(4320)=="1 h 12 min" && durationText(-120)=="2 min")
        precondition(durationRangeText(2280,3300)=="38–55 min" && durationRangeText(-60,120)=="between 1 min lost and 2 min saved")
        precondition(durationRangeText(-300,-120)=="2–5 min added" && durationRangeText(-120,-300)=="2–5 min added")
        let mix=[timed(local(10,27,9),50,out:100,dur:5000,ttft:1000),timed(local(10,27,9),50,out:300,dur:5000,ttft:1000)]
        precondition(usageVersusStandard(mix) {$0.outputTokens==100 ? "fast" : "ultrafast"}==6.625)
        precondition(durationRangeText(35100,53100)=="10–15 h")
        // Report data is built once (background) from an index; time it on ~12k synthetic readings.
        do {
            let perfNow=local(10,31,21,0)
            var modes:[SpeedModeGroup]=[]
            var total=0
            for (ti,tier) in ["standard","fast","ultrafast"].enumerated() {
                var rs:[SpeedReading]=[]
                for d in 0..<14 {for i in 0..<280 {
                    let date=perfNow.addingTimeInterval(-Double(d)*86400-Double(i)*300)
                    let out=Int64(300+(i*37)%1700),base=[40.0,55,100][ti]
                    rs.append(timed(date,base+Double((i*13)%20)-10,out:out,dur:Double(out)/base*1000+[2500,1500,2400][ti],ttft:[2500,1500,2400][ti]))
                }}
                total+=rs.count
                modes.append(SpeedModeGroup(mode:tier,readings:rs,responseDates:rs.map(\.date),latestResponse:rs.map(\.date).max()!))
            }
            let perfReport=RecentSpeedReport(models:[SpeedModelGroup(model:"Perf",efforts:[SpeedEffortGroup(effort:"high",modes:modes)],latestResponse:perfNow)])
            let key=PatternsKey(model:"Perf",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24")
            let t0=Date()
            let pd=PatternsData.build(report:perfReport,key:key,now:perfNow,calendar:analyticsCal)
            let ms=Date().timeIntervalSince(t0)*1000
            precondition(pd.speedRows.count==3 && pd.worthRows.count==5 && (pd.speedRows+pd.worthRows).allSatisfy {$0.cells.count==3} && pd.fast.windows>0 && pd.ultrafast.windows>0 && pd.savedUltraWeek != nil && pd.grid.days.count==14)
            precondition(pd.worthRows[0].cells[0].value=="Baseline" && pd.worthRows[0].tall && pd.speedRows[1].cells[2].value.hasSuffix("t/s") && !pd.hoursAnswer.isEmpty)
            precondition(pd.weekdayStrip.days.count==7 && pd.weekdayStrip.weekdays.days+pd.weekdayStrip.weekends.days==(pd.grid.genDayScores.isEmpty ? pd.grid.dayScores : pd.grid.genDayScores).count)
            // Left-out days scope every section; the Days filter only scopes "Slow and fast hours".
            let weekendKey=PatternsKey(model:"Perf",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24",days:"weekends")
            let we=PatternsData.build(report:perfReport,key:weekendKey,now:perfNow,calendar:analyticsCal)
            precondition(!we.grid.days.isEmpty && we.grid.days.allSatisfy {analyticsCal.isDateInWeekend($0)} && we.grid.dayScores.keys.allSatisfy {analyticsCal.isDateInWeekend($0)})
            precondition(we.worthRows.map {$0.cells.map(\.value)}==pd.worthRows.map {$0.cells.map(\.value)} && we.fast.windows==pd.fast.windows && we.hoursAnswer.hasPrefix("Weekends only. "))
            let leftOut=analyticsCal.startOfDay(for:perfNow.addingTimeInterval(-2*86400))
            let lo=PatternsData.build(report:perfReport,key:PatternsKey(model:"Perf",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24",excluded:[leftOut]),now:perfNow,calendar:analyticsCal)
            precondition(!lo.grid.days.contains(leftOut) && lo.grid.days.count==13 && lo.grid.dayScores[leftOut]==nil)
            let today=analyticsCal.startOfDay(for:perfNow)
            let withoutToday=PatternsData.build(report:perfReport,key:PatternsKey(model:"Perf",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24",excluded:[perfNow]),now:perfNow,calendar:analyticsCal)
            precondition(withoutToday.speedRows[0].cells.allSatisfy {$0.value=="Left out" && $0.dim && $0.tone==nil && $0.sub.isEmpty} && withoutToday.speedAnswer.isEmpty)
            precondition(!withoutToday.grid.days.contains(today) && withoutToday.grid.cells[today]==nil && withoutToday.grid.dayScores[today]==nil)
            for i in 0..<3 {
                precondition(we.speedRows[0].cells[i].value==pd.speedRows[0].cells[i].value && we.speedRows[0].cells[i].sub==pd.speedRows[0].cells[i].sub)
                // The Days filter is local to "Slow and fast hours": the tables above don't change.
                precondition(we.speedRows[1].cells[i].value==pd.speedRows[1].cells[i].value && we.speedRows[2].cells[i].value==pd.speedRows[2].cells[i].value)
            }
            func dropping(_ rejected:Set<Date>)->RecentSpeedReport {
                let groups=modes.map {g->SpeedModeGroup in var copy=g;copy.readings=g.readings.filter {!rejected.contains(analyticsCal.startOfDay(for:$0.date))};return copy}
                return RecentSpeedReport(models:[SpeedModelGroup(model:"Perf",efforts:[SpeedEffortGroup(effort:"high",modes:groups)],latestResponse:perfNow)])
            }
            // Compare the entire projected report with physically removing an exact historical date.
            let reference=PatternsData.build(report:dropping([leftOut]),key:key,now:perfNow,calendar:analyticsCal)
            for (actual,expected) in zip(lo.speedRows+lo.worthRows,reference.speedRows+reference.worthRows) {
                precondition(actual.cells.map(\.value)==expected.cells.map(\.value) && actual.cells.map(\.sub)==expected.cells.map(\.sub) && actual.cells.map(\.dim)==expected.cells.map(\.dim))
            }
            precondition(lo.speedAnswer==reference.speedAnswer && lo.worthAnswer==reference.worthAnswer && lo.hoursAnswer==reference.hoursAnswer && lo.typicalTokens==reference.typicalTokens)
            precondition(lo.fast.fromWindows.flatMap{$0}.allSatisfy {analyticsCal.startOfDay(for:$0.date) != leftOut} && lo.ultrafast.fromWindows.flatMap{$0}.allSatisfy {analyticsCal.startOfDay(for:$0.date) != leftOut})
            precondition(lo.fast.windows==reference.fast.windows && lo.ultrafast.windows==reference.ultrafast.windows && lo.savedFastWeek?.seconds==reference.savedFastWeek?.seconds && lo.savedUltraWeek?.bootstrapEstimates==reference.savedUltraWeek?.bootstrapEstimates)
            precondition(lo.grid.dayScores==reference.grid.dayScores && lo.weekday==reference.weekday && lo.weekdayStrip.days.map(\.days)==reference.weekdayStrip.days.map(\.days))
            let allDays=Set(modes.flatMap(\.readings).map {analyticsCal.startOfDay(for:$0.date)})
            let keep=analyticsCal.date(byAdding:.day,value:-2,to:today)!
            let early=PatternsData.build(report:dropping(allDays.subtracting([keep])),key:key,now:perfNow,calendar:analyticsCal)
            precondition(!settled(early.fast.strength.0) && early.savedFastWeek?.bootstrapEstimates.isEmpty==true)
            precondition(early.worthRows[0].cells[1].dim && !early.worthRows[0].cells[1].value.contains("poor") && early.worthRows[3].cells[1].dim && !early.worthRows[3].cells[1].sub.contains("likely"))
            // An excluded local day removes both repeated fall-back hours, even when keyed by midday.
            let dstMode=SpeedModeGroup(mode:"fast",readings:[analyticReading(firstFall,10),analyticReading(secondFall,20)],responseDates:[firstFall,secondFall],latestResponse:secondFall)
            let dstReport=RecentSpeedReport(models:[SpeedModelGroup(model:"DST",efforts:[SpeedEffortGroup(effort:"high",modes:[dstMode])],latestResponse:secondFall)])
            let dst=PatternsData.build(report:dstReport,key:PatternsKey(model:"DST",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24",excluded:[local(11,1,12)]),now:local(11,2,12),calendar:analyticsCal)
            precondition(dst.grid.days.isEmpty && dst.speedRows[1].cells[1].value=="—")
            let baselineNow=local(11,2,12,30),baselineToday=analyticsCal.startOfDay(for:baselineNow)
            var baselineRows:[SpeedReading]=[]
            for d in 0...5 {for h in 9...11 {for minute in [0,10,20] {
                let date=analyticsCal.date(byAdding:.day,value:-d,to:local(11,2,h,minute))!
                baselineRows.append(analyticReading(date,d==0 ? 30 : Double(d*10)))
            }}}
            let baselineMode=SpeedModeGroup(mode:"fast",readings:baselineRows,responseDates:baselineRows.map(\.date),latestResponse:baselineNow)
            let baselineReport=RecentSpeedReport(models:[SpeedModelGroup(model:"Baseline",efforts:[SpeedEffortGroup(effort:"high",modes:[baselineMode])],latestResponse:baselineNow)])
            let baselineKey=PatternsKey(model:"Baseline",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24",days:"weekdays")
            let beforeDrop=PatternsData.build(report:baselineReport,key:baselineKey,now:baselineNow,calendar:analyticsCal)
            var dropKey=baselineKey;dropKey.excluded=[local(11,1,12)]
            let afterDrop=PatternsData.build(report:baselineReport,key:dropKey,now:baselineNow,calendar:analyticsCal)
            precondition(!beforeDrop.speedRows[0].cells[1].sub.contains("no usual yet") && afterDrop.speedRows[0].cells[1].sub.contains("no usual yet · 4 of 5 days"))
            precondition(afterDrop.speedRows[0].cells[1].value=="30 t/s" && !afterDrop.grid.cells.keys.contains(baselineToday.addingTimeInterval(-86400)))
            precondition(lo.fast.fromWindows.map{$0.map(\.id)}==reference.fast.fromWindows.map{$0.map(\.id)})
            print("PASS v4 explicit exclusions in every report path/Today baseline; excluded Today is Left out with no comparison; Days filter leaves Today unchanged; independent filtered counts/means; complete projected-report exclusion equivalence; settled-only ranges; DST repeated-hour exclusion")
            print("PERF PatternsData.build: \(Int(ms)) ms for \(total) readings (built once per data/selection change, off the main thread)")
        }
        // v4 report helpers: day filter, day scores, weekday strip, wording.
        precondition(DayFilter.weekends.includes(local(10,31,12),calendar:analyticsCal) && !DayFilter.weekdays.includes(local(10,31,12),calendar:analyticsCal) && DayFilter.weekdays.includes(local(10,27,12),calendar:analyticsCal) && DayFilter.all.includes(local(10,31,12),calendar:analyticsCal))
        var scoreRows:[SpeedReading]=[]
        for h in 9...11 {
            scoreRows += (0..<3).map {i in analyticReading(local(10,27,h,i*10),50)}+(0..<3).map {i in analyticReading(local(10,26,h,i*10),100)}
        }
        scoreRows += (0..<3).map {i in analyticReading(local(10,25,13,i*10),80)}+(0..<3).map {i in analyticReading(local(10,25,14,i*10),80)}   // only 2 hours: no score
        let ds=dayScores(scoreRows,calendar:analyticsCal)
        precondition(ds.count==2 && abs(ds[local(10,27,0)]!-50.0/75.0)<1e-9 && abs(ds[local(10,26,0)]!-100.0/75.0)<1e-9 && ds[local(10,25,0)]==nil)
        let ws=weekdayScores(ds,calendar:analyticsCal)
        precondition(ws.days.count==7 && ws.days[0].label=="Mon" && ws.days[0].days==1 && ws.days[1].days==1 && ws.weekdays.days==2 && ws.weekends.days==0 && ws.weekends.score==nil)
        precondition(percentText(1.04)=="+4%" && percentText(0.95)=="−5%" && percentText(1.0)=="0%")
        precondition(approxDuration(36600)=="~10 h" && approxDuration(9000)=="~2½ h" && approxDuration(1500)=="~25 min" && approxDuration(45)=="~45 s" && approxDuration(2700*2)=="~1½ h")
        precondition(todayCell([],now:local(10,31,12),calendar:analyticsCal).cell.value=="—")
        precondition(speedRatioText(1.4)=="1.4× faster" && speedRatioText(0.88)=="1.1× slower" && speedRatioText(1.02)=="Same speed")
        precondition(multiplierText(8)=="8×" && multiplierText(3.2)=="3.2×" && multiplierText(2.5)=="2.5×")
        precondition(secondsPairText(12.56,13.04)=="12.6 s → 13.0 s" && secondsPairText(20,14)=="20 s → 14 s")
        precondition(typicalReplyTokens([500,700,900].map {timed(local(10,27,9),50,out:$0,dur:9000,ttft:1000)})==700 && typicalReplyTokens([])==750)
        // Congestion grid: one effort + tier, hour cells, baseline = median of solid hours, typical needs 3+ days.
        var congest:[SpeedReading]=[]
        for d in 0..<4 {congest += (0..<3).map {i in analyticReading(local(10,31-d,9,i*10),Double(30+d))}+(0..<3).map {i in analyticReading(local(10,31-d,20,i*10),60)}}
        congest += [analyticReading(local(10,31,7,0),200),analyticReading(local(10,31,7,30),200)]   // 2 responses: shown, not colored
        congest.append(analyticReading(local(10,1,9,0),5))   // older than 14 days
        let weGrid=congestionGrid(congest,now:local(10,31,21,0),include:{analyticsCal.isDateInWeekend($0)},calendar:analyticsCal)
        precondition(weGrid.days==[local(10,31,0)] && weGrid.typical.isEmpty)
        let cg=congestionGrid(congest,now:local(10,31,21,0),calendar:analyticsCal)
        precondition(cg.days.count==4 && cg.days[0]==local(10,31,0) && cg.days[3]==local(10,28,0) && cg.pastDays==3)   // only days since first use
        precondition(cg.cell(local(10,31,0),9)!.mean==30 && cg.cell(local(10,31,0),9)!.count==3 && cg.cell(local(10,31,0),7)!.count==2 && cg.cell(local(10,1,0),9)==nil)
        precondition(cg.baseline==(60+33)/2.0 && cg.typical[20]==60 && cg.typical[9]==32 && cg.typical[7]==nil && cg.daysSoFar==31)
        precondition(congestionLevel(30,baseline:46.5) == .muchSlower && congestionLevel(40,baseline:46.5) == .slower && congestionLevel(46,baseline:46.5) == .normal && congestionLevel(60,baseline:46.5) == .faster)
        precondition(congestionLevel(41.8,baseline:46.5) == .slower && congestionLevel(42,baseline:46.5) == .normal && congestionLevel(51.2,baseline:46.5) == .faster && congestionLevel(5,baseline:0) == .normal)
        // Inclusive congestion cutoffs must not miss exact boundaries through subtractive rounding.
        precondition(congestionLevel(75,baseline:100) == .muchSlower && congestionLevel(75.0001,baseline:100) == .slower)
        precondition(congestionLevel(90,baseline:100) == .slower && congestionLevel(90.0001,baseline:100) == .normal)
        precondition(congestionLevel(110,baseline:100) == .faster && congestionLevel(109.9999,baseline:100) == .normal)
        let wk=weekdayCongestion(congest,now:local(10,31,21,0),calendar:analyticsCal)
        precondition(wk.values.allSatisfy {$0.isEmpty})   // each weekday seen once so far
        var weekly:[SpeedReading]=[]
        for w in 0..<3 {weekly += (0..<3).map {i in analyticReading(local(10,31-7*w,9,i*10),Double(40+w*10))}}
        let wk2=weekdayCongestion(weekly,now:local(10,31,21,0),calendar:analyticsCal)
        precondition(wk2[analyticsCal.component(.weekday,from:local(10,31,0))]![9]==50)
        precondition(congestionDayLabel(local(10,31,0),now:local(10,31,21,0),calendar:analyticsCal)=="Today" && congestionDayLabel(local(10,27,0),now:local(10,31,21,0),calendar:analyticsCal)=="Tue 27 Oct")
        // Hour grid v2: wait and reply counts per cell, merged runs (wrapping midnight), and the insight strip.
        precondition(hourRuns(Set([22,23,0,1]))==[HourRun(start:22,length:4)] && hourRuns(Set([9,10,11,19]))==[HourRun(start:9,length:3),HourRun(start:19,length:1)])
        precondition(hourRuns(Set(0..<24))==[HourRun(start:0,length:24)] && hourRuns([]).isEmpty && HourRun(start:22,length:4).hours==[22,23,0,1])
        precondition(waitLevel(2.5,normal:2) == .muchSlower && waitLevel(2.2,normal:2) == .slower && waitLevel(2,normal:2) == .normal && waitLevel(1.8,normal:2) == .faster && waitLevel(5,normal:0) == .normal)
        func waited(_ date:Date,_ speed:Double,_ wait:Double)->SpeedReading {var r=analyticReading(date,speed);r.ttftMS=wait*1000;return r}
        func hoursFixture(morningWait:Double)->[SpeedReading] {
            var out:[SpeedReading]=[]
            for d in 0..<4 {out += (0..<3).map {i in waited(local(10,31-d,9,i*10),30,morningWait)}+(0..<3).map {i in waited(local(10,31-d,20,i*10),60,2)}}
            return out
        }
        let hg=congestionGrid(hoursFixture(morningWait:2),now:local(10,31,21,0),calendar:analyticsCal)
        precondition(hg.cell(local(10,31,0),9)!.wait==2 && hg.typicalWait[9]==2 && hg.normalWait==2 && hg.typicalCount[9]==3 && hg.typicalCount[7]==nil && hg.maxCount==3 && hg.typicalDays[9]==3)
        precondition(hg.baseline==45 && hg.typical[9]==30 && hg.typical[20]==60)
        let hi=hoursInsight(hg,now:local(10,31,21,0),tier:"fast",calendar:analyticsCal)!
        precondition(hi.answer!.hasPrefix("Plan heavy work for the evening: Fast usually runs 60 t/s at ") && hi.answer!.hasSuffix("about 100% quicker."))
        precondition(hi.slowest.value.hasSuffix(" · 33% slower") && hi.slowest.tone == .muchSlower && hi.slowest.sub=="from 3 past days per hour · early pattern")
        precondition(hi.fastest.value.hasSuffix(" · 33% faster") && hi.fastest.sub.hasPrefix("none left today") && hi.now.value=="No usual for this hour yet")
        precondition(hi.waitNote=="Slow mornings show similar first output waits (about 2.0 s). This does not establish whether generating (est.) is slower.")
        let hiAfternoon=hoursInsight(hg,now:local(10,31,14,0),tier:"fast",calendar:analyticsCal)!
        precondition(hiAfternoon.fastest.sub.hasPrefix("best window left today: ") && hoursInsight(hg,now:local(10,31,20,30),tier:"fast",calendar:analyticsCal)!.fastest.sub=="you’re in one now")
        precondition(hoursInsight(hg,now:local(10,31,9,30),tier:"fast",calendar:analyticsCal)!.now.value=="Usually 33% slower now")
        let slowStart=hoursInsight(congestionGrid(hoursFixture(morningWait:4),now:local(10,31,21,0),calendar:analyticsCal),now:local(10,31,21,0),tier:"fast",calendar:analyticsCal)!
        precondition(slowStart.waitNote=="Slow mornings also show a longer first output wait (4.0 s vs 3.0 s overall).")
        precondition(hoursInsight(congestionGrid([],now:local(10,31,21,0),calendar:analyticsCal),now:local(10,31,21,0),tier:"fast",calendar:analyticsCal)==nil)
        // A later qualifying run must remain discoverable even when it is not in the top two overall runs.
        var remaining=CongestionGrid(days:[],cells:[:],typical:[1:160,8:150,18:120],baseline:100,daysSoFar:14,pastDays:5)
        remaining.typicalDays=[1:5,8:5,18:5]
        precondition(hoursInsight(remaining,now:local(10,31,12),tier:"fast",calendar:analyticsCal)!.fastest.sub=="best window left today: "+hourClock(18))
        precondition(hoursInsight(remaining,now:local(10,31,18),tier:"fast",calendar:analyticsCal)!.fastest.sub=="you’re in one now")
        let zeroWait=(0..<4).flatMap {d in (0..<3).map {i in waited(local(10,31-d,9,i*10),40,0)}}
        let zeroGrid=congestionGrid(zeroWait,now:local(10,31,12),calendar:analyticsCal)
        precondition(zeroGrid.normalWait==0 && zeroGrid.typicalWait[9]==0 && zeroGrid.cell(local(10,31,0),9)?.wait==0)
        let missingWait=zeroWait.map {r->SpeedReading in var x=r;x.ttftMS=nil;return x}
        let missingGrid=congestionGrid(missingWait,now:local(10,31,12),calendar:analyticsCal)
        precondition(missingGrid.normalWait==nil && missingGrid.typicalWait.isEmpty && missingGrid.cell(local(10,31,0),9)?.wait==nil && missingGrid.cell(local(10,31,0),9)?.count==3)
        // Generating speed per hour = output tokens ÷ time after the first-output wait.
        let generatingGrid=congestionGrid(hoursFixture(morningWait:4),now:local(10,31,21,0),calendar:analyticsCal)
        precondition(abs(generatingGrid.cell(local(10,31,0),9)!.generating!-100.0/6)<1e-9 && abs(generatingGrid.typicalGenerating[20]!-12.5)<1e-9 && generatingGrid.normalGenerating != nil)
        precondition(missingGrid.normalGenerating==nil && missingGrid.cell(local(10,31,0),9)?.generating==nil && missingGrid.typicalGenerating.isEmpty)
        precondition(GridMetric.allCases.map(\.title)==["Overall","Generating","Wait","Replies"] && GridMetric(rawValue:"speed") == .speed)
        precondition(SpeedTimeRange.allCases.map(\.title)==["1h","4h","12h","24h","7d","30d"])
        do {
        // Generating-first regression cases: unequal intervals must be pooled, and missing
        // first-output timing stays eligible for overall without entering generation coverage.
        let pooledNow=local(10,31,14,50)
        let unequal=[timed(local(10,31,14,1),500,out:1000,dur:2000,ttft:1000),timed(local(10,31,14,2),90,out:900,dur:10000,ttft:1000)]
        let pooled=timingSplit(unequal)!
        precondition(abs(pooled.generating-190)<1e-9 && pooled.responses==2)
        precondition(abs(unequal.compactMap(\.generatingSpeed).reduce(0,+)/2-550)<1e-9)
        let absent=timed(local(10,31,14,3),75,out:750,dur:10000,ttft:nil)
        let partial=unequal+[absent]
        precondition(timingSplit(partial)!.generating==190 && timingSplit(partial)!.responses==2)
        let partialModel=SpeedCellModel(group:SpeedModeGroup(mode:"fast",readings:partial,responseDates:partial.map(\.date)),range:.hour,history:[],now:pooledNow)
        precondition(partialModel.displayDetail=="2/3 timed" && partialModel.accessibleValue.contains("190 tokens per second generating") && partialModel.tooltip.contains("overall"))
        let fallbackModel=SpeedCellModel(group:SpeedModeGroup(mode:"fast",readings:[absent],responseDates:[absent.date]),range:.hour,history:[],now:pooledNow)
        precondition(fallbackModel.displayDetail=="overall · 1 reply" && fallbackModel.accessibleValue.contains("75 tokens per second overall"))
        precondition(timingCoverageText(timed:2,measured:3,total:5).hasPrefix("Generating: 2 of 5 replies · Overall: 3 of 5."))
        let partialToday=generatingTodayCell(partial,now:pooledNow,calendar:analyticsCal)!
        precondition(partialToday.cell.value=="190 t/s" && partialToday.cell.sub.contains("2/3 timed"))
        let fallbackSection=speedSection(raw:["standard":[absent]],completed:["standard":[absent]],now:pooledNow,calendar:analyticsCal)
        precondition(fallbackSection.rows[0].cells[0].sub.hasPrefix("overall · ") && fallbackSection.rows[1].cells[0].sub.hasPrefix("overall · "))
        let zeroWaitReading=timed(local(10,31,14),100,out:100,dur:1000,ttft:0)
        precondition(zeroWaitReading.waitSeconds==0 && zeroWaitReading.generatingSpeed==100)
        let tiny=timed(local(10,31,14),1,out:100,dur:0.00000001,ttft:0)
        precondition(tiny.generatingSeconds!>0 && timingSplit([tiny])!.generating.isFinite && timingSplit([tiny])!.generating>1e12)
        for invalid in [timed(pooledNow,1,out:100,dur:0,ttft:0),timed(pooledNow,1,out:100,dur:1000,ttft:1000),timed(pooledNow,1,out:100,dur:1000,ttft:-1),timed(pooledNow,1,out:100,dur:1000,ttft:.nan),timed(pooledNow,1,out:100,dur:.infinity,ttft:0),timed(pooledNow,1,out:100,dur:Double.leastNonzeroMagnitude,ttft:0)] {
            precondition(invalid.waitSeconds==nil && invalid.generatingSeconds==nil && invalid.generatingSpeed==nil && timingSplit([invalid])==nil)
        }
        let huge=timed(pooledNow,1,out:Int64.max,dur:1000,ttft:0)
        precondition(timingSplit([huge,huge])!.generating==Double(Int64.max))
        let pooledHistory=(1...5).flatMap {offset-> [SpeedReading] in
            let date=analyticsCal.date(byAdding:.day,value:-offset,to:local(10,31,14))!
            return [timed(date,100,out:1000,dur:2000,ttft:1000),timed(date,100,out:900,dur:10000,ttft:1000),timed(date,100,out:1900,dur:11000,ttft:1000)]
        }
        let pooledUsual=usualTiming(pooledHistory,start:local(10,31,14),now:pooledNow,calendar:analyticsCal)!
        precondition(pooledUsual.generating==190 && pooledUsual.generatingLo==190 && pooledUsual.generatingHi==190)
        let previousTimedDays=pooledHistory.map {r in timed(analyticsCal.date(byAdding:.day,value:-7,to:r.date)!,r.speed,out:r.outputTokens,dur:r.durationMS,ttft:r.ttftMS)}
        let untimedThisWeek=timed(local(10,30,14),75,out:750,dur:10000,ttft:nil)
        let missingWeekTrend=generatingTrend(previousTimedDays+[untimedThisWeek],weekStart:local(10,24,0),prevStart:local(10,17,0),calendar:analyticsCal)!
        precondition(missingWeekTrend.value=="No timed days this week")
        let pooledBands=pastHourBands(pooledHistory,now:pooledNow,generating:true,calendar:analyticsCal)
        precondition(pooledBands.count==1 && pooledBands[0].mid==190)
        let current=(0..<10).map {i in timed(local(10,31,14,i),20,out:1000,dur:2000,ttft:1000)}
        let arrows=SpeedCellModel(group:SpeedModeGroup(mode:"fast",readings:current,responseDates:current.map(\.date)),range:.hour,history:pooledHistory,now:pooledNow)
        precondition(arrows.marker == .slower && arrows.genMarker == .faster && arrows.displayMarker == .faster && arrows.accessibleValue.contains("faster than usual"))
        let chartDetail=TierReadingDetail(readings:partial,history:partial,now:pooledNow)
        precondition(chartDetail.chartGenerating && chartDetail.todayHours.count==1 && chartDetail.todayHours[0].mean==190 && chartDetail.todayHours[0].count==2)
        let plot=TodayVsUsualChart(bands:[],today:chartDetail.todayHours,currentHour:14,generating:true)
        precondition(plot.readoutLines(Calendar.current.component(.hour,from:pooledNow))[0].contains("generating (est.) · 2 replies"))
        let noGenHistory=pooledHistory.map {r->SpeedReading in var x=r;x.ttftMS=nil;return x}
        let actual=unequal+[timed(local(10,31,14,3),100,out:1900,dur:11000,ttft:1000),absent]+noGenHistory
        let reportForGen=RecentSpeedReport(models:[SpeedModelGroup(model:"M",efforts:[SpeedEffortGroup(effort:"high",modes:[SpeedModeGroup(mode:"standard",readings:actual,responseDates:actual.map(\.date))])],latestResponse:pooledNow)])
        let patternsForGen=PatternsData.build(report:reportForGen,key:PatternsKey(model:"M",effort:"high",tier:"standard",minute:1,stamp:nil,clock:"24"),now:pooledNow,calendar:analyticsCal)
        // A generating plot cannot borrow an overall-only usual or weekday score.
        precondition(patternsForGen.grid.normalGenerating != nil && patternsForGen.insight==nil && patternsForGen.weekdayStrip.days.allSatisfy {$0.score==nil})
        precondition(compactCount(999)=="999" && compactCount(1000)=="1k" && compactCount(2812)=="2.8k" && compactCount(12400)=="12k" && compactReplies(1)=="1 reply" && compactReplies(2812)=="2.8k replies")
        precondition(partialModel.compactDetail=="2/3 timed" && fallbackModel.compactDetail=="overall · 1 reply")
        print("PASS compact tile counts")
        do {
            // Chart-first report: same-window generating comparison, range buckets, coverage and evidence-led answers.
            let chartNow=local(10,31,16)
            var std:[SpeedReading]=[],fst:[SpeedReading]=[]
            for d in 1...3 {
                let day=analyticsCal.date(byAdding:.day,value:-d,to:local(10,31,14))!
                for m in 0..<3 {std.append(timed(day.addingTimeInterval(Double(m)*60),40,out:1000,dur:21000,ttft:1000))}
                for m in 0..<4 {fst.append(timed(day.addingTimeInterval(Double(m)*60+30),80,out:1000,dur:11000,ttft:1000))}
            }
            let chartReport=RecentSpeedReport(models:[SpeedModelGroup(model:"Chart",efforts:[SpeedEffortGroup(effort:"high",modes:[
                SpeedModeGroup(mode:"standard",readings:std,responseDates:std.map(\.date)),SpeedModeGroup(mode:"fast",readings:fst,responseDates:fst.map(\.date))])],latestResponse:chartNow)])
            let week=PatternsData.build(report:chartReport,key:PatternsKey(model:"Chart",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24",range:"7d"),now:chartNow,calendar:analyticsCal)
            let afternoon=week.panels[.afternoon]!
            let fastMatch=afternoon.matched["fast"]!
            precondition(fastMatch.windows==3 && fastMatch.days==3 && fastMatch.wins==3 && abs(fastMatch.ratio-2)<1e-9 && fastMatch.clear && abs(fastMatch.savedPer1000-10)<1e-9)
            precondition(afternoon.matched["ultrafast"]==nil && week.panels[.morning]!.matched.isEmpty && afternoon.observed[1].replies==12 && afternoon.observed[1].days==3 && abs(afternoon.observed[1].value!-100)<1e-9)
            precondition(week.hourSeries[1].points[14]!.count==12 && week.hourSeries[1].points[14]!.days==3 && week.hourSeries[1].points[13]==nil)
            precondition(week.historySeries[1].points.count==56 && week.historyHourly && week.historyStepHours==3 && week.historySeries[1].points[28]!.count==4 && week.historySeries[1].points[6]==nil && week.historySeries[1].replies==12)
            precondition(week.hourSeries[1].points[14]!.perDay.count==3 && week.hourSeries[1].points[14]!.perDay.allSatisfy {abs($0-100)<1e-9})
            precondition(week.coverage=="Last 7 days · data on 3 of 7 days" && week.grid.days.count<=7)
            precondition(week.historyAnswer=="Fast held steady over this range: about 100 t/s. You didn’t use Ultrafast." && week.hourAnswer.hasPrefix("Not enough replies yet"))
            // Two shared windows are too few to call, and the panel says so instead of naming a winner.
            let twoDays=PatternsData.build(report:chartReport,key:PatternsKey(model:"Chart",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24",excluded:[analyticsCal.date(byAdding:.day,value:-3,to:local(10,31,12))!],range:"7d"),now:chartNow,calendar:analyticsCal)
            precondition(twoDays.panels[.all]!.matched["fast"]!.windows==2 && !twoDays.panels[.all]!.matched["fast"]!.clear && twoDays.coverage.hasSuffix(" · 1 left out"))
            let day=PatternsData.build(report:chartReport,key:PatternsKey(model:"Chart",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24",range:"24h"),now:chartNow,calendar:analyticsCal)
            precondition(day.historyHourly && day.historyStepHours==1 && day.historyBuckets.count==24 && day.historySeries.allSatisfy {$0.replies==0} && day.historyAnswer=="No timed replies in this range yet.")
            var otherRange=PatternsKey(model:"Chart",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24")
            precondition(otherRange.range=="14d");otherRange.range="30d"
            precondition(!PatternsKey(model:"Chart",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24").sameSelection(as:otherRange))
            print("PASS chart-first report: same-day 3-hour generating windows, clear/too-few rule, time saved per 1,000 tokens, hour/day buckets, range coverage and left-out days, evidence-led answers")
            // Day × hour: 3-hour blocks over the range, newest day first, colored against a 14-day normal.
            let g=week.weekGrid!
            precondition(g.days.count==7 && g.days[0]==analyticsCal.startOfDay(for:chartNow) && g.nowBlock==5)
            precondition(g.isFuture(g.days[0],6) && !g.isFuture(g.days[0],5) && !g.isFuture(g.days[1],7) && g.pastBlocks==54)
            let b28=g.cell("fast",analyticsCal.startOfDay(for:local(10,28,14)),4)!
            precondition(b28.count==4 && abs(b28.value-100)<1e-9 && g.cell("fast",analyticsCal.startOfDay(for:local(10,28,14)),3)==nil)
            precondition(abs(g.normal["fast"]!-100)<1e-9 && g.normalReplies["fast"]==12 && g.normalDays["fast"]==3 && g.normal["ultrafast"]==nil)
            precondition(g.blocks("fast").count==3 && g.blocks("standard").count==3 && g.blocks("ultrafast").isEmpty)
            precondition(week.gridAnswers["fast"]!.hasPrefix("Fast stayed near your normal of 100 t/s") && week.gridAnswers["ultrafast"]=="No timed Ultrafast replies in this range.")
            precondition(gridReadout(g,tier:"fast",spot:GridSpot(day:analyticsCal.startOfDay(for:local(10,28,14)),block:4)).hasSuffix("Fast 100 t/s · 4 replies · at your normal"))
            precondition(gridReadout(g,tier:"fast",spot:GridSpot(day:g.days[0],block:0)).hasSuffix("no timed Fast replies") && gridReadout(g,tier:"fast",spot:nil)=="Hover a block for its replies")
            // A slow block is named; 1–2 replies never are.
            var slowFast=fst
            for m in 0..<3 {slowFast.append(timed(local(10,30,9,m),50,out:500,dur:11000,ttft:1000))}
            slowFast.append(timed(local(10,29,22),10,out:100,dur:11000,ttft:1000))
            let slowGrid=buildWeekGrid(["fast":slowFast],days:7,now:chartNow,calendar:analyticsCal)
            let slowAnswer=weekGridAnswer(slowGrid,tier:"fast")
            precondition(slowAnswer.hasPrefix("Fast was slowest on ") && slowAnswer.contains("at 50 t/s") && slowAnswer.hasSuffix("Blank blocks are times you didn’t use Fast."))
            precondition(gridReadout(slowGrid,tier:"fast",spot:GridSpot(day:analyticsCal.startOfDay(for:local(10,29,22)),block:7)).hasSuffix("1 reply · too few to compare"))
            let month=PatternsData.build(report:chartReport,key:PatternsKey(model:"Chart",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24",range:"30d"),now:chartNow,calendar:analyticsCal)
            precondition(month.weekGrid!.days.count==30 && day.weekGrid!.days.count==7)
            print("PASS Day × hour: 3-hour blocks, newest day first, future blocks blank, 14-day normal per tier, slowest-block answer, thin blocks never named, hover readouts, range rows")
            // History labels and membership must use the same wall-clock blocks.
            for zone in ["America/New_York", "Australia/Lord_Howe"] {
                var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(identifier:zone)!
                let transitions=zone=="America/New_York" ? [(3,8),(11,1)] : [(4,5),(10,4)]
                for (month,day) in transitions {
                    func stamp(_ hour:Int,_ minute:Int=0)->Date {
                        cal.date(from:DateComponents(year:2026,month:month,day:day,hour:hour,minute:minute))!
                    }
                    let window=patternsWindow(.week,now:stamp(23),calendar:cal)
                    precondition(window.buckets.count==56 && window.step==3)
                    precondition(window.buckets==window.buckets.sorted() && Set(window.buckets).count==56)
                    let slots=Array(window.buckets.suffix(8))
                    precondition(slots.map {cal.component(.hour,from:$0)}==Array(stride(from:0,to:24,by:3)))
                    let rows=[timed(stamp(0,15),100,out:1000,dur:11000,ttft:1000),timed(stamp(3,0),100,out:1000,dur:11000,ttft:1000),timed(stamp(5,59),100,out:1000,dur:11000,ttft:1000),timed(stamp(6,0),100,out:1000,dur:11000,ttft:1000)]
                    let points=chartHistoryPoints(rows,buckets:window.buckets,step:3,calendar:cal)
                    precondition(points[48]?.count==1 && points[49]?.count==2 && points[50]?.count==1)
                    if zone=="America/New_York" && month==11 {
                        let first=cal.date(bySettingHour:1,minute:15,second:0,of:stamp(0),matchingPolicy:.strict,repeatedTimePolicy:.first)!
                        let second=cal.date(bySettingHour:1,minute:15,second:0,of:stamp(0),matchingPolicy:.strict,repeatedTimePolicy:.last)!
                        precondition(second.timeIntervalSince(first)==3600)
                        let repeated=chartHistoryPoints([timed(first,100,out:1000,dur:11000,ttft:1000),timed(second,100,out:1000,dur:11000,ttft:1000)],buckets:window.buckets,step:3,calendar:cal)
                        precondition(repeated[48]?.count==2 && repeated[49]==nil)
                    }
                }
            }
            var helsinki=Calendar(identifier:.gregorian);helsinki.timeZone=TimeZone(identifier:"Europe/Helsinki")!
            let skipped=helsinki.date(from:DateComponents(year:2026,month:3,day:29,hour:23))!
            let skippedWindow=patternsWindow(.week,now:skipped,calendar:helsinki)
            precondition(helsinki.component(.hour,from:skippedWindow.buckets[49])==4)
            var titleData=week;titleData.historyBuckets=skippedWindow.buckets;titleData.historyStepHours=3
            let title=SpeedPatternsView(report:chartReport,now:chartNow).bucketTitle(49,data:titleData,hourly:false)
            precondition(title.hasSuffix(hourClock(3)+"–"+hourClock(6)))
            print("PASS seven-day History wall-clock labels and boundaries across spring/fall and half-hour DST; repeated hours share their clock block")
        }
        print("PASS pooled generating weighting; zero/tiny/nonfinite intervals; token-sum overflow; missing-timing coverage and explicit overall fallbacks; generating usual/hourly consistency; distinct overall/generating arrows and accessibility; chart subset counts")
        }
        // Generating first: tiles and Today use tokens ÷ time after the wait, pooled; untimed falls back to overall.
        let genReadings=(0..<12).map {i in timed(local(10,31,14,i*4),40,out:1000,dur:10000,ttft:2000)}
        let genCell=SpeedCellModel(group:SpeedModeGroup(mode:"fast",readings:genReadings,responseDates:genReadings.map(\.date),latestResponse:genReadings.last!.date),range:.hour,history:genReadings,now:local(10,31,14,50))
        precondition(genCell.gen != nil && abs(genCell.gen!.generating-125)<1e-9 && genCell.displayNumber=="125" && genCell.mean==40)
        let untimedCell=SpeedCellModel(group:SpeedModeGroup(mode:"fast",readings:[analyticReading(local(10,31,14),40)],responseDates:[local(10,31,14)],latestResponse:local(10,31,14)),range:.hour,history:[],now:local(10,31,14,30))
        precondition(untimedCell.gen==nil && untimedCell.displayNumber==untimedCell.number)
        precondition(generatingTodayCell(genReadings,now:local(10,31,14,50),calendar:analyticsCal)!.cell.value=="125 t/s" && generatingTodayCell([analyticReading(local(10,31,14),40)],now:local(10,31,14,30),calendar:analyticsCal)==nil)
        precondition(timingCompareText(1.0,usual:1.02,longerIsSlower:true)=="about usual" && timingCompareText(3.2,usual:1.6,longerIsSlower:true)=="2.0× usual" && timingCompareText(1.2,usual:1.0,longerIsSlower:true)=="20% longer than usual")
        precondition(timingCompareText(78,usual:100,longerIsSlower:false)=="22% slower than usual" && timingCompareText(120,usual:100,longerIsSlower:false)=="20% faster than usual" && timingCompareText(5,usual:0,longerIsSlower:false)=="no usual yet")
        precondition(timingReason(TimingSplit(wait:1.6,generating:78),UsualTiming(wait:1.6,waitLo:1.4,waitHi:1.8,generating:100,generatingLo:90,generatingHi:110,days:5))=="generating 22% slower than usual · wait about usual")
        // Equal first-output wait and equal generating rate can still produce different overall t/s at different output lengths.
        var lengthMix:[SpeedReading]=[]
        for d in 0..<4 {for i in 0..<3 {
            lengthMix.append(timed(local(10,31-d,9,i*10),200.0/6,out:200,dur:6000,ttft:2000))
            lengthMix.append(timed(local(10,31-d,20,i*10),1000.0/22,out:1000,dur:22000,ttft:2000))
        }}
        precondition(lengthMix.allSatisfy {$0.generatingSpeed==50 && $0.waitSeconds==2})
        let mixtureNote=hoursInsight(congestionGrid(lengthMix,now:local(10,31,21),calendar:analyticsCal),now:local(10,31,21),tier:"fast",calendar:analyticsCal)!.waitNote!
        precondition(mixtureNote.contains("does not establish whether generating (est.) is slower") && !mixtureNote.contains("generation itself slows down"))
        print("PASS best remaining eligible hour beyond top-two display, current third run, zero versus missing wait, and noncausal wait note under reply-length confounding")
        let dstNow=local(11,1,12,30),dstWindow=[analyticReading(firstFall,10),analyticReading(local(11,1,12,15),20)]
        precondition(matchedDayMeans(dstWindow,history:matchedHistory,start:dstNow.addingTimeInterval(-43200),now:dstNow,calendar:analyticsCal).isEmpty)
        print("PASS weighted-mean cluster-robust margins; matched clock/minute coverage; future/today exclusions; missing-hour and minimum-day gates; midnight windows; DST 23/25-hour Today and repeated-hour clusters; exact-effort pairing; same-window usual and ▲/▼ markers; gated usual bands; chart labels and steps; rough averages; congestion grid; first-output wait vs estimated generating; matched tier comparisons; value verdicts vs Standard; time saved with joint middle-80% bootstrap ranges, shared/distinct/partial windows, unchanged points and deterministic seeds; 12/24-hour clock")
        let chartNow=Date(timeIntervalSince1970:1800000000)
        func chartReading(_ offset:TimeInterval,_ speed:Double)->SpeedReading {SpeedReading(id:String(offset),date:chartNow.addingTimeInterval(offset),speed:speed,outputTokens:100,durationMS:10000)}
        let chartRows=[chartReading(-3600,10),chartReading(-3550,30),chartReading(-60,90),chartReading(0,110),chartReading(-3601,999),chartReading(1,999)]
        let bins=speedBins(chartRows,range:.hour,now:chartNow)
        precondition(bins.count==2 && bins.map(\.id)==[0,11] && bins.map(\.count)==[2,2])
        precondition(bins[0].mean==20 && bins[0].p25==15 && bins[0].p75==25 && bins[1].mean==100 && bins[0].segment != bins[1].segment)
        precondition(speedBins([],range:.day,now:chartNow).isEmpty && speedBins([chartReading(0,0)],range:.day,now:chartNow)[0].mean==0)
        precondition(speedTrend(Array(chartRows.prefix(4)),range:.hour,now:chartNow)==nil)
        let trendRows=(0..<12).map {i in chartReading(-Double(i/4)*1200-60,Double(i))}
        let trend=speedTrend(trendRows,range:.hour,now:chartNow)!
        precondition(trend.points.compactMap{$0}.count==3 && trend.points.contains{$0==nil} && trend.mean==5.5)
        for range in SpeedTimeRange.allCases {
            let edge=speedBins([chartReading(-range.seconds,10),chartReading(0,20)],range:range,now:chartNow)
            precondition(edge.count==2 && edge.first!.id==0 && edge.last!.id==range.chartBins.count-1)
        }
        print("PASS redesigned chart buckets, quartiles, inclusive edges, future/outside exclusions, empty/zero/sparse cases and missing-data segments")
        var db:OpaquePointer?;precondition(sqlite3_open(":memory:",&db)==SQLITE_OK);defer{sqlite3_close(db)}
        func sql(_ text:String) {precondition(sqlite3_exec(db,text,nil,nil,nil)==SQLITE_OK,String(cString:sqlite3_errmsg(db)))}
        sql("CREATE TABLE daemon_heartbeats(ts TEXT); CREATE TABLE trusted_turn_cache(source TEXT,source_id TEXT,model TEXT,mode TEXT,reasoning_effort TEXT,completed_at TEXT,output_tokens INTEGER,duration_ms REAL,output_tokens_per_second REAL,speed_eligible INTEGER,input_tokens INTEGER,total_tokens INTEGER)")
        let now=parseISO("2026-10-28T15:00:00Z")!
        func row(_ id:String,_ model:String,_ effort:String?,_ mode:String?,_ speed:Double?,_ offset:Int,_ duration:Double=10000) {
            let time=ISO8601DateFormatter().string(from:now.addingTimeInterval(-Double(offset)))
            let e=effort.map{"'\($0)'"} ?? "NULL",m=mode.map{"'\($0)'"} ?? "NULL",s=speed.map{String($0)} ?? "NULL"
            sql("INSERT INTO trusted_turn_cache(source,source_id,model,mode,reasoning_effort,completed_at,output_tokens,duration_ms,output_tokens_per_second,speed_eligible,input_tokens,total_tokens) VALUES('test','\(id)','\(model)',\(m),\(e),'\(time)',1000,\(duration),\(s),\(speed == nil ? 0 : 1),9999999,99999999)")
        }
        for i in 1...20 {row("a\(i)","A","xhigh","fast",Double(i),i*60)}
        row("std","A","xhigh","default",200,1)
        row("high","A","high","fast",300,2)
        row("other","B","xhigh","fast",400,3)
        row("missing","A","xhigh","fast",nil,0)
        row("unspec","A",nil,"fast",50,4)
        row("unknown","A","unknown",nil,60,5)
        row("auto","A","max","auto",70,6)
        row("zero","Z","low","standard",0,7)
        row("invalid-zero-duration","A","xhigh","fast",999,8,0)
        func read()->RecentSpeedReport {RecentSpeedReport.read(db,usageTable:"trusted_turn_cache",speedTable:"trusted_turn_cache",cached:true,path:"/tmp/does-not-exist",now:now)}
        let report=read();precondition(report.error==nil)
        func group(_ model:String,_ effort:String,_ mode:String)->SpeedModeGroup {report.models.first{$0.model==model}!.efforts.first{$0.effort==effort}!.modes.first{$0.mode==mode}!}
        let fast=group("A","xhigh","fast")
        precondition(fast.stats().readings.count==20 && fast.stats().mean==10.5)
        precondition(fast.stats().readings.count==20 && fast.stats().mean==10.5)
        precondition(fast.excluded==2 && fast.stats().latest==now.addingTimeInterval(-60))
        precondition(group("A","xhigh","standard").stats().mean==200)
        precondition(group("A","high","fast").stats().mean==300)
        precondition(group("B","xhigh","fast").stats().mean==400)
        precondition(group("A","unknown","fast").stats().mean==50)
        precondition(group("A","unknown","unknown").stats().mean==60)
        precondition(group("A","max","auto").stats().mean==70)
        precondition(group("Z","low","standard").stats().mean==0)
        precondition(report.models.first{$0.model=="A"}!.efforts.count==4)
        precondition(!report.models.first{$0.model=="A"}!.efforts.contains{$0.effort=="low"})
        precondition(fast.stats().readings.count==20) // All valid readings, no hidden sample cap.
        var nav=SpeedNavigation()
        for _ in 0..<100 {nav.open(model:"A",effort:"xhigh",mode:"fast");precondition(nav.selection==SpeedSelection(model:"A",effort:"xhigh",mode:"fast"));nav.back();nav.back();precondition(nav.selection==nil)}
        // Positive measured durations; 100 output tokens and exact timing identity remain required.
        sql("CREATE TABLE short_cache(source TEXT,source_id TEXT,model TEXT,mode TEXT,reasoning_effort TEXT,completed_at TEXT,output_tokens INTEGER,duration_ms REAL,output_tokens_per_second REAL,speed_eligible INTEGER,raw_json TEXT)")
        func shortRow(_ id:String,_ duration:Double?,_ output:Int=100,_ flag:Int=0,_ streams:Int=1,_ completions:Int=1,_ conflict:Int=0) {
            let d=duration.map(String.init(describing:)) ?? "NULL"
            let rate=duration.flatMap {$0>0 ? Double(output)*1000/$0 : nil}.map(String.init(describing:)) ?? "NULL"
            let meta="{\"matching_streams\":\(streams),\"matching_completions\":\(completions),\"identity_conflict\":\(conflict)}"
            sql("INSERT INTO short_cache VALUES('test','\(id)','Short','fast','xhigh','2026-10-28T14:59:00Z',\(output),\(d),\(rate),\(flag),'\(meta)')")
        }
        shortRow("under",2500);shortRow("exact-five",5000);shortRow("above-five",5001)
        shortRow("legacy",1500,100,1,0,0);shortRow("tiny-positive",10)
        shortRow("zero",0);shortRow("negative",-1);shortRow("missing",nil)
        shortRow("99-tokens",2500,99);shortRow("ambiguous-stream",2500,100,0,2)
        shortRow("ambiguous-completion",2500,100,0,1,2);shortRow("missing-match",2500,100,0,0,0)
        shortRow("identity-conflict",2500,100,0,1,1,1)
        sql("CREATE VIEW short_speed AS SELECT * FROM short_cache WHERE speed_eligible=1")
        for cached in [true,false] {
            let measured=RecentSpeedReport.read(db,usageTable:"short_cache",speedTable:"short_speed",cached:cached,path:"/tmp/not-present",now:now)
            let g=measured.models[0].efforts[0].modes[0]
            precondition(Set(g.readings.map(\.id))==Set(["under","exact-five","above-five","legacy","tiny-positive"].map{"test:"+$0}))
            precondition(g.responseDates.count==13 && g.excluded==8)
            let cell=SpeedCellModel(group:g,range:.hour,history:g.readings,now:now)
            precondition(cell.responses==5 && cell.detail=="5 replies")
            precondition(cell.mean==g.stats().mean)
            let detail=TierReadingDetail(responseDates:g.responseDates,readings:g.readings,history:g.readings,now:now)
            precondition(detail.windowTotalReplies==13 && detail.aboutLines.contains(replyMeasurementExplanation))
            let data=PatternsData.build(report:measured,key:PatternsKey(model:"Short",effort:"xhigh",tier:"fast",minute:0,stamp:nil,clock:"24"),now:now)
            precondition(data.speedRows[0].cells[1].value != "—")
        }
        var eligibilityStatement:OpaquePointer?
        let eligibilitySQL="SELECT source_id FROM short_cache WHERE "+measuredReplyEligibilitySQL(legacyEligibleSQL:"speed_eligible")
        precondition(sqlite3_prepare_v2(db,eligibilitySQL,-1,&eligibilityStatement,nil)==SQLITE_OK)
        var sqlEligible=Set<String>()
        while sqlite3_step(eligibilityStatement)==SQLITE_ROW {sqlEligible.insert(String(cString:sqlite3_column_text(eligibilityStatement,0)))}
        sqlite3_finalize(eligibilityStatement)
        precondition(sqlEligible==Set(["under","exact-five","above-five","legacy","tiny-positive"]))
        sql("INSERT INTO short_cache VALUES('test','infinite-duration','Short','fast','xhigh','2026-10-28T14:59:00Z',100,1e309,40,1,'{}')")
        sql("INSERT INTO short_cache VALUES('test','infinite-rate','Short','fast','xhigh','2026-10-28T14:59:00Z',100,2500,1e309,1,'{}')")
        let finiteSQL="SELECT count(*) FROM short_cache WHERE source_id LIKE 'infinite-%' AND "+measuredReplyEligibilitySQL(legacyEligibleSQL:"speed_eligible")
        precondition(sqlite3_prepare_v2(db,finiteSQL,-1,&eligibilityStatement,nil)==SQLITE_OK && sqlite3_step(eligibilityStatement)==SQLITE_ROW && sqlite3_column_int(eligibilityStatement,0)==0)
        sqlite3_finalize(eligibilityStatement)
        for duration in [0.0,-1,.infinity,.nan] {precondition(!measuredReplyEligible(legacyEligible:true,matchingStreams:1,matchingCompletions:1,identityConflict:false,durationMS:duration,outputTokens:100,speed:40))}
        for speed in [Double?.none,Double?(-1),Double?(.infinity),Double?(.nan)] {precondition(!measuredReplyEligible(legacyEligible:true,matchingStreams:1,matchingCompletions:1,identityConflict:false,durationMS:2500,outputTokens:100,speed:speed))}
        precondition(measuredReplyEligible(legacyEligible:false,matchingStreams:1,matchingCompletions:1,identityConflict:false,durationMS:0.001,outputTokens:100,speed:100_000_000))
        let none=SpeedCellModel(group:SpeedModeGroup(mode:"fast",responseDates:[now],latestResponse:now),range:.hour,history:[],now:now)
        precondition(none.mean==nil && none.detail=="1 logged" && none.number=="—" && none.tooltip.contains("none meet") && none.accessibleValue.contains("speed unavailable"))
        let ambiguous=SpeedCellModel(group:SpeedModeGroup(mode:"ultrafast",responseDates:Array(repeating:now,count:9),latestResponse:now),range:.hour,history:[],now:now)
        precondition(ambiguous.mean==nil && ambiguous.responses==0 && ambiguous.loggedResponses==9 && ambiguous.detail=="9 logged" && ambiguous.number=="—" && ambiguous.tooltip.contains("ambiguous"))
        let unmeasured=SpeedModeGroup(mode:"fast",responseDates:[now],latestResponse:now)
        let absent=RecentSpeedReport(models:[SpeedModelGroup(model:"Unmeasured",efforts:[SpeedEffortGroup(effort:"high",modes:[unmeasured])],latestResponse:now)])
        let missingData=PatternsData.build(report:absent,key:PatternsKey(model:"Unmeasured",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24"),now:now)
        precondition(missingData.speedRows[0].cells[1].value=="—" && missingData.speedRows[0].cells[1].sub=="no qualifying replies")
        precondition(missingData.speedAnswer=="Replies logged today, but none meet the measurement rules.")
        precondition(todayCell([],totalReplies:0,now:now).cell.sub=="not used today")

        sql("CREATE TABLE matched_short_cache AS SELECT * FROM short_cache WHERE 0")
        for mode in ["default","fast"] {for i in 1...3 {
            let duration=mode=="default" ? 2000 : 1000,rate=mode=="default" ? 50 : 100
            sql("INSERT INTO matched_short_cache VALUES('test','\(mode)-\(i)','MatchedShort','\(mode)','high','2026-10-28T14:0\(i):00Z',100,\(duration),\(rate),0,'{\"matching_streams\":1,\"matching_completions\":1,\"identity_conflict\":0}')")
        }}
        let shortPool=RecentSpeedReport.read(db,usageTable:"matched_short_cache",speedTable:"matched_short_cache",cached:true,path:"/tmp/not-present",now:now)
        let matchedData=PatternsData.build(report:shortPool,key:PatternsKey(model:"MatchedShort",effort:"high",tier:"fast",minute:0,stamp:nil,clock:"24"),now:now)
        precondition(shortPool.models[0].efforts[0].modes.flatMap(\.readings).count==6)
        precondition(matchedData.fast.windows==1 && matchedData.fast.responses==6 && matchedData.fast.speedRatio==2)
        precondition(matchedData.fast.strength.0 == .notEnough) // admission does not bypass existing evidence gates
        print("PASS newly eligible sub-five-second reader pool reaches matched worth-it comparison; unchanged three-per-tier/minimum-window evidence gates")
        print("PASS positive-duration eligibility below/exact/above five seconds; 99/100 tokens; zero/negative/missing/nonfinite timing; legacy and exact/ambiguous/conflicting matches; cached/noncached paths; no arbitrary speed cap; measured/total overview/detail/report coverage; unavailable distinct from zero")
        let oldOrder=report.models.map(\.model);row("new","B","xhigh","fast",123,-1)
        precondition(read().preservingOrder(from:report).models.map(\.model)==oldOrder)
        precondition(freshness(now.addingTimeInterval(-90000),now:now).contains("stale"))
        precondition(freshness(nil,now:now)=="No valid timing")
        precondition(readingTime(now).contains("2026"))
        sql("DELETE FROM trusted_turn_cache")
        row("day-edge","Boundary","xhigh","fast",10,86400)
        row("outside-day","Boundary","xhigh","fast",100,86401)
        row("week-edge","Boundary","xhigh","fast",20,7*86400)
        row("outside-week","Boundary","xhigh","fast",200,7*86400+1)
        row("month-edge","Boundary","xhigh","fast",30,30*86400)
        row("outside-month","Boundary","xhigh","fast",300,30*86400+1)
        row("future","Future","xhigh","fast",500,-1)
        let boundaries=read()
        func mean(_ range:SpeedTimeRange)->SpeedStats {boundaries.filtered(range:range,now:now).models.first{$0.model=="Boundary"}!.efforts[0].modes[0].stats()}
        precondition(mean(.day).readings.count==1 && mean(.day).mean==10)
        precondition(mean(.week).readings.count==3 && abs(mean(.week).mean!-130.0/3)<0.00001)
        precondition(mean(.month).readings.count==5 && mean(.month).mean==72)
        precondition(boundaries.filtered(range:.day,now:now).models.count==1)
        sql("DELETE FROM trusted_turn_cache")
        row("old-only","Old model","high","standard",75,2*86400)
        let onlyOld=read()
        precondition(onlyOld.filtered(range:.day,now:now).models.isEmpty) // no stale fallback
        precondition(onlyOld.filtered(range:.week,now:now).models.count==1)
        var persistentNav=SpeedNavigation();persistentNav.open(model:"Old model",effort:"high",mode:"standard")
        let chosenRange=SpeedTimeRange.week
        persistentNav.back();persistentNav.open(model:"Old model",effort:"high",mode:"standard")
        precondition(chosenRange == .week)
        precondition(SpeedTimeRange.day.label=="Last 24 hours" && SpeedTimeRange.month.seconds==30*86400)
        sql("DELETE FROM trusted_turn_cache")
        row("untimed","Only untimed","dynamic-effort","fast",nil,2)
        let untimed=read().models[0].efforts[0].modes[0]
        precondition(untimed.stats().mean==nil && untimed.excluded==1)
        sql("DELETE FROM trusted_turn_cache");precondition(read().models.isEmpty)
        sql("ALTER TABLE trusted_turn_cache ADD COLUMN service_tier_served TEXT")
        sql("ALTER TABLE trusted_turn_cache ADD COLUMN service_tier_requested TEXT")
        row("ultra","Tier model","max","fast",25,10)
        row("requested-ultra","Tier model","max","default",35,11)
        row("priority","Tier model","max","default",60,12)
        row("new-tier","Tier model","max","default",70,13)
        row("unknown-served","Tier model","max","fast",99,14)
        sql("UPDATE trusted_turn_cache SET service_tier_served='ultrafast' WHERE source_id='ultra'")
        sql("UPDATE trusted_turn_cache SET service_tier_requested='ultrafast' WHERE source_id='requested-ultra'")
        sql("UPDATE trusted_turn_cache SET service_tier_served='priority' WHERE source_id='priority'")
        sql("UPDATE trusted_turn_cache SET service_tier_served='future-tier' WHERE source_id='new-tier'")
        sql("UPDATE trusted_turn_cache SET service_tier_served='unknown',service_tier_requested='ultrafast' WHERE source_id='unknown-served'")
        let tierModes=read().models.first{$0.model=="Tier model"}!.efforts[0].modes
        precondition(tierModes.first{$0.mode=="ultrafast"}!.stats().mean==30)
        precondition(tierModes.first{$0.mode=="fast"}!.stats().mean==60)
        precondition(tierModes.first{$0.mode=="future-tier"}!.stats().mean==70)
        precondition(tierModes.first{$0.mode=="unknown"}!.stats().mean==99)
        precondition(!tierModes.contains{$0.mode=="standard"})
        precondition(cleanMode("ultrafast")=="Ultrafast")
        precondition(cleanMode("future-standard")=="Future-Standard")
        let modeFixtures=[ModeRow(name:"fast",tokens:0,turns:1,tps:10),ModeRow(name:"ultrafast",tokens:0,turns:1,tps:999)]
        precondition(ReportModeSummary(modes:modeFixtures).fastRows.count==1)
        precondition(ModeComparison(title:"Test",modes:modeFixtures).fastRows.count==1)
        print("PASS authoritative ultrafast tier isolation; requested fallback; unfamiliar tier preservation; unknown served never inferred")
        precondition(orderedModes(tierModes).map(\.mode).prefix(2)==["ultrafast","fast"])
        for range in SpeedTimeRange.allCases {
            sql("DELETE FROM trusted_turn_cache")
            row("inside","Window","xhigh","fast",10,Int(range.seconds))
            row("outside","Window","xhigh","fast",999,Int(range.seconds)+1)
            row("future","Window","xhigh","fast",999,-1)
            let window=read().filtered(range:range,now:now).models[0].efforts[0].modes[0]
            precondition(window.stats().readings.count==1 && window.stats().mean==10)
            let selected=read().group(for:SpeedSelection(model:"Window",effort:"xhigh",mode:"fast"),range:range,now:now)
            precondition(selected.readings.map(\.id)==window.readings.map(\.id) && selected.stats().mean==window.stats().mean)
            precondition(window.plotReadings.count==1 && window.plotReadings[0].date==now.addingTimeInterval(-range.seconds))
            var state=SpeedNavigation()
            for tier in ["ultrafast","fast","standard","future-tier"] {
                for _ in 0..<100 {state.open(model:"Window",effort:"xhigh",mode:tier);precondition(state.selection?.mode==tier);state.back();precondition(state.selection==nil)}
            }
        }
        sql("DELETE FROM trusted_turn_cache")
        for i in 0..<200 {row("many-\(i)","All records","xhigh","fast",Double(i),i)}
        let all=read().filtered(range:.hour,now:now).models[0].efforts[0].modes[0]
        precondition(all.stats().readings.count==200 && all.stats().mean==99.5)
        precondition(all.plotReadings.map(\.date)==all.readings.map(\.date).reversed())
        precondition(SpeedTimeRange.month.label=="Last 30 days")
        precondition(read().oldestAvailable != nil)
        print("PASS six inclusive rolling windows; all 200 samples in mean; exact tier navigation; chronological plot points without interpolation; retained-history metadata")
        sql("DELETE FROM trusted_turn_cache; ALTER TABLE trusted_turn_cache ADD COLUMN raw_json TEXT")
        func effortRow(_ id:String,reported:String?,selected:String?,source:String,conflict:Int=0,speed:Double=40,mode:String="fast",offset:Int=60) {
            row(id,"Effort provenance",reported,mode,speed,offset)
            let meta:[String:Any]=["selected_reasoning_effort":selected as Any? ?? NSNull(),"reported_reasoning_effort":reported as Any? ?? NSNull(),"selected_effort_source":source,"selected_effort_conflict":conflict,"matching_streams":1,"matching_completions":1,"identity_conflict":0]
            let value=String(data:try! JSONSerialization.data(withJSONObject:meta),encoding:.utf8)!.replacingOccurrences(of:"'",with:"''")
            sql("UPDATE trusted_turn_cache SET raw_json='\(value)' WHERE source_id='\(id)'")
        }
        effortRow("selected-high-1",reported:"high",selected:"high",source:"parent_turn",speed:10)
        effortRow("selected-high-2",reported:"high",selected:"high",source:"parent_turn",speed:30)
        effortRow("reported-high",reported:" HIGH ",selected:nil,source:"unresolved",speed:90)
        effortRow("conflict-fallback",reported:"high",selected:"xhigh",source:"conflict",conflict:1,speed:70)
        effortRow("unresolved-evidence",reported:"high",selected:"xhigh",source:"unresolved",speed:40)
        effortRow("selected-xhigh",reported:"high",selected:"xhigh",source:"parent_turn",speed:50)
        effortRow("reported-extra-high",reported:"extra high",selected:nil,source:"unresolved",speed:150)
        effortRow("unknown-conflict",reported:"unknown",selected:"xhigh",source:"conflict",conflict:1,speed:20)
        effortRow("old-selected",reported:"high",selected:"high",source:"parent_turn",speed:999,offset:7200)
        effortRow("ultra",reported:"high",selected:nil,source:"unresolved",speed:400,mode:"ultrafast")
        effortRow("standard",reported:"high",selected:"high",source:"parent_turn",speed:200,mode:"standard")
        effortRow("reverse-mismatch",reported:"xhigh",selected:" HIGH ",source:"parent_turn",speed:30,mode:"standard")
        effortRow("bad-identity",reported:"high",selected:"high",source:"parent_turn",speed:999)
        sql("UPDATE trusted_turn_cache SET raw_json=json_set(raw_json,'$.identity_conflict',1) WHERE source_id='bad-identity'")
        effortRow("selected-only",reported:nil,selected:"xhigh",source:"parent_turn",speed:80,mode:"standard")
        let proven=read(),hour=proven.filtered(range:.hour,now:now)
        let model=hour.models[0];precondition(model.efforts.count==3 && Set(model.efforts.map(\.id)).count==3)
        precondition(model.efforts.map(\.effort)==["high","xhigh","unknown"])
        let high=proven.group(for:SpeedSelection(model:model.model,effort:"high",mode:"fast"),range:.hour,now:now)
        precondition(high.excluded==1 && !high.readings.contains{$0.id=="test:bad-identity"})
        precondition(high.readings.count==5 && high.stats().mean==48) // Sum all five readings, not an unweighted mean of old provenance-group means.
        precondition(high.readings.filter(\.usesSelected).count==2 && high.readings.filter{!$0.usesSelected}.count==3)
        precondition(model.efforts[0].measuredModes.map(\.mode)==["ultrafast","fast","standard"])
        precondition(model.efforts[0].modes.first{$0.mode=="standard"}!.readings.count==2 && model.efforts[0].modes.first{$0.mode=="standard"}!.mismatchCount==1)
        precondition(model.efforts[0].modes.first{$0.mode=="standard"}!.readings.first{$0.id=="test:reverse-mismatch"}!.selectedEffort==" HIGH ")
        precondition(model.efforts[0].summaryTitle=="Effort high" && model.efforts[0].attributionLabel=="Includes fallback")
        let conflict=high.readings.first{$0.id=="test:conflict-fallback"}!
        precondition(conflict.selectedEffort=="xhigh" && conflict.reportedEffort=="high" && conflict.selectedEffortConflict && !conflict.usesSelected && conflict.effortSource=="conflict")
        let unresolved=high.readings.first{$0.id=="test:unresolved-evidence"}!
        precondition(unresolved.selectedEffort=="xhigh" && !unresolved.usesSelected && unresolved.effortSource=="unresolved")
        let chosen=SpeedSelection(model:model.model,effort:"xhigh",mode:"fast")
        let xhigh=proven.group(for:chosen,range:.hour,now:now)
        precondition(xhigh.readings.count==2 && xhigh.stats().mean==100 && xhigh.mismatchCount==1)
        precondition(xhigh.readings.first{$0.id=="test:selected-xhigh"}!.reportedEffort=="high")
        precondition(xhigh.readings.first{$0.id=="test:reported-extra-high"}!.reportedEffort=="extra high")
        let selectedOnly=proven.group(for:SpeedSelection(model:model.model,effort:"xhigh",mode:"standard"),range:.hour,now:now).readings[0]
        precondition(selectedOnly.selectedEffort=="xhigh" && selectedOnly.reportedEffort==nil && selectedOnly.usesSelected)
        let unknown=proven.group(for:SpeedSelection(model:model.model,effort:"unknown",mode:"fast"),range:.hour,now:now)
        precondition(unknown.readings.count==1 && unknown.readings[0].selectedEffortConflict)
        precondition(proven.group(for:SpeedSelection(model:model.model,effort:"high",mode:"fast"),range:.fourHours,now:now).readings.count==6)
        var effectiveNav=SpeedNavigation()
        for _ in 0..<100 {effectiveNav.open(model:model.model,effort:"high",mode:"fast");let g=proven.group(for:effectiveNav.selection!,range:.hour,now:now);precondition(g.readings.count==5 && g.stats().mean==48);effectiveNav.back();precondition(effectiveNav.selection==nil)}
        // Exact parent evidence arriving with the same effective effort changes attribution, never the bucket, sample identities or mean.
        sql("UPDATE trusted_turn_cache SET raw_json=json_set(raw_json,'$.selected_reasoning_effort','high','$.selected_effort_source','parent_turn') WHERE source_id='reported-high'")
        let afterParent=read().group(for:SpeedSelection(model:model.model,effort:"high",mode:"fast"),range:.hour,now:now)
        precondition(afterParent.readings.map(\.id)==high.readings.map(\.id) && afterParent.stats().mean==48 && afterParent.readings.filter(\.usesSelected).count==3)
        // A truly different exact selection moves only that reading to its correct effective effort.
        sql("UPDATE trusted_turn_cache SET raw_json=json_set(raw_json,'$.selected_reasoning_effort','xhigh') WHERE source_id='reported-high'")
        let corrected=read(),correctedHigh=corrected.group(for:SpeedSelection(model:model.model,effort:"high",mode:"fast"),range:.hour,now:now),correctedX=corrected.group(for:chosen,range:.hour,now:now)
        precondition(correctedHigh.readings.count==4 && correctedX.readings.count==3 && abs(correctedX.stats().mean!-290.0/3)<0.0000001)
        precondition(corrected.models[0].efforts.count==3)
        print("PASS one effective-effort bucket across verified/fallback metadata; all-record weighted subgroup merge, normalized aliases, unknown/conflict handling, raw provenance preserved, exact xhigh precedence and late-parent refresh")
        sql("DELETE FROM trusted_turn_cache")
        for i in 0..<48 {effortRow("ongoing-\(i)",reported:"high",selected:nil,source:"unresolved",offset:i*30)}
        effortRow("same-high-1",reported:"high",selected:"high",source:"parent_turn",speed:10)
        effortRow("same-high-2",reported:"high",selected:"high",source:"parent_turn",speed:30)
        effortRow("different-xhigh",reported:"high",selected:"xhigh",source:"parent_turn",speed:50)
        row("untimed-ultra","Effort provenance","high","ultrafast",nil,20)
        let activeModel=read().filtered(range:.hour,now:now).models[0],active=activeModel.efforts.first{$0.effort=="high"}!
        precondition(activeModel.efforts.count==2 && active.measuredModes.count==1 && active.measuredModes[0].readings.count==50 && active.measuredModes[0].stats().mean==39.2)
        precondition(active.selectedReadingCount==2 && active.fallbackReadingCount==48 && active.untimedModes.map(\.mode)==["ultrafast"])
        precondition(activeModel.efforts.first{$0.effort=="xhigh"}!.modes[0].mismatchCount==1)
        let noTiming=SpeedEffortGroup(effort:"high",modes:active.untimedModes);precondition(noTiming.measuredModes.isEmpty && noTiming.untimedModes.count==1)
        let validZero=SpeedEffortGroup(effort:"low",modes:[SpeedModeGroup(mode:"fast",readings:[SpeedReading(id:"zero",date:now,speed:0,outputTokens:100,durationMS:10000)],responseDates:[now])]);precondition(validZero.measuredModes.count==1 && validZero.untimedModes.isEmpty)
        print("PASS 48 ongoing fallback readings and two exact-high readings form one 50-reading high overview/detail group; xhigh stays separate; no blank timing cards or invented zero")
        // Large single-group history must retain every row without quadratic COW appends.
        sql("DELETE FROM trusted_turn_cache")
        for i in 0..<12000 { effortRow("large-\(i)",reported:"high",selected:nil,source:"unresolved",offset:i % 3600) }
        let largeStart = Date(), large = read()
        precondition(large.error == nil)
        precondition(large.models.flatMap(\.efforts).flatMap(\.modes).reduce(0) {$0 + $1.responseDates.count} == 12000)
        print("PASS 12000 same-group rows retained; read seconds \(Date().timeIntervalSince(largeStart))")
        do {
            let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            defer {try? FileManager.default.removeItem(at:dir)}
            let source=dir.appendingPathComponent("snapshot.sqlite")
            var liveDB: OpaquePointer?
            precondition(sqlite3_open(source.path, &liveDB) == SQLITE_OK)
            defer { sqlite3_close(liveDB) }
            precondition(sqlite3_exec(liveDB, "PRAGMA journal_mode=WAL; CREATE TABLE sample(value); INSERT INTO sample VALUES (7);", nil, nil, nil) == SQLITE_OK)
            let stable=try stableTelemetrySnapshot(at:source.path)
            defer {try? FileManager.default.removeItem(at:stable)}
            // Replacing source after preparation cannot change the copied database.
            try Data("replacement".utf8).write(to:source,options:.atomic)
            var copiedDB: OpaquePointer?, statement: OpaquePointer?
            precondition(sqlite3_open_v2(stable.path, &copiedDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
            defer {sqlite3_finalize(statement);sqlite3_close(copiedDB)}
            precondition(sqlite3_prepare_v2(copiedDB,"SELECT value FROM sample",-1,&statement,nil) == SQLITE_OK)
            precondition(sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement,0) == 7)
            print("PASS stable viewer snapshot survives atomic sync replacement")
        }
        sql("DROP TABLE trusted_turn_cache");precondition(read().error != nil)
        print("PASS exact model/effort/mode isolation; all-record valid arithmetic means; partial windows; missing/zero/dynamic/unknown; no invented combinations; stable refresh order; 100 repeated Back/open cycles; exact time boundaries, future/empty-range exclusions and no fallback; stale/empty/error states")
    }
}
