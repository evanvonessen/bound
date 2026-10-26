import Foundation

private final class BoundDebugNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

protocol BoundDebugServing: Sendable {
    func request(_ body: [String: BoundDebugJSON], session: AppCloudSession) async throws -> BoundDebugJSON
    func request(_ body: [String: BoundDebugJSON], session: AppCloudSession,timeout:TimeInterval) async throws -> BoundDebugJSON
}
extension BoundDebugServing {
    func request(_ body:[String:BoundDebugJSON],session:AppCloudSession,timeout:TimeInterval) async throws -> BoundDebugJSON {
        try await request(body,session:session)
    }
}

/// Only the gateway can issue DEBUG authority. Account authentication is read
/// afresh for every request; this service never persists tokens or capabilities.
struct BoundDebugService: BoundDebugServing {
    struct Response: Sendable { let data: Data; let status: Int; let url: URL? }
    typealias Transport = @Sendable (URLRequest) async throws -> Response
    private let transport: Transport
    init(transport: @escaping Transport = { try await Self.perform($0) }) { self.transport=transport }

    func request(_ body: [String: BoundDebugJSON], session: AppCloudSession) async throws -> BoundDebugJSON {
        try await request(body,session:session,timeout:10)
    }
    func request(_ body:[String:BoundDebugJSON],session:AppCloudSession,timeout:TimeInterval) async throws -> BoundDebugJSON {
        try Task.checkCancellation()
        guard timeout.isFinite,timeout>0,timeout<=10 else { throw BoundDebugFailure.invalidResponse }
        var request=try session.debugRequest(body:BoundDebugJSON.object(body).data(limit:65_536));request.timeoutInterval=timeout
        let response: Response
        do { response=try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch let failure as BoundDebugFailure { throw failure }
        catch { throw BoundDebugFailure.timedOut }
        try Task.checkCancellation()
        try session.credentials()
        guard response.url==request.url,response.data.count<=524_288 else { throw BoundDebugFailure.invalidResponse }
        guard response.status==200 else {
            // Never surface arbitrary gateway/body text, which could contain
            // account information or a reflected credential.
            switch response.status {
            case 401:throw BoundDebugFailure.signedOut
            case 403:throw BoundDebugFailure.rejected
            case 409:throw BoundDebugFailure.busy
            case 408,429,500...599:throw BoundDebugFailure.timedOut
            default:throw BoundDebugFailure.invalidResponse
            }
        }
        let value=try BoundDebugJSON(data:response.data)
        guard value.object != nil else { throw BoundDebugFailure.invalidResponse }
        return value
    }

    static func perform(_ request: URLRequest) async throws -> Response {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies=false;configuration.httpCookieStorage=nil;configuration.urlCache=nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest=request.timeoutInterval;configuration.timeoutIntervalForResource=request.timeoutInterval
        let session=URLSession(configuration:configuration,delegate:BoundDebugNoRedirect(),delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        let (stream,response)=try await session.bytes(for:request)
        guard let response=response as? HTTPURLResponse,response.url==request.url else { throw BoundDebugFailure.invalidResponse }
        if response.expectedContentLength>524_288 { throw BoundDebugFailure.invalidResponse }
        var data=Data()
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count<524_288 else { throw BoundDebugFailure.invalidResponse }
            data.append(byte)
        }
        return .init(data:data,status:response.statusCode,url:response.url)
    }
}
