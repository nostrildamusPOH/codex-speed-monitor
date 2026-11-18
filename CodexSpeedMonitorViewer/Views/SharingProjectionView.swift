import SwiftUI
import Charts

struct SharingProjectionView: View {
    // Synthetic injection is test-only; personal points require explicit local projection.
    var syntheticPoints: [SharingProjectionPoint] = []
    var points: [SharingProjectionPoint] = []
    private var displayed: [SharingProjectionPoint] { syntheticPoints.isEmpty ? points : syntheticPoints }
    var blocked: SharingProjectionBlock = .missingBaseline
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hypothetical projection at your usual speed").font(.headline)
            Text("Community median ratio × your matching usual generating speed. A hypothetical scenario, not observed user speed or a prediction.")
                .font(.caption).foregroundStyle(.secondary)
            if displayed.isEmpty || !SharingProjection.coherent(displayed) {
                Text(displayed.isEmpty ? blocked.rawValue : "Series has gaps or incompatible inputs. Chart withheld rather than interpolating missing evidence.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(syntheticPoints.isEmpty ? "HYPOTHETICAL SCENARIO · NOT OBSERVED SPEED" : "SYNTHETIC MATCHED-EFFORT DEMO · NOT YOUR DATA").font(.caption.bold()).foregroundStyle(.orange)
                if let first = displayed.first {
                    Text("\(first.model) · \(first.tier) · exact effort: \(first.exactEffort) · \(first.region) · baseline calendar: \(first.baselineTimeZone)").font(.caption)
                }
                Chart(displayed.sorted { $0.windowStart < $1.windowStart }) { point in
                    LineMark(x:.value("UTC window", Date(timeIntervalSince1970:Double(point.windowStart)/1000)),y:.value("Estimated tokens/s",point.baseline))
                        .foregroundStyle(by:.value("Series","Your usual estimate"))
                        .lineStyle(StrokeStyle(lineWidth:1.5,dash:[2,3]))
                    LineMark(x:.value("UTC window", Date(timeIntervalSince1970:Double(point.windowStart)/1000)),y:.value("Estimated tokens/s",point.hypothetical))
                        .foregroundStyle(by:.value("Series","Hypothetical projection"))
                        .lineStyle(StrokeStyle(lineWidth:2,dash:[6,3]))
                    PointMark(x:.value("UTC window", Date(timeIntervalSince1970:Double(point.windowStart)/1000)),y:.value("Estimated tokens/s",point.hypothetical))
                        .foregroundStyle(by:.value("Series","Hypothetical projection"))
                }
                .chartForegroundStyleScale(["Your usual estimate":Color.gray,"Hypothetical projection":Color.purple])
                .chartYAxisLabel("Estimated tokens/s")
                .chartXAxis {
                    AxisMarks(values:.automatic(desiredCount:4)) { value in
                        AxisGridLine();AxisTick()
                        if let date=value.as(Date.self) { AxisValueLabel(Self.utc(date)) }
                    }
                }
                .chartXAxisLabel("Observation window start · UTC")
                .frame(height:220)
                .accessibilityLabel("Hypothetical generating-speed projection. Dashed gray is the local usual estimate; dashed purple is the community ratio multiplied by that estimate. No observed user speeds are shown.")
                Text("No confidence band: the server supplies neither uncertainty nor exact contributor counts. The local usual estimate requires at least five eligible days with three timed replies each, 100+ output tokens per reply, and matching method/model/tier/effort.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).background(.white.opacity(0.045),in:RoundedRectangle(cornerRadius:10))
    }
    private static func utc(_ date: Date) -> String {
        let f=DateFormatter();f.timeZone=TimeZone(secondsFromGMT:0);f.dateFormat="HH:mm";return f.string(from:date)
    }
}
