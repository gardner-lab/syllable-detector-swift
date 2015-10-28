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

// CONSTANT: trigger duration in seconds
let kTriggerDuration = 0.001

class SyllableDetector: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, AudioInputInterfaceDelegate
{
    let config: SyllableDetectorConfig
    
    // very specific audio settings required, since down sampling signal
    var audioSettings: [String: AnyObject] {
        get {
            return [AVFormatIDKey: NSNumber(unsignedInt: kAudioFormatLinearPCM), AVLinearPCMBitDepthKey: NSNumber(int: 32), AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true, AVSampleRateKey: NSNumber(double: config.samplingRate)]
        }
    }
    
    // last values
    var lastTime: Int = 0
    var lastOutput: Float
    var lastDetected: Bool {
        get {
            return (Double(lastOutput) >= config.threshold)
        }
    }
    
    private let shortTimeFourierTransform: CircularShortTimeFourierTransform
    private let freqIndices: (Int, Int) // default: (26, 90)
    private var buffer: TPCircularBuffer
    
    private var aiDetected: AudioOutputInterface?
    
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
        
        // detection audio
        do {
            aiDetected = AudioOutputInterface()
            try aiDetected?.initializeAudio()
        }
        catch {
            DLog("Unable to setup audio output: \(error)")
            aiDetected = nil
        }
        
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
        processSampleBuffer(sampleBuffer)
        while processNewValue() {}
    }
    
    func receiveAudioFrom(interface: AudioInputInterface, inBufferList bufferList: AudioBufferList, withNumberOfSamples numSamples: Int) {
        // is interleaved
        let isInterleaved = 1 < interface.inputFormat.mChannelsPerFrame && 0 == (interface.inputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved)
        let isFloat = 0 < (interface.inputFormat.mFormatFlags & kAudioFormatFlagIsFloat)
        
        // checks
        guard interface.inputFormat.mFormatID == kAudioFormatLinearPCM && isFloat && interface.inputFormat.mBitsPerChannel == 32 && abs(interface.inputFormat.mSampleRate - config.samplingRate) < 1 else {
            fatalError("Invalid audio format.")
        }
        
        // if is interleaved
        if isInterleaved {
            // seems dumb, can't find a copy operation
            var samples = UnsafeMutablePointer<Float>.alloc(numSamples)
            defer {
                samples.destroy()
                samples.dealloc(numSamples)
            }
            
            // double: convert
            var zero: Float = 0.0
            vDSP_vsadd(UnsafeMutablePointer<Float>(bufferList.mBuffers.mData), vDSP_Stride(interface.inputFormat.mChannelsPerFrame), &zero, samples, 1, vDSP_Length(numSamples))
            shortTimeFourierTransform.appendData(samples, withSamples: numSamples)
        }
        else {
            // float: add directly
            shortTimeFourierTransform.appendData(UnsafeMutablePointer<Float>(bufferList.mBuffers.mData), withSamples: numSamples)
        }
        
        while processNewValue() {}
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
        
        // increment last time
        if 0 == lastTime {
            lastTime = config.fourierLength + ((config.fourierLength - config.fourierOverlap) * (config.timeRange - 1))
        }
        else {
            lastTime += (config.fourierLength - config.fourierOverlap)
        }
        
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
        
        // signal
        if let detected = aiDetected {
            if lastDetected {
                detected.outputHighFor = Int(detected.outputFormat.mSampleRate * kTriggerDuration)
                DLog("play")
            }
        }
        
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