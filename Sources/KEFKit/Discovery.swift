import dnssd
import Foundation
import Network

/// A speaker found on the network.
public struct DiscoveredSpeaker: Sendable, Hashable, Identifiable {
    public var name: String
    /// IPv4 address (the speaker's HTTPS certificate is issued for it).
    public var host: String
    /// Product code, e.g. `SP4041` (LSX II).
    public var model: String?
    public var modelName: String?
    public var mac: String?
    public var firmware: String?

    public var id: String { mac ?? host }
}

/// Discovery of KEF W2 speakers over Bonjour (`_kef-info._tcp`).
///
/// The service advertises TXT records (`name`, `model`, `modelName`, `mac`,
/// `version`) and port 80, which recent firmware no longer serves, so the host
/// name is resolved to an IPv4 address instead of connecting to the service.
public enum KEFDiscovery {
    public static let serviceType = "_kef-info._tcp"

    /// Browse for `timeout`, then resolve every speaker found.
    public static func discover(timeout: Duration = .seconds(3)) async -> [DiscoveredSpeaker] {
        let results = await browse(timeout: timeout)
        return await withTaskGroup(of: DiscoveredSpeaker?.self) { group in
            for result in results { group.addTask { await resolve(result) } }
            var speakers: [DiscoveredSpeaker] = []
            for await speaker in group {
                if let speaker, !speakers.contains(where: { $0.id == speaker.id }) { speakers.append(speaker) }
            }
            return speakers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private struct BrowseResult: Sendable {
        var name: String, type: String, domain: String
        var interfaceIndex: UInt32
        var txt: [String: String]
    }

    private static func browse(timeout: Duration) async -> [BrowseResult] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: "local."), using: .tcp)
        let found = Locked<[String: BrowseResult]>([:])
        browser.browseResultsChangedHandler = { results, _ in
            for result in results {
                guard case let .service(name, type, domain, interface) = result.endpoint else { continue }
                var txt: [String: String] = [:]
                if case let .bonjour(record) = result.metadata {
                    for (key, entry) in record.dictionary { txt[key] = entry }
                }
                let item = BrowseResult(name: name, type: type, domain: domain,
                                        interfaceIndex: UInt32(interface?.index ?? 0), txt: txt)
                found.withLock { $0[name] = item }
            }
        }
        browser.start(queue: .global(qos: .userInitiated))
        try? await Task.sleep(for: timeout)
        browser.cancel()
        return Array(found.withLock { $0 }.values)
    }

    private static func resolve(_ result: BrowseResult) async -> DiscoveredSpeaker? {
        guard let target = await DNSSD.resolveHostTarget(
                  name: result.name, type: result.type, domain: result.domain, interface: result.interfaceIndex),
              let address = await DNSSD.ipv4Address(host: target, interface: result.interfaceIndex)
        else { return nil }
        let instance = result.name.split(separator: "@").last.map(String.init) ?? result.name
        return DiscoveredSpeaker(
            name: result.txt["name"] ?? instance,
            host: address,
            model: result.txt["model"],
            modelName: result.txt["modelName"],
            mac: result.txt["mac"],
            firmware: result.txt["version"])
    }
}

/// Minimal async wrappers over the dns_sd C API (resolve + IPv4 lookup).
enum DNSSD {
    static let queue = DispatchQueue(label: "KEFKit.dnssd")

    /// One-shot operation: finishes once (first answer or timeout) and cleans up.
    private final class Operation: @unchecked Sendable {
        private var continuation: CheckedContinuation<String?, Never>?
        var ref: DNSServiceRef?

        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

        /// Always called on `DNSSD.queue`.
        func finish(_ value: String?) {
            guard let continuation else { return }
            self.continuation = nil
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
            continuation.resume(returning: value)
            Unmanaged.passUnretained(self).release()  // balance passRetained in start
        }

        func start(timeout: TimeInterval, _ body: (UnsafeMutableRawPointer) -> (DNSServiceErrorType, DNSServiceRef?)) {
            let context = Unmanaged.passRetained(self).toOpaque()
            let (error, ref) = body(context)
            guard error == kDNSServiceErr_NoError, let ref else { finish(nil); return }
            self.ref = ref
            DNSServiceSetDispatchQueue(ref, DNSSD.queue)
            DNSSD.queue.asyncAfter(deadline: .now() + timeout) { self.finish(nil) }
        }

        static func from(_ context: UnsafeMutableRawPointer?) -> Operation {
            Unmanaged<Operation>.fromOpaque(context!).takeUnretainedValue()
        }
    }

    static func resolveHostTarget(name: String, type: String, domain: String, interface: UInt32) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                Operation(continuation).start(timeout: 3) { context in
                    var ref: DNSServiceRef?
                    let error = DNSServiceResolve(&ref, 0, interface, name, type, domain, { _, _, _, error, _, target, _, _, _, context in
                        let host = error == kDNSServiceErr_NoError ? target.map { String(cString: $0) } : nil
                        Operation.from(context).finish(host)
                    }, context)
                    return (error, ref)
                }
            }
        }
    }

    static func ipv4Address(host: String, interface: UInt32) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                Operation(continuation).start(timeout: 3) { context in
                    var ref: DNSServiceRef?
                    let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv4)
                    let error = DNSServiceGetAddrInfo(&ref, 0, interface, protocols, host, { _, _, _, error, _, address, _, context in
                        guard error == kDNSServiceErr_NoError, let address, address.pointee.sa_family == sa_family_t(AF_INET) else { return }
                        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                            var addr = sin.pointee.sin_addr
                            _ = inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN))
                        }
                        let length = text.firstIndex(of: 0) ?? text.count
                        Operation.from(context).finish(String(decoding: text[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self))
                    }, context)
                    return (error, ref)
                }
            }
        }
    }
}

/// A tiny lock-protected box (Network callbacks run on arbitrary queues).
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
