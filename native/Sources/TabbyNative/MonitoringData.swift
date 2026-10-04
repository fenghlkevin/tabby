import Foundation

struct MonitoringCPUCore: Identifiable, Equatable, Sendable {
    var id: Int
    var usagePercent: Double?
    var userPercent: Double?
    var systemPercent: Double?
    var nicePercent: Double?
    var ioWaitPercent: Double?
    var stealPercent: Double?
}
struct MonitoringCPU: Equatable, Sendable {
    var usagePercent: Double?
    var userPercent: Double?
    var systemPercent: Double?
    var nicePercent: Double?
    var ioWaitPercent: Double?
    var stealPercent: Double?
    var cores: [MonitoringCPUCore]
}
struct MonitoringLoad: Equatable, Sendable {
    var oneMinute: Double
    var fiveMinutes: Double
    var fifteenMinutes: Double
}
struct MonitoringMemory: Equatable, Sendable {
    var totalBytes: UInt64
    var availableBytes: UInt64?
    var usedBytes: UInt64?
    var usedPercent: Double?
    var cachedBytes: UInt64?
    var buffersBytes: UInt64?
    var swapTotalBytes: UInt64?
    var swapUsedBytes: UInt64?
    var freeBytes: UInt64? = nil
}
struct MonitoringDisk: Identifiable, Equatable, Sendable {
    var id: String { device + ":" + mountpoint }
    var device: String
    var mountpoint: String
    var filesystem: String?
    var totalBytes: UInt64
    var usedBytes: UInt64
    var availableBytes: UInt64
    var usedPercent: Double?
}
struct MonitoringDiskIO: Identifiable, Equatable, Sendable {
    var id: String { device }
    var device: String
    var readBytesPerSecond: Double?
    var writeBytesPerSecond: Double?
    var readIOPS: Double?
    var writeIOPS: Double?
    var utilizationPercent: Double?
}
struct MonitoringProcess: Identifiable, Equatable, Sendable {
    var id: Int { pid }
    var pid: Int
    var user: String
    var threads: Int?
    var state: String
    var cpuPercent: Double?
    var memoryBytes: UInt64?
    /// Executable name; the optional argument display is bounded and redacted.
    var command: String
    var arguments: String? = nil
}
struct MonitoringInterface: Identifiable, Equatable, Sendable {
    var id: String { name }
    var name: String
    var addresses: [String]
    var state: String?
    var receivedBytes: UInt64?
    var transmittedBytes: UInt64?
    var receiveBytesPerSecond: Double?
    var transmitBytesPerSecond: Double?
}
struct MonitoringGPU: Identifiable, Equatable, Sendable {
    var id: String { uuid }
    var index: Int
    var uuid: String
    var name: String
    var temperatureCelsius: Double?
    var utilizationPercent: Double?
    var memoryTotalBytes: UInt64?
    var memoryUsedBytes: UInt64?
    var powerWatts: Double?
    var powerLimitWatts: Double?
    var driverVersion: String?
    var fanPercent: Double? = nil
    /// Maximum CUDA version supported by the NVIDIA driver, not installed toolkit.
    var cudaVersion: String? = nil
}
struct MonitoringGPUProcess: Identifiable, Equatable, Sendable {
    var id: String { gpuUUID + ":" + String(pid) }
    var gpuUUID: String
    var pid: Int
    var name: String
    var usedMemoryBytes: UInt64?
}
struct MonitoringContainer: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var image: String
    var state: String
    var status: String
    var health: String?
    var restartCount: Int?
    var pid: Int?
    var startedAt: String?
    var cpuPercent: Double?
    var memoryUsedBytes: UInt64?
    var memoryLimitBytes: UInt64?
    var memoryPercent: Double?
    var networkReceivedBytes: UInt64?
    var networkTransmittedBytes: UInt64?
    var blockReadBytes: UInt64?
    var blockWrittenBytes: UInt64?
    var pids: Int?
    var ports: String? = nil
}
struct MonitoringTrafficHistoryRecord: Identifiable, Equatable, Sendable {
    var id: String
    var interface: String
    var period: String
    var timestamp: Date?
    var receivedBytes: UInt64
    var transmittedBytes: UInt64
}
struct MonitoringTrafficHistory: Equatable, Sendable {
    var source: String
    var records: [MonitoringTrafficHistoryRecord]
}
struct MonitoringCPUCounters: Equatable, Sendable { var values: [UInt64] }
struct MonitoringDiskCounters: Equatable, Sendable {
    var reads: UInt64; var readSectors: UInt64; var writes: UInt64; var writtenSectors: UInt64; var busyMilliseconds: UInt64
}
struct MonitoringNetworkCounters: Equatable, Sendable { var received: UInt64; var transmitted: UInt64 }

struct MonitoringSnapshot: Equatable, Sendable {
    var timestamp: Date
    var os: String
    var distribution: String? = nil
    var cpuModel: String? = nil
    var architecture: String? = nil
    var kernel: String?
    var uptime: TimeInterval?
    var bootID: String?
    var coreCount: Int?
    var cpu: MonitoringCPU?
    var load: MonitoringLoad?
    var memory: MonitoringMemory?
    var disks: [MonitoringDisk] = []
    var diskIO: [MonitoringDiskIO] = []
    var processes: [MonitoringProcess] = []
    var interfaces: [MonitoringInterface] = []
    var gpus: [MonitoringGPU] = []
    var gpuProcesses: [MonitoringGPUProcess] = []
    var containers: [MonitoringContainer] = []
    var trafficHistory: MonitoringTrafficHistory?
    /// Keys: system,cpu,load,memory,disks,diskIO,processes,interfaces,addresses,history,gpus,gpuInfo,gpuProcesses,containers,containerDetails,containerStats.
    /// "Available" denotes valid data; other strings state the missing/unsupported capability.
    var availability: [String: String] = [:]
    var issues: [String] = []
    var cpuCounters: [String: MonitoringCPUCounters] = [:]
    var diskCounters: [String: MonitoringDiskCounters] = [:]
    var networkCounters: [String: MonitoringNetworkCounters] = [:]
    var isSupported: Bool { os == "Linux" }
}

enum MonitoringParseError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
enum MonitoringCommand {
    static let maximumResponseBytes = 2 * 1024 * 1024
    // One read-only sample. No daemon, temporary file, sudo, installation or sleep.
    // Base64 framing prevents process arguments or tool errors from injecting sections.
    static let script = #"""
    LC_ALL=C; LANG=C; export LC_ALL LANG
    set -f
    printf 'AXON_MONITOR_V1\n'
    if ! command -v base64 >/dev/null 2>&1; then
        printf 'system\tunavailable: base64 utility is missing\t\nAXON_MONITOR_END\n'
        exit 0
    fi
    emit() { printf '%s\t%s\t' "$1" "$2"; printf '%s' "$3" | base64 | tr -d '\n'; printf '\n'; }
    run() { if command -v timeout >/dev/null 2>&1; then timeout 8 "$@"; else "$@"; fi; }
    capture() {
        axon_section=$1; axon_limit=$2; shift 2
        axon_output=$({ "$@" 2>&1; printf '\nAXON_EXIT_STATUS=%s\n' "$?"; } | head -c "$axon_limit")
        axon_last=$(printf '%s\n' "$axon_output" | tail -n 1)
        case "$axon_last" in
            AXON_EXIT_STATUS=*)
                axon_code=${axon_last#AXON_EXIT_STATUS=}
                axon_output=$(printf '%s\n' "$axon_output" | sed '$d')
                if [ "$axon_code" = 0 ]; then emit "$axon_section" ok "$axon_output";
                else emit "$axon_section" unavailable "$axon_output"; fi ;;
            *) emit "$axon_section" truncated "$axon_output" ;;
        esac
    }
    system_sample() {
        printf 'os=%s\nkernel=%s\narchitecture=%s\n' "$(uname -s)" "$(uname -r)" "$(uname -m)"
        if [ -r /etc/os-release ]; then awk -F= '$1=="PRETTY_NAME" {v=substr($0,index($0,"=")+1);gsub(/^"|"$/,"",v);print "distribution=" v;exit}' /etc/os-release; fi
        if [ -r /proc/uptime ]; then awk '{print "uptime=" $1}' /proc/uptime; fi
        if [ -r /proc/sys/kernel/random/boot_id ]; then printf 'bootID=%s\n' "$(cat /proc/sys/kernel/random/boot_id)"; fi
        if [ -r /proc/cpuinfo ]; then awk -F: '$1 ~ /model name|Hardware|Processor/ {v=substr($0,index($0,":")+1);sub(/^ +/,"",v);print "cpuModel=" v;exit}' /proc/cpuinfo; fi
    }
    capture system 8192 system_sample
    if [ "$(uname -s)" != Linux ]; then
        emit unsupported unavailable 'Monitoring currently supports Linux /proc. This host is not Linux.'
        printf 'AXON_MONITOR_END\n'; exit 0
    fi
    capture cpu 65536 cat /proc/stat
    capture load 2048 cat /proc/loadavg
    capture memory 8192 cat /proc/meminfo
    # Read cumulative counters together before df/ps or optional CLI tools can block.
    capture diskIO 65536 cat /proc/diskstats
    capture interfaces 16384 cat /proc/net/dev
    capture disks 65536 run df -PT -B1
    process_sample() {
        axon_ps=$(run ps -eo pid=,user:32=,nlwp=,stat=,pcpu=,rss=,args= --sort=-pcpu --cols 1200 2>&1)
        axon_ps_code=$?
        if [ "$axon_ps_code" != 0 ]; then printf '%s\n' "$axon_ps"; return "$axon_ps_code"; fi
        printf '%s\n' "$axon_ps" | awk 'NR<=300 {p=$1;u=$2;t=$3;s=$4;c=$5;r=$6;$1=$2=$3=$4=$5=$6="";sub(/^ +/,"");a=substr($0,1,1024);gsub(/\t/," ",a);printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",p,u,t,s,c,r,a}'
    }
    capture processes 393216 process_sample
    if command -v ip >/dev/null 2>&1; then capture addresses 65536 run ip -j address show;
    else emit addresses unavailable 'ip utility is not installed; interface counters remain available'; fi
    if command -v vnstat >/dev/null 2>&1; then capture history 262144 run vnstat --json --limit 48;
    else emit history unavailable 'vnStat is not installed; no historical traffic database is available'; fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        capture gpus 32768 run nvidia-smi --query-gpu=index,uuid,name,temperature.gpu,utilization.gpu,memory.total,memory.used,power.draw,power.limit,driver_version,fan.speed --format=csv,noheader,nounits
        gpu_info() {
            axon_header=$(run nvidia-smi 2>&1); axon_header_code=$?
            if [ "$axon_header_code" != 0 ]; then printf '%s\n' "$axon_header"; return "$axon_header_code"; fi
            printf '%s\n' "$axon_header" | awk '/CUDA Version:/ {sub(/^.*CUDA Version:[ ]*/,"");sub(/[ |].*$/,"");print "cudaVersion=" $0;exit}'
        }
        capture gpuInfo 8192 gpu_info
        capture gpuProcesses 65536 run nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_gpu_memory --format=csv,noheader,nounits
    else
        emit gpus unavailable 'nvidia-smi is not installed; NVIDIA telemetry is unavailable'
        emit gpuInfo unavailable 'NVIDIA driver CUDA-version information requires nvidia-smi'
        emit gpuProcesses unavailable 'NVIDIA compute-process telemetry requires nvidia-smi'
    fi
    docker_details() {
        axon_ids=$(run docker ps -a -q --no-trunc 2>&1)
        axon_ids_code=$?
        if [ "$axon_ids_code" != 0 ]; then printf '%s\n' "$axon_ids"; return "$axon_ids_code"; fi
        axon_ids=$(printf '%s\n' "$axon_ids" | awk 'length($0)==64 && $0 !~ /[^0-9a-f]/ && ++n<=300')
        if [ -z "$axon_ids" ]; then return 0; fi
        run docker inspect --format '{{.Id}}{{printf "\t"}}{{.State.Pid}}{{printf "\t"}}{{.RestartCount}}{{printf "\t"}}{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}{{printf "\t"}}{{.State.StartedAt}}' $axon_ids
    }
    if command -v docker >/dev/null 2>&1; then
        capture containers 131072 run docker ps -a --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Ports}}'
        capture containerDetails 131072 docker_details
        capture containerStats 131072 run docker stats --no-stream --no-trunc --format '{{json .}}'
    else
        emit containers unavailable 'Docker is not installed'
        emit containerDetails unavailable 'Container inspection requires Docker'
        emit containerStats unavailable 'Container statistics require Docker'
    fi
    printf 'AXON_MONITOR_END\n'
    """#
}
enum MonitoringSampleParser {
    static func parse(raw: String, previous: MonitoringSnapshot?, timestamp: Date) throws -> MonitoringSnapshot {
        guard raw.utf8.count <= MonitoringCommand.maximumResponseBytes else { throw MonitoringParseError.invalid("Monitoring response exceeds 2 MiB") }
        let sections = try frames(raw)
        var snapshot = MonitoringSnapshot(timestamp: timestamp, os: "Unknown", kernel: nil, uptime: nil, bootID: nil, coreCount: nil, cpu: nil, load: nil, memory: nil)
        for key in sectionNames { snapshot.availability[key] = sections[key]?.availability ?? "Not reported by this sample" }
        for (key, section) in sections where section.status != "ok" {
            snapshot.issues.append(key + ": " + section.availability)
        }
        if let system = sections["system"], system.usable {
            let fields = keyValues(system.body)
            snapshot.os = fields["os"] ?? "Unknown"
            snapshot.kernel = nonempty(fields["kernel"])
            snapshot.distribution = nonempty(fields["distribution"])
            snapshot.cpuModel = nonempty(fields["cpuModel"])
            snapshot.architecture = nonempty(fields["architecture"])
            snapshot.uptime = number(fields["uptime"])
            snapshot.bootID = nonempty(fields["bootID"])
        }
        guard snapshot.isSupported else {
            let reason = snapshot.os == "Unknown" ? snapshot.availability["system"] ?? "Operating system unavailable" : "Unsupported operating system: " + snapshot.os
            snapshot.availability["system"] = reason
            for key in sectionNames where key != "system" { snapshot.availability[key] = reason }
            if !snapshot.issues.contains(reason) { snapshot.issues.append(reason) }
            return snapshot
        }
        let interval: Double? = {
            guard let previous, previous.os == snapshot.os,
                  let now = snapshot.uptime, let before = previous.uptime, now > before,
                  snapshot.bootID == previous.bootID else { return nil }
            return now - before
        }()
        if let section = sections["cpu"], section.usable {
            snapshot.cpuCounters = parseCPU(section.body)
            let coreNames = snapshot.cpuCounters.keys.filter { $0 != "cpu" }.sorted { (Int($0.dropFirst(3)) ?? 0) < (Int($1.dropFirst(3)) ?? 0) }
            snapshot.coreCount = coreNames.isEmpty ? nil : coreNames.count
            if let aggregate = snapshot.cpuCounters["cpu"] {
                let baseline = interval != nil && previous?.coreCount == snapshot.coreCount && Set(previous?.cpuCounters.keys.map { $0 } ?? []) == Set(snapshot.cpuCounters.keys) ? previous?.cpuCounters : nil
                let usage = cpuUsage(aggregate, previous: baseline?["cpu"])
                snapshot.cpu = MonitoringCPU(usagePercent: usage[0], userPercent: usage[1], systemPercent: usage[2], nicePercent: usage[3], ioWaitPercent: usage[4], stealPercent: usage[5],
                    cores: coreNames.map { name in
                        let percentages = cpuUsage(snapshot.cpuCounters[name]!, previous: baseline?[name])
                        return MonitoringCPUCore(id: Int(name.dropFirst(3))!, usagePercent: percentages[0], userPercent: percentages[1], systemPercent: percentages[2], nicePercent: percentages[3], ioWaitPercent: percentages[4], stealPercent: percentages[5])
                    })
                if usage[0] == nil { snapshot.availability["cpu"] = "Waiting for a second valid CPU sample; counters may have reset" }
            } else { invalid("cpu", "CPU counters are missing or malformed", in: &snapshot) }
        }
        if let section = sections["load"], section.usable {
            let fields = words(section.body)
            if fields.count >= 3, let one = number(fields[0]), let five = number(fields[1]), let fifteen = number(fields[2]) {
                snapshot.load = MonitoringLoad(oneMinute: one, fiveMinutes: five, fifteenMinutes: fifteen)
            } else { invalid("load", "Load averages are malformed", in: &snapshot) }
        }
        if let section = sections["memory"], section.usable {
            snapshot.memory = parseMemory(section.body)
            if snapshot.memory == nil { invalid("memory", "Memory counters are missing or malformed", in: &snapshot) }
            else if snapshot.memory?.availableBytes == nil { invalid("memory", "Partial memory data: MemAvailable is not reported; used memory is unavailable", in: &snapshot) }
        }
        if let section = sections["disks"], section.usable {
            snapshot.disks = parseDisks(section.body)
            if snapshot.disks.isEmpty { invalid("disks", "No valid filesystem rows were reported", in: &snapshot) }
        }
        if let section = sections["diskIO"], section.usable {
            snapshot.diskCounters = parseDiskCounters(section.body)
            snapshot.diskIO = snapshot.diskCounters.keys.sorted().map { device in
                let now = snapshot.diskCounters[device]!
                let candidate = previous?.diskCounters[device]
                let old = candidate.flatMap { value in
                    now.reads >= value.reads && now.readSectors >= value.readSectors && now.writes >= value.writes && now.writtenSectors >= value.writtenSectors && now.busyMilliseconds >= value.busyMilliseconds ? value : nil
                }
                return MonitoringDiskIO(device: device, readBytesPerSecond: rate(now.readSectors, old?.readSectors, interval, multiplier: 512), writeBytesPerSecond: rate(now.writtenSectors, old?.writtenSectors, interval, multiplier: 512), readIOPS: rate(now.reads, old?.reads, interval), writeIOPS: rate(now.writes, old?.writes, interval), utilizationPercent: rate(now.busyMilliseconds, old?.busyMilliseconds, interval, multiplier: 0.1).map { min(100, $0) })
            }
            if snapshot.diskIO.isEmpty { invalid("diskIO", "No valid disk counters were reported", in: &snapshot) }
        }
        if let section = sections["processes"], section.usable {
            snapshot.processes = parseProcesses(section.body)
            if snapshot.processes.isEmpty && !section.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { invalid("processes", "Process rows are malformed", in: &snapshot) }
        }
        if let section = sections["interfaces"], section.usable {
            snapshot.networkCounters = parseNetwork(section.body)
            snapshot.interfaces = snapshot.networkCounters.keys.sorted().map { name in
                let now = snapshot.networkCounters[name]!
                let old = previous?.networkCounters[name].flatMap { value in now.received >= value.received && now.transmitted >= value.transmitted ? value : nil }
                return MonitoringInterface(name: name, addresses: [], state: nil, receivedBytes: now.received, transmittedBytes: now.transmitted, receiveBytesPerSecond: rate(now.received, old?.received, interval), transmitBytesPerSecond: rate(now.transmitted, old?.transmitted, interval))
            }
            if snapshot.interfaces.isEmpty { invalid("interfaces", "No valid network counters were reported", in: &snapshot) }
        }
        if let section = sections["addresses"], section.usable {
            do { try addAddresses(section.body, to: &snapshot) }
            catch { invalid("addresses", "Interface address JSON is malformed", in: &snapshot) }
        }
        if let section = sections["history"], section.usable {
            do { snapshot.trafficHistory = try parseHistory(section.body) }
            catch { invalid("history", error.localizedDescription, in: &snapshot) }
        }
        if let section = sections["gpus"], section.usable {
            snapshot.gpus = parseGPUs(section.body)
            if snapshot.gpus.isEmpty && !section.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { invalid("gpus", "GPU rows are malformed", in: &snapshot) }
        }
        if let section = sections["gpuInfo"], section.usable {
            if let version = nonempty(keyValues(section.body)["cudaVersion"]), number(version) != nil {
                for index in snapshot.gpus.indices { snapshot.gpus[index].cudaVersion = version }
            } else { invalid("gpuInfo", "NVIDIA driver did not report a supported CUDA version", in: &snapshot) }
        }
        if let section = sections["gpuProcesses"], section.usable {
            snapshot.gpuProcesses = parseGPUProcesses(section.body)
            if snapshot.gpuProcesses.isEmpty && !section.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { invalid("gpuProcesses", "GPU process rows are malformed", in: &snapshot) }
        }
        if let section = sections["containers"], section.usable {
            snapshot.containers = parseContainers(section.body)
            if snapshot.containers.isEmpty && !section.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { invalid("containers", "Container rows are malformed", in: &snapshot) }
        }
        if let section = sections["containerDetails"], section.usable {
            do { try addContainerDetails(section.body, to: &snapshot) }
            catch { invalid("containerDetails", "Container detail rows are malformed", in: &snapshot) }
        }
        if let section = sections["containerStats"], section.usable {
            do { try addContainerStats(section.body, to: &snapshot) }
            catch { invalid("containerStats", "Container statistics JSON is malformed", in: &snapshot) }
        }
        return snapshot
    }
}

private extension MonitoringSampleParser {
    static let sectionNames = ["system", "cpu", "load", "memory", "disks", "diskIO", "processes", "interfaces", "addresses", "history", "gpus", "gpuInfo", "gpuProcesses", "containers", "containerDetails", "containerStats"]
    struct Section {
        var status: String
        var body: String
        var availability: String
        var usable: Bool { status == "ok" || status == "truncated" }
    }
    static func frames(_ raw: String) throws -> [String: Section] {
        var rows = raw.components(separatedBy: "\n")
        while rows.last == "" { rows.removeLast() }
        guard rows.first == "AXON_MONITOR_V1", rows.last == "AXON_MONITOR_END" else { throw MonitoringParseError.invalid("Incomplete or unsupported monitoring response") }
        var result: [String: Section] = [:]
        for row in rows.dropFirst().dropLast() {
            let fields = row.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, sectionNames.contains(fields[0]) || fields[0] == "unsupported", result[fields[0]] == nil,
                  let bytes = Data(base64Encoded: fields[2]) else { throw MonitoringParseError.invalid("Invalid monitoring section framing") }
            let status = fields[1]
            guard ["ok", "unavailable", "truncated"].contains(status) || status.hasPrefix("unavailable:") else { throw MonitoringParseError.invalid("Invalid monitoring section status") }
            var body: String
            if let text = String(data: bytes, encoding: .utf8) { body = text }
            else if status == "truncated" { body = String(decoding: bytes, as: UTF8.self) }
            else if status == "unavailable" || status.hasPrefix("unavailable:") { body = String(decoding: bytes, as: UTF8.self) }
            else {
                result[fields[0]] = Section(status: "unavailable", body: "", availability: "Capability returned non-UTF-8 data")
                continue
            }
            let availability: String
            if status == "ok" { availability = "Available" }
            else if status == "truncated" {
                availability = "Partial data: section response limit exceeded"
                // The bounded pipe may end mid-row or mid-UTF8 character. Never parse that row as complete data.
                if let newline = body.lastIndex(of: "\n") { body = String(body[...newline]) } else { body = "" }
            } else {
                let detail = status.hasPrefix("unavailable:") ? String(status.dropFirst("unavailable:".count)) : body
                availability = nonempty(String(redactArguments(detail).prefix(300))) ?? "Capability unavailable"
                body = ""
            }
            result[fields[0]] = Section(status: status, body: body, availability: availability)
        }
        guard result["system"] != nil else { throw MonitoringParseError.invalid("Monitoring system section is missing") }
        return result
    }
    static func lines(_ body: String) -> [String] { body.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    static func words(_ body: String) -> [String] { body.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
    static func keyValues(_ body: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines(body) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }
    static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    static func number(_ value: String?) -> Double? {
        guard let value = nonempty(value), let number = Double(value), number.isFinite, number >= 0 else { return nil }
        return number
    }
    static func uint(_ value: String?) -> UInt64? {
        guard let text = nonempty(value), !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(text)
    }
    static func integer(_ value: String?) -> Int? { uint(value).flatMap(Int.init(exactly:)) }
    static func multiplied(_ value: UInt64?, by factor: UInt64) -> UInt64? {
        guard let value else { return nil }
        let (product, overflow) = value.multipliedReportingOverflow(by: factor)
        return overflow ? nil : product
    }
    static func invalid(_ key: String, _ message: String, in snapshot: inout MonitoringSnapshot) {
        snapshot.availability[key] = message
        snapshot.issues.append(key + ": " + message)
    }
    static func rate(_ value: UInt64, _ previous: UInt64?, _ interval: Double?, multiplier: Double = 1) -> Double? {
        guard let previous, value >= previous, let interval, interval.isFinite, interval > 0 else { return nil }
        let result = Double(value - previous) * multiplier / interval
        return result.isFinite ? result : nil
    }
    static func parseCPU(_ body: String) -> [String: MonitoringCPUCounters] {
        var result: [String: MonitoringCPUCounters] = [:]
        for line in lines(body) {
            let fields = words(line)
            guard fields.count >= 9, let name = fields.first else { continue }
            if name != "cpu" {
                guard name.hasPrefix("cpu"), let id = integer(String(name.dropFirst(3))), String(id) == String(name.dropFirst(3)) else { continue }
            }
            let counters = fields.dropFirst().prefix(10).compactMap { uint($0) }
            guard counters.count == min(10, fields.count - 1) else { continue }
            result[name] = MonitoringCPUCounters(values: counters)
        }
        return result
    }
    static func cpuUsage(_ current: MonitoringCPUCounters, previous: MonitoringCPUCounters?) -> [Double?] {
        let missing: [Double?] = Array(repeating: nil, count: 6)
        guard let previous, current.values.count >= 8, previous.values.count >= 8 else { return missing }
        var deltas: [Double] = []
        // guest/guest_nice are already included in user/nice and must not enter the total again.
        for index in 0..<8 {
            guard current.values[index] >= previous.values[index] else { return missing }
            deltas.append(Double(current.values[index] - previous.values[index]))
        }
        let total = deltas.reduce(0, +)
        guard total > 0 else { return missing }
        return [(total - deltas[3] - deltas[4]) / total * 100, deltas[0] / total * 100, (deltas[2] + deltas[5] + deltas[6]) / total * 100, deltas[1] / total * 100, deltas[4] / total * 100, deltas[7] / total * 100]
    }
    static func parseMemory(_ body: String) -> MonitoringMemory? {
        var values: [String: UInt64] = [:]
        for line in lines(body) {
            let fields = words(line)
            guard fields.count == 3, fields[2] == "kB", let bytes = multiplied(uint(fields[1]), by: 1024) else { continue }
            values[fields[0].replacingOccurrences(of: ":", with: "")] = bytes
        }
        guard let total = values["MemTotal"], total > 0 else { return nil }
        let available = values["MemAvailable"].flatMap { $0 <= total ? $0 : nil }
        let free = values["MemFree"].flatMap { $0 <= total ? $0 : nil }
        let used = available.map { total - $0 }
        let swapTotal = values["SwapTotal"]
        let swapUsed = swapTotal.flatMap { total in values["SwapFree"].flatMap { $0 <= total ? total - $0 : nil } }
        return MonitoringMemory(totalBytes: total, availableBytes: available, usedBytes: used, usedPercent: used.map { Double($0) / Double(total) * 100 }, cachedBytes: values["Cached"], buffersBytes: values["Buffers"], swapTotalBytes: swapTotal, swapUsedBytes: swapUsed, freeBytes: free)
    }
    static func parseDisks(_ body: String) -> [MonitoringDisk] {
        var result: [MonitoringDisk] = []; var seen = Set<String>()
        for line in lines(body) {
            let fields = line.split(maxSplits: 6, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count == 7, let total = uint(fields[2]), let used = uint(fields[3]), let available = uint(fields[4]) else { continue }
            let row = MonitoringDisk(device: fields[0], mountpoint: fields[6], filesystem: fields[1], totalBytes: total, usedBytes: used, availableBytes: available, usedPercent: percent(fields[5]))
            if seen.insert(row.id).inserted { result.append(row) }
            if result.count == 512 { break }
        }
        return result
    }
    static func parseDiskCounters(_ body: String) -> [String: MonitoringDiskCounters] {
        var result: [String: MonitoringDiskCounters] = [:]
        for line in lines(body) {
            let f = words(line)
            guard f.count >= 14, let reads = uint(f[3]), let sectors = uint(f[5]), let writes = uint(f[7]), let written = uint(f[9]), let busy = uint(f[12]) else { continue }
            result[f[2]] = MonitoringDiskCounters(reads: reads, readSectors: sectors, writes: writes, writtenSectors: written, busyMilliseconds: busy)
            if result.count == 512 { break }
        }
        return result
    }
    static func parseProcesses(_ body: String) -> [MonitoringProcess] {
        var result: [MonitoringProcess] = []; var seen = Set<Int>()
        for line in lines(body) {
            let fields = line.split(separator: "\t", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7, let pid = integer(fields[0]), pid > 0, let user = nonempty(fields[1]), let state = nonempty(fields[3]), seen.insert(pid).inserted else { continue }
            let arguments = String(redactArguments(fields[6]).prefix(1024))
            let executable = words(arguments).first ?? "Unknown"
            result.append(MonitoringProcess(pid: pid, user: String(user.prefix(64)), threads: integer(fields[2]), state: String(state.prefix(16)), cpuPercent: number(fields[4]), memoryBytes: multiplied(uint(fields[5]), by: 1024), command: String((executable as NSString).lastPathComponent.prefix(128)), arguments: nonempty(arguments)))
            if result.count == 300 { break }
        }
        return result
    }
    /// Arguments remain local to the in-memory snapshot. This intentionally avoids environment reads.
    static func redactArguments(_ body: String) -> String {
        var output = body.replacingOccurrences(of: "[\\x00-\\x1f\\x7f]", with: " ", options: .regularExpression)
        let patterns: [(String, String)] = [
            // ps joins argv with spaces and loses shell quoting. Conservatively
            // redact the entire sensitive value through the next explicit option.
            (#"(?i)((?:--?|-D)[\w.-]*(?:password|passwd|token|secret|api[-_]?key|access[-_]?key)[\w.-]*(?:=|\s+)).*?(?=\s+--?[\w]|$)"#, "$1[redacted]"),
            (#"(?i)(\b[\w]*(?:PASSWORD|PASSWD|TOKEN|SECRET|API_KEY|ACCESS_KEY)[\w]*=).*?(?=\s+--?[\w]|$)"#, "$1[redacted]"),
            (#"(?i)(Authorization\s*:\s*(?:Bearer|Basic)\s+)[\w+/=.-]+"#, "$1[redacted]"),
            (#"(?i)([a-z][a-z0-9+.-]*://)[^\s/@]+(?::[^\s/@]*)?@"#, "$1[redacted]@")
        ]
        for (pattern, replacement) in patterns { output = output.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression) }
        return output
    }
    static func parseNetwork(_ body: String) -> [String: MonitoringNetworkCounters] {
        var result: [String: MonitoringNetworkCounters] = [:]
        for line in lines(body) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let name = nonempty(String(parts[0])) else { continue }
            let fields = words(String(parts[1]))
            guard fields.count >= 16, let received = uint(fields[0]), let transmitted = uint(fields[8]) else { continue }
            result[name] = MonitoringNetworkCounters(received: received, transmitted: transmitted)
            if result.count == 512 { break }
        }
        return result
    }
    static func addAddresses(_ body: String, to snapshot: inout MonitoringSnapshot) throws {
        guard let rows = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [[String: Any]] else { throw MonitoringParseError.invalid("Expected interface array") }
        for row in rows.prefix(512) {
            guard let name = nonempty(row["ifname"] as? String) else { continue }
            let index: Int
            if let existing = snapshot.interfaces.firstIndex(where: { $0.name == name }) { index = existing }
            else {
                snapshot.interfaces.append(MonitoringInterface(name: name, addresses: [], state: nil, receivedBytes: nil, transmittedBytes: nil, receiveBytesPerSecond: nil, transmitBytesPerSecond: nil))
                index = snapshot.interfaces.count - 1
            }
            snapshot.interfaces[index].state = nonempty(row["operstate"] as? String)
            for address in (row["addr_info"] as? [[String: Any]] ?? []).prefix(128) {
                guard let value = nonempty(address["local"] as? String) else { continue }
                let prefix = jsonUInt(address["prefixlen"])
                let formatted = value + (prefix.map { "/" + String($0) } ?? "")
                if !snapshot.interfaces[index].addresses.contains(formatted) { snapshot.interfaces[index].addresses.append(formatted) }
            }
        }
    }
    static func csvFields(_ line: String) -> [String]? {
        var result: [String] = []; var field = ""; var quoted = false
        let characters = Array(line); var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted && index + 1 < characters.count && characters[index + 1] == "\"" { field.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if character == "," && !quoted { result.append(field.trimmingCharacters(in: .whitespaces)); field = "" }
            else { field.append(character) }
            index += 1
        }
        guard !quoted else { return nil }
        result.append(field.trimmingCharacters(in: .whitespaces))
        return result
    }
    static func percent(_ string: String?) -> Double? { string.flatMap { number($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) } }
    static func mib(_ string: String?) -> UInt64? {
        guard let value = number(string) else { return nil }
        return boundedBytes(value * 1_048_576)
    }
    static func boundedBytes(_ value: Double) -> UInt64? {
        // Double(UInt64.max) rounds up, so the upper endpoint itself is unsafe to convert.
        guard value.isFinite, value >= 0, value < Double(UInt64.max) else { return nil }
        return UInt64(value)
    }
    static func parseGPUs(_ body: String) -> [MonitoringGPU] {
        var result: [MonitoringGPU] = []; var seen = Set<String>()
        for line in lines(body) {
            guard let f = csvFields(line), f.count >= 10, let index = integer(f[0]), let uuid = nonempty(f[1]), let name = nonempty(f[2]), seen.insert(uuid).inserted else { continue }
            result.append(MonitoringGPU(index: index, uuid: uuid, name: name, temperatureCelsius: number(f[3]), utilizationPercent: percent(f[4]), memoryTotalBytes: mib(f[5]), memoryUsedBytes: mib(f[6]), powerWatts: number(f[7]), powerLimitWatts: number(f[8]), driverVersion: nonempty(f[9]), fanPercent: f.count > 10 ? percent(f[10]) : nil))
            if result.count == 128 { break }
        }
        return result
    }
    static func parseGPUProcesses(_ body: String) -> [MonitoringGPUProcess] {
        var result: [MonitoringGPUProcess] = []; var seen = Set<String>()
        for line in lines(body) {
            guard let f = csvFields(line), f.count == 4, let uuid = nonempty(f[0]), let pid = integer(f[1]), pid > 0, let name = nonempty(f[2]) else { continue }
            let row = MonitoringGPUProcess(gpuUUID: uuid, pid: pid, name: name, usedMemoryBytes: mib(f[3]))
            if seen.insert(row.id).inserted { result.append(row) }
            if result.count == 300 { break }
        }
        return result
    }
    static func parseContainers(_ body: String) -> [MonitoringContainer] {
        var result: [MonitoringContainer] = []; var seen = Set<String>()
        for line in lines(body) {
            let f = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let id = nonempty(f[0]), let name = nonempty(f[1]), seen.insert(id).inserted else { continue }
            result.append(MonitoringContainer(id: id, name: name, image: f[2], state: f[3], status: f[4], health: nil, restartCount: nil, pid: nil, startedAt: nil, cpuPercent: nil, memoryUsedBytes: nil, memoryLimitBytes: nil, memoryPercent: nil, networkReceivedBytes: nil, networkTransmittedBytes: nil, blockReadBytes: nil, blockWrittenBytes: nil, pids: nil, ports: f.count > 5 ? nonempty(f[5]) : nil))
            if result.count == 300 { break }
        }
        return result
    }
    static func addContainerDetails(_ body: String, to snapshot: inout MonitoringSnapshot) throws {
        for line in lines(body) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 5 else { throw MonitoringParseError.invalid("Malformed Docker detail row") }
            guard let index = snapshot.containers.firstIndex(where: { $0.id == f[0] }) else { continue }
            snapshot.containers[index].pid = integer(f[1])
            snapshot.containers[index].restartCount = integer(f[2])
            snapshot.containers[index].health = f[3] == "none" ? nil : nonempty(f[3])
            snapshot.containers[index].startedAt = nonempty(f[4])
        }
    }
    static func byteSize(_ string: String) -> UInt64? {
        let text = string.trimmingCharacters(in: .whitespaces)
        guard let expression = try? NSRegularExpression(pattern: #"^([0-9]+(?:\.[0-9]+)?)\s*([A-Za-z]*)$"#), let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let valueRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text), let value = number(String(text[valueRange])) else { return nil }
        let scales: [String: Double] = ["": 1, "B": 1, "KB": 1e3, "kB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15, "KiB": 1024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776, "PiB": 1_125_899_906_842_624]
        guard let scale = scales[String(text[unitRange])] else { return nil }
        return boundedBytes(value * scale)
    }
    static func bytePair(_ string: String?) -> (UInt64?, UInt64?) {
        guard let string else { return (nil, nil) }
        let fields = string.components(separatedBy: "/")
        guard fields.count == 2 else { return (nil, nil) }
        return (byteSize(fields[0]), byteSize(fields[1]))
    }
    static func addContainerStats(_ body: String, to snapshot: inout MonitoringSnapshot) throws {
        for line in lines(body).prefix(300) {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { throw MonitoringParseError.invalid("Expected Docker statistics object") }
            guard let id = nonempty((row["ID"] ?? row["Container"]) as? String) else { continue }
            let matches = snapshot.containers.indices.filter { snapshot.containers[$0].id == id || (id.count >= 12 && snapshot.containers[$0].id.hasPrefix(id)) }
            guard matches.count == 1, let index = matches.first, snapshot.containers[index].state == "running" else { continue }
            let memory = bytePair(row["MemUsage"] as? String), network = bytePair(row["NetIO"] as? String), block = bytePair(row["BlockIO"] as? String)
            snapshot.containers[index].cpuPercent = percent(row["CPUPerc"] as? String)
            snapshot.containers[index].memoryUsedBytes = memory.0; snapshot.containers[index].memoryLimitBytes = memory.1
            snapshot.containers[index].memoryPercent = percent(row["MemPerc"] as? String)
            snapshot.containers[index].networkReceivedBytes = network.0; snapshot.containers[index].networkTransmittedBytes = network.1
            snapshot.containers[index].blockReadBytes = block.0; snapshot.containers[index].blockWrittenBytes = block.1
            snapshot.containers[index].pids = integer(row["PIDs"] as? String)
        }
    }
    static func jsonUInt(_ value: Any?) -> UInt64? {
        if let value = value as? String { return uint(value) }
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return uint(value.stringValue)
    }
    static func parseHistory(_ body: String) throws -> MonitoringTrafficHistory {
        guard let root = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              String(describing: root["jsonversion"] ?? "") == "2", let interfaces = root["interfaces"] as? [[String: Any]] else { throw MonitoringParseError.invalid("Traffic history requires vnStat JSON version 2; legacy units are unsupported") }
        var records: [MonitoringTrafficHistoryRecord] = []; var seen = Set<String>()
        for interface in interfaces.prefix(512) {
            guard let name = nonempty(interface["name"] as? String), let traffic = interface["traffic"] as? [String: Any] else { continue }
            for period in ["total", "fiveminute", "hour", "day", "month", "year", "top"] {
                let values: [[String: Any]]
                if period == "total", let row = traffic[period] as? [String: Any] { values = [row] }
                else { values = Array((traffic[period] as? [[String: Any]] ?? []).prefix(48)) }
                for (offset, value) in values.enumerated() {
                    guard let received = jsonUInt(value["rx"]), let transmitted = jsonUInt(value["tx"]) else { continue }
                    let stamp = jsonUInt(value["timestamp"])
                    let token = (value["id"] as? NSNumber)?.stringValue ?? stamp.map(String.init) ?? String(offset)
                    let id = name + ":" + period + ":" + token
                    guard seen.insert(id).inserted else { continue }
                    records.append(MonitoringTrafficHistoryRecord(id: id, interface: name, period: period, timestamp: stamp.map { Date(timeIntervalSince1970: Double($0)) }, receivedBytes: received, transmittedBytes: transmitted))
                }
            }
        }
        guard !records.isEmpty else { throw MonitoringParseError.invalid("vnStat has not recorded any usable historical traffic") }
        return MonitoringTrafficHistory(source: "vnStat " + (root["vnstatversion"] as? String ?? "2.x"), records: records)
    }
}
