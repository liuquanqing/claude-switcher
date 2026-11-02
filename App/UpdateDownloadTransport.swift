import Foundation
import SwitcherCore

/// The delegate queue is serial. No authenticated request headers are used.
final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { AppReleasePolicy.permitsHTTPS($0, redirectedAsset: true) } == true ? request : nil)
    }
}
final class UpdateDownloadTransport: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var downloaded: URL?
    private var failure: Error?
    private let destination: URL
    private let expectedSize: Int64
    private let progress: @Sendable (Double) -> Void
    private var session: URLSession!
    private var task: URLSessionDownloadTask!
    init(asset: AppReleaseAsset, destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination=destination;self.expectedSize=asset.size;self.progress=progress
        super.init()
        let config=URLSessionConfiguration.ephemeral
        config.urlCache=nil;config.httpCookieStorage=nil
        config.timeoutIntervalForRequest=30;config.timeoutIntervalForResource=600
        let queue=OperationQueue();queue.maxConcurrentOperationCount=1
        session=URLSession(configuration:config,delegate:self,delegateQueue:queue)
        task=session.downloadTask(with:asset.downloadURL)
    }
    func run() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation=continuation;task.resume()
        }
    }
    func cancel() { task.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedSize {
            failure=SafetyError("更新包大小与发布信息不符。");downloadTask.cancel();return
        }
        progress(min(1,Double(totalBytesWritten)/Double(expectedSize)))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode==200,
                  let url=downloadTask.response?.url,AppReleasePolicy.permitsHTTPS(url,redirectedAsset:true) else {
                throw SafetyError("更新下载未完成，请稍后重试。")
            }
            let size=(try FileManager.default.attributesOfItem(atPath:location.path)[.size] as? NSNumber)?.int64Value
            guard size==expectedSize else { throw SafetyError("更新包尚未完整下载。") }
            try FileManager.default.moveItem(at:location,to:destination);downloaded=destination
        } catch { failure=error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result=continuation;continuation=nil
        defer { session.finishTasksAndInvalidate() }
        if let problem=failure ?? error { result?.resume(throwing:problem) }
        else if let downloaded { result?.resume(returning:downloaded) }
        else { result?.resume(throwing:SafetyError("没有取得完整更新包。")) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { AppReleasePolicy.permitsHTTPS($0,redirectedAsset:true) } == true ? request : nil)
    }
}
