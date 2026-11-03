import Foundation

/// Refuses to follow a redirect that leaves the host the request was aimed at.
///
/// Provider requests carry `Authorization: Bearer …` (and, for Grok, `x-userid`).
/// URLSession follows redirects by default and does not guarantee that custom
/// headers are stripped when the destination changes origin, so a redirect from
/// a compromised or misconfigured endpoint could hand the token to another host.
/// Same-host redirects are still allowed; anything else stops here.
private final class ProviderRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let original = task.originalRequest?.url?.host?.lowercased()
    let destination = request.url?.host?.lowercased()
    guard let original, let destination, original == destination,
      request.url?.scheme?.lowercased() == "https"
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

public enum ProviderHTTPSession {
  private static let redirectPolicy = ProviderRedirectPolicy()

  public static let shared: URLSession = Self.make()

  public static func make(
    requestTimeout: TimeInterval = 15,
    resourceTimeout: TimeInterval = 20
  ) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = resourceTimeout
    return URLSession(
      configuration: configuration, delegate: Self.redirectPolicy, delegateQueue: nil)
  }

  public static func boundedData(
    for request: URLRequest,
    using session: URLSession = Self.shared,
    maximumBytes: Int,
    allowsRedirect: (@Sendable (URL?) -> Bool)? = nil
  ) async throws -> (Data, URLResponse) {
    precondition(maximumBytes >= 0)
    let receiver = BoundedHTTPReceiver(maximumBytes: maximumBytes, allowsRedirect: allowsRedirect)
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        let task = session.dataTask(with: request)
        task.delegate = receiver
        receiver.start(task: task, continuation: continuation)
      }
    } onCancel: {
      receiver.cancel()
    }
  }
}

/// Data delegates receive network chunks instead of scheduling one async
/// iteration per byte. A per-task delegate preserves injected session settings
/// and URLProtocol fixtures, while retaining the same redirect policy.
private final class BoundedHTTPReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let maximumBytes: Int
  private let lock = NSLock()
  private var data = Data()
  private var response: URLResponse?
  private var task: URLSessionDataTask?
  private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
  private var finished = false
  /// Nil keeps every redirect on the original host. Only requests that carry
  /// no credentials (installer downloads) widen it.
  private let allowsRedirect: (@Sendable (URL?) -> Bool)?

  init(maximumBytes: Int, allowsRedirect: (@Sendable (URL?) -> Bool)? = nil) {
    self.maximumBytes = maximumBytes
    self.allowsRedirect = allowsRedirect
    self.data.reserveCapacity(min(maximumBytes, 64 * 1_024))
  }

  func start(
    task: URLSessionDataTask,
    continuation: CheckedContinuation<(Data, URLResponse), Error>
  ) {
    self.lock.lock()
    if self.finished {
      self.lock.unlock()
      task.cancel()
      continuation.resume(throwing: CancellationError())
      return
    }
    self.task = task
    self.continuation = continuation
    // Resume before releasing the lock so cancellation cannot precede launch.
    task.resume()
    self.lock.unlock()
  }

  func cancel() {
    self.finish(.failure(CancellationError()), cancelTask: true)
  }

  private func finish(_ result: Result<(Data, URLResponse), Error>, cancelTask: Bool = false) {
    self.lock.lock()
    guard !self.finished else { self.lock.unlock(); return }
    self.finished = true
    let continuation = self.continuation
    let task = self.task
    self.continuation = nil
    self.task = nil
    self.data = Data()
    self.lock.unlock()
    if cancelTask { task?.cancel() }
    continuation?.resume(with: result)
  }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    self.lock.lock()
    let finished = self.finished
    self.response = response
    self.lock.unlock()
    if finished || response.expectedContentLength > Int64(self.maximumBytes) {
      completionHandler(.cancel)
      if !finished { self.rejectOversize() }
    } else {
      completionHandler(.allow)
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    self.lock.lock()
    guard !self.finished else { self.lock.unlock(); return }
    let exceedsLimit = data.count > self.maximumBytes - self.data.count
    if !exceedsLimit { self.data.append(data) }
    self.lock.unlock()
    if exceedsLimit { self.rejectOversize() }
  }

  private func rejectOversize() {
    self.finish(
      .failure(UsageProviderError.invalidResponse(
        "network response exceeded \(self.maximumBytes) bytes")), cancelTask: true)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    self.lock.lock()
    let data = self.data
    let response = self.response
    self.lock.unlock()
    if let error {
      self.finish(.failure(error))
    } else if let response {
      self.finish(.success((data, response)))
    } else {
      self.finish(.failure(UsageProviderError.invalidResponse("network response was missing")))
    }
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    if let allowsRedirect = self.allowsRedirect {
      completionHandler(allowsRedirect(request.url) ? request : nil)
      return
    }
    let original = task.originalRequest?.url?.host?.lowercased()
    let destination = request.url?.host?.lowercased()
    completionHandler(
      original != nil && original == destination && request.url?.scheme?.lowercased() == "https"
        ? request : nil)
  }
}
