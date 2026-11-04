#!/usr/bin/env swift
// Synthesizes the "Tentacl Crew" notification sound: a short soft water-bubble bloop (sine, quick upward glide, soft decay).
// Usage: swift scripts/make-notification-sound.swift [out.caf]   (default: app/AgentPanel/Resources/Sounds/TentaclCrew.caf)
import AVFoundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "app/AgentPanel/Resources/Sounds/TentaclCrew.caf"
let rate = 44100.0, dur = 0.32, peak: Float = 0.35   // ~ -9 dBFS peak, soft
let n = Int(rate * dur)
let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true)!
let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
buf.frameLength = AVAudioFrameCount(n)
var phase = 0.0
for i in 0..<n {
    let t = Double(i) / rate
    let f = 380 + 520 * (1 - exp(-t / 0.035))                       // 380 → 900 Hz glide
    phase += 2 * .pi * f / rate
    let attack = min(1, t / 0.006), decay = exp(-t / 0.075), tail = min(1, (dur - t) / 0.02)   // 6 ms in, soft decay, 20 ms fade-out
    let v = (sin(phase) + 0.18 * sin(2 * phase)) / 1.18 * attack * decay * tail
    buf.int16ChannelData![0][i] = Int16(max(-1, min(1, Float(v) * peak)) * 32767)
}
let file = try AVAudioFile(forWriting: URL(fileURLWithPath: out), settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatInt16, interleaved: true)
try file.write(from: buf)
print("wrote \(out)")
