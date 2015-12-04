//
//  CircularShortTimeFourierTransform.swift
//  SongDetector
//
//  Created by Nathan Perkins on 9/4/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Foundation
import Accelerate

enum WindowType
{
    case None
    case Hamming
    case Hanning
    case Blackman
    
    func createWindow(pointer: UnsafeMutablePointer<Float>, len: Int) {
        switch self {
        case None:
            var one: Float = 1.0
            vDSP_vfill(&one, pointer, 1, vDSP_Length(len))
        case Hamming: vDSP_hamm_window(pointer, vDSP_Length(len), 0)
        case Hanning: vDSP_hann_window(pointer, vDSP_Length(len), 0)
        case Blackman: vDSP_blkman_window(pointer, vDSP_Length(len), 0)
        }
    }
}

class CircularShortTimeFourierTransform
{
    private var buffer: TPCircularBuffer
    
    let length: Int
    
    // only one can be non-zero
    let gap: Int // gaps between samples
    let overlap: Int // overlap between samples
    
    private let fftLength: vDSP_Length
    private let fftSetup: FFTSetup
    
    // kind of hacky, but nice for normalizing audio depending on the format
    // if changed, should reset window for better accuracy
    var scaleInputBy: Double = 1.0 {
        didSet {
            var s = Float(scaleInputBy / oldValue)
            vDSP_vsmul(window, 1, &s, window, 1, vDSP_Length(length))
        }
    }
    
    var windowType = WindowType.Hanning {
        didSet {
            resetWindow()
        }
    }
    
    private let window: UnsafeMutablePointer<Float>
    
    // reusable memory
    private var complexBufferA: DSPSplitComplex
    private var complexBufferT: DSPSplitComplex
    
    init(length: Int = 1024, overlap: Int = 0, buffer: Int = 409600) {
        // length of the fourier transform (must be a power of 2)
        self.length = length
        
        // if negative overlap, interpret that as a gap
        if overlap < 0 {
            self.gap = 0 - overlap
            self.overlap = 0
        }
        else {
            self.overlap = overlap
            self.gap = 0
        }
        
        // sanity check
        if overlap >= length {
            fatalError("Invalid overlap value.")
        }
        
        // maybe use lazy instantion?
        
        // setup fft
        fftLength = vDSP_Length(ceil(log2(CDouble(length))))
        fftSetup = vDSP_create_fftsetup(fftLength, FFTRadix(kFFTRadix2))
        
        // setup window
        window = UnsafeMutablePointer<Float>.alloc(length)
        windowType.createWindow(window, len: length)
        
        // half length (for buffer allocation)
        let halfLength = length / 2
        
        // setup complex buffers
        complexBufferA = DSPSplitComplex(realp: UnsafeMutablePointer<Float>.alloc(halfLength), imagp: UnsafeMutablePointer<Float>.alloc(halfLength))
        complexBufferT = DSPSplitComplex(realp: nil, imagp: nil)
        // to get desired alignment..
        var p: UnsafeMutablePointer<Void> = nil
        posix_memalign(&p, 0x4, halfLength * sizeof(Float))
        complexBufferT.realp = UnsafeMutablePointer<Float>(p)
        p = nil
        posix_memalign(&p, 0x4, halfLength * sizeof(Float))
        complexBufferT.imagp = UnsafeMutablePointer<Float>(p)
        
        // create the circular buffer
        self.buffer = TPCircularBuffer()
        if !TPCircularBufferInit(&self.buffer, Int32(buffer)) {
            fatalError("Unable to allocate circular buffer.")
        }
    }
    
    deinit {
        // half length (for buffer allocation)
        let halfLength = length / 2
        
        // free the complex buffer
        complexBufferA.realp.destroy()
        complexBufferA.realp.dealloc(halfLength)
        complexBufferA.imagp.destroy()
        complexBufferA.imagp.dealloc(halfLength)
        complexBufferT.realp.destroy()
        complexBufferT.realp.dealloc(halfLength)
        complexBufferT.imagp.destroy()
        complexBufferT.imagp.dealloc(halfLength)
        
        // free the FFT setup
        vDSP_destroy_fftsetup(fftSetup)
        
        // free the window
        window.destroy()
        window.dealloc(length)
        
        // release the circular buffer
        TPCircularBufferCleanup(&self.buffer)
    }
    
    func frequenciesForSampleRate(rate: Double) -> [Double] {
        let halfLength = length / 2
        let toSampleRate = rate / Double(length)
        return (0..<halfLength).map { Double($0) * toSampleRate }
    }
    
    func frequencyIndexRangeFrom(startFreq: Double, to endFreq: Double, forSampleRate rate: Double) -> (Int, Int)? {
        // sensible inputs
        guard startFreq >= 0.0 && endFreq > startFreq else {
            return nil
        }
        
        // helpful numbers
        let halfLength = length / 2
        let fromFrequency = Double(length) / rate
        
        // calculate start index
        let startIndex = Int(ceil(fromFrequency * startFreq))
        if startIndex >= halfLength {
            return nil
        }
        
        // calculate end index + 1 (ceil instead of floor)
        let endIndex = Int(ceil(fromFrequency * endFreq))
        if endIndex < startIndex {
            return nil
        }
        if endIndex > halfLength {
            return (startIndex, halfLength)
        }
        return (startIndex, endIndex)
    }
    
    func resetWindow() {
        windowType.createWindow(window, len: length)
        
        var s = Float(scaleInputBy)
        vDSP_vsmul(window, 1, &s, window, 1, vDSP_Length(length))
    }
    
    func appendData(data: UnsafeMutablePointer<Float>, withSamples numSamples: Int) {
        if !TPCircularBufferProduceBytes(&self.buffer, data, Int32(numSamples * sizeof(Float))) {
            fatalError("Insufficient space on buffer.")
        }
    }
    
    func appendInterleavedData(data: UnsafeMutablePointer<Float>, withSamples numSamples: Int, fromChannel channel: Int, ofTotalChannels totalChannels: Int) {
        // get head of circular buffer
        var space: Int32 = 0
        let head = TPCircularBufferHead(&self.buffer, &space)
        if Int(space) < numSamples {
            fatalError("Insufficient space on buffer.")
        }
        
        // use vDSP to perform copy with stride
        var zero: Float = 0.0
        vDSP_vsadd(data + channel, vDSP_Stride(totalChannels), &zero, UnsafeMutablePointer<Float>(head), 1, vDSP_Length(numSamples))
        
        // move head forward
        TPCircularBufferProduce(&self.buffer, Int32(numSamples))
    }
    
    // TODO: write better functions that can help avoid double copying
    
    func extractMagnitude() -> [Float]? {
        // get buffer read point and available bytes
        var availableBytes: Int32 = 0
        var samples: UnsafeMutablePointer<Float> = UnsafeMutablePointer<Float>(TPCircularBufferTail(&buffer, &availableBytes))
        
        // not enough available bytes
        if Int(availableBytes) < ((gap + length) * sizeof(Float)) {
            return nil
        }
        
        // skip gap
        if 0 < gap {
            samples = samples + gap
        }
        
        // mark circular buffer as consumed at END of excution
        defer {
            // mark as consumed
            TPCircularBufferConsume(&buffer, Int32((gap + length - overlap) * sizeof(Float)))
        }
        
        // get half length
        let halfLength = length / 2
        
        // temporary holding (for windowing)
        let samplesCur = UnsafeMutablePointer<Float>.alloc(length)
        defer {
            samplesCur.destroy()
            samplesCur.dealloc(length)
        }
        
        // prepare output
        var output = [Float](count: halfLength, repeatedValue: 0.0)
        
        // window the samples
        vDSP_vmul(samples, 1, window, 1, samplesCur, 1, UInt(length))
            
        // pack samples into complex values (use stride 2 to fill just reals
        vDSP_ctoz(UnsafePointer<DSPComplex>(samplesCur), 2, &complexBufferA, 1, UInt(halfLength))
            
        // perform FFT
        // TODO: potentially use vDSP_fftm_zrip
        vDSP_fft_zript(fftSetup, &complexBufferA, 1, &complexBufferT, fftLength, FFTDirection(FFT_FORWARD))
            
        // clear imagp, represents frequency at midpoint of symmetry, due to packing of array
        complexBufferA.imagp[0] = 0
            
        // convert to magnitudes
        vDSP_zvmags(&complexBufferA, 1, &output, 1, UInt(halfLength))
        
        // scaling unit
        // THE LENGTH MAKES THE FFT SYMMETRIC
        var scale: Float = 4.0 // 4.0 * Float(length)
        vDSP_vsdiv(&output, 1, &scale, &output, 1, UInt(halfLength))
        
        // TODO: add appropriate scaling based on window
        
        return output
    }
    
    func extractPower() -> [Float]? {
        // get buffer read point and available bytes
        var availableBytes: Int32 = 0
        var samples: UnsafeMutablePointer<Float> = UnsafeMutablePointer<Float>(TPCircularBufferTail(&buffer, &availableBytes))
        
        // not enough available bytes
        if Int(availableBytes) < ((gap + length) * sizeof(Float)) {
            return nil
        }
        
        // skip gap
        if 0 < gap {
            samples = samples + gap
        }
        
        // mark circular buffer as consumed at END of excution
        defer {
            // mark as consumed
            TPCircularBufferConsume(&buffer, Int32((gap + length - overlap) * sizeof(Float)))
        }
        
        // get half length
        let halfLength = length / 2
        
        // temporary holding (for windowing)
        let samplesCur = UnsafeMutablePointer<Float>.alloc(length)
        defer {
            samplesCur.destroy()
            samplesCur.dealloc(length)
        }
        
        // prepare output
        var output = [Float](count: halfLength, repeatedValue: 0.0)
        
        // window the samples
        vDSP_vmul(samples, 1, window, 1, samplesCur, 1, UInt(length))
        
        // pack samples into complex values (use stride 2 to fill just reals
        vDSP_ctoz(UnsafePointer<DSPComplex>(samplesCur), 2, &complexBufferA, 1, UInt(halfLength))
        
        // perform FFT
        // TODO: potentially use vDSP_fftm_zrip
        vDSP_fft_zript(fftSetup, &complexBufferA, 1, &complexBufferT, fftLength, FFTDirection(FFT_FORWARD))
        
        // clear imagp, represents frequency at midpoint of symmetry, due to packing of array
        complexBufferA.imagp[0] = 0
        
        // convert to magnitudes
        vDSP_zvabs(&complexBufferA, 1, &output, 1, UInt(halfLength))
        
        // scaling unit
        // THE SQRT MAKES THE FFT SYMMETRIC
        var scale: Float = 2.0 // 2.0 * sqrt(Float(length))
        vDSP_vsdiv(&output, 1, &scale, &output, 1, UInt(halfLength))
        
        // TODO: add appropriate scaling based on window
        
        return output
    }
}
