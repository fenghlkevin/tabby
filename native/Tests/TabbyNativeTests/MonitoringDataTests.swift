import XCTest
@testable import TabbyNative

final class MonitoringDataTests: XCTestCase {
    private let sampledAt = Date(timeIntervalSince1970: 1_791_032_400)
    private func frame(_ name: String, _ body: String, status: String = "ok") -> String {
        name + "\t" + status + "\t" + Data(body.utf8).base64EncodedString() + "\n"
    }
    private func sample(_ fields: [(String, String)], uptime: Double = 100, bootID: String = "boot-a", os: String = "Linux") -> String {
        "AXON_MONITOR_V1\n" + frame("system", "os=\(os)\nkernel=fixture\nuptime=\(uptime)\nbootID=\(bootID)\n") + fields.map { frame($0.0, $0.1) }.joined() + "AXON_MONITOR_END\n"
    }
    private func parse(_ raw: String, previous: MonitoringSnapshot? = nil, date: Date? = nil) throws -> MonitoringSnapshot {
        try MonitoringSampleParser.parse(raw: raw, previous: previous, timestamp: date ?? sampledAt)
    }
    private func fixture(_ name: String) throws -> String {
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: native.appendingPathComponent("scripts/fixtures/\(name).txt"), encoding: .utf8)
    }
    private func replacingFrame(_ raw: String, name: String, body: String, status: String = "ok") -> String {
        raw.components(separatedBy: "\n").map { line in line.hasPrefix(name + "\t") ? String(frame(name, body, status: status).dropLast()) : line }.joined(separator: "\n")
    }

    func testFullLinuxFixtureHasRealOptionalModulesAndNoFirstSampleRates() throws {
        let value = try parse(fixture("monitoring-linux"))
        XCTAssertTrue(value.isSupported)
        XCTAssertEqual(value.coreCount, 4)
        XCTAssertEqual(value.cpu?.cores.count, 4)
        XCTAssertNil(value.cpu?.usagePercent)
        XCTAssertEqual(value.cpuModel, "Synthetic 4/16-core QA CPU")
        XCTAssertEqual(value.architecture, "x86_64")
        XCTAssertEqual(value.memory?.totalBytes, 32 * 1024 * 1024 * 1024)
        XCTAssertEqual(value.memory?.freeBytes, 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(value.memory?.availableBytes, 22 * 1024 * 1024 * 1024)
        XCTAssertEqual(value.disks.count, 4)
        XCTAssertTrue(value.disks.contains { $0.mountpoint == "/srv/archive data" })
        XCTAssertEqual(value.processes.count, 3)
        XCTAssertEqual(value.processes.first?.threads, 12)
        XCTAssertEqual(value.processes.first?.cpuPercent, 18.5) // ps lifecycle average
        XCTAssertEqual(value.processes.first?.memoryBytes, 256 * 1024 * 1024)
        XCTAssertFalse(value.processes.first?.arguments?.contains("fixture-secret") ?? true)
        XCTAssertEqual(value.interfaces.first { $0.name == "eth0" }?.addresses.count, 3)
        XCTAssertNil(value.interfaces.first?.receiveBytesPerSecond)
        XCTAssertNil(value.diskIO.first?.readBytesPerSecond)
        XCTAssertEqual(value.gpus.count, 2)
        XCTAssertEqual(value.gpus.first?.fanPercent, 38)
        XCTAssertEqual(value.gpus.first?.cudaVersion, "12.4")
        XCTAssertNil(value.gpus.last?.temperatureCelsius)
        XCTAssertNil(value.gpus.last?.utilizationPercent)
        XCTAssertNil(value.gpus.last?.fanPercent)
        XCTAssertEqual(value.gpuProcesses.count, 2)
        XCTAssertEqual(value.containers.count, 2)
        XCTAssertEqual(value.containers.first?.health, "healthy")
        XCTAssertEqual(value.containers.first?.ports, "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp")
        XCTAssertEqual(value.containers.last?.restartCount, 2)
        XCTAssertNil(value.containers.last?.cpuPercent)
        XCTAssertEqual(value.trafficHistory?.records.count, 37)
        XCTAssertEqual(value.availability["history"], "Available")
    }

    func testRatesUseServerUptimeInsteadOfWallClockAndSectorBytesAre512() throws {
        let first = try parse(fixture("monitoring-linux"))
        let next = try parse(fixture("monitoring-linux-next"), previous: first, date: sampledAt.addingTimeInterval(-1000))
        XCTAssertEqual(try XCTUnwrap(next.interfaces.first { $0.name == "eth0" }?.receiveBytesPerSecond), 1_048_576, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(next.interfaces.first { $0.name == "eth0" }?.transmitBytesPerSecond), 524_288, accuracy: 0.001)
        let device = try XCTUnwrap(next.diskIO.first { $0.device == "nvme0n1" })
        XCTAssertEqual(try XCTUnwrap(device.readBytesPerSecond), 128 * 512 / 5.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(device.readIOPS), 8 / 5.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(device.utilizationPercent), 3, accuracy: 0.001)
        XCTAssertNotNil(next.cpu?.usagePercent)
        XCTAssertEqual(next.availability["cpu"], "Available")
    }

    func testCPUExcludesGuestDoubleCountingAndIncludesInterruptsInSystem() throws {
        let first = try parse(sample([("cpu", "cpu 100 0 50 800 0 0 0 0 50 0\ncpu0 100 0 50 800 0 0 0 0 50 0\n")]))
        let next = try parse(sample([("cpu", "cpu 120 5 65 850 5 3 2 0 70 1\ncpu0 120 5 65 850 5 3 2 0 70 1\n")], uptime: 105), previous: first)
        XCTAssertEqual(try XCTUnwrap(next.cpu?.usagePercent), 45, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(next.cpu?.userPercent), 20, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(next.cpu?.systemPercent), 20, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(next.cpu?.nicePercent), 5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(next.cpu?.ioWaitPercent), 5, accuracy: 0.0001)
        XCTAssertEqual(next.cpu?.cores.first?.usagePercent, next.cpu?.usagePercent)
    }

    func testRebootUptimeResetAndTopologyChangeInvalidateCPUBaseline() throws {
        let first = try parse(fixture("monitoring-linux"))
        let raw = try fixture("monitoring-linux-next")
        let reboot = replacingFrame(raw, name: "system", body: "os=Linux\nuptime=86405\nbootID=another-boot\n")
        let rebooted = try parse(reboot, previous: first)
        XCTAssertNil(rebooted.cpu?.usagePercent)
        XCTAssertNil(rebooted.diskIO.first?.readBytesPerSecond)
        XCTAssertNil(rebooted.interfaces.first?.receiveBytesPerSecond)
        let backwards = replacingFrame(raw, name: "system", body: "os=Linux\nuptime=10\nbootID=11111111-2222-3333-4444-555555555555\n")
        XCTAssertNil(try parse(backwards, previous: first).cpu?.usagePercent)
        let hotplug = try parse(fixture("monitoring-linux-16cores-next"), previous: first)
        XCTAssertEqual(hotplug.coreCount, 16)
        XCTAssertNil(hotplug.cpu?.usagePercent)
        let sixteen = try parse(fixture("monitoring-linux-16cores"))
        XCTAssertNotNil(try parse(fixture("monitoring-linux-16cores-next"), previous: sixteen).cpu?.usagePercent)
    }

    func testOneResetCounterInvalidatesEntireDeviceOrInterfaceAndNeverUnderflows() throws {
        let first = try parse(fixture("monitoring-linux"))
        var raw = try fixture("monitoring-linux-next")
        raw = replacingFrame(raw, name: "interfaces", body: "eth0: 1 0 0 0 0 0 0 0 800100000 0 0 0 0 0 0 0\n")
        raw = replacingFrame(raw, name: "diskIO", body: "259 0 nvme0n1 40010 0 1000020 200 12010 0 800020 300 0 1 6000\n")
        let next = try parse(raw, previous: first)
        XCTAssertNil(next.interfaces.first?.receiveBytesPerSecond)
        XCTAssertNil(next.interfaces.first?.transmitBytesPerSecond)
        XCTAssertNil(next.diskIO.first?.readBytesPerSecond)
        XCTAssertNil(next.diskIO.first?.utilizationPercent)
        let cpuFirst = try parse(sample([("cpu", "cpu 100 0 20 200 100 0 0 0\ncpu0 100 0 20 200 100 0 0 0\n")]))
        let cpuNext = try parse(sample([("cpu", "cpu 110 0 25 250 90 0 0 0\ncpu0 110 0 25 250 90 0 0 0\n")], uptime: 105), previous: cpuFirst)
        XCTAssertNil(cpuNext.cpu?.usagePercent) // Linux iowait can decrease; wait for another valid baseline.
    }

    func testMissingMemoryFieldsAndOverflowRemainUnavailableInsteadOfZero() throws {
        let memory = "MemTotal: 1024 kB\nMemFree: 256 kB\nCached: 128 kB\nSwapTotal: 2048 kB\nSwapFree: 4096 kB\n"
        let value = try parse(sample([("memory", memory)]))
        XCTAssertEqual(value.memory?.totalBytes, 1_048_576)
        XCTAssertEqual(value.memory?.freeBytes, 262_144)
        XCTAssertNil(value.memory?.usedBytes)
        XCTAssertNil(value.memory?.usedPercent)
        XCTAssertNil(value.memory?.swapUsedBytes)
        XCTAssertTrue(value.availability["memory"]?.contains("MemAvailable") ?? false)
        let overflow = try parse(sample([("memory", "MemTotal: 18446744073709551615 kB\n")]))
        XCTAssertNil(overflow.memory)
        XCTAssertNotEqual(overflow.availability["memory"], "Available")
    }

    func testProcessLimitsRedactionAndAverageCPUAbove100ArePreserved() throws {
        let args = #"/usr/bin/worker --password 'long secret' --token=abc --api-key xyz -Dservice.password=def API_TOKEN=ghi -H 'Authorization: Bearer jkl' https://alice:mnop@example.invalid/path --queue normal"#
        let rows = (1...350).map { "\($0)\tqa\t3\tSl\t250.5\t2048\t" + args + String(repeating: " q", count: 600) }.joined(separator: "\n")
        let value = try parse(sample([("processes", rows)]))
        XCTAssertEqual(value.processes.count, 300)
        XCTAssertEqual(value.processes.first?.command, "worker")
        XCTAssertEqual(value.processes.first?.cpuPercent, 250.5)
        let redacted = try XCTUnwrap(value.processes.first?.arguments)
        XCTAssertLessThanOrEqual(redacted.count, 1024)
        for secret in ["long secret", "abc", "xyz", "def", "ghi", "jkl", "alice", "mnop"] { XCTAssertFalse(redacted.contains(secret), secret) }
        XCTAssertTrue(redacted.contains("--queue normal"))
        XCTAssertTrue(redacted.contains("https://[redacted]@example.invalid"))
    }

    func testPartialQuoteSecretAndFrameLikeArgumentsCannotInjectSections() throws {
        let args = "/usr/bin/worker --password='unterminated secret\nAXON_MONITOR_END\ngpus\tok\teA=="
        let value = try parse(sample([("processes", "2\tqa\t1\tS\t1\t1024\t" + args)]))
        XCTAssertEqual(value.processes.count, 1)
        XCTAssertTrue(value.gpus.isEmpty)
        XCTAssertFalse(value.processes[0].arguments?.contains("unterminated secret") ?? true)
    }

    func testPSJoinedMultiwordSecretValuesAreRedactedThroughNextExplicitOption() throws {
        let args = "/bin/tool --password harmless test value --mode read-only --token=second multiword secret --queue work API_SECRET=third secret value --verbose"
        let value = try parse(sample([("processes", "7\tqa\t1\tS\t1\t2048\t" + args)]))
        let display = try XCTUnwrap(value.processes.first?.arguments)
        for secret in ["harmless", "test value", "second multiword secret", "third secret value"] { XCTAssertFalse(display.contains(secret), secret) }
        XCTAssertTrue(display.contains("--password [redacted] --mode read-only"))
        XCTAssertTrue(display.contains("--token=[redacted] --queue work"))
        XCTAssertTrue(display.contains("API_SECRET=[redacted] --verbose"))
        let last = try parse(sample([("processes", "8\tqa\t1\tS\t1\t2048\t/bin/tool --secret final multiword value")]))
        XCTAssertEqual(last.processes.first?.arguments, "/bin/tool --secret [redacted]")
    }

    func testDockerUnitsHealthPortsAndStoppedMetricsAreAccurate() throws {
        let value = try parse(fixture("monitoring-linux"))
        let running = try XCTUnwrap(value.containers.first)
        XCTAssertEqual(running.pid, 502)
        XCTAssertEqual(running.memoryUsedBytes, 67_108_864)
        XCTAssertEqual(running.memoryLimitBytes, 2_147_483_648)
        XCTAssertEqual(running.networkReceivedBytes, 52_400_000)
        XCTAssertEqual(running.blockWrittenBytes, 524_000)
        XCTAssertEqual(running.pids, 4)
        let stopped = try XCTUnwrap(value.containers.last)
        XCTAssertEqual(stopped.state, "exited")
        XCTAssertNil(stopped.health)
        XCTAssertNil(stopped.memoryUsedBytes)
        XCTAssertNil(stopped.networkReceivedBytes)
        var raw = try fixture("monitoring-linux")
        raw = replacingFrame(raw, name: "containerStats", body: #"{"ID":"aaaaaaaaaaaa","CPUPerc":"--","MemUsage":"N/A / 1EiB","MemPerc":"--","NetIO":"--","BlockIO":"--","PIDs":"--"}"#)
        let missing = try parse(raw).containers[0]
        XCTAssertNil(missing.cpuPercent)
        XCTAssertNil(missing.memoryUsedBytes)
        XCTAssertNil(missing.memoryLimitBytes)
        XCTAssertNil(missing.networkReceivedBytes)
    }

    func testNvidiaQuotedNamesNAAndOptionalFanCudaRemainExplicit() throws {
        let value = try parse(fixture("monitoring-linux"))
        XCTAssertEqual(value.gpus[1].name, "NVIDIA A100, MIG-capable")
        XCTAssertEqual(value.gpus[1].memoryTotalBytes, 40_960 * 1_048_576)
        XCTAssertEqual(value.gpuProcesses[0].usedMemoryBytes, 2048 * 1_048_576)
        let raw = replacingFrame(try fixture("monitoring-linux"), name: "gpuInfo", body: "nvidia-smi lacks CUDA version", status: "unavailable")
        let absent = try parse(raw)
        XCTAssertNil(absent.gpus[0].cudaVersion)
        XCTAssertTrue(absent.availability["gpuInfo"]?.contains("lacks CUDA") ?? false)
    }

    func testVnstatV2UsesByteCountsAndActualEpochAndRejectsLegacyUnits() throws {
        let history = #"{"vnstatversion":"2.12","jsonversion":"2","interfaces":[{"name":"eth0","traffic":{"total":{"rx":18446744073709551615,"tx":0},"day":[{"id":7,"timestamp":1791032400,"rx":123,"tx":456}]}}]}"#
        let value = try parse(sample([("history", history)]))
        XCTAssertEqual(value.trafficHistory?.records[0].receivedBytes, UInt64.max)
        XCTAssertEqual(value.trafficHistory?.records[1].receivedBytes, 123)
        XCTAssertEqual(value.trafficHistory?.records[1].timestamp, sampledAt)
        let legacy = try parse(sample([("history", history.replacingOccurrences(of: #""jsonversion":"2""#, with: #""jsonversion":"1""#))]))
        XCTAssertNil(legacy.trafficHistory)
        XCTAssertTrue(legacy.availability["history"]?.contains("legacy units") ?? false)
        let empty = try parse(sample([("history", #"{"jsonversion":"2","interfaces":[]}"#)]))
        XCTAssertNil(empty.trafficHistory)
        XCTAssertTrue(empty.availability["history"]?.contains("has not recorded") ?? false)
    }

    func testUnavailableToolsAndMalformedOptionalJsonKeepOtherModules() throws {
        var raw = try fixture("monitoring-linux")
        raw = replacingFrame(raw, name: "gpus", body: "Permission denied; nvidia-smi unavailable", status: "unavailable")
        raw = replacingFrame(raw, name: "history", body: "not JSON")
        raw = replacingFrame(raw, name: "addresses", body: "{}")
        raw = replacingFrame(raw, name: "containerDetails", body: "bad row")
        raw = replacingFrame(raw, name: "containerStats", body: "not JSON")
        let value = try parse(raw)
        XCTAssertNotNil(value.memory)
        XCTAssertEqual(value.cpu?.cores.count, 4)
        XCTAssertTrue(value.gpus.isEmpty)
        XCTAssertTrue(value.availability["gpus"]?.contains("Permission denied") ?? false)
        XCTAssertNotEqual(value.availability["history"], "Available")
        XCTAssertNotEqual(value.availability["addresses"], "Available")
        XCTAssertNotEqual(value.availability["containerDetails"], "Available")
        XCTAssertNotEqual(value.availability["containerStats"], "Available")
        XCTAssertEqual(value.containers.count, 2)
    }

    func testTruncatedSectionDiscardsPartialRowAndNonUtf8IsOnlyCapabilityFailure() throws {
        let complete = "1\tqa\t1\tS\t0\t1024\t/usr/bin/one\n"
        var raw = sample([])
        raw = raw.replacingOccurrences(of: "AXON_MONITOR_END\n", with: frame("processes", complete + "2\tqa\t1\tS\t0\t1024\t/bin/cut", status: "truncated") + "AXON_MONITOR_END\n")
        let partial = try parse(raw)
        XCTAssertEqual(partial.processes.map(\.pid), [1])
        XCTAssertTrue(partial.availability["processes"]?.contains("Partial data") ?? false)
        let badUtf = "processes\tok\t" + Data([0xff, 0xfe]).base64EncodedString() + "\n"
        let response = sample([("load", "0.1 0.2 0.3")]).replacingOccurrences(of: "AXON_MONITOR_END\n", with: badUtf + "AXON_MONITOR_END\n")
        let decoded = try parse(response)
        XCTAssertNotNil(decoded.load)
        XCTAssertTrue(decoded.processes.isEmpty)
        XCTAssertEqual(decoded.availability["processes"], "Capability returned non-UTF-8 data")
    }

    func testInvalidVersionFramingBase64DuplicateAndMaximumResponseAreRejected() throws {
        let valid = sample([("load", "0 0 0")])
        let invalid = [valid.replacingOccurrences(of: "AXON_MONITOR_V1", with: "AXON_MONITOR_V2"),
                       valid.replacingOccurrences(of: "AXON_MONITOR_END\n", with: ""),
                       valid.replacingOccurrences(of: "AXON_MONITOR_END\n", with: frame("load", "1 1 1") + "AXON_MONITOR_END\n"),
                       valid.replacingOccurrences(of: "AXON_MONITOR_END\n", with: "gpus\tok\t%%%\nAXON_MONITOR_END\n"),
                       valid + "unexpected trailing text",
                       String(repeating: "x", count: MonitoringCommand.maximumResponseBytes + 1)]
        for raw in invalid { XCTAssertThrowsError(try parse(raw)) }
    }

    func testUnsupportedMacHostAndUnavailableFramingUtilityStayUnsupported() throws {
        let mac = try parse(sample([], os: "Darwin"))
        XCTAssertFalse(mac.isSupported)
        XCTAssertNil(mac.cpu)
        XCTAssertTrue(mac.availability["cpu"]?.contains("Darwin") ?? false)
        let missing = "AXON_MONITOR_V1\nsystem\tunavailable: base64 utility is missing\t\nAXON_MONITOR_END\n"
        let value = try parse(missing)
        XCTAssertFalse(value.isSupported)
        XCTAssertTrue(value.availability["system"]?.contains("base64") ?? false)
    }

    func testFixedCollectorHasBoundedReadOnlyCommandsAndNoEnvironmentReads() {
        let script = MonitoringCommand.script
        XCTAssertTrue(script.contains("printf 'AXON_MONITOR_V1\\n'"))
        XCTAssertTrue(script.contains("head -c"))
        XCTAssertTrue(script.contains("timeout 8"))
        XCTAssertTrue(script.contains("NR<=300"))
        XCTAssertTrue(script.contains("substr($0,1,1024)"))
        XCTAssertTrue(script.contains("--query-gpu="))
        XCTAssertTrue(script.contains("fan.speed"))
        XCTAssertTrue(script.contains("docker inspect --format"))
        XCTAssertTrue(script.contains("{{printf \"\\t\"}}"))
        for forbidden in ["sudo ", "/environ", "curl ", "wget ", "docker exec", "docker start", "docker restart", "sleep ", "apt install", "dnf install"] { XCTAssertFalse(script.contains(forbidden), forbidden) }
    }
}
