//
//  PCMConverterTests.swift
//  RayBanMiniMaxTests
//
//  Pure-Swift tests using Swift Testing. Works on macOS 13+ without XCTest.
//

import Testing
@testable import RayBanMiniMaxCore

@Suite("PCMConverter")
struct PCMConverterTests {

    @Test("Float to Int16 zero")
    func floatToInt16_zero() {
        let data = PCMConverter.floatToInt16([0])
        #expect(data == Data([0x00, 0x00]))
    }

    @Test("Float to Int16 positive full scale")
    func floatToInt16_positiveFullScale() {
        let data = PCMConverter.floatToInt16([1.0])
        #expect(data == Data([0xff, 0x7f]))
    }

    @Test("Float to Int16 negative full scale")
    func floatToInt16_negativeFullScale() {
        let data = PCMConverter.floatToInt16([-1.0])
        #expect(data == Data([0x01, 0x80]))
    }

    @Test("Float to Int16 clamps out of range")
    func floatToInt16_clampsOutOfRange() {
        let data = PCMConverter.floatToInt16([2.0, -2.0])
        #expect(data == Data([0xff, 0x7f, 0x01, 0x80]))
    }

    @Test("Int16 round trip")
    func int16ToFloat_roundTrip() {
        let original: [Float] = [0.0, 0.5, -0.5, 0.99, -0.99]
        let data = PCMConverter.floatToInt16(original)
        let back = PCMConverter.int16ToFloat(data)
        #expect(back.count == original.count)
        for (a, b) in zip(back, original) {
            #expect(abs(a - b) < 1.0 / 32_000)
        }
    }

    @Test("Resample pass-through when rates match")
    func resample_passthrough() {
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4]
        let out = PCMConverter.resample(samples, from: 16_000, to: 16_000)
        #expect(out == samples)
    }

    @Test("Resample downsample by 2")
    func resample_downsampleBy2() {
        let samples: [Float] = [0.0, 1.0, 0.0, 1.0]
        let out = PCMConverter.resample(samples, from: 16_000, to: 8_000)
        #expect(out.count == 2)
    }

    @Test("Resample upsample by 2")
    func resample_upsampleBy2() {
        let samples: [Float] = [0.0, 1.0, 0.0, 1.0]
        let out = PCMConverter.resample(samples, from: 8_000, to: 16_000)
        #expect(out.count == 8)
    }

    @Test("Resample empty input")
    func resample_handlesEmpty() {
        #expect(PCMConverter.resample([], from: 16_000, to: 24_000) == [])
    }

    @Test("Normalize peak to target")
    func normalize_peakToTarget() {
        let samples: [Float] = [0.1, 0.2, -0.4, 0.0]
        let normalized = PCMConverter.normalize(samples, target: 0.95)
        let peakAbs = normalized.map(abs).max() ?? 0
        #expect(abs(peakAbs - 0.95) < 0.0001)
    }

    @Test("RMS silence")
    func rms_silence() {
        #expect(abs(PCMConverter.rms([0, 0, 0, 0])) < 0.0001)
    }

    @Test("RMS full scale")
    func rms_fullScale() {
        #expect(abs(PCMConverter.rms([1, -1, 1, -1]) - 1.0) < 0.0001)
    }
}
