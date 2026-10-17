// SPDX-FileCopyrightText: 2026 Cadence contributors
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import CoreMIDI
import Foundation
import MusicCore

struct MIDISourceChoice: Identifiable, Equatable, Sendable {
    var id: Int32
    var endpoint: MIDIEndpointRef
    var name: String
}
struct MIDIUpdate: Sendable {
    var message: MIDIMessage
    var keyboard: MIDIKeyboardState
    var timestamp: Double = PracticeClock.now()
    var arrivalTimestamp = false
}
struct MIDITimedWords: Sendable {
    var words: [UInt32]
    var timestamp: Double
    var arrivalTimestamp: Bool
}
@MainActor enum MIDIDiagnostics { static var checks: [String: Bool] = [:] }

@MainActor final class MIDIKeyboard: ObservableObject {
    @Published private(set) var sources: [MIDISourceChoice] = []
    @Published private(set) var selectedID: Int32?
    @Published private(set) var connected = false
    @Published private(set) var connectionRevision = 0
    @Published private(set) var keyboard = MIDIKeyboardState()
    @Published private(set) var error: String?
    let updates = PassthroughSubject<MIDIUpdate, Never>()
    let preview: Bool
    private let persistSelection: Bool
    private var client: MIDIClientRef = 0, port: MIDIPortRef = 0, endpoint: MIDIEndpointRef = 0
    private var generation = 0
    var clientIsOpen: Bool { client != 0 }
    init(preview: Bool = false, persistSelection: Bool = true) {
        self.preview = preview
        self.persistSelection = persistSelection
        if !preview && persistSelection, let value = UserDefaults.standard.object(forKey: "midi-source-id") as? Int {
            selectedID = Int32(exactly: value)
        }
    }
    var status: String {
        if connected { return sources.first { $0.id == selectedID }?.name ?? "Keyboard connected" }
        return selectedID == nil ? "Choose a MIDI input" : "Selected keyboard is disconnected"
    }
    func start() {
        guard !preview else { return }
        if client == 0 {
            let status = MIDIClientCreateWithBlock("Cadence keyboard" as CFString, &client) { @Sendable [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            guard status == noErr else {
                error = "Could not start MIDI (\(status))."
                return
            }
        }
        refresh()
    }
    func refresh() {
        guard !preview, client != 0 else { return }
        var list: [MIDISourceChoice] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            var id: Int32 = 0
            var name: Unmanaged<CFString>?
            guard MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id) == noErr else { continue }
            _ = MIDIObjectGetStringProperty(source, kMIDIPropertyDisplayName, &name)
            list.append(
                MIDISourceChoice(
                    id: id, endpoint: source, name: name?.takeRetainedValue() as String? ?? "MIDI input \(i+1)"))
        }
        sources = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let desired = sources.first { $0.id == selectedID }?.endpoint ?? 0
        if desired != endpoint {
            disconnect()
            if desired != 0 { connect(desired) }
        }
    }
    func choose(_ id: Int32?) {
        guard id != selectedID else { return }
        disconnect()
        selectedID = id
        if !preview {
            if persistSelection {
                if let id {
                    UserDefaults.standard.set(Int(id), forKey: "midi-source-id")
                } else {
                    UserDefaults.standard.removeObject(forKey: "midi-source-id")
                }
            }
            start()
        } else {
            connected = id != nil
        }
    }
    private func connect(_ source: MIDIEndpointRef) {
        generation += 1
        let token = generation
        var newPort: MIDIPortRef = 0
        let status = MIDIInputPortCreateWithProtocol(client, "Cadence input" as CFString, MIDIProtocolID._1_0, &newPort)
        { @Sendable [weak self] list, _ in
            let packets = Self.copyPackets(list)
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.receive(packets)
            }
        }
        guard status == noErr else {
            error = "Could not open MIDI input (\(status))."
            return
        }
        port = newPort
        let result = MIDIPortConnectSource(port, source, nil)
        guard result == noErr else {
            MIDIPortDispose(port)
            port = 0
            error = "Could not connect this keyboard (\(result))."
            return
        }
        endpoint = source
        connected = true
        error = nil
    }
    nonisolated static func copyPackets(_ list: UnsafePointer<MIDIEventList>) -> [MIDITimedWords] {
        let offset = MemoryLayout<MIDIEventList>.offset(of: \.packet)!
        let dataOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)!
        var packet = UnsafeRawPointer(list).advanced(by: offset).assumingMemoryBound(to: MIDIEventPacket.self)
        var packets: [MIDITimedWords] = []
        let arrival = PracticeClock.now()
        for _ in 0..<list.pointee.numPackets {
            let data = UnsafeRawPointer(packet).advanced(by: dataOffset).assumingMemoryBound(to: UInt32.self)
            let raw = packet.pointee.timeStamp
            let source = PracticeClock.seconds(raw)
            let fallback = raw == 0 || source > arrival + 0.01
            packets.append(
                MIDITimedWords(
                    words: Array(UnsafeBufferPointer(start: data, count: Int(packet.pointee.wordCount))),
                    timestamp: fallback ? arrival : source, arrivalTimestamp: fallback))
            packet = UnsafePointer(MIDIEventPacketNext(packet))
        }
        return packets
    }
    private func receive(_ packets: [MIDITimedWords]) {
        for packet in packets {
            for message in MIDIWords.decode(packet.words) {
                receive(message, timestamp: packet.timestamp, arrivalTimestamp: packet.arrivalTimestamp)
            }
        }
    }
    private func receive(
        _ message: MIDIMessage, timestamp: Double = PracticeClock.now(), arrivalTimestamp: Bool = false
    ) {
        keyboard.receive(message)
        updates.send(
            MIDIUpdate(message: message, keyboard: keyboard, timestamp: timestamp, arrivalTimestamp: arrivalTimestamp))
    }
    func panic() { receive(.reset) }
    private func disconnect() {
        generation += 1
        connectionRevision += 1
        if port != 0 {
            if endpoint != 0 { MIDIPortDisconnectSource(port, endpoint) }
            MIDIPortDispose(port)
            port = 0
        }
        endpoint = 0
        connected = false
        panic()
    }
    func shutdown() {
        disconnect()
        if client != 0 {
            MIDIClientDispose(client)
            client = 0
        }
    }
    func previewInput(_ messages: [MIDIMessage], timestamp: Double = PracticeClock.now()) {
        guard preview else { return }
        for message in messages { receive(message, timestamp: timestamp) }
    }
    func installPreview() {
        guard preview else { return }
        sources = [MIDISourceChoice(id: -100, endpoint: 0, name: "Preview keyboard")]
        selectedID = -100
        connected = true
    }

    /// Actual CoreMIDI source → input-port callback, with no physical keyboard or sound.
    func verifyVirtualInput() async throws -> [String: Bool] {
        guard !preview else { return [:] }
        let ownsClient = client == 0
        start()
        guard client != 0 else { throw MusicError.invalid(error ?? "The MIDI test client did not start.") }
        var source: MIDIEndpointRef = 0
        let status = MIDISourceCreateWithProtocol(
            client, "Cadence isolated MIDI check" as CFString, MIDIProtocolID._1_0, &source)
        guard status == noErr else { throw MusicError.invalid("Could not create the MIDI test source (\(status)).") }
        defer {
            disconnect()
            MIDIEndpointDispose(source)
            if ownsClient { shutdown() }
        }
        // Connect directly: never alter the user's selected source preference.
        var fixtureID: Int32 = 0
        _ = MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &fixtureID)
        selectedID = fixtureID
        disconnect()
        connect(source)
        var seen: [MIDIUpdate] = []
        let subscription = updates.sink { seen.append($0) }
        defer { subscription.cancel() }
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, MIDIProtocolID._1_0)
        let words: [UInt32] = [0x2090_3c64, 0x2090_4064, 0x2090_4364]
        let sentTime = mach_absolute_time()
        _ = words.withUnsafeBufferPointer {
            MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, sentTime, words.count, $0.baseAddress!)
        }
        guard MIDIReceivedEventList(source, &list) == noErr else {
            throw MusicError.invalid("Could not send the MIDI test notes.")
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        let notes = keyboard.downNotes == [60, 64, 67]
        var off = MIDIEventList()
        let offPacket = MIDIEventListInit(&off, MIDIProtocolID._1_0)
        let releases: [UInt32] = [0x2080_3c00, 0x2080_4000, 0x2080_4300]
        _ = releases.withUnsafeBufferPointer {
            MIDIEventListAdd(
                &off, MemoryLayout<MIDIEventList>.size, offPacket, mach_absolute_time(), releases.count, $0.baseAddress!
            )
        }
        _ = MIDIReceivedEventList(source, &off)
        try await Task.sleep(nanoseconds: 150_000_000)
        let released = keyboard.downNotes.isEmpty
        let timestamps =
            seen.prefix(3).count == 3
            && seen.prefix(3).allSatisfy {
                !$0.arrivalTimestamp && abs($0.timestamp - PracticeClock.seconds(sentTime)) < 0.000001
            }
        disconnect()
        return [
            "virtualMIDINotes": notes, "virtualMIDIRelease": released,
            "midiDisconnectClearsNotes": keyboard.soundingNotes.isEmpty, "virtualMIDITimestamps": timestamps,
        ]
    }
}
