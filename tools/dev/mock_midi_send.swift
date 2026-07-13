// mock_midi_send.swift — hardware-free reactive smoke source for halo.
//
// Publishes a CoreMIDI *virtual source* whose name contains "EP-40" so the
// app's EP40MIDIObserver treats it as the real device and reaches DISPLAY LIVE.
// It loops group-A pad notes (36…47) as Note-On (0x90 n 110) / Note-Off
// (0x80 n 0) pairs. This is a DEVELOPER TEST STIMULUS ONLY — it is not the
// hardware and makes no claim about real device state; the app still labels the
// feed LIVE strictly because it observed these MIDI events.
//
// Build & run:
//   swiftc -O tools/dev/mock_midi_send.swift -o /tmp/halo_mock_midi
//   /tmp/halo_mock_midi              # default loop, runs until Ctrl-C
//   /tmp/halo_mock_midi 6            # default loop for ~6 s, then exits
//   /tmp/halo_mock_midi 10 poly      # POLY pattern for ~10 s (velocity LED +
//                                    # simultaneous holds + shared-pad refcount)

import CoreMIDI
import Foundation

let sourceName = "EP-40 Mock Source"

var client = MIDIClientRef()
var status = MIDIClientCreateWithBlock(sourceName as CFString, &client) { _ in }
guard status == noErr else {
    FileHandle.standardError.write(Data("MIDIClientCreate failed: \(status)\n".utf8))
    exit(1)
}

var source = MIDIEndpointRef()
status = MIDISourceCreateWithProtocol(client, sourceName as CFString, ._1_0, &source)
guard status == noErr else {
    FileHandle.standardError.write(Data("MIDISourceCreate failed: \(status)\n".utf8))
    exit(1)
}

// Advertise a model/manufacturer so the observer's identity match is robust.
MIDIObjectSetStringProperty(source, kMIDIPropertyModel, "EP-40" as CFString)
MIDIObjectSetStringProperty(source, kMIDIPropertyManufacturer, "Teenage Engineering" as CFString)

/// Send one MIDI 1.0 channel-voice message as a Universal MIDI Packet word.
func send(status: UInt8, data1: UInt8, data2: UInt8) {
    // UMP 32-bit: message type 0x2 (MIDI 1.0 channel voice), group 0.
    let word: UInt32 =
        (0x2 << 28) |
        (UInt32(status) << 16) |
        (UInt32(data1) << 8) |
        UInt32(data2)

    var builder = MIDIEventList()
    let listPtr = withUnsafeMutablePointer(to: &builder) { $0 }
    var packet = MIDIEventListInit(listPtr, ._1_0)
    var word32 = word
    packet = MIDIEventListAdd(listPtr, 1024, packet, 0, 1, &word32)
    MIDIReceivedEventList(source, listPtr)
}

let args = Array(CommandLine.arguments.dropFirst())
let runSeconds = args.first.flatMap { Double($0) }
let deadline = runSeconds.map { Date().addingTimeInterval($0) }
let polyMode = args.contains("poly")

func on(_ note: UInt8, _ vel: UInt8)  { send(status: 0x90, data1: note, data2: vel) }
func off(_ note: UInt8)               { send(status: 0x80, data1: note, data2: 0) }
func expired() -> Bool { if let deadline { return Date() >= deadline }; return false }

FileHandle.standardError.write(Data(
    "mock EP-40 source live as \"\(sourceName)\"\(polyMode ? " [poly]" : "")\n".utf8))

if polyMode {
    // POLY pattern — proves velocity-scaled LEDs, simultaneous depression, and the
    // shared-physical-pad refcount (notes 36 and 48 map to the same pad). This is a
    // DEVELOPER TEST STIMULUS ONLY; the app labels the feed LIVE strictly because it
    // observed these events.
    while !expired() {
        // (1) chord — three pads down together at three visibly different LED levels.
        on(40, 30); on(43, 80); on(47, 127)
        Thread.sleep(forTimeInterval: 0.7)
        off(40); Thread.sleep(forTimeInterval: 0.12)
        off(43); Thread.sleep(forTimeInterval: 0.12)
        off(47); Thread.sleep(forTimeInterval: 0.35)
        if expired() { break }

        // (2) refcount proof — 36 then 48 hit the SAME physical pad. Off 36 must NOT
        // release it (48 still holds); Off 48 releases and the LED decays.
        on(36, 100); Thread.sleep(forTimeInterval: 0.18)
        on(48, 100); Thread.sleep(forTimeInterval: 0.18)
        off(36);     Thread.sleep(forTimeInterval: 0.5)   // pad stays down, LED holds
        off(48);     Thread.sleep(forTimeInterval: 0.4)   // now it releases + decays
        if expired() { break }

        // (3) a lone soft tap to eyeball the floor intensity and the decay tail.
        on(38, 20); Thread.sleep(forTimeInterval: 0.15); off(38)
        Thread.sleep(forTimeInterval: 0.6)
    }
} else {
    var note: UInt8 = 36
    while !expired() {
        on(note, 110)
        Thread.sleep(forTimeInterval: 0.12)
        off(note)
        Thread.sleep(forTimeInterval: 0.06)
        note += 1
        if note > 47 { note = 36 }                  // group A pads only
    }
}

MIDIEndpointDispose(source)
MIDIClientDispose(client)
