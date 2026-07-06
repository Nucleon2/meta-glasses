//
//  PCMConverter.swift
//  RayBanMiniMax
//
//  Float32 <-> Int16 conversion, simple linear resampling, and normalization
//  helpers used by the audio pipeline. All routines are pure and testable.
//

import Foundation
import AVFoundation

enum PCMConverter {
    // MARK: - Float32 <-> Int16

    /// Convert interleaved Float32 samples (range -1.0 ... 1.0) to little-endian
    /// Int16 PCM. Out-of-range values are clamped.
    static func floatToInt16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            let value = Int16(clamped * 32_767.0)
            // Little-endian
            data.append(UInt8(value & 0xff))
            data.append(UInt8((value >> 8) & 0xff))
        }
        return data
    }

    /// Convert a contiguous Float32 buffer to Int16 samples (in-place on a new array).
    static func floatToInt16Samples(_ samples: [Float]) -> [Int16] {
        var out = [Int16]()
        out.reserveCapacity(samples.count)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            out.append(Int16(clamped * 32_767.0))
        }
        return out
    }

    /// Convert little-endian Int16 PCM bytes to Float32 samples in -1.0 ... 1.0.
    static func int16ToFloat(_ data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float]()
        out.reserveCapacity(count)
        var i = 0
        while i < data.count - 1 {
            let lo = UInt16(data[i])
            let hi = UInt16(data[i + 1])
            let sample = Int16(bitPattern: (hi << 8) | lo)
            out.append(Float(sample) / 32_767.0)
            i += 2
        }
        return out
    }

    // MARK: - Resampling (linear interpolation)

    /// Resample `samples` from `inputRate` to `outputRate` using linear
    /// interpolation. Mono in, mono out.
    static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double) -> [Float] {
        guard inputRate > 0, outputRate > 0, !samples.isEmpty else { return [] }
        if abs(inputRate - outputRate) < 0.5 {
            return samples
        }
        let ratio = inputRate / outputRate
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }

        var out = [Float]()
        out.reserveCapacity(outputCount)
        for i in 0..<outputCount {
            let sourceIndex = Double(i) * ratio
            let lowIndex = Int(sourceIndex)
            let frac = Float(sourceIndex - Double(lowIndex))
            let low = samples[lowIndex]
            let high = (lowIndex + 1 < samples.count) ? samples[lowIndex + 1] : low
            out.append(low + (high - low) * frac)
        }
        return out
    }

    /// Same as above, but produces Int16 little-endian bytes ready for AVAudioEngine.
    static func resampleToInt16(_ samples: [Float],
                                from inputRate: Double,
                                to outputRate: Double) -> Data {
        return floatToInt16(resample(samples, from: inputRate, to: outputRate))
    }

    // MARK: - Normalization

    /// Peak-normalize samples to a target amplitude in (0, 1].
    static func normalize(_ samples: [Float], target: Float = 0.95) -> [Float] {
        guard let peak = samples.map(abs).max(), peak > 0 else { return samples }
        let gain = target / peak
        return samples.map { $0 * gain }
    }

    /// Apply a simple per-sample gain.
    static func applyGain(_ samples: [Float], gain: Float) -> [Float] {
        return samples.map { $0 * gain }
    }

    // MARK: - AVAudioPCMBuffer helpers

    /// Build a mono Float32 AVAudioPCMBuffer at the given sample rate from a
    /// Float32 sample array. Returns nil on failure.
    static func makeMonoFloat32Buffer(samples: [Float],
                                      sampleRate: Double) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData {
            let dst = channelData[0]
            for i in 0..<samples.count {
                dst[i] = samples[i]
            }
        }
        return buffer
    }

    /// Read all Float32 samples from a mono/stereo Float32 buffer (downmix to mono).
    static func readMonoFloat32Samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var out = [Float]()
        out.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            var sum: Float = 0
            for c in 0..<channels {
                sum += channelData[c][i]
            }
            out.append(sum / Float(channels))
        }
        return out
    }

    // MARK: - RMS

    /// Root-mean-square energy of a sample buffer. Useful for VAD.
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return sqrt(sum / Float(samples.count))
    }
}
