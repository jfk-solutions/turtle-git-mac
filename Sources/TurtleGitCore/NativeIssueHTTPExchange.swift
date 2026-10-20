// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// One request owns its session until the invalidation callback. Cancellation
/// therefore returns after the actual data task/delegate have retired, rather
/// than merely cancelling a Swift continuation and leaving network work alive.
final class NativeIssueHTTPExchange:NSObject,URLSessionDataDelegate,@unchecked Sendable {
    private let lock=NSLock()
    private let request:URLRequest
    private let maximumBytes:Int
    private var session:URLSession?
    private var task:URLSessionDataTask?
    private var continuation:CheckedContinuation<Data,Error>?
    private var bytes=Data()
    private var error:Error?
    private var outcome:Result<Data,Error>?
    private var cancelled=false,finished=false
    init(request:URLRequest,maximumBytes:Int){self.request=request;self.maximumBytes=maximumBytes}
    private struct Failure:LocalizedError,Sendable {let text:String;var errorDescription:String?{text}}
    private var isFinished:Bool {lock.lock();defer{lock.unlock()};return finished}
    func run(cancellation:OperationCancellation?) async throws->Data {
        let watcher=Task { [self] in
            while !Task.isCancelled && !isFinished {
                if cancellation?.isCancelled==true {cancel();return}
                do {try await Task.sleep(nanoseconds:10_000_000)}catch{return}
            }
        }
        defer{watcher.cancel()}
        return try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation {reply in
                let configuration=URLSessionConfiguration.ephemeral
                configuration.urlCache=nil;configuration.httpCookieStorage=nil;configuration.urlCredentialStorage=nil
                configuration.httpShouldSetCookies=false;configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest=30;configuration.timeoutIntervalForResource=45
                configuration.waitsForConnectivity=false;configuration.httpMaximumConnectionsPerHost=1
                let queue=OperationQueue();queue.maxConcurrentOperationCount=1;queue.name="TurtleGit.issue-provider"
                let owned=URLSession(configuration:configuration,delegate:self,delegateQueue:queue)
                let task=owned.dataTask(with:request)
                lock.lock();continuation=reply;session=owned;self.task=task;let stop=cancelled;lock.unlock()
                if stop {task.cancel()};task.resume()
            }
        },onCancel:{self.cancel()})
    }
    private func cancel() {
        lock.lock();cancelled=true;if error==nil {error=OperationCancellationFailure.cancelled};let task=task;lock.unlock()
        task?.cancel()
    }
    private func reject(_ message:String) {lock.lock();if error==nil {error=Failure(text:message)};let task=task;lock.unlock();task?.cancel()}
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping @Sendable(URLRequest?)->Void) {
        reject("Provider redirects are refused. Configure the final endpoint in Settings.");completionHandler(nil)
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping @Sendable(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        if challenge.protectionSpace.authenticationMethod==NSURLAuthenticationMethodServerTrust {completionHandler(.performDefaultHandling,nil)}
        else {reject("Provider authentication failed. Configure its bearer token in Settings.");completionHandler(.cancelAuthenticationChallenge,nil)}
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping @Sendable(URLSession.ResponseDisposition)->Void) {
        guard let response=response as? HTTPURLResponse else{reject("The provider did not return an HTTP response.");completionHandler(.cancel);return}
        guard (200...299).contains(response.statusCode) else {
            reject(response.statusCode==401 || response.statusCode==403 ? "Provider authentication was refused (HTTP \(response.statusCode)). Check its token and permissions in Settings.":"Provider request failed (HTTP \(response.statusCode)).")
            completionHandler(.cancel);return
        }
        guard response.expectedContentLength<=Int64(maximumBytes) else{reject("Provider response exceeds 1 MiB.");completionHandler(.cancel);return}
        let mime=response.mimeType?.lowercased() ?? ""
        guard mime=="application/json" || mime.hasPrefix("application/") && mime.hasSuffix("+json") else{reject("The provider must return application/json.");completionHandler(.cancel);return}
        completionHandler(.allow)
    }
    func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
        lock.lock()
        if data.count>maximumBytes-bytes.count {if error==nil {error=Failure(text:"Provider response exceeds 1 MiB.")};lock.unlock();dataTask.cancel();return}
        if error==nil {bytes.append(data)};lock.unlock()
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError completionError:Error?) {
        lock.lock()
        if let error=error ?? completionError {outcome = .failure(error)}else{outcome = .success(bytes)}
        lock.unlock();session.finishTasksAndInvalidate()
    }
    func urlSession(_ session:URLSession,didBecomeInvalidWithError invalidationError:Error?) {
        lock.lock();finished=true
        let result=outcome ?? .failure(invalidationError ?? Failure(text:"The provider request ended without a response."))
        let reply=continuation;continuation=nil;self.session=nil;task=nil;bytes=Data();lock.unlock()
        reply?.resume(with:result)
    }
}
