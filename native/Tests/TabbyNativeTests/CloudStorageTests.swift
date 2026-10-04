import XCTest
import CryptoKit
import Darwin
@testable import TabbyNative

final class CloudStorageTests: XCTestCase {
    private let accessKey = "AKIAIOSFODNN7EXAMPLE"
    private let secretKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    private var exampleDate: Date { ISO8601DateFormatter().date(from: "2013-05-24T00:00:00Z")! }

    override func tearDown() {
        S3StubProtocol.handler = nil
        super.tearDown()
    }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S3StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func configuration(endpoint: String = "https://backup.example.invalid") -> S3BackupConfiguration {
        S3BackupConfiguration(endpoint: endpoint, bucket: "backups", accessKeyID: accessKey)
    }

    // AWS publishes these vectors specifically for verifying implementations:
    // https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
    func testOfficialAWSGetObjectSignature() throws {
        let request = S3RequestSigner.signedRequest(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!, body: Data(), accessKeyID: accessKey, secretAccessKey: secretKey, region: "us-east-1", date: exampleDate, headers: ["Range": "bytes=0-9"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testOfficialAWSPutObjectSignature() throws {
        let request = S3RequestSigner.signedRequest(method: "PUT", url: URL(string: "https://examplebucket.s3.amazonaws.com/test%24file.text")!, body: Data("Welcome to Amazon S3.".utf8), accessKeyID: accessKey, secretAccessKey: secretKey, region: "us-east-1", date: exampleDate, headers: ["Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class": "REDUCED_REDUNDANCY"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        XCTAssertTrue(try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization")).hasSuffix("Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"))
    }

    func testOfficialAWSLifecycleAndListQuerySignatures() throws {
        for (query, signature) in [("lifecycle", "fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"), ("prefix=J&max-keys=2", "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7")] {
            let request = S3RequestSigner.signedRequest(method: "GET", url: URL(string: "https://examplebucket.s3.amazonaws.com/?" + query)!, body: Data(), accessKeyID: accessKey, secretAccessKey: secretKey, region: "us-east-1", date: exampleDate)
            XCTAssertTrue(try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization")).hasSuffix("Signature=" + signature))
        }
    }

    func testCustomEndpointPathAndObjectKeyEncoding() throws {
        var value = configuration(endpoint: "https://S3.example.invalid:9443/service%2fpath/$prefix/")
        value.objectKey = "资料/a b+%?#.axonbackup//../final"
        let request = try S3BackupClient(configuration: value, secretAccessKey: secretKey).makeRequest(method: "PUT", body: Data("encrypted".utf8), date: exampleDate)
        XCTAssertEqual(request.url?.absoluteString, "https://S3.example.invalid:9443/service%2Fpath/%24prefix/backups/%E8%B5%84%E6%96%99/a%20b%2B%25%3F%23.axonbackup//../final")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Host"), "s3.example.invalid:9443")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
        XCTAssertEqual(request.timeoutInterval, 60)
        let authorization = try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authorization.contains("SignedHeaders=content-type;host;if-none-match;x-amz-content-sha256;x-amz-date"))
        XCTAssertFalse(authorization.contains(secretKey))
    }

    func testQiniuEndpointAndS3Region() throws {
        var value = configuration(endpoint: "https://s3.cn-east-1.qiniucs.com")
        value.region = "cn-east-1"
        value.bucket = "the-global-s3-bucket-name"
        let request = try S3BackupClient(configuration: value, secretAccessKey: secretKey).makeRequest(method: "GET", body: Data(), date: exampleDate)
        XCTAssertEqual(request.url?.absoluteString, "https://s3.cn-east-1.qiniucs.com/the-global-s3-bucket-name/Axon/workspace.axonbackup")
        XCTAssertTrue(try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization")).contains("/cn-east-1/s3/aws4_request"))
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
    }

    func testExplicitReplacementOmitsWriteConditionWithoutChangingManualDefault() throws {
        let client = S3BackupClient(configuration: configuration(), secretAccessKey: secretKey)
        let replacement = try client.makeRequest(method: "PUT", body: Data("new backup".utf8), date: exampleDate, overwrite: true)
        XCTAssertNil(replacement.value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertTrue(try XCTUnwrap(replacement.value(forHTTPHeaderField: "Authorization"))
            .contains("SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date"))
        let manual = try client.makeRequest(method: "PUT", body: Data("manual backup".utf8), date: exampleDate)
        XCTAssertEqual(manual.value(forHTTPHeaderField: "If-None-Match"), "*")
    }

    func testConfigurationDefaultsAndSecretIsNeverSerialized() throws {
        let partial = Data("{\"endpoint\":\"https://s3.example.invalid\",\"bucket\":\"backups\",\"accessKeyID\":\"public-key\"}".utf8)
        let value = try JSONDecoder().decode(S3BackupConfiguration.self, from: partial)
        XCTAssertEqual(value.region, "us-east-1")
        XCTAssertEqual(value.objectKey, "Axon/workspace.axonbackup")
        XCTAssertEqual(try JSONDecoder().decode(S3BackupConfiguration.self, from: JSONEncoder().encode(value)), value)
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertFalse(encoded.contains("secretAccessKey"))
    }

    func testUnsafeOrIncompleteConfigurationFailsBeforeNetworking() throws {
        for endpoint in ["http://s3.example.invalid", "ftp://localhost", "https://key:secret@example.invalid", "https://example.invalid?token=secret", "https://example.invalid/#fragment", "example.invalid", "http://localhost.example.invalid"] {
            XCTAssertThrowsError(try configuration(endpoint: endpoint).objectURL(), endpoint)
        }
        for endpoint in ["http://localhost:9000", "http://127.0.0.1:9000", "http://[::1]:9000", "https://example.invalid/prefix/"] {
            XCTAssertNoThrow(try configuration(endpoint: endpoint).objectURL(), endpoint)
        }
        var invalid = configuration()
        invalid.bucket = "../outside"
        XCTAssertThrowsError(try invalid.objectURL())
        invalid = configuration(); invalid.region = "cn-east-1\nmalformed"
        XCTAssertThrowsError(try invalid.objectURL())
        invalid = configuration(); invalid.objectKey = String(repeating: "界", count: 342)
        XCTAssertThrowsError(try invalid.objectURL())
        invalid = configuration(); invalid.objectKey = "name\nheader"
        XCTAssertThrowsError(try invalid.objectURL())
        invalid = configuration(); invalid.accessKeyID = "key/header"
        XCTAssertThrowsError(try invalid.objectURL())
        XCTAssertThrowsError(try S3BackupClient(configuration: configuration(), secretAccessKey: "").makeRequest(method: "GET", body: Data()))
    }

    func testUploadAndDownloadThroughInjectedProtocol() async throws {
        let bytes = Data("opaque encrypted backup".utf8)
        let received = RequestRecorder()
        S3StubProtocol.handler = { request in
            received.append(request)
            return S3Stub(status: 200, chunks: request.httpMethod == "GET" ? [bytes.prefix(5), bytes.dropFirst(5)] : [])
        }
        let source = session()
        defer { source.invalidateAndCancel() }
        let client = S3BackupClient(configuration: configuration(), secretAccessKey: secretKey, session: source)
        try await client.upload(bytes)
        let downloaded = try await client.download()
        XCTAssertEqual(downloaded, bytes)
        let requests = received.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "GET"])
        XCTAssertEqual(requests.first?.httpBody, bytes)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "If-None-Match"), "*")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization")?.contains("AWS4-HMAC-SHA256") == true })
    }

    func testHTTPFailuresHaveUsefulErrorsWithoutReflectingServerBody() async throws {
        let source = session()
        defer { source.invalidateAndCancel() }
        let client = S3BackupClient(configuration: configuration(), secretAccessKey: secretKey, session: source)
        for (status, expected) in [(403, S3BackupError.forbidden), (404, .objectNotFound), (409, .objectAlreadyExists), (412, .objectAlreadyExists), (500, .httpStatus(500))] {
            S3StubProtocol.handler = { _ in S3Stub(status: status, chunks: [Data("secret server response".utf8)]) }
            do {
                if status == 409 || status == 412 { try await client.upload(Data()) }
                else { _ = try await client.download() }
                XCTFail("Expected HTTP \(status) to fail")
            } catch {
                XCTAssertEqual(error as? S3BackupError, expected)
                XCTAssertFalse(error.localizedDescription.contains("secret server response"))
            }
        }
    }

    func testRedirectNeverSendsSignedRequestToSecondHost() async throws {
        let received = RequestRecorder()
        S3StubProtocol.handler = { request in
            received.append(request)
            return S3Stub(status: 307, redirect: URL(string: "https://another.example.invalid/capture")!)
        }
        let source = session()
        defer { source.invalidateAndCancel() }
        let client = S3BackupClient(configuration: configuration(), secretAccessKey: secretKey, session: source)
        do { _ = try await client.download(); XCTFail("Expected redirect refusal") }
        catch { XCTAssertEqual(error as? S3BackupError, .redirectNotAllowed) }
        XCTAssertEqual(received.requests.count, 1)
        XCTAssertEqual(received.requests.first?.url?.host, "backup.example.invalid")
    }

    func testAdvertisedAndStreamingOversizedDownloadsFail() async throws {
        let source = session()
        defer { source.invalidateAndCancel() }
        let client = S3BackupClient(configuration: configuration(), secretAccessKey: secretKey, session: source)
        S3StubProtocol.handler = { _ in S3Stub(status: 200, headers: ["Content-Length": String(S3BackupClient.maximumBackupSize + 1)]) }
        do { _ = try await client.download(); XCTFail("Expected advertised size rejection") }
        catch { XCTAssertEqual(error as? S3BackupError, .responseTooLarge) }
        let chunk = Data(repeating: 120, count: 1_024 * 1_024)
        S3StubProtocol.handler = { _ in S3Stub(status: 200, chunks: Array(repeating: chunk, count: 21)) }
        do { _ = try await client.download(); XCTFail("Expected streaming size rejection") }
        catch { XCTAssertEqual(error as? S3BackupError, .responseTooLarge) }
    }

    func testOversizedUploadIsRejectedBeforeSending() async throws {
        let received = RequestRecorder()
        S3StubProtocol.handler = { request in received.append(request); return S3Stub(status: 200) }
        let source = session()
        defer { source.invalidateAndCancel() }
        let client = S3BackupClient(configuration: configuration(), secretAccessKey: secretKey, session: source)
        do { try await client.upload(Data(repeating: 0, count: S3BackupClient.maximumBackupSize + 1)); XCTFail("Expected upload size rejection") }
        catch { XCTAssertEqual(error as? S3BackupError, .responseTooLarge) }
        XCTAssertTrue(received.requests.isEmpty)
    }

    func testCancelledTaskDoesNotStartNetworkRequest() async throws {
        let received = RequestRecorder()
        S3StubProtocol.handler = { request in received.append(request); return S3Stub(status: 200) }
        let source = session()
        defer { source.invalidateAndCancel() }
        let client = S3BackupClient(configuration: configuration(), secretAccessKey: secretKey, session: source)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.download()
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(received.requests.isEmpty)
    }

    func testLoopbackHTTPUploadDownloadAndConditionalWritePreserveOriginalBytes() async throws {
        let fixture = try LoopbackS3Fixture()
        defer { fixture.close() }
        var value = configuration(endpoint: fixture.endpoint + "/service")
        value.objectKey = "nested/a b.axonbackup"
        let client = S3BackupClient(configuration: value, secretAccessKey: secretKey)
        let original = Data([0, 1, 2, 255]) + Data("encrypted backup bytes".utf8)
        try await client.upload(original)
        let downloaded = try await client.download()
        XCTAssertEqual(downloaded, original)
        do { try await client.upload(Data("replacement".utf8)); XCTFail("Expected conditional PUT to reject an existing key") }
        catch { XCTAssertEqual(error as? S3BackupError, .objectAlreadyExists) }
        let afterRejectedWrite = try await client.download()
        XCTAssertEqual(afterRejectedWrite, original)
        let requests = fixture.requests
        XCTAssertEqual(requests.map(\.method), ["PUT", "GET", "PUT", "GET"])
        XCTAssertTrue(requests.allSatisfy { $0.path == "/service/backups/nested/a%20b.axonbackup" })
        XCTAssertEqual(requests.first?.body, original)
        XCTAssertEqual(requests.first?.headers["if-none-match"], "*")
        XCTAssertEqual(requests.first?.headers["content-length"], String(original.count))
        XCTAssertTrue(requests.allSatisfy { $0.headers["authorization"]?.hasPrefix("AWS4-HMAC-SHA256 ") == true })
    }

    func testLoopbackHTTPRedirectIsRejectedWithoutFollowingLocation() async throws {
        let fixture = try LoopbackS3Fixture()
        defer { fixture.close() }
        var value = configuration(endpoint: fixture.endpoint)
        value.objectKey = "redirect"
        let client = S3BackupClient(configuration: value, secretAccessKey: secretKey)
        do { _ = try await client.download(); XCTFail("Expected actual HTTP redirect refusal") }
        catch { XCTAssertEqual(error as? S3BackupError, .redirectNotAllowed) }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.requests.first?.path, "/backups/redirect")
    }

    func testAutomaticS3DependencyReplacesEncryptedObjectAndManualUploadStillProtectsIt() async throws {
        let fixture = try LoopbackS3Fixture()
        defer { fixture.close() }
        var value = configuration(endpoint: fixture.endpoint)
        value.objectKey = "Axon/Automatic/Axon-latest.axonbackup"
        let password = "automatic-http-password-fixture"
        var workspace = Workspace()
        workspace.preferences.language = "en-US"
        let first = try WorkspaceArchiveCodec.encode(workspace: workspace, password: password)
        workspace.preferences.language = "zh-CN"
        let second = try WorkspaceArchiveCodec.encode(workspace: workspace, password: password)
        let automaticUpload = AutomaticBackupDependencies().upload
        try await automaticUpload(first, value, secretKey)
        try await automaticUpload(second, value, secretKey)
        let client = S3BackupClient(configuration: value, secretAccessKey: secretKey)
        let current = try await client.download()
        XCTAssertEqual(current, second)
        XCTAssertEqual(try WorkspaceArchiveCodec.decode(current, password: password).workspace.preferences.language, "zh-CN")
        do { try await client.upload(first); XCTFail("Manual upload must still reject the existing automatic object") }
        catch { XCTAssertEqual(error as? S3BackupError, .objectAlreadyExists) }
        let afterRejectedWrite = try await client.download()
        XCTAssertEqual(afterRejectedWrite, second)
        let requests = fixture.requests
        XCTAssertEqual(requests.map(\.method), ["PUT", "PUT", "GET", "PUT", "GET"])
        XCTAssertTrue(requests.allSatisfy { $0.path == "/backups/Axon/Automatic/Axon-latest.axonbackup" })
        XCTAssertEqual(requests[0].body, first); XCTAssertEqual(requests[1].body, second)
        XCTAssertNil(requests[0].headers["if-none-match"]); XCTAssertNil(requests[1].headers["if-none-match"])
        XCTAssertEqual(requests[3].headers["if-none-match"], "*")
        XCTAssertTrue(requests.allSatisfy { $0.headers["authorization"]?.hasPrefix("AWS4-HMAC-SHA256 ") == true })
    }
}

private struct S3Stub {
    var status: Int
    var headers: [String: String] = [:]
    var chunks: [Data] = []
    var redirect: URL? = nil
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ request: URLRequest) { lock.lock(); values.append(request); lock.unlock() }
}

private final class S3StubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((URLRequest) -> S3Stub)?
    static var handler: ((URLRequest) -> S3Stub)? {
        get { lock.lock(); defer { lock.unlock() }; return storedHandler }
        set { lock.lock(); storedHandler = newValue; lock.unlock() }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var received = request
        // Foundation exposes a dataTask's upload body as a stream to URLProtocol.
        // Preserve the bytes for assertions instead of weakening body verification.
        if received.httpBody == nil, let stream = received.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            received.httpBody = body
        }
        guard let stub = Self.handler?(received), let url = received.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.status, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        if let redirect = stub.redirect {
            var forwarded = request
            forwarded.url = redirect
            client?.urlProtocol(self, wasRedirectedTo: forwarded, redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A real HTTP fixture verifies Foundation's wire behavior without an account or
/// an external runtime. The listener binds only to loopback and times out reads.
private final class LoopbackS3Fixture: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }
    private let descriptor: Int32
    private let port: UInt16
    private let lock = NSLock()
    private var closed = false
    private var received: [Request] = []
    private var objects: [String: Data] = [:]
    var endpoint: String { "http://127.0.0.1:\(port)" }
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return received }

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor); throw POSIXError(.EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let inspected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        guard inspected == 0 else { Darwin.close(descriptor); throw POSIXError(.EIO) }
        self.descriptor = descriptor
        self.port = UInt16(bigEndian: address.sin_port)
        DispatchQueue(label: "Axon.CloudStorageTests.loopback").async { self.serve() }
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        Darwin.shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
    }

    private func serve() {
        while true {
            lock.lock(); let finished = closed; lock.unlock()
            if finished { return }
            let client = Darwin.accept(descriptor, nil, nil)
            if client < 0 { return }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            var noSignal: Int32 = 1
            withUnsafePointer(to: &timeout) {
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            }
            withUnsafePointer(to: &noSignal) { _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }
            if let request = readRequest(client) {
                lock.lock(); received.append(request); lock.unlock()
                let status: Int
                var body = Data()
                var extraHeaders = ""
                if request.path == "/backups/redirect" {
                    status = 307
                    extraHeaders = "Location: \(endpoint)/captured\r\n"
                } else if request.method == "PUT" {
                    if let condition = request.headers["if-none-match"], condition != "*" { status = 428 }
                    else if request.headers["if-none-match"] == "*", objects[request.path] != nil { status = 412 }
                    else { objects[request.path] = request.body; status = 200 }
                } else if let object = objects[request.path] { status = 200; body = object }
                else { status = 404 }
                let headers = "HTTP/1.1 \(status) Fixture\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extraHeaders)\r\n"
                let response = Data(headers.utf8) + body
                response.withUnsafeBytes { buffer in
                    var sent = 0
                    while sent < buffer.count {
                        let count = Darwin.send(client, buffer.baseAddress!.advanced(by: sent), buffer.count - sent, 0)
                        if count <= 0 { break }
                        sent += count
                    }
                }
            }
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
        }
    }

    private func readRequest(_ client: Int32) -> Request? {
        let boundary = Data("\r\n\r\n".utf8)
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        var expectedLength: Int?
        var headerEnd: Int?
        var method = "", path = ""
        var headers: [String: String] = [:]
        while bytes.count <= 1_024 * 1_024 {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            bytes.append(contentsOf: buffer.prefix(count))
            if headerEnd == nil, let range = bytes.range(of: boundary) {
                headerEnd = range.upperBound
                let lines = String(decoding: bytes.prefix(range.lowerBound), as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines.first?.split(separator: " ") ?? []
                guard first.count == 3 else { return nil }
                method = String(first[0]); path = String(first[1])
                for line in lines.dropFirst() {
                    guard let separator = line.firstIndex(of: ":") else { continue }
                    headers[String(line[..<separator]).lowercased()] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                }
                expectedLength = Int(headers["content-length"] ?? "0")
                guard let expectedLength, (0...1_024 * 1_024).contains(expectedLength) else { return nil }
            }
            if let headerEnd, let expectedLength, bytes.count >= headerEnd + expectedLength {
                return Request(method: method, path: path, headers: headers, body: bytes.subdata(in: headerEnd..<(headerEnd + expectedLength)))
            }
        }
        return nil
    }
}
