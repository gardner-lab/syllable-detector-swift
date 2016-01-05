//
//  NeuralNet.swift
//  SongDetector
//
//  Created by Nathan Perkins on 9/22/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Foundation
import Accelerate

// mapping function protocol
protocol InputProcessingFunction {
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int)
    func applyAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>)
}

protocol OutputProcessingFunction {
    func reverseInPlace(values: UnsafeMutablePointer<Float>, count: Int)
    func reverseAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>)
}

class PassThrough: InputProcessingFunction, OutputProcessingFunction {
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        // do nothing
    }
    
    func applyAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        memcpy(destination, values, count * sizeof(Float))
    }
    
    func reverseInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        // do nothing
    }
    
    func reverseAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        memcpy(destination, values, count * sizeof(Float))
    }
}

class L2Normalize: InputProcessingFunction {
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        // vDSP functions in the copy version support in place operations
        applyAndCopy(values, count: count, to: values)
    }
    
    func applyAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        let len = vDSP_Length(count)
        
        // sum of squares
        var sumsq: Float = 0.0, sqrtsumsq: Float = 0.0
        vDSP_svesq(values, 1, &sumsq, len)
        
        // get square root
        sqrtsumsq = sqrt(sumsq)
        
        // divide by sum of squares
        vDSP_vsdiv(values, 1, &sqrtsumsq, destination, 1, len)
    }
    
}

class Normalize: InputProcessingFunction {
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        // vDSP functions in the copy version support in place operations
        applyAndCopy(values, count: count, to: values)
    }
    
    func applyAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        let len = vDSP_Length(count)
        
        // max and min values
        var mx: Float = 0.0, mn: Float = 0.0
        var slope: Float, intercept: Float
        
        // calculate min and max
        vDSP_minv(values, 1, &mn, len)
        vDSP_maxv(values, 1, &mx, len)
        
        // calculate range
        let range = mx - mn
        
        // no range? fill with -1
        if 0 == range {
            var val: Float = -1.0
            vDSP_vfill(&val, destination, 1, len)
            return
        }
        
        // calculate slope
        slope = 2.0 / range
        intercept = (0 - mn - mx) / range;
        
        // scalar multiply and add
        vDSP_vsmsa(values, 1, &slope, &intercept, destination, 1, len)
    }
}

class NormalizeStd: InputProcessingFunction {
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        // vDSP functions in the copy version support in place operations
        applyAndCopy(values, count: count, to: values)
    }
    
    func applyAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        var mean: Float = 0.0, stddev: Float = 0.0
        vDSP_normalize(values, 1, destination, 1, &mean, &stddev, vDSP_Length(count))
    }
}

class MapMinMax: InputProcessingFunction, OutputProcessingFunction {
    var gains: [Float]
    var xOffsets: [Float]
    var yMin: Float
    
    init(xOffsets: [Float], gains: [Float], yMin: Float) {
        self.xOffsets = xOffsets
        self.gains = gains
        self.yMin = yMin
    }
    
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        // vDSP functions in the copy version support in place operations
        applyAndCopy(values, count: count, to: values)
    }
    
    func applyAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        // (values - xOffsets) * gain + yMin
        vDSP_vsbm(values, 1, &xOffsets, 1, &gains, 1, destination, 1, vDSP_Length(count))
        vDSP_vsadd(destination, 1, &yMin, destination, 1, vDSP_Length(count))
    }
    
    func reverseInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        // vDSP functions in the copy version support in place operations
        reverseAndCopy(values, count: count, to: values)
    }
    
    func reverseAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        var negYMin = 0 - yMin
        vDSP_vsadd(values, 1, &negYMin, destination, 1, vDSP_Length(count))
        vDSP_vdiv(&gains, 1, destination, 1, destination, 1, vDSP_Length(count))
        vDSP_vadd(destination, 1, &xOffsets, 1, destination, 1, vDSP_Length(count))
    }
}

class MapStd: InputProcessingFunction, OutputProcessingFunction {
    var gains: [Float]
    var xOffsets: [Float]
    var yMean: Float
    
    init(xOffsets: [Float], gains: [Float], yMean: Float) {
        self.xOffsets = xOffsets
        self.gains = gains
        self.yMean = yMean
    }
    
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        // vDSP functions in the copy version support in place operations
        applyAndCopy(values, count: count, to: values)
    }
    
    func applyAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        // (values - xOffsets) * gain + yMean
        vDSP_vsbm(values, 1, &xOffsets, 1, &gains, 1, destination, 1, vDSP_Length(count))
        
        if 0 != yMean {
            vDSP_vsadd(destination, 1, &yMean, destination, 1, vDSP_Length(count))
        }
    }
    
    func reverseInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        // vDSP functions in the copy version support in place operations
        reverseAndCopy(values, count: count, to: values)
    }
    
    func reverseAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        var negYMean = 0 - yMean
        vDSP_vsadd(values, 1, &negYMean, destination, 1, vDSP_Length(count))
        vDSP_vdiv(&gains, 1, destination, 1, destination, 1, vDSP_Length(count))
        vDSP_vadd(destination, 1, &xOffsets, 1, destination, 1, vDSP_Length(count))
    }
}

// transfer function protocol
protocol TransferFunction {
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int)
}

struct TanSig: TransferFunction {
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        var c = Int32(count)
        vvtanhf(values, values, &c)
    }
}

struct LogSig: TransferFunction {
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        let len = vDSP_Length(count)
        
        // invert sign
        var negOne: Float = -1.0
        vDSP_vsmul(values, 1, &negOne, values, 1, len)
        
        // exponent
        var c = Int32(count)
        vvexpf(values, values, &c)
        
        // add one
        var one: Float = 1.0
        vDSP_vsadd(values, 1, &one, values, 1, len)
        
        // invert
        vDSP_svdiv(&one, values, 1, values, 1, len)
    }
}

struct PureLin: TransferFunction {
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        // dp nothing
    }
}

struct SatLin: TransferFunction {
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        var zero: Float = 0.0, one: Float = 1.0
        vDSP_vclip(values, 1, &zero, &one, values, 1, vDSP_Length(count))
    }
}

/// Handles an extremely limited subset of neural networks from matlab of the form I -> L -> ... -> L -> O. That is, all inputs
/// connect to the first layer only. Each layer only receives values from the prior layer. And the output only receives values
/// from the last layer. This makes memory management and sharing easy(ier).
class NeuralNet
{
    let inputs: Int
    let outputs: Int
    let inputProcessing: [InputProcessingFunction]
    let outputProcessing: [OutputProcessingFunction]
    let layers: [NeuralNetLayer]
    
    private var bufferInput: UnsafeMutablePointer<Float>
    
    init(layers: [NeuralNetLayer], inputProcessing: [InputProcessingFunction] = [], outputProcessing: [OutputProcessingFunction] = []) {
        guard 0 < layers.count else {
            fatalError("Neural network must have 1 or more layers.")
        }
        
        for (i, l) in layers.enumerate() {
            if 0 < i {
                if layers[i - 1].outputs != l.inputs {
                    fatalError("Number of inputs for layer \(i) does not match previous outputs.")
                }
            }
        }
        
        self.inputs = layers[0].inputs
        self.outputs = layers[layers.count - 1].outputs
        self.layers = layers
        
        // default input and output processing functions
        if 0 < inputProcessing.count {
            self.inputProcessing = inputProcessing
        }
        else {
            self.inputProcessing = [PassThrough()]
        }
        if 0 < outputProcessing.count {
            self.outputProcessing = outputProcessing
        }
        else {
            self.outputProcessing = [PassThrough()]
        }
        
        // memory for input layer
        bufferInput = UnsafeMutablePointer<Float>.alloc(inputs)
    }
    
    deinit {
        // free the window
        bufferInput.destroy()
        bufferInput.dealloc(inputs)
    }
    
    func apply(input: UnsafePointer<Float>) -> [Float] {
        // pointer to current buffer
        var currentBuffer: UnsafeMutablePointer<Float> = bufferInput
        var curOutput = [Float](count: outputs, repeatedValue: 0.0)

        // create input
        for (k, ip) in inputProcessing.enumerate() {
            if k == 0 {
                ip.applyAndCopy(input, count: inputs, to: currentBuffer)
            }
            else {
                ip.applyInPlace(currentBuffer, count: inputs)
            }
        }

        
        for layer in layers {
            // apply the layer and move the content buffer
            currentBuffer = layer.apply(currentBuffer)
        }
        
        // create output
        for (k, op) in outputProcessing.enumerate() {
            if k == 0 {
                op.reverseAndCopy(currentBuffer, count: outputs, to: &curOutput)
            }
            else {
                op.reverseInPlace(&curOutput, count: outputs)
            }
        }
        
        return curOutput
    }
}

class NeuralNetLayer
{
    let inputs: Int
    let outputs: Int
    var weights: [Float] // matrix of size inputs × outputs; should not change! just var for vDSP functions
    var biases: [Float] // should not change! just var for vDSP functions
    let transferFunction: TransferFunction
    
    private var bufferIntermediate: UnsafeMutablePointer<Float>
    
    init(inputs: Int, weights: [Float], biases: [Float], outputs: Int, transferFunction: TransferFunction) {
        guard 0 < inputs && 0 < outputs else {
            fatalError("Each layer must have at least one input and at least one output.")
        }
        guard weights.count == (inputs * outputs) else {
            fatalError("Weights must be a matrix with \(inputs * outputs) elements.")
        }
        guard biases.count == outputs else {
            fatalError("Biases must be a vector with \(outputs) element(s).")
        }
        
        self.inputs = inputs
        self.outputs = outputs
        self.weights = weights
        self.biases = biases
        self.transferFunction = transferFunction
        
        // memory for intermediate values and output
        bufferIntermediate = UnsafeMutablePointer<Float>.alloc(outputs)
    }
    
    deinit {
        // free the window
        bufferIntermediate.destroy()
        bufferIntermediate.dealloc(outputs)
    }
    
    func apply(input: UnsafeMutablePointer<Float>) -> UnsafeMutablePointer<Float> {
        // transform inputs
        vDSP_mmul(&weights, 1, input, 1, bufferIntermediate, 1, vDSP_Length(outputs), 1, vDSP_Length(inputs))
        
        // add biases
        vDSP_vadd(bufferIntermediate, 1, &biases, 1, bufferIntermediate, 1, vDSP_Length(outputs))
        
        // apply transfer function
        transferFunction.applyInPlace(bufferIntermediate, count: outputs)
        
        return bufferIntermediate
    }
}
