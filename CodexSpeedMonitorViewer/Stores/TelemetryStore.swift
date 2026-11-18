import Foundation
import SQLite3

let dbPath: String = {
    if let override = ProcessInfo.processInfo.environment["CODEX_TELEMETRY_DB"], !override.isEmpty {
        return override
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let defaultDir = support?.appendingPathComponent("CodexSpeedMonitor", isDirectory: true)
        ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/CodexSpeedMonitor", isDirectory: true)
    let configURL = defaultDir.appendingPathComponent("config.json")
    if let data = try? Data(contentsOf: configURL),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let configured = obj["db_path"] as? String,
       !configured.isEmpty {
        return configured
    }
    return defaultDir.appendingPathComponent("codex_telemetry.sqlite").path
}()

// The caller owns cleanup. SQLite backup also includes committed WAL pages for
// locally collected databases; copying only the .sqlite file would lose them.
func stableTelemetrySnapshot(at source: String) throws -> URL {
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-viewer-read-" + UUID().uuidString + ".sqlite")
    var input: OpaquePointer?, output: OpaquePointer?
    var succeeded = false
    defer {
        if output != nil { sqlite3_close(output) }
        if input != nil { sqlite3_close(input) }
        if !succeeded { try? FileManager.default.removeItem(at: destination) }
    }
    func failure() -> NSError { NSError(domain: "CodexSpeedMonitor.Snapshot", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to prepare a stable telemetry snapshot."]) }
    guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw failure() }
    guard sqlite3_open_v2(source, &input, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
          sqlite3_open_v2(destination.path, &output, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw failure() }
    // This is a disposable read copy, not durable user storage.
    guard sqlite3_exec(output, "PRAGMA synchronous=OFF; PRAGMA journal_mode=MEMORY", nil, nil, nil) == SQLITE_OK else { throw failure() }
    guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw failure() }
    let result = sqlite3_backup_step(backup, -1)
    let finished = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finished == SQLITE_OK,
          sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw failure() }
    guard sqlite3_close(output) == SQLITE_OK else { throw failure() }
    output = nil
    if let stamp = try? FileManager.default.attributesOfItem(atPath: source)[.modificationDate] {
        try? FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: destination.path)
    }
    succeeded = true
    return destination
}

private struct TelemetryPayload {
    let snapshot: Snapshot
    let speedReport: RecentSpeedReport
    let days: [MiniDay]
    let hours: [MiniDay]
    let modes: [ModeRow]
    let effectiveSnapshot: Snapshot
    let effectiveDays: [MiniDay]
    let effectiveHours: [MiniDay]
    let effectiveModes: [ModeRow]
    let models: [ModelRow]
    let reasoning: [ReasoningRow]
    let recent: [RecentTurn]
}

private struct QuerySource {
    let usageTable: String
    let speedTable: String
    let cached: Bool
}

final class TelemetryStore: ObservableObject {
    @Published var speedReport = RecentSpeedReport()
    @Published var snapshot = Snapshot()
    @Published var days: [MiniDay] = []
    @Published var hours: [MiniDay] = []
    @Published var modes: [ModeRow] = []
    @Published var effectiveSnapshot = Snapshot()
    @Published var effectiveDays: [MiniDay] = []
    @Published var effectiveHours: [MiniDay] = []
    @Published var effectiveModes: [ModeRow] = []
    @Published var models: [ModelRow] = []
    @Published var reasoning: [ReasoningRow] = []
    @Published var recent: [RecentTurn] = []
    @Published var refreshing = false

    @Published private(set) var historicalReportingReady = false
    private var historicalReportingVisible = false
    func setHistoricalReportingVisible(_ visible: Bool) {
        guard historicalReportingVisible != visible else { return }
        historicalReportingVisible = visible
        historicalReportingReady = false
        cache.removeAll()
        refresh(scope: activeScope, force: true)
    }

    private let queue = DispatchQueue(label: "codex.telemetry.viewer.store", qos: .utility)
    private var loading = false
    private var activeScope = "today"
    private var pendingScope: String?
    private var cache: [String: TelemetryPayload] = [:]
    private var lastLoadedAt: [String: Date] = [:]
    private let minimumRefreshInterval: TimeInterval = 15

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    private let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone.current
        return f
    }()

    init() {
        refresh(scope: "today", force: true)
    }

    func setScope(_ rawScope: String) {
        let scope = normalizedScope(rawScope)
        activeScope = scope
        if let payload = cache[scope] {
            apply(payload)
            historicalReportingReady = historicalReportingVisible
        } else if historicalReportingVisible {
            historicalReportingReady = false
        }
        refresh(scope: scope)
    }

    func refresh(scope rawScope: String = "today", force: Bool = false) {
        let scope = normalizedScope(rawScope)
        activeScope = scope
        let includeHistorical = historicalReportingVisible
        queue.async {
            if self.loading && !force {
                self.pendingScope = scope
                return
            }
            if !force, let last = self.lastLoadedAt[scope], Date().timeIntervalSince(last) < self.minimumRefreshInterval {
                return
            }
            self.loading = true
            DispatchQueue.main.async { self.refreshing = true }
            defer {
                self.loading = false
                DispatchQueue.main.async { self.refreshing = false }
            }

            // Sync publishes by atomically replacing dbPath. SQLite's macOS VFS
            // can reject a connection whose original vnode disappears mid-read.
            // Read an isolated copy so all payload queries see one stable snapshot.
            let readURL: URL
            do { readURL = try stableTelemetrySnapshot(at: dbPath) }
            catch {
                DispatchQueue.main.async { self.speedReport.error = "Snapshot unavailable. Check the existing sync connection." }
                return
            }
            defer { try? FileManager.default.removeItem(at: readURL) }
            var db: OpaquePointer?
            guard sqlite3_open_v2(readURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                if db != nil { sqlite3_close(db) }
                DispatchQueue.main.async { self.speedReport.error = "Snapshot unavailable. Check the existing sync connection." }
                return
            }
            defer { sqlite3_close(db) }

            let payload = self.loadPayload(db, scope: scope, snapshotPath: readURL.path, includeHistorical: includeHistorical)
            self.lastLoadedAt[scope] = Date()

            DispatchQueue.main.async {
                guard includeHistorical == self.historicalReportingVisible else { return }
                self.cache[scope] = payload
                if let active = self.cache[self.activeScope] {
                    self.apply(active)
                    self.historicalReportingReady = includeHistorical
                }
            }

            if let pending = self.pendingScope, pending != scope {
                self.pendingScope = nil
                self.refresh(scope: pending, force: true)
            } else {
                self.pendingScope = nil
            }
        }
    }

    // Independent read-only snapshot for a consented sharing provider. Never uses
    // cached UI state or mutates the visible report. Disabled app never calls it.
    func readSharingSnapshot() async -> RecentSpeedReport {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.readSharingSnapshot(path: dbPath)) }
        }
    }
    // Injectable path/time only for synthetic reader tests. Never use the UI cache:
    // its rebuild can lag despite a fresh heartbeat and copied-file modification time.
    static func readSharingSnapshot(path: String, now: Date = Date()) -> RecentSpeedReport {
        func failed() -> RecentSpeedReport { var report = RecentSpeedReport(); report.error = "Sharing snapshot unavailable"; return report }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }; return failed()
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { return failed() }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        return RecentSpeedReport.read(db, usageTable: "trusted_codex_turns", speedTable: "trusted_codex_speed_turns", cached: false, path: path, now: now)
    }

    private func loadPayload(_ db: OpaquePointer?, scope: String, snapshotPath: String, includeHistorical: Bool) -> TelemetryPayload {
        let source = querySource(db)
        let report = RecentSpeedReport.read(db, usageTable: source.usageTable, speedTable: source.speedTable, cached: source.cached, path: snapshotPath)
        if !includeHistorical {
            // The live chart never consumes the old tables. Read them on demand
            // for History & export rather than blocking each fifteen-second refresh.
            var light = Snapshot()
            if let heartbeat = report.heartbeat {
                light.heartbeatAge = Date().timeIntervalSince(heartbeat)
                light.live = light.heartbeatAge < 90
            }
            return TelemetryPayload(snapshot: light, speedReport: report, days: [], hours: [], modes: [],
                effectiveSnapshot: light, effectiveDays: [], effectiveHours: [], effectiveModes: [],
                models: [], reasoning: [], recent: [])
        }
        let nextSnapshot = loadSnapshot(db, source: source, scope: scope)
        let cutoff = nextSnapshot.cutover
        return TelemetryPayload(
            snapshot: nextSnapshot,
            speedReport: report,
            days: loadDays(db, source: source, cutoff: cutoff, scope: scope),
            hours: loadHours(db, source: source, cutoff: cutoff, scope: scope),
            modes: loadModes(db, source: source, cutoff: cutoff, scope: scope),
            effectiveSnapshot: loadEffectiveSnapshot(db, base: nextSnapshot, scope: scope),
            effectiveDays: loadEffectiveDays(db, scope: scope),
            effectiveHours: loadEffectiveHours(db, scope: scope),
            effectiveModes: loadEffectiveModes(db, scope: scope),
            models: loadModels(db, source: source, cutoff: cutoff, scope: scope),
            reasoning: loadReasoning(db, source: source, cutoff: cutoff, scope: scope),
            recent: loadRecent(db, source: source, cutoff: cutoff, scope: scope)
        )
    }

    private func apply(_ payload: TelemetryPayload) {
        speedReport = payload.speedReport.preservingOrder(from: speedReport)
        snapshot = payload.snapshot
        days = payload.days
        hours = payload.hours
        modes = payload.modes
        effectiveSnapshot = payload.effectiveSnapshot
        effectiveDays = payload.effectiveDays
        effectiveHours = payload.effectiveHours
        effectiveModes = payload.effectiveModes
        models = payload.models
        reasoning = payload.reasoning
        recent = payload.recent
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private func querySource(_ db: OpaquePointer?) -> QuerySource {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "select 1 from sqlite_master where type='table' and name='trusted_turn_cache' limit 1", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return QuerySource(usageTable: "trusted_turn_cache", speedTable: "trusted_turn_cache", cached: true)
            }
        } else {
            sqlite3_finalize(stmt)
        }
        return QuerySource(usageTable: "trusted_codex_turns", speedTable: "trusted_codex_speed_turns", cached: false)
    }

    private func cutoff(_ db: OpaquePointer?) -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select value from capture_state where key='trusted_cutover_at' limit 1", -1, &stmt, nil) == SQLITE_OK else { return "1970-01-01T00:00:00Z" }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? text(stmt, 0) : "1970-01-01T00:00:00Z"
    }

    private func normalizedScope(_ scope: String) -> String {
        if scope == "7d" || scope == "14d" { return scope }
        return "today"
    }

    private func rangePredicate(_ scope: String) -> String {
        switch normalizedScope(scope) {
        case "7d":
            return "date(completed_at, 'localtime') >= date('now', 'localtime', '-6 days')"
        case "14d":
            return "date(completed_at, 'localtime') >= date('now', 'localtime', '-13 days')"
        default:
            return "date(completed_at, 'localtime') = date('now', 'localtime')"
        }
    }

    private func trustedPredicate(cutover: String, scope: String) -> String {
        "completed_at is not null and \(rangePredicate(scope))"
    }

    private func speedEligibilitySQL(source:QuerySource,alias:String="")->String {
        let prefix=(alias.isEmpty ? source.usageTable : alias)+"."
        let legacy=source.cached ? prefix+"speed_eligible" : "EXISTS(SELECT 1 FROM \(source.speedTable) s WHERE s.source=\(prefix)source AND s.source_id=\(prefix)source_id)"
        return measuredReplyEligibilitySQL(legacyEligibleSQL:legacy,prefix:prefix)
    }
    private func speedPredicate(source: QuerySource, scope: String) -> String {
        "\(speedEligibilitySQL(source:source)) and completed_at is not null and julianday(completed_at)<=julianday('now') and \(rangePredicate(scope))"
    }

    private func hasTable(_ db: OpaquePointer?, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        let safeName = name.replacingOccurrences(of: "'", with: "''")
        let sql = "select 1 from sqlite_master where type='table' and name='\(safeName)' limit 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func effectivePredicate(scope: String) -> String {
        "confidence = 'exact' and completed_at is not null and duration_ms > 0 and output_tokens > 0 and \(rangePredicate(scope))"
    }

    private func effectiveLaneSQL() -> String {
        """
        case
          when lower(coalesce(mode,'')) = 'fast' then 'Fast'
          when lower(coalesce(mode,'')) in ('default','standard') then 'Standard'
          else 'Other'
        end
        """
    }

    private func modeSQL() -> String {
        let raw="lower(trim(coalesce(nullif(trim(service_tier_served),''),nullif(trim(service_tier_requested),''),nullif(trim(mode),''),'unknown')))"
        return "case \(raw) when 'priority' then 'fast' when 'default' then 'standard' else \(raw) end"
    }

    private func laneSQL(source: QuerySource) -> String {
        if source.cached { return "lane" }
        return """
        case
          when lower(\(modeSQL())) = 'fast' then 'Fast'
          when lower(\(modeSQL())) = 'standard' then 'Standard'
          else 'Other'
        end
        """
    }

    private func speedBucketSQL(scope: String) -> String {
        if normalizedScope(scope) == "today" {
            return """
            strftime('%Y-%m-%d %H:', completed_at, 'localtime') ||
            printf('%02d', (cast(strftime('%M', completed_at, 'localtime') as integer) / 5) * 5)
            """
        }
        return "strftime('%Y-%m-%d %H:00', completed_at, 'localtime')"
    }

    private func loadSnapshot(_ db: OpaquePointer?, source: QuerySource, scope: String) -> Snapshot {
        var s = Snapshot()
        s.cutover = cutoff(db)
        var stmt: OpaquePointer?
        let trusted = trustedPredicate(cutover: s.cutover, scope: scope)
        let speedTrusted = speedPredicate(source: source, scope: scope)

        let summarySQL = """
        select
          (select count(*) from \(source.usageTable) where \(trusted)),
          (select coalesce(sum(total_tokens),0) from \(source.usageTable) where \(trusted)),
          (select coalesce(avg(output_tokens_per_second),0) from \(source.usageTable) where \(speedTrusted))
        """
        if sqlite3_prepare_v2(db, summarySQL, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            s.todayTurns = Int(sqlite3_column_int(stmt, 0))
            s.todayTokens = sqlite3_column_int64(stmt, 1)
            s.todayTPS = sqlite3_column_double(stmt, 2)
            s.trustedTurns = s.todayTurns
        }
        sqlite3_finalize(stmt)

        let latestSQL = """
        select coalesce(model,'-'), \(modeSQL()), coalesce(output_tokens_per_second,0)
        from \(source.usageTable)
        where \(speedTrusted)
        order by completed_at desc
        limit 1
        """
        if sqlite3_prepare_v2(db, latestSQL, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            s.latestModel = text(stmt, 0)
            s.latestMode = text(stmt, 1)
            s.latestTPS = sqlite3_column_double(stmt, 2)
        }
        sqlite3_finalize(stmt)

        let hbSQL = "select ts from daemon_heartbeats order by id desc limit 1"
        if sqlite3_prepare_v2(db, hbSQL, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            if let date = parseISO(text(stmt, 0)) {
                s.heartbeatAge = Date().timeIntervalSince(date)
                s.live = s.heartbeatAge < 90
            }
        }
        sqlite3_finalize(stmt)
        return s
    }

    private func loadEffectiveSnapshot(_ db: OpaquePointer?, base: Snapshot, scope: String) -> Snapshot {
        var s = base
        s.todayTurns = 0
        s.todayTokens = 0
        s.todayTPS = 0
        s.trustedTurns = 0
        s.latestModel = "-"
        s.latestMode = "-"
        s.latestTPS = 0
        guard hasTable(db, "effective_turns") else { return s }

        var stmt: OpaquePointer?
        let predicate = effectivePredicate(scope: scope)
        let summarySQL = """
        select count(*), coalesce(sum(total_tokens),0),
               coalesce(sum(output_tokens) * 1000.0 / nullif(sum(duration_ms),0),0)
        from effective_turns
        where \(predicate)
        """
        if sqlite3_prepare_v2(db, summarySQL, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            s.todayTurns = Int(sqlite3_column_int(stmt, 0))
            s.todayTokens = sqlite3_column_int64(stmt, 1)
            s.todayTPS = sqlite3_column_double(stmt, 2)
            s.trustedTurns = s.todayTurns
        }
        sqlite3_finalize(stmt)

        let latestSQL = """
        select coalesce(model,'-'), coalesce(mode,'-'),
               coalesce(output_tokens * 1000.0 / nullif(duration_ms,0),0)
        from effective_turns
        where \(predicate)
        order by completed_at desc
        limit 1
        """
        if sqlite3_prepare_v2(db, latestSQL, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            s.latestModel = text(stmt, 0)
            s.latestMode = text(stmt, 1)
            s.latestTPS = sqlite3_column_double(stmt, 2)
        }
        sqlite3_finalize(stmt)
        return s
    }

    private func loadEffectiveHours(_ db: OpaquePointer?, scope: String) -> [MiniDay] {
        guard hasTable(db, "effective_turns") else { return [] }
        let bucket = speedBucketSQL(scope: scope)
        let sql = """
        select \(bucket) as bucket, \(effectiveLaneSQL()) as lane,
               coalesce(sum(output_tokens) * 1000.0 / nullif(sum(duration_ms),0),0) as tps,
               coalesce(sum(total_tokens),0) as tokens
        from effective_turns
        where \(effectivePredicate(scope: scope))
        group by bucket, lane
        order by bucket, lane
        """
        return loadSeries(db, sql: sql, formatter: hourFormatter)
    }

    private func loadEffectiveDays(_ db: OpaquePointer?, scope: String) -> [MiniDay] {
        guard hasTable(db, "effective_turns") else { return [] }
        let sql = """
        select date(completed_at, 'localtime') as day, \(effectiveLaneSQL()) as lane,
               coalesce(sum(output_tokens) * 1000.0 / nullif(sum(duration_ms),0),0) as tps,
               coalesce(sum(total_tokens),0) as tokens
        from effective_turns
        where \(effectivePredicate(scope: scope))
        group by day, lane
        order by day, lane
        """
        return loadSeries(db, sql: sql, formatter: dayFormatter)
    }

    private func loadEffectiveModes(_ db: OpaquePointer?, scope: String) -> [ModeRow] {
        guard hasTable(db, "effective_turns") else { return [] }
        var rows: [ModeRow] = []
        var stmt: OpaquePointer?
        let sql = """
        select \(effectiveLaneSQL()) as lane,
               coalesce(sum(total_tokens),0) as tokens,
               count(*) as turns,
               coalesce(sum(output_tokens) * 1000.0 / nullif(sum(duration_ms),0),0) as tps
        from effective_turns
        where \(effectivePredicate(scope: scope))
        group by lane
        order by case lane when 'Fast' then 0 when 'Standard' then 1 else 2 end
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(ModeRow(name: text(stmt, 0), tokens: sqlite3_column_int64(stmt, 1), turns: Int(sqlite3_column_int(stmt, 2)), tps: sqlite3_column_double(stmt, 3)))
        }
        return rows
    }

    private func loadHours(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [MiniDay] {
        let trusted = speedPredicate(source: source, scope: scope)
        let bucket = source.cached ? (normalizedScope(scope) == "today" ? "five_min_bucket" : "hour_bucket") : speedBucketSQL(scope: scope)
        let sql = """
        with turns as (
          select \(bucket) as bucket,
                 \(laneSQL(source: source)) as lane,
                 output_tokens_per_second,
                 total_tokens
          from \(source.usageTable)
          where \(trusted)
        )
        select bucket, lane, coalesce(avg(output_tokens_per_second),0), coalesce(sum(total_tokens),0)
        from turns
        where lane in ('Fast', 'Standard')
        group by 1, 2
        order by 1, 2
        """
        return loadSeries(db, sql: sql, formatter: hourFormatter)
    }

    private func loadDays(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [MiniDay] {
        let trusted = speedPredicate(source: source, scope: scope)
        let bucket = source.cached ? "day_bucket" : "date(completed_at, 'localtime')"
        let sql = """
        with turns as (
          select \(bucket) as bucket,
                 \(laneSQL(source: source)) as lane,
                 output_tokens_per_second,
                 total_tokens
          from \(source.usageTable)
          where \(trusted)
        )
        select bucket, lane, coalesce(avg(output_tokens_per_second),0), coalesce(sum(total_tokens),0)
        from turns
        where lane in ('Fast', 'Standard')
        group by 1, 2
        order by 1, 2
        """
        return loadSeries(db, sql: sql, formatter: dayFormatter)
    }

    private func loadSeries(_ db: OpaquePointer?, sql: String, formatter: DateFormatter) -> [MiniDay] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [MiniDay] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let date = formatter.date(from: text(stmt, 0)) else { continue }
            rows.append(MiniDay(date: date, lane: text(stmt, 1), tps: sqlite3_column_double(stmt, 2), tokens: sqlite3_column_double(stmt, 3)))
        }
        return rows
    }

    private func loadModes(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [ModeRow] {
        let trusted = trustedPredicate(cutover: cutoff, scope: scope)
        let speedTrusted = speedPredicate(source: source, scope: scope)
        let sql = """
        with usage as (
          select \(modeSQL()) as mode, coalesce(sum(total_tokens),0) as tokens, count(*) as turns
          from \(source.usageTable)
          where \(trusted)
          group by 1
        ),
        speed as (
          select \(modeSQL()) as mode, coalesce(avg(output_tokens_per_second),0) as tps
          from \(source.usageTable)
          where \(speedTrusted)
          group by 1
        )
        select usage.mode, usage.tokens, usage.turns, coalesce(speed.tps,0)
        from usage left join speed using(mode)
        order by usage.tokens desc
        limit 4
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ModeRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(ModeRow(name: text(stmt, 0), tokens: sqlite3_column_int64(stmt, 1), turns: Int(sqlite3_column_int(stmt, 2)), tps: sqlite3_column_double(stmt, 3)))
        }
        return rows
    }

    private func loadModels(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [ModelRow] {
        let trusted = trustedPredicate(cutover: cutoff, scope: scope)
        let sql = """
        with usage as (
          select coalesce(model,'unknown') as model, \(modeSQL()) as mode, coalesce(reasoning_effort,'unspecified') as reasoning, coalesce(sum(total_tokens),0) as tokens, count(*) as turns
          from \(source.usageTable)
          where \(trusted)
          group by 1, 2, 3
        ),
        speed as (
          select coalesce(model,'unknown') as model, \(modeSQL()) as mode, coalesce(reasoning_effort,'unspecified') as reasoning, coalesce(avg(output_tokens_per_second),0) as tps
          from \(source.usageTable)
          where \(speedPredicate(source: source, scope: scope))
          group by 1, 2, 3
        )
        select usage.model, usage.mode, usage.reasoning, usage.tokens, usage.turns, coalesce(speed.tps,0)
        from usage left join speed using(model, mode, reasoning)
        order by usage.tokens desc
        limit 10
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ModelRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(ModelRow(model: text(stmt, 0), mode: text(stmt, 1), reasoning: text(stmt, 2), tokens: sqlite3_column_int64(stmt, 3), turns: Int(sqlite3_column_int(stmt, 4)), tps: sqlite3_column_double(stmt, 5)))
        }
        return rows
    }

    private func loadReasoning(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [ReasoningRow] {
        let trusted = trustedPredicate(cutover: cutoff, scope: scope)
        let sql = """
        with usage as (
          select coalesce(reasoning_effort,'unspecified') as level, coalesce(sum(total_tokens),0) as tokens, count(*) as turns
          from \(source.usageTable)
          where \(trusted)
          group by 1
        ),
        speed as (
          select coalesce(reasoning_effort,'unspecified') as level, coalesce(avg(output_tokens_per_second),0) as tps
          from \(source.usageTable)
          where \(speedPredicate(source: source, scope: scope))
          group by 1
        )
        select usage.level, usage.tokens, usage.turns, speed.tps
        from usage left join speed using(level)
        order by usage.tokens desc
        limit 6
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ReasoningRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tps = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Optional(sqlite3_column_double(stmt, 3))
            rows.append(ReasoningRow(level: text(stmt, 0), tokens: sqlite3_column_int64(stmt, 1), turns: Int(sqlite3_column_int(stmt, 2)), tps: tps))
        }
        return rows
    }

    private func loadRecent(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [RecentTurn] {
        let trusted = speedPredicate(source: source, scope: scope)
        let sql = """
        select coalesce(completed_at,''), coalesce(model,'unknown'), \(modeSQL()), coalesce(reasoning_effort,'unspecified'), coalesce(total_tokens,0), coalesce(output_tokens_per_second,0)
        from \(source.usageTable)
        where \(trusted)
        order by completed_at desc
        limit 10
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [RecentTurn] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(RecentTurn(completedAt: text(stmt, 0), model: text(stmt, 1), mode: text(stmt, 2), reasoning: text(stmt, 3), tokens: sqlite3_column_int64(stmt, 4), tps: sqlite3_column_double(stmt, 5)))
        }
        return rows
    }

    func exportTrustedCSV(to url: URL, scope rawScope: String = "today") throws {
        let scope = normalizedScope(rawScope)
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                if db != nil { sqlite3_close(db) }
                DispatchQueue.main.async { self.speedReport.error = "Snapshot unavailable. Check the existing sync connection." }
                return
            }
        defer { sqlite3_close(db) }
        let source=querySource(db)
        let eligibleSQL=speedEligibilitySQL(source:source,alias:"u")
        let cutoffValue = cutoff(db)
        let trusted = trustedPredicate(cutover: cutoffValue, scope: scope)
        let sql = """
        select completed_at,
               surface,
               coalesce(model,''),
               \(modeSQL()),
               coalesce(service_tier_requested,''),
               coalesce(service_tier_served,''),
               coalesce(reasoning_effort,'unspecified'),
               coalesce(input_tokens,0),
               coalesce(cached_input_tokens,0),
               coalesce(output_tokens,0),
               coalesce(reasoning_tokens,0),
               coalesce(total_tokens,0),
               output_tokens_per_second,
               non_reasoning_tokens_per_second,
               duration_ms,
               case when source='app_response' then 'api_created_completed_seconds'
                    when source='otel_trace' then 'otel_span_nanos'
                    else source end,
               \(eligibleSQL),
               coalesce(thread_id,''),
               json_extract(case when json_valid(raw_json) then raw_json else '{}' end,'$.selected_reasoning_effort'),
               coalesce(json_extract(case when json_valid(raw_json) then raw_json else '{}' end,'$.reported_reasoning_effort'),reasoning_effort),
               coalesce(json_extract(case when json_valid(raw_json) then raw_json else '{}' end,'$.selected_effort_source'),'unresolved'),
               coalesce(json_extract(case when json_valid(raw_json) then raw_json else '{}' end,'$.selected_effort_conflict'),0)
        from \(source.usageTable) u
        where \(trusted)
        order by completed_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        var lines = ["completed_at,surface,model,mode,service_tier_requested,service_tier_served,reasoning_effort,input_tokens,cached_input_tokens,output_tokens,reasoning_tokens,total_tokens,output_tokens_per_second,non_reasoning_tokens_per_second,duration_ms,timing_source,speed_eligible,thread_id,selected_reasoning_effort,reported_reasoning_effort,selected_effort_source,selected_effort_conflict"]
        while sqlite3_step(stmt) == SQLITE_ROW {
            var cols: [String] = []
            for i in 0..<Int(sqlite3_column_count(stmt)) { cols.append(csv(text(stmt, Int32(i)))) }
            lines.append(cols.joined(separator: ","))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func csv(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
