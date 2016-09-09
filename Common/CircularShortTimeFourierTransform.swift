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
    case none
    case hamming
    case hanning
    case blackman
    
    func createWindow(_ pointer: UnsafeMutablePointer<Float>, len: Int) {
        switch self {
        case .none:
            var one: Float = 1.0
            vDSP_vfill(&one, pointer, 1, vDSP_Length(len))
        case .hamming: vDSP_hamm_window(pointer, vDSP_Length(len), 0)
        case .hanning: vDSP_hann_window(pointer, vDSP_Length(len), 0)
        case .blackman: vDSP_blkman_window(pointer, vDSP_Length(len), 0)
        }
    }
}

class CircularShortTimeFourierTransform
{
    private var buffer: TPCircularBuffer
    
    let lengthFft: Int // power of 2
    let lengthWindow: Int
    
    // only one can be non-zero
    let gap: Int // gaps between samples
    let overlap: Int // overlap between samples
    
    private let fftSize: vDSP_Length
    private let fftSetup: FFTSetup
    
    var windowType = WindowType.hanning {
        didSet {
            resetWindow()
        }
    }
    
    // store actual window
    private let window: UnsafeMutablePointer<Float>
    
    // store windowed values
    private let samplesWindowed: UnsafeMutablePointer<Float>
    
    // reusable memory
    private var complexBufferA: DSPSplitComplex
    private var complexBufferT: DSPSplitComplex
    
    init(windowLength lengthWindow: Int = 1024, withOverlap overlap: Int = 0, fftSizeOf theLengthFft: Int? = nil, buffer: Int = 409600) {
        // length of the fourier transform (must be a power of 2)
        self.lengthWindow = lengthWindow
        
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
        if overlap >= lengthWindow {
            fatalError("Invalid overlap value.")
        }
        
        // calculate fft
        if let v = theLengthFft {
            guard v.isPowerOfTwo() else {
                fatalError("The FFT size must be a power of 2.")
            }
            
            guard lengthWindow <= v else {
                fatalError("The FFT size must be greater than or equal to the window length.")
            }
            
            lengthFft = v
            fftSize = vDSP_Length(ceil(log2(CDouble(v))))
        }
        else {
            // automatically calculate
            fftSize = vDSP_Length(ceil(log2(CDouble(lengthWindow))))
            lengthFft = 1 << Int(fftSize)
        }
        
        // maybe use lazy instantion?
        
        // setup fft
        fftSetup = vDSP_create_fftsetup(fftSize, FFTRadix(kFFTRadix2))!
        
        // setup window
        window = UnsafeMutablePointer<Float>.allocate(capacity: lengthWindow)
        windowType.createWindow(window, len: lengthWindow)
        
        // setup windowed samples
        samplesWindowed = UnsafeMutablePointer<Float>.allocate(capacity: lengthFft)
        vDSP_vclr(samplesWindowed, 1, vDSP_Length(lengthFft))
        
        // half length (for buffer allocation)
        let halfLength = lengthFft / 2
        
        // setup complex buffers
        complexBufferA = DSPSplitComplex(realp: UnsafeMutablePointer<Float>.allocate(capacity: halfLength), imagp: UnsafeMutablePointer<Float>.allocate(capacity: halfLength))
        // to get desired alignment..
        let alignment: Int = 0x10
        let ptrReal = UnsafeMutableRawPointer.allocate(bytes: halfLength * MemoryLayout<Float>.size, alignedTo: alignment)
        let ptrImag = UnsafeMutableRawPointer.allocate(bytes: halfLength * MemoryLayout<Float>.size, alignedTo: alignment)
        
        complexBufferT = DSPSplitComplex(realp: ptrReal.bindMemory(to: Float.self, capacity: halfLength), imagp: ptrImag.bindMemory(to: Float.self, capacity: halfLength))
        
        // create the circular buffer
        self.buffer = TPCircularBuffer()
        if !TPCircularBufferInit(&self.buffer, Int32(buffer)) {
            fatalError("Unable to allocate circular buffer.")
        }
    }
    
    deinit {
        // half length (for buffer allocation)
        let halfLength = lengthFft / 2
        
        // free the complex buffer
        complexBufferA.realp.deinitialize()
        complexBufferA.realp.deallocate(capacity: halfLength)
        complexBufferA.imagp.deinitialize()
        complexBufferA.imagp.deallocate(capacity: halfLength)
        complexBufferT.realp.deinitialize()
        complexBufferT.realp.deallocate(capacity: halfLength)
        complexBufferT.imagp.deinitialize()
        complexBufferT.imagp.deallocate(capacity: halfLength)
        
        // free the FFT setup
        vDSP_destroy_fftsetup(fftSetup)
        
        // free the memory used to store the samples
        samplesWindowed.deinitialize()
        samplesWindowed.deallocate(capacity: lengthFft)
        
        // free the window
        window.deinitialize()
        window.deallocate(capacity: lengthWindow)
        
        // release the circular buffer
        TPCircularBufferCleanup(&self.buffer)
    }
    
    func frequenciesForSampleRate(_ rate: Double) -> [Double] {
        let halfLength = lengthFft / 2
        let toSampleRate = rate / Double(lengthFft)
        return (0..<halfLength).map { Double($0) * toSampleRate }
    }
    
    func frequencyIndexRangeFrom(_ startFreq: Double, through endFreq: Double, forSampleRate rate: Double) -> (Int, Int)? {
        // sensible inputs
        guard startFreq >= 0.0 && endFreq > startFreq else {
            return nil
        }
        
        // helpful numbers
        let halfLength = lengthFft / 2
        let fromFrequency = Double(lengthFft) / rate
        
        // calculate start index
        let startIndex = Int(ceil(fromFrequency * startFreq))
        if startIndex >= halfLength {
            return nil
        }
        
        // calculate end index + 1
        let endIndex = Int(floor(fromFrequency * endFreq)) + 1
        if endIndex < startIndex {
            return nil
        }
        if endIndex > halfLength {
            return (startIndex, halfLength)
        }
        return (startIndex, endIndex)
    }
    
    func resetWindow() {
        windowType.createWindow(window, len: lengthWindow)
    }
    
    func appendData(_ data: UnsafeMutablePointer<Float>, withSamples numSamples: Int) {
        if !TPCircularBufferProduceBytes(&self.buffer, data, Int32(numSamples * MemoryLayout<Float>.size)) {
            fatalError("Insufficient space on buffer.")
        }
    }
    
    func appendInterleavedData(_ data: UnsafeMutablePointer<Float>, withSamples numSamples: Int, fromChannel channel: Int, ofTotalChannels totalChannels: Int) {
        // get head of circular buffer
        var space: Int32 = 0
        let head = TPCircularBufferHead(&self.buffer, &space)
        if Int(space) < numSamples * MemoryLayout<Float>.size {
            fatalError("Insufficient space on buffer.")
        }
        
        // use vDSP to perform copy with stride
        var zero: Float = 0.0
        vDSP_vsadd(data + channel, vDSP_Stride(totalChannels), &zero, head!.bindMemory(to: Float.self, capacity: numSamples), 1, vDSP_Length(numSamples))
        
        // move head forward
        TPCircularBufferProduce(&self.buffer, Int32(numSamples * MemoryLayout<Float>.size))
    }
    
    // TODO: write better functions that can help avoid double copying
    
    func extractMagnitude() -> [Float]? {
        // get buffer read point and available bytes
        var availableBytes: Int32 = 0
        let tail = TPCircularBufferTail(&buffer, &availableBytes)
        
        // not enough available bytes
        if Int(availableBytes) < ((gap + lengthWindow) * MemoryLayout<Float>.size) {
            return nil
        }
        
        // make samples
        var samples = tail!.bindMemory(to: Float.self, capacity: Int(availableBytes) / MemoryLayout<Float>.size)
        
        // skip gap
        if 0 < gap {
            samples = samples + gap
        }
        
        // mark circular buffer as consumed at END of excution
        defer {
            // mark as consumed
            TPCircularBufferConsume(&buffer, Int32((gap + lengthWindow - overlap) * MemoryLayout<Float>.size))
        }
        
        // get half length
        let halfLength = lengthFft / 2
        
        // prepare output
        var output = [Float](repeating: 0.0, count: halfLength)
        
        // window the samples
        vDSP_vmul(samples, 1, window, 1, samplesWindowed, 1, UInt(lengthWindow))
            
        // pack samples into complex values (use stride 2 to fill just reals
        vDSP_ctoz(unsafeBitCast(samplesWindowed, to: UnsafePointer<DSPComplex>.self), 2, &complexBufferA, 1, UInt(halfLength))
            
        // perform FFT
        // TODO: potentially use vDSP_fftm_zrip
        vDSP_fft_zript(fftSetup, &complexBufferA, 1, &complexBufferT, fftSize, FFTDirection(FFT_FORWARD))
            
        // clear imagp, represents frequency at midpoint of symmetry, due to packing of array
        complexBufferA.imagp[0] = 0
            
        // convert to magnitudes
        vDSP_zvmags(&complexBufferA, 1, &output, 1, UInt(halfLength))
        
        // scaling unit
        var scale: Float = 4.0
        vDSP_vsdiv(&output, 1, &scale, &output, 1, UInt(halfLength))
        
        return output
    }
    
    func extractPower() -> [Float]? {
        // get buffer read point and available bytes
        var availableBytes: Int32 = 0
        let tail = TPCircularBufferTail(&buffer, &availableBytes)
        
        // not enough available bytes
        if Int(availableBytes) < ((gap + lengthWindow) * MemoryLayout<Float>.size) {
            return nil
        }
        
        // make samples
        var samples = tail!.bindMemory(to: Float.self, capacity: Int(availableBytes) / MemoryLayout<Float>.size)
        
        // skip gap
        if 0 < gap {
            samples = samples + gap
        }
        
        // mark circular buffer as consumed at END of excution
        defer {
            // mark as consumed
            TPCircularBufferConsume(&buffer, Int32((gap + lengthWindow - overlap) * MemoryLayout<Float>.size))
        }
        
        // get half length
        let halfLength = lengthFft / 2
        
        // prepare output
        var output = [Float](repeating: 0.0, count: halfLength)
        
        // window the samples
        vDSP_vmul(samples, 1, window, 1, samplesWindowed, 1, UInt(lengthWindow))
        
        // pack samples into complex values (use stride 2 to fill just reals
        vDSP_ctoz(unsafeBitCast(samplesWindowed, to: UnsafePointer<DSPComplex>.self), 2, &complexBufferA, 1, UInt(halfLength))
        
        // perform FFT
        // TODO: potentially use vDSP_fftm_zrip
        vDSP_fft_zript(fftSetup, &complexBufferA, 1, &complexBufferT, fftSize, FFTDirection(FFT_FORWARD))
        
        // clear imagp, represents frequency at midpoint of symmetry, due to packing of array
        complexBufferA.imagp[0] = 0
        
        // convert to magnitudes
        vDSP_zvabs(&complexBufferA, 1, &output, 1, UInt(halfLength))
        
        // scaling unit
        var scale: Float = 2.0
        vDSP_vsdiv(&output, 1, &scale, &output, 1, UInt(halfLength))
        
        return output
    }
}
