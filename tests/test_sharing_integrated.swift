import Foundation
import AppKit

private final class IntegratedHTTP: URLProtocol {
    static let lock = NSLock()
    static var posts = 0
    static var configs = 0
    static var configBody = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.host == "sharing.example.invalid")
        let data: Data
        if request.url?.path == "/records" {
            precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer SYNTHETIC_INVITE_NOT_REAL_000000001")
            Self.lock.lock(); Self.posts += 1; Self.lock.unlock()
            data = Data("{\"accepted\":true}".utf8)
        } else {
            precondition(request.url?.path == "/config" && request.value(forHTTPHeaderField:"Authorization") == nil)
            Self.lock.lock(); Self.configs += 1; Self.lock.unlock()
            data = Self.configBody
        }
        client?.urlProtocol(self, didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static var configCount: Int { lock.lock(); defer {lock.unlock()}; return configs }
    static var count: Int { lock.lock(); defer {lock.unlock()}; return posts }
}
@main struct SharingIntegratedTests {
    @MainActor static func eventually(_ predicate: () -> Bool) async {
        for _ in 0..<200 { if predicate() {return}; try? await Task.sleep(nanoseconds:5_000_000) }
        preconditionFailure("Synthetic integration timed out")
    }
    @MainActor static func main() async throws {
        let now = Date(timeIntervalSince1970:1_800_000_010)
        let window = SharingClientState.completedWindow(at:now)!
        let draft = SharingMeasurementDraft(methodId:SharingMethod.id,windowStart:window,comparisons:[SharingComparison(model:"synthetic",tier:"standard",ratio:1.1, exactEffort: "high")])
        let fresh = SharingFreshDraft(checkedAt:now,snapshotAt:now,heartbeat:now,draft:draft)
        precondition(fresh.isFresh(window:window,now:now))
        for bad in [nil, now.addingTimeInterval(-121), now.addingTimeInterval(1), Date(timeIntervalSince1970:Double(window)/1000)] as [Date?] {
            precondition(!SharingFreshDraft(checkedAt:now,snapshotAt:now,heartbeat:bad,draft:draft).isFresh(window:window,now:now))
        }
        let disabled = SharingIntegratedRuntime()
        disabled.configure { _,_,_ in fatalError("Disabled runtime read telemetry") }
        disabled.poll();precondition(!disabled.isScheduling);disabled.shutdown()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sharing-integrated-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer {try? FileManager.default.removeItem(at:root)}
        let http = URLSessionConfiguration.ephemeral;http.protocolClasses=[IntegratedHTTP.self]
        IntegratedHTTP.configBody=Data("{\"enabled\":true,\"minAppVersion\":\"1.0.0\",\"models\":[\"synthetic\"],\"regions\":[\"europe\"],\"windowSeconds\":1800,\"exactEfforts\":[\"minimal\",\"low\",\"medium\",\"high\",\"xhigh\",\"max\",\"ultra\"],\"graceSeconds\":300,\"methodId\":\"\(SharingMethod.id)\"}".utf8)
        for mode in ["fresh","stale","cancel","shutdown","outside"] {
            let base=root.appendingPathComponent(mode)
            try FileManager.default.createDirectory(at:base,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            var currentTime = now
            var controller: SharingOfflineController?
            let onboarding=SharingOnboarding(policy:.reviewedEndpoint(URL(string:"https://sharing.example.invalid")!),appVersion:"1.0.0",httpConfiguration:http,clock:{currentTime},makeController:{ date in
                let c=try SharingStorageLocation.controller(enabled:true,applicationDirectory:base,now:date)!
                controller=c;return c
            })
            let runtime=SharingIntegratedRuntime(onboarding:onboarding)
            var reads=0
            var suspended: CheckedContinuation<SharingFreshDraft?,Never>?
            runtime.configure { _,_,_ in
                reads += 1
                if mode == "cancel" { return await withCheckedContinuation { suspended=$0 } }
                if mode == "stale" { return SharingFreshDraft(checkedAt:now,snapshotAt:now,heartbeat:nil,draft:draft) }
                return fresh
            }
            await onboarding.checkConfiguration()
            precondition(!runtime.isScheduling && controller == nil)
            let before=IntegratedHTTP.count, beforeConfigs=IntegratedHTTP.configCount
            onboarding.approve(account:.personal,region:"europe",reviewed:true,invite:"SYNTHETIC_INVITE_NOT_REAL_000000001")
            if mode == "outside" {
                currentTime = Date(timeIntervalSince1970:Double(window+SharingMethod.windowMS+SharingMethod.graceMS)/1000+1)
                await eventually {runtime.isScheduling && !onboarding.busy}
                for _ in 0..<10 {await Task.yield()}
                precondition(reads==0 && IntegratedHTTP.count==before && IntegratedHTTP.configCount==beforeConfigs)
                runtime.shutdown();continue
            }
            if mode == "shutdown" {
                runtime.shutdown() // before Combine's queued start callback can run
                for _ in 0..<10 {await Task.yield()}
                precondition(!runtime.isScheduling && reads==0 && IntegratedHTTP.count==before)
                continue
            }
            await eventually { reads == 1 }
            if mode == "cancel" {
                runtime.stop();suspended!.resume(returning:fresh)
                for _ in 0..<20 {await Task.yield()}
                precondition(IntegratedHTTP.count==before && controller!.state.pending==nil && !controller!.state.consented)
            } else if mode == "stale" {
                await eventually {!onboarding.busy}
                precondition(IntegratedHTTP.count==before && controller!.state.pending==nil && onboarding.status.contains("Fresh post-window"))
            } else {
                await eventually {controller!.state.accepted}
                precondition(IntegratedHTTP.count==before+1 && runtime.isScheduling)
                runtime.poll();await eventually {!onboarding.busy}
                precondition(reads==1 && IntegratedHTTP.count==before+1)
            }
            runtime.shutdown()
            precondition(!runtime.isScheduling && onboarding.session==nil)
        }
        print("PASS unified runtime→managed storage→fresh synthetic provider→HTTP acknowledgement; default no-I/O; stale/missing/future/pre-window rejection; no duplicate send; cancellation during async telemetry; queued start invalidated by shutdown")
    }
}
