import Foundation
import CryptoKit

/// Contains only connection metadata. The secret access key belongs in Keychain.
struct S3BackupConfiguration: Codable, Equatable {
    var endpoint = ""
    var region = "us-east-1"
    var bucket = ""
    var objectKey = "Axon/workspace.axonbackup"
    var accessKeyID = ""

    init(endpoint: String = "", region: String = "us-east-1", bucket: String = "",
         objectKey: String = "Axon/workspace.axonbackup", accessKeyID: String = "") {
        self.endpoint = endpoint
        self.region = region
        self.bucket = bucket
        self.objectKey = objectKey
        self.accessKeyID = accessKeyID
    }

    private enum CodingKeys: String, CodingKey { case endpoint, region, bucket, objectKey, accessKeyID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        region = try values.decodeIfPresent(String.self, forKey: .region) ?? "us-east-1"
        bucket = try values.decodeIfPresent(String.self, forKey: .bucket) ?? ""
        objectKey = try values.decodeIfPresent(String.self, forKey: .objectKey) ?? "Axon/workspace.axonbackup"
        accessKeyID = try values.decodeIfPresent(String.self, forKey: .accessKeyID) ?? ""
    }

    /// Path-style URLs also support S3 services mounted below an endpoint path.
    func objectURL() throws -> URL {
        let input = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw S3BackupError.invalidConfiguration("Enter an HTTPS endpoint without credentials, query parameters or a fragment. / 请填写不含凭据、查询参数和片段的 HTTPS Endpoint。")
        }
        let loopbackHosts = ["localhost", "127.0.0.1", "::1", "[::1]"]
        guard scheme == "https" || (scheme == "http" && loopbackHosts.contains(host)) else {
            throw S3BackupError.invalidConfiguration("The S3 endpoint must use HTTPS. / S3 Endpoint 必须使用 HTTPS。")
        }
        guard !bucket.isEmpty, bucket != ".", bucket != "..", bucket.utf8.count <= 255,
              bucket.utf8.allSatisfy({ S3RequestSigner.isUnreserved($0) && $0 != 126 }) else {
            throw S3BackupError.invalidConfiguration("Enter a valid S3 bucket name. / 请填写有效的 S3 空间名。")
        }
        guard !region.isEmpty, region.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else {
            throw S3BackupError.invalidConfiguration("Enter the service's S3 region ID. / 请填写服务商的 S3 Region ID。")
        }
        guard !objectKey.isEmpty, objectKey.utf8.count <= 1_024,
              !objectKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw S3BackupError.invalidConfiguration("Enter an object key of at most 1,024 UTF-8 bytes. / 请填写不超过 1,024 个 UTF-8 字节的对象路径。")
        }
        guard !accessKeyID.isEmpty,
              !accessKeyID.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) || $0 == "/" }) else {
            throw S3BackupError.invalidConfiguration("Enter a valid access key ID. / 请填写有效的 Access Key ID。")
        }
        // Do not resolve '..' or collapse consecutive slashes: S3 keys are literal.
        var basePath = S3RequestSigner.encodedPath(components.percentEncodedPath)
        if basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + "/" + S3RequestSigner.uriEncode(bucket) + "/" + S3RequestSigner.uriEncode(objectKey, preserveSlashes: true)
        guard let url = components.url else {
            throw S3BackupError.invalidConfiguration("The S3 object address is invalid. / S3 对象地址无效。")
        }
        return url
    }
}

enum S3BackupError: LocalizedError, Equatable {
    case invalidConfiguration(String)
    case objectAlreadyExists
    case objectNotFound
    case forbidden
    case redirectNotAllowed
    case responseTooLarge
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): return message
        case .objectAlreadyExists:
            return "A backup already exists at this object key. Choose a new name, for example one containing the date and time. / 此对象路径已有备份，请使用新名称，例如加入日期和时间。"
        case .objectNotFound:
            return "The backup was not found. Check the bucket and object key. / 未找到备份，请检查空间名和对象路径。"
        case .forbidden:
            return "Access was denied. Check the endpoint, region, keys and bucket permissions. / 访问被拒绝，请检查 Endpoint、区域、密钥和空间权限。"
        case .redirectNotAllowed:
            return "The service redirected the request. Use its direct regional S3 endpoint. / 服务重定向了请求，请使用对应区域的直接 S3 Endpoint。"
        case .responseTooLarge:
            return "The backup exceeds the 20 MB limit. / 备份超过 20 MB 上限。"
        case .invalidResponse:
            return "The S3 service returned an invalid response. / S3 服务返回了无效响应。"
        case .httpStatus(let status):
            return "The S3 request failed (HTTP \(status)). / S3 请求失败（HTTP \(status)）。"
        }
    }
}

/// Transfers opaque backup bytes; serialization and encryption are handled by the caller.
struct S3BackupClient {
    static let maximumBackupSize = 20 * 1_024 * 1_024
    private let configuration: S3BackupConfiguration
    private let secretAccessKey: String
    private let session: URLSession

    init(configuration: S3BackupConfiguration, secretAccessKey: String, session: URLSession = .shared) {
        self.configuration = configuration
        self.secretAccessKey = secretAccessKey
        self.session = session
    }

    /// Manual uploads default to creating a new object. Automatic backup calls
    /// explicitly opt into replacing the fixed latest object.
    func upload(_ data: Data, overwrite: Bool = false) async throws {
        guard data.count <= Self.maximumBackupSize else { throw S3BackupError.responseTooLarge }
        let request = try makeRequest(method: "PUT", body: data, overwrite: overwrite)
        _ = try await S3BackupTransfer.perform(request, using: session, maximumSize: Self.maximumBackupSize)
    }

    func download() async throws -> Data {
        let request = try makeRequest(method: "GET", body: Data())
        return try await S3BackupTransfer.perform(request, using: session, maximumSize: Self.maximumBackupSize)
    }

    func makeRequest(method: String, body: Data, date: Date = Date(), overwrite: Bool = false) throws -> URLRequest {
        let url = try configuration.objectURL()
        guard !secretAccessKey.isEmpty else {
            throw S3BackupError.invalidConfiguration("Enter a secret access key. / 请填写 Secret Access Key。")
        }
        var headers: [String: String] = [:]
        if method == "PUT" {
            headers["Content-Type"] = "application/octet-stream"
            // The default prevents accidental manual replacement. Automatic
            // backup deliberately updates the same object with an ordinary PUT.
            if !overwrite { headers["If-None-Match"] = "*" }
        }
        return S3RequestSigner.signedRequest(method: method, url: url, body: body,
                                            accessKeyID: configuration.accessKeyID,
                                            secretAccessKey: secretAccessKey, region: configuration.region,
                                            date: date, headers: headers)
    }
}

/// AWS Signature Version 4, with the S3 rule that the encoded URI is never normalized.
enum S3RequestSigner {
    static func signedRequest(method: String, url: URL, body: Data,
                              accessKeyID: String, secretAccessKey: String, region: String,
                              date: Date, headers: [String: String] = [:]) -> URLRequest {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: date)
        let day = String(timestamp.prefix(8))
        let payloadHash = hex(SHA256.hash(data: body))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = method
        if method != "GET" { request.httpBody = body }
        var signedHeaders = headers.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = normalizeHeader($1.value) }
        var host = url.host?.lowercased() ?? ""
        if host.contains(":"), !host.hasPrefix("[") { host = "[" + host + "]" }
        if let port = url.port { host += ":\(port)" }
        signedHeaders["host"] = host
        signedHeaders["x-amz-date"] = timestamp
        signedHeaders["x-amz-content-sha256"] = payloadHash
        let names = signedHeaders.keys.sorted()
        let headerNames = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(signedHeaders[$0]!)\n" }.joined()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? "/"
        var queryPairs: [(String, String)] = (components?.queryItems ?? []).map {
            (uriEncode($0.name), uriEncode($0.value ?? ""))
        }
        queryPairs.sort { first, second in
            first.0 == second.0 ? first.1 < second.1 : first.0 < second.0
        }
        let canonicalQuery = queryPairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let canonicalRequest = [method, path.isEmpty ? "/" : path, canonicalQuery,
                                canonicalHeaders, headerNames, payloadHash].joined(separator: "\n")
        let scope = "\(day)/\(region)/s3/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", timestamp, scope,
                            hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")
        let dayKey = hmac(Data(("AWS4" + secretAccessKey).utf8), day)
        let regionKey = hmac(dayKey, region)
        let serviceKey = hmac(regionKey, "s3")
        let signingKey = hmac(serviceKey, "aws4_request")
        let signature = hex(hmac(signingKey, stringToSign))
        for (name, value) in signedHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope),SignedHeaders=\(headerNames),Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func isUnreserved(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
            || byte == 45 || byte == 46 || byte == 95 || byte == 126
    }

    static func uriEncode(_ value: String, preserveSlashes: Bool = false) -> String {
        value.utf8.map { byte in
            if isUnreserved(byte) || (preserveSlashes && byte == 47) { return String(UnicodeScalar(byte)) }
            return String(format: "%%%02X", byte)
        }.joined()
    }

    /// Encode reserved endpoint-path bytes while preserving existing escapes.
    /// An encoded slash in a custom service prefix stays an encoded slash.
    static func encodedPath(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var output = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 37, index + 2 < bytes.count,
               let high = hexDigit(bytes[index + 1]), let low = hexDigit(bytes[index + 2]) {
                output += String(format: "%%%02X", high * 16 + low)
                index += 3
            } else {
                output += isUnreserved(byte) || byte == 47 ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
                index += 1
            }
        }
        return output
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        if (48...57).contains(byte) { return byte - 48 }
        if (65...70).contains(byte) { return byte - 65 + 10 }
        if (97...102).contains(byte) { return byte - 97 + 10 }
        return nil
    }

    private static func normalizeHeader(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func hmac(_ key: Data, _ value: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(value.utf8), using: SymmetricKey(data: key)))
    }

    private static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// A private session prevents inherited delegates from following a signed redirect.
/// Streaming delegate callbacks enforce the limit before buffering an entire response.
final class S3BackupTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumSize: Int
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var failure: Error?
    private var cancelled = false

    init(maximumSize: Int) { self.maximumSize = maximumSize }

    static func perform(_ request: URLRequest, using sourceSession: URLSession, maximumSize: Int) async throws -> Data {
        let transfer = S3BackupTransfer(maximumSize: maximumSize)
        // URLSession.configuration is a copy, and preserves injected URLProtocol classes.
        let settings = sourceSession.configuration
        settings.timeoutIntervalForRequest = 60
        settings.timeoutIntervalForResource = 60
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        settings.httpShouldSetCookies = false
        settings.httpAdditionalHeaders = nil
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(request, configuration: settings, continuation: continuation)
            }
        }, onCancel: { transfer.cancel() })
    }

    private func start(_ request: URLRequest, configuration: URLSessionConfiguration, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        if failure == nil { failure = CancellationError() }
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    private func record(_ error: Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        record(S3BackupError.redirectNotAllowed)
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            record(S3BackupError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(response.statusCode) else {
            let error: S3BackupError
            switch response.statusCode {
            case 301...399: error = .redirectNotAllowed
            case 401, 403: error = .forbidden
            case 404: error = .objectNotFound
            case 409, 412: error = .objectAlreadyExists
            default: error = .httpStatus(response.statusCode)
            }
            record(error)
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(maximumSize) else {
            record(S3BackupError.responseTooLarge)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive incoming: Data) {
        lock.lock()
        if incoming.count > maximumSize - data.count {
            if failure == nil { failure = S3BackupError.responseTooLarge }
            lock.unlock()
            dataTask.cancel()
            return
        }
        if failure == nil { data.append(incoming) }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let result: Result<Data, Error>
        if let failure = failure ?? error { result = .failure(failure) }
        else { result = .success(data) }
        let continuation = self.continuation
        self.continuation = nil
        self.task = nil
        self.session = nil
        lock.unlock()
        session.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }
}
