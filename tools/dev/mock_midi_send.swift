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
//   /tmp/halo_mock_midi            # runs until Ctrl-C
//   /tmp/halo_mock_midi 6          # runs for ~6 seconds, then exits

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

let runSeconds = CommandLine.arguments.dropFirst().first.flatMap { Double($0) }
let deadline = runSeconds.map { Date().addingTimeInterval($0) }

FileHandle.standardError.write(Data("mock EP-40 source live as \"\(sourceName)\"\n".utf8))

var note: UInt8 = 36
while true {
    if let deadline, Date() >= deadline { break }
    send(status: 0x90, data1: note, data2: 110) // Note-On, velocity 110
    Thread.sleep(forTimeInterval: 0.12)
    send(status: 0x80, data1: note, data2: 0)   // Note-Off
    Thread.sleep(forTimeInterval: 0.06)
    note += 1
    if note > 47 { note = 36 }                  // group A pads only
}

MIDIEndpointDispose(source)
MIDIClientDispose(client)
