//
//  SyllableDetector.swift
//  SongDetector
//
//  Created by Nathan Perkins on 9/18/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Foundation
import Accelerate
import AVFoundation

class SyllableDetector: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate
{
    // should be constant, but sampling rate can be changed when initializing
    let config: SyllableDetectorConfig
    
    // very specific audio settings required, since down sampling signal
    var audioSettings: [String: AnyObject] {
        get {
            return [AVFormatIDKey: NSNumber(value: kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: NSNumber(value: 32), AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true, AVSampleRateKey: NSNumber(value: config.samplingRate)]
        }
    }
    
    // last values
    var lastOutputs: [Float]
    var lastDetected: Bool {
        get {
            return (Double(lastOutputs[0]) >= config.thresholds[0])
        }
    }
    
    private let shortTimeFourierTransform: CircularShortTimeFourierTransform
    private let freqIndices: (Int, Int) // default: (26, 90)
    private var buffer: TPCircularBuffer
    
    init(config: SyllableDetectorConfig) {
        // set configuration
        self.config = config
        
        // initialize the FFT
        shortTimeFourierTransform = CircularShortTimeFourierTransform(windowLength: config.windowLength, withOverlap: config.windowOverlap, fftSizeOf: config.fourierLength)
        shortTimeFourierTransform.windowType = WindowType.hamming
        
        // store frequency indices
        guard let idx = shortTimeFourierTransform.frequencyIndexRangeFrom(config.freqRange.0, through: config.freqRange.1, forSampleRate: config.samplingRate) else {
            fatalError("The frequency range is invalid.")
        }
        freqIndices = idx
        
        // check that matches input size
        let expectedInputs = (freqIndices.1 - freqIndices.0) * config.timeRange
        guard expectedInputs == config.net.inputs else {
            fatalError("The neural network has \(config.net.inputs) inputs, but the configuration settings suggest there should be \(expectedInputs).")
        }
        
        // check that the threshold count matches the output size
        guard config.thresholds.count == config.net.outputs else {
            fatalError("The neural network has \(config.net.outputs) outputs, but the configuration settings suggest there should be \(config.thresholds.count).")
        }
        
        // create the circular buffer
        let bufferCapacity = 512 // hold several full sets of data (could be 2 easily, maybe even 1, for live processing)
        buffer = TPCircularBuffer()
        if !TPCircularBufferInit(&buffer, Int32((freqIndices.1 - freqIndices.0) * config.timeRange * bufferCapacity)) {
            fatalError("Unable to allocate circular buffer.")
        }
        
        // no last output
        lastOutputs = [Float](repeating: 0.0, count: config.net.outputs)
        
        // call super
        super.init()
    }
    
    deinit {
        // release the circular buffer
        TPCircularBufferCleanup(&buffer)
    }
    
    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // has samples
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard 0 < numSamples else {
            return
        }
        
        // get format
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            DLog("Unable to get format information.")
            return
        }
        let audioDescription = CMAudioFormatDescriptionGetStreamBasicDescription(format)
        
        // is interleaved
        let isInterleaved = 1 < (audioDescription?[0].mChannelsPerFrame)! && 0 == ((audioDescription?[0].mFormatFlags)! & kAudioFormatFlagIsNonInterleaved)
        let isFloat = 0 < ((audioDescription?[0].mFormatFlags)! & kAudioFormatFlagIsFloat)
        
        // checks
        guard audioDescription?[0].mFormatID == kAudioFormatLinearPCM && isFloat && !isInterleaved && audioDescription?[0].mBitsPerChannel == 32 else {
            fatalError("Invalid audio format.")
        }
        
        // get audio buffer
        guard let audioBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            DLog("Unable to get audio buffer.")
            return
        }
        
        // get data pointer
        var lengthAtOffset: Int = 0, totalLength: Int = 0
        var inSamples: UnsafeMutablePointer<Int8>? = nil
        CMBlockBufferGetDataPointer(audioBuffer, 0, &lengthAtOffset, &totalLength, &inSamples)
        
        // append it to fourier transform
        shortTimeFourierTransform.appendData(UnsafeMutablePointer<Float>(inSamples!), withSamples: numSamples)
    }
    
    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, from connection: AVCaptureConnection!) {
        // append sample data
        processSampleBuffer(sampleBuffer)
        
        // process immediately
        while processNewValue() {}
    }
    
    func appendAudioData(_ data: UnsafeMutablePointer<Float>, withSamples numSamples: Int) {
        // add to short-time fourier transform
        shortTimeFourierTransform.appendData(data, withSamples: numSamples)
    }
    
    private func processFourierData() -> Bool {
        // get the power information
        guard var powr = shortTimeFourierTransform.extractPower() else {
            return false
        }
        
        let lengthPerTime = freqIndices.1 - freqIndices.0
        
        // append data to local circular buffer
        withUnsafePointer(&powr[freqIndices.0]) {
            up in
            if !TPCircularBufferProduceBytes(&self.buffer, up, Int32(lengthPerTime * sizeof(Float))) {
                fatalError("Insufficient space on buffer.")
            }
        }
        
        return true
    }
    
    func processNewValue() -> Bool {
        // append all new fourier data
        while processFourierData() {}
        
        // get data counts
        let lengthPerTime = freqIndices.1 - freqIndices.0
        let lengthTotal = lengthPerTime * config.timeRange
        
        // let UnsafeMutablePointer<Float>: samples
        var availableBytes: Int32 = 0
        let samples: UnsafeMutablePointer<Float>
        guard let p = TPCircularBufferTail(&buffer, &availableBytes) else {
            return false
        }
        samples = UnsafeMutablePointer<Float>(p)
        
        // not enough available bytes
        if Int(availableBytes) < (lengthTotal * sizeof(Float)) {
            return false
        }
        
        // mark circular buffer as consumed at END of excution
        defer {
            // mark as consumed, one time per-time length
            TPCircularBufferConsume(&buffer, Int32(lengthPerTime * sizeof(Float)))
        }
        
        /// samples now points to a vector of `lengthTotal` bytes of power data for the last `timeRange` outputs of the short-timer fourier transform
        /// view as a column vector
        
        let scaledSamples: UnsafeMutablePointer<Float>
        switch config.spectrogramScaling {
        case .db:
            // temporary memory
            scaledSamples = UnsafeMutablePointer<Float>.allocate(capacity: lengthTotal)
            defer {
                scaledSamples.deinitialize()
                scaledSamples.deallocate(capacity: lengthTotal)
            }
            
            // convert to db with amplitude flag
            var one: Float = 1.0
            vDSP_vdbcon(samples, 1, &one, scaledSamples, 1, vDSP_Length(lengthTotal), 1)
            
        case .log:
            // temporary memory
            scaledSamples = UnsafeMutablePointer<Float>.allocate(capacity: lengthTotal)
            defer {
                scaledSamples.deinitialize()
                scaledSamples.deallocate(capacity: lengthTotal)
            }
            
            // natural log
            var c = Int32(lengthTotal)
            vvlogf(samples, scaledSamples, &c)
            
        case .linear:
            // no copy needed
            scaledSamples = samples
        }
        
        lastOutputs = config.net.apply(scaledSamples)
        
        return true
    }
    
    // Returns true if a syllable seen since last call to this function.
    func seenSyllable() -> Bool {
        var ret = false
        
        while processNewValue() {
            if lastDetected {
                ret = true
            }
        }
        
        return ret
    }
}
