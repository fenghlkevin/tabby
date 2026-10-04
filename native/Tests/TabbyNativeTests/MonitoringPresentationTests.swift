import XCTest
@testable import TabbyNative

final class MonitoringPresentationTests: XCTestCase {
    func testMissingMetricsAndBinaryCapacityUnitsRemainAccurate() {
        XCTAssertEqual(MonitoringPresentation.bytes(UInt64(1024)), "1.0 KiB")
        XCTAssertEqual(MonitoringPresentation.bytes(UInt64(1073741824)), "1.0 GiB")
        XCTAssertEqual(MonitoringPresentation.bytes(UInt64(0)), "0 B")
        XCTAssertEqual(MonitoringPresentation.bytes(nil), "—")
        XCTAssertEqual(MonitoringPresentation.rate(nil), "—")
        XCTAssertEqual(MonitoringPresentation.rate(-1), "—")
        XCTAssertEqual(MonitoringPresentation.rate(.infinity), "—")
        XCTAssertEqual(MonitoringPresentation.rate(0), "0 B/s")
        XCTAssertNil(MonitoringPresentation.percent(1, 0))
        XCTAssertNil(MonitoringPresentation.percent(101, 100))
        XCTAssertEqual(MonitoringPresentation.percent(25, 100), 25)
        XCTAssertEqual(MonitoringPresentation.percentage(nil), "—")
        XCTAssertEqual(MonitoringPresentation.percentage(.nan), "—")
    }
    func testLoadSparklineUsesOnlyBoundedValidRealSamples() {
        let values = [-1, .infinity, .nan] + (0..<150).map(Double.init)
        let result = MonitoringPresentation.sparklineSamples(values)
        XCTAssertEqual(result.count, 60)
        XCTAssertEqual(result.first, 90)
        XCTAssertEqual(result.last, 149)
        XCTAssertTrue(MonitoringPresentation.sparklineSamples([.nan, -.infinity, -1]).isEmpty)
    }
    func testTrendUsesActualTimeAndDoesNotJoinAcrossPausedIntervals() {
        let start = Date(timeIntervalSince1970: 1000)
        let points = [0.0, 5, 10, 6010, 6015].map { MonitoringTrendPoint(timestamp: start.addingTimeInterval($0), value: 1) }
        let samples = MonitoringPresentation.trendSamples(points)
        XCTAssertEqual(MonitoringPresentation.trendX(samples[1], in: samples), 5.0 / 6015.0, accuracy: 0.000001)
        XCTAssertEqual(MonitoringPresentation.trendX(samples.last!, in: samples), 1)
        XCTAssertEqual(MonitoringPresentation.trendSegments(samples).map(\.count), [3, 2])
        let many = (0..<150).map { MonitoringTrendPoint(timestamp: start.addingTimeInterval(Double($0)), value: Double($0)) }
        XCTAssertEqual(MonitoringPresentation.trendSamples(many).count, 60)
        let replaced = MonitoringPresentation.trendSamples([points[0], MonitoringTrendPoint(timestamp: start, value: 9)])
        XCTAssertEqual(replaced.count, 1); XCTAssertEqual(replaced[0].value, 9)
    }
    func testNetworkClassificationUsesRealLocalAddressFacts() {
        XCTAssertEqual(MonitoringPresentation.addressKind("172.26.148.202/24"), .privateAddress)
        XCTAssertEqual(MonitoringPresentation.addressKind("192.168.0.1"), .privateAddress)
        XCTAssertEqual(MonitoringPresentation.addressKind("10.1.2.3"), .privateAddress)
        XCTAssertEqual(MonitoringPresentation.addressKind("100.64.1.1"), .shared)
        XCTAssertEqual(MonitoringPresentation.addressKind("127.0.0.1/8"), .loopback)
        XCTAssertEqual(MonitoringPresentation.addressKind("169.254.1.2"), .linkLocal)
        XCTAssertEqual(MonitoringPresentation.addressKind("203.0.113.42"), .reserved)
        XCTAssertEqual(MonitoringPresentation.addressKind("8.8.8.8"), .publicAddress)
        XCTAssertEqual(MonitoringPresentation.addressKind("fc00::1/7"), .privateAddress)
        XCTAssertEqual(MonitoringPresentation.addressKind("fe80::1%en0/64"), .linkLocal)
        XCTAssertEqual(MonitoringPresentation.addressKind("::1"), .loopback)
        XCTAssertEqual(MonitoringPresentation.addressKind("::ffff:192.168.1.2"), .privateAddress)
        XCTAssertEqual(MonitoringPresentation.addressKind("2001:db8::1"), .reserved)
        XCTAssertEqual(MonitoringPresentation.addressKind("2001:4860:4860::8888"), .publicAddress)
        XCTAssertNil(MonitoringPresentation.addressKind("server.invalid"))
    }
    func testProcessSortKeepsMissingMetricsLastAndSortsActualValues() {
        let unknown = process(1, cpu: nil, memory: nil)
        let smaller = process(2, cpu: 2, memory: 1024)
        let bigger = process(3, cpu: 12, memory: 4096)
        let values = [unknown, smaller, bigger]
        XCTAssertEqual(MonitoringProcessOrdering.sorted(values, by: .cpu, descending: true).map(\.pid), [3, 2, 1])
        XCTAssertEqual(MonitoringProcessOrdering.sorted(values, by: .cpu, descending: false).map(\.pid), [2, 3, 1])
        XCTAssertEqual(MonitoringProcessOrdering.sorted(values, by: .memory, descending: true).map(\.pid), [3, 2, 1])
        XCTAssertEqual(MonitoringProcessOrdering.sorted(values, by: .memory, descending: false).map(\.pid), [2, 3, 1])
        XCTAssertEqual(MonitoringProcessOrdering.sorted(values, by: .pid, descending: false).map(\.pid), [1, 2, 3])
    }
    private func process(_ pid: Int, cpu: Double?, memory: UInt64?) -> MonitoringProcess {
        MonitoringProcess(pid: pid, user: "root", threads: nil, state: "S", cpuPercent: cpu, memoryBytes: memory, command: "process-\(pid)")
    }
}
