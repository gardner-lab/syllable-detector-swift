//
//  Resampler.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 1/5/16.
//  Copyright © 2016 Gardner Lab. All rights reserved.
//

import Foundation
import Accelerate

protocol Resampler {
    func resampleVector(data: UnsafePointer<Float>, ofLength numSamples: Int) -> [Float]
//    func resampleVector(data: UnsafePointer<Float>, ofLength numSamples: Int, toOutput: UnsafeMutablePointer<Float>) -> Int
}

// potentially use: http://www.mega-nerd.com/SRC/api_misc.html#Converters

/// Terrible quality, very fast.
class ResamplerLinear: Resampler {
    let samplingRateIn: Double
    let samplingRateOut: Double
    
    private let step: Float
    private var last: Float = 0.0 // used for interpolating across samples
    private var offset: Float = 0.0
    
    init(fromRate samplingRateIn: Double, toRate samplingRateOut: Double) {
        self.samplingRateIn = samplingRateIn
        self.samplingRateOut = samplingRateOut
        
        self.step = Float(samplingRateIn / samplingRateOut)
    }
    
    func resampleVector(data: UnsafePointer<Float>, ofLength numSamplesIn: Int) -> [Float] {
        // need to interpolate across last set of samples
        let interpolateAcross = (offset < 0)
        
        // expected number of samples from current
        let numSamplesOut = Int((Float(numSamplesIn) - offset) / step)
        
        // return list
        var ret = [Float](count: numSamplesOut, repeatedValue: 0.0)
        
        // indices
        let indices = UnsafeMutablePointer<Float>.alloc(numSamplesOut)
        var t_offset = offset, t_step = step
        defer {
            indices.destroy()
            indices.dealloc(numSamplesOut)
        }
        vDSP_vramp(&t_offset, &t_step, indices, 1, vDSP_Length(numSamplesOut))
        
        if interpolateAcross {
            indices[0] = 0.0
        }
        
        // interpolate
        vDSP_vlint(data, indices, 1, &ret, 1, vDSP_Length(numSamplesOut), vDSP_Length(numSamplesIn))
        
        if interpolateAcross {
            ret[0] = (last * (0 - offset)) + (data[0] * (1 + offset))
        }
        
        offset = indices[numSamplesOut - 1] + step - Float(numSamplesIn - 1)
        last = data[numSamplesIn - 1]
        //print("\(indices[numSamplesOut - 1]) \(numSamplesIn) \(offset)")

        return ret
    }
    
    func resampleArray(arr: [Float]) -> [Float] {
        // used for testing
        var arr = arr
        return self.resampleVector(&arr, ofLength: arr.count)
    }
    
//    func resampleVector(data: UnsafePointer<Float>, ofLength numSamples: Int, toOutput: UnsafeMutablePointer<Float>) -> Int {
//
//    }
}

