import Foundation

/// One GET with no redirects, no proxy and no cache, timed from the request's
/// own metrics. Any answer below 500 passes, since an internal service may
/// answer 401 or redirect to its login.
public struct ReachabilityCheckerURLSession: ReachabilityChecker {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 3) {
        self.timeout = timeout
    }

    public func check(_ url: URL, insecureTLS: Bool) async -> CheckResult {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return CheckResult(http: "bad URL") }

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1

        let delegate = CheckDelegate(host: host, insecureTLS: insecureTLS)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = timeout
        request.setValue("VPN Widget", forHTTPHeaderField: "User-Agent")

        let outcome = await delegate.run(session.dataTask(with: request))
        return Self.result(from: outcome, hostIsLiteral: Self.isIPLiteral(host))
    }

    struct Outcome: Sendable {
        var status: Int?
        var error: URLError?
        var dnsMS = 0
        var connectMS = 0
        var totalMS = 0
        var resolved = false
    }

    static func result(from o: Outcome, hostIsLiteral: Bool) -> CheckResult {
        var r = CheckResult(dnsMS: o.dnsMS, connectMS: o.connectMS, totalMS: o.totalMS)
        if let status = o.status {
            r.dns = "ok"
            r.http = "HTTP \(status)"
            r.httpStatus = status
            r.ok = status < 500
            return r
        }
        guard let error = o.error else {
            r.http = "failed"
            return r
        }
        let word = describe(error)
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            r.dns = word
            r.connectMS = 0
            r.totalMS = 0
        default:
            r.dns = (o.resolved || hostIsLiteral) ? "ok" : ""
            r.http = word
        }
        return r
    }

    /// Short words, never the error text, which carries addresses.
    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .cannotFindHost: return "no such host"
        case .dnsLookupFailed: return "lookup failed"
        case .timedOut: return "timeout"
        case .cannotConnectToHost:
            switch posixCode(error) {
            case EHOSTUNREACH, ENETUNREACH, ENETDOWN: return "unreachable"
            default: return "refused"
            }
        case .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
            return "unreachable"
        case .networkConnectionLost:
            return "connection reset"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return "bad certificate"
        case .badURL, .unsupportedURL:
            return "bad URL"
        case .cancelled:
            return "cancelled"
        default:
            return "failed"
        }
    }

    static func posixCode(_ error: URLError) -> Int32? {
        var current: NSError? = error as NSError
        while let e = current {
            if e.domain == NSPOSIXErrorDomain { return Int32(e.code) }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return inet_pton(AF_INET, h, &v4) == 1 || inet_pton(AF_INET6, h, &v6) == 1
    }
}

private final class CheckDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let host: String
    private let insecureTLS: Bool
    private let lock = NSLock()
    private var outcome = ReachabilityCheckerURLSession.Outcome()
    private var continuation: CheckedContinuation<ReachabilityCheckerURLSession.Outcome, Never>?

    init(host: String, insecureTLS: Bool) {
        self.host = host
        self.insecureTLS = insecureTLS
    }

    func run(_ task: URLSessionDataTask) async -> ReachabilityCheckerURLSession.Outcome {
        await withCheckedContinuation { c in
            lock.withLock { continuation = c }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        if space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           insecureTLS, space.host == host, let trust = space.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        lock.withLock { outcome.status = (response as? HTTPURLResponse)?.statusCode }
        return .cancel
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let m = metrics.transactionMetrics.first else { return }
        lock.withLock {
            if let s = m.domainLookupStartDate, let e = m.domainLookupEndDate {
                outcome.dnsMS = Int(e.timeIntervalSince(s) * 1000)
                outcome.resolved = true
            }
            if let s = m.connectStartDate, let e = m.connectEndDate {
                outcome.connectMS = max(Int(e.timeIntervalSince(s) * 1000), 1)
            }
            if let s = m.fetchStartDate, let e = m.responseStartDate {
                outcome.totalMS = max(Int(e.timeIntervalSince(s) * 1000), 1)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (c, o): (CheckedContinuation<ReachabilityCheckerURLSession.Outcome, Never>?, ReachabilityCheckerURLSession.Outcome) = lock.withLock {
            if outcome.status == nil, let e = error as? URLError { outcome.error = e }
            else if outcome.status == nil, error != nil { outcome.error = URLError(.unknown) }
            let c = continuation
            continuation = nil
            return (c, outcome)
        }
        c?.resume(returning: o)
    }
}
