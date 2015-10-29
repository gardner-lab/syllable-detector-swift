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
protocol MappingFunction {
//    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int)
    func applyAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>)
    func reverseAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>)
}

class MapMinMax: MappingFunction {
    var gains: [Float]
    var xOffsets: [Float]
    var yMin: Float
    
    init(xOffsets: [Float], gains: [Float], yMin: Float) {
        self.xOffsets = xOffsets
        self.gains = gains
        self.yMin = yMin
    }
    
    func applyAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        // (values - xOffsets) * gain + yMin
        vDSP_vsbm(values, 1, &xOffsets, 1, &gains, 1, destination, 1, vDSP_Length(count))
        vDSP_vsadd(destination, 1, &yMin, destination, 1, vDSP_Length(count))
    }
    
    func reverseAndCopy(values: UnsafePointer<Float>, count: Int, to destination: UnsafeMutablePointer<Float>) {
        var negYMin = 0 - yMin
        vDSP_vsadd(values, 1, &negYMin, destination, 1, vDSP_Length(count))
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

struct PureLin: TransferFunction {
    func applyInPlace(values: UnsafeMutablePointer<Float>, count: Int) {
        // dp nothing
    }
}

/// Handles an extremely limited subset of neural networks from matlab of the form I -> L -> ... -> L -> O. That is, all inputs
/// connect to the first layer only. Each layer only receives values from the prior layer. And the output only receives values
/// from the last layer. This makes memory management and sharing easy(ier).
class NeuralNet
{
    let inputs: Int
    let outputs: Int
    let inputMapping: MappingFunction
    let outputMapping: MappingFunction
    let layers: [NeuralNetLayer]
    
    private var bufferInput: UnsafeMutablePointer<Float>
    
    init(layers: [NeuralNetLayer], inputMapping: MappingFunction, outputMapping: MappingFunction) {
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
        self.inputMapping = inputMapping
        self.outputMapping = outputMapping
        self.layers = layers
        
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
        inputMapping.applyAndCopy(input, count: inputs, to: currentBuffer)
        
        for layer in layers {
            // apply the layer and move the content buffer
            currentBuffer = layer.apply(currentBuffer)
        }
        
        // create output
        outputMapping.reverseAndCopy(currentBuffer, count: outputs, to: &curOutput)
        
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