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
    var config: SyllableDetectorConfig
    
    // very specific audio settings required, since down sampling signal
    var audioSettings: [String: AnyObject] {
        get {
            return [AVFormatIDKey: NSNumber(unsignedInt: kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: NSNumber(int: 32), AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true, AVSampleRateKey: NSNumber(double: config.samplingRate)]
        }
    }
    
    // last values
    var lastOutput: Float
    var lastDetected: Bool {
        get {
            return (Double(lastOutput) >= config.threshold)
        }
    }
    
    private let shortTimeFourierTransform: CircularShortTimeFourierTransform
    private let freqIndices: (Int, Int) // default: (26, 90)
    private var buffer: TPCircularBuffer
    
    init(config: SyllableDetectorConfig) {
        // set configuration
        self.config = config
        
        // initialize the FFT
        shortTimeFourierTransform = CircularShortTimeFourierTransform(length: config.fourierLength, overlap: config.fourierOverlap)
        shortTimeFourierTransform.windowType = WindowType.Hamming
        
        // store frequency indices
        guard let idx = shortTimeFourierTransform.frequencyIndexRangeFrom(config.freqRange.0, to: config.freqRange.1, forSampleRate: config.samplingRate) else {
            fatalError("The frequency range is invalid.")
        }
        freqIndices = idx
        
        // create the circular buffer
        let bufferCapacity = 512 // hold several full sets of data (could be 2 easily, maybe even 1, for live processing)
        buffer = TPCircularBuffer()
        if !TPCircularBufferInit(&buffer, Int32((freqIndices.1 - freqIndices.0) * config.timeRange * bufferCapacity)) {
            fatalError("Unable to allocate circular buffer.")
        }
        
        // no last output
        lastOutput = 0.0
        
        // call super
        super.init()
    }
    
    deinit {
        // release the circular buffer
        TPCircularBufferCleanup(&buffer)
    }
    
    func processSampleBuffer(sampleBuffer: CMSampleBuffer) {
        // has samplesΩ
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
        let isInterleaved = 1 < audioDescription[0].mChannelsPerFrame && 0 == (audioDescription[0].mFormatFlags & kAudioFormatFlagIsNonInterleaved)
        let isFloat = 0 < (audioDescription[0].mFormatFlags & kAudioFormatFlagIsFloat)
        
        // checks
        guard audioDescription[0].mFormatID == kAudioFormatLinearPCM && isFloat && !isInterleaved && audioDescription[0].mBitsPerChannel == 32 else {
            fatalError("Invalid audio format.")
        }
        
        // get audio buffer
        guard let audioBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            DLog("Unable to get audio buffer.")
            return
        }
        
        // get data pointer
        var lengthAtOffset: Int = 0, totalLength: Int = 0
        var inSamples: UnsafeMutablePointer<Int8> = nil
        CMBlockBufferGetDataPointer(audioBuffer, 0, &lengthAtOffset, &totalLength, &inSamples)
        
        // append it to fourier transform
        shortTimeFourierTransform.appendData(UnsafeMutablePointer<Float>(inSamples), withSamples: numSamples)
    }
    
    func captureOutput(captureOutput: AVCaptureOutput!, didOutputSampleBuffer sampleBuffer: CMSampleBuffer!, fromConnection connection: AVCaptureConnection!) {
        // append sample data
        processSampleBuffer(sampleBuffer)
        
        // process immediately
        while processNewValue() {}
    }
    
    func appendAudioData(data: UnsafeMutablePointer<Float>, withSamples numSamples: Int) {
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
        let samples: UnsafeMutablePointer<Float> = UnsafeMutablePointer<Float>(TPCircularBufferTail(&buffer, &availableBytes))
        
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
        
        let ret = config.net.apply(samples)
        lastOutput = ret[0]
        
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