//
//  SyllableDetectorConfig.swift
//  SongDetector
//
//  Created by Nathan Perkins on 9/22/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Foundation

struct SyllableDetectorConfig
{
    enum Scaling {
        case linear
        case log
        case db
        
        init?(fromName name: String) {
            switch name {
            case "linear":
                self = .linear
            case "log":
                self = .log
            case "db":
                self = .db
            default:
                return nil
            }
        }
    }
    
    let samplingRate: Double // eqv: samplerate
    let fourierLength: Int // eqv: FFT_SIZE
    let windowLength: Int
    let windowOverlap: Int // eqv: NOVERLAP = FFT_SIZE - (floor(samplerate * FFT_TIME_SHIFT))
    
    let freqRange: (Double, Double) // eqv: freq_range
    let timeRange: Int // eqv: time_window_steps = double(floor(time_window / timestep))
    
    let spectrogramScaling: Scaling
    
    let thresholds: [Double] // eqv: trigger threshold
    
    let net: NeuralNet
}

// make parsable
extension SyllableDetectorConfig
{
    enum ParseError: Error {
        case unableToOpenPath(String)
        case missingValue(String)
        case invalidValue(String)
        case mismatchedLength(String)
    }
    
    private static func parseString(_ nm: String, from data: [String: String]) throws -> String {
        guard let v = data[nm] else { throw ParseError.missingValue(nm) }
        return v
    }
    
    private static func parseDouble(_ nm: String, from data: [String: String]) throws -> Double {
        guard let v = data[nm] else { throw ParseError.missingValue(nm) }
        guard let d = Double(v) else { throw ParseError.invalidValue(nm) }
        return d
    }
    
    private static func parseFloat(_ nm: String, from data: [String: String]) throws -> Float {
        guard let v = data[nm] else { throw ParseError.missingValue(nm) }
        guard let f = Float(v) else { throw ParseError.invalidValue(nm) }
        return f
    }
    
    private static func parseInt(_ nm: String, from data: [String: String]) throws -> Int {
        guard let v = data[nm] else { throw ParseError.missingValue(nm) }
        guard let i = Int(v) else { throw ParseError.invalidValue(nm) }
        return i
    }
    
    private static func parseDoubleArray(_ nm: String, withCount cnt: Int? = nil, from data: [String: String]) throws -> [Double] {
        guard let v = data[nm] else { throw ParseError.missingValue(nm) }
        
        // split into doubles
        let stringParts = v.splitAtCharacter(",").map { $0.trim() }
        let doubleParts = stringParts.compactMap(Double.init)
        
        // compare lengths to make sure all doubles were parsed
        if stringParts.count != doubleParts.count { throw ParseError.invalidValue(nm) }
        
        // check count
        if let desiredCnt = cnt {
            if doubleParts.count != desiredCnt { throw ParseError.mismatchedLength(nm) }
        }
        
        return doubleParts
    }
    
    private static func parseFloatArray(_ nm: String, withCount cnt: Int, from data: [String: String]) throws -> [Float] {
        guard let v = data[nm] else { throw ParseError.missingValue(nm) }
        
        // split into doubles
        let stringParts = v.splitAtCharacter(",").map { $0.trim() }
        let floatParts = stringParts.compactMap(Float.init)
        
        // compare lengths to make sure all doubles were parsed
        if stringParts.count != floatParts.count { throw ParseError.invalidValue(nm) }
        
        // check count
        if floatParts.count != cnt { throw ParseError.mismatchedLength(nm) }
        
        return floatParts
    }
    
    private static func parseMapMinMax(_ nm: String, withCount cnt: Int, from data: [String: String]) throws -> MapMinMax {
        let xOffsets = try SyllableDetectorConfig.parseFloatArray("\(nm).xOffsets", withCount: cnt, from: data)
        let gains = try SyllableDetectorConfig.parseFloatArray("\(nm).gains", withCount: cnt, from: data)
        let yMin = try SyllableDetectorConfig.parseFloat("\(nm).yMin", from: data)
        return MapMinMax(xOffsets: xOffsets, gains: gains, yMin: yMin)
    }
    
    private static func parseMapStd(_ nm: String, withCount cnt: Int, from data: [String: String]) throws -> MapStd {
        let xOffsets = try SyllableDetectorConfig.parseFloatArray("\(nm).xOffsets", withCount: cnt, from: data)
        let gains = try SyllableDetectorConfig.parseFloatArray("\(nm).gains", withCount: cnt, from: data)
        let yMean = try SyllableDetectorConfig.parseFloat("\(nm).yMean", from: data)
        return MapStd(xOffsets: xOffsets, gains: gains, yMean: yMean)
    }
    
    private static func parseInputProcessingFunction(_ nm: String, withCount cnt: Int, from data: [String: String]) throws -> InputProcessingFunction {
        // get processing function
        // TODO: add a default processing function that passes through values
        let functionName = try SyllableDetectorConfig.parseString("\(nm).function", from: data)
        
        switch functionName {
        case "mapminmax":
            return try SyllableDetectorConfig.parseMapMinMax(nm, withCount: cnt, from: data)
            
        case "mapstd":
            return try SyllableDetectorConfig.parseMapStd(nm, withCount: cnt, from: data)
            
        case "l2normalize":
            return L2Normalize()
            
        case "normalize":
            return Normalize()
            
        case "normalizestd":
            return NormalizeStd()
            
        default:
            throw ParseError.invalidValue("\(nm).function")
        }
    }
    
    private static func parseOutputProcessingFunction(_ nm: String, withCount cnt: Int, from data: [String: String]) throws -> OutputProcessingFunction {
        // get processing function
        let functionName = try SyllableDetectorConfig.parseString("\(nm).function", from: data)
        
        switch functionName {
        case "mapminmax":
            return try SyllableDetectorConfig.parseMapMinMax(nm, withCount: cnt, from: data)
            
        case "mapstd":
            return try SyllableDetectorConfig.parseMapStd(nm, withCount: cnt, from: data)
            
        default:
            throw ParseError.invalidValue("\(nm).function")
        }
    }
    
    init(fromTextFile path: String) throws {
        // get stream
        guard let stream = StreamReader(path: path) else {
            throw ParseError.unableToOpenPath(path)
        }
        
        // automatically close
        defer {
            stream.close()
        }
        
        // read line
        var data = [String: String]()
        for line in stream {
            // split string into parts
            let parts = line.splitAtCharacter("=")
            if 2 == parts.count {
                data[parts[0].trim()] = parts[1].trim()
            }
        }
        
        // read data
        // THIS SHOULD ALL BE REWRITTEN IN SOME SORT OF SYSTEMETIZED
        
        // sampling rate: double
        samplingRate = try SyllableDetectorConfig.parseDouble("samplingRate", from: data)
        
        // fourier length: int
        fourierLength = try SyllableDetectorConfig.parseInt("fourierLength", from: data)
        if !fourierLength.isPowerOfTwo() {
            throw SyllableDetectorConfig.ParseError.invalidValue("fourierLength")
        }
        
        // window length: int, defaults to fourierLength
        if nil == data["windowLength"] {
            windowLength = fourierLength
        }
        else {
            windowLength = try SyllableDetectorConfig.parseInt("windowLength", from: data)
        }
        
        // fourier length: int
        windowOverlap = try SyllableDetectorConfig.parseInt("windowOverlap", from: data)
        
        // frequency range: double, double
        let potentialFreqRange = try SyllableDetectorConfig.parseDoubleArray("freqRange", withCount: 2, from: data)
        if 2 != potentialFreqRange.count { throw ParseError.mismatchedLength("freqRange") }
        freqRange = (potentialFreqRange[0], potentialFreqRange[1])
        
        // time range: int
        timeRange = try SyllableDetectorConfig.parseInt("timeRange", from: data)
        
        // threshold: double
        do {
            thresholds = try SyllableDetectorConfig.parseDoubleArray("thresholds", from: data)
        }
        catch {
            // backwards compatibility
            thresholds = try SyllableDetectorConfig.parseDoubleArray("threshold", from: data)
        }
        
        // read scaling
        if let scaling = Scaling(fromName: try SyllableDetectorConfig.parseString("scaling", from: data)) {
            spectrogramScaling = scaling
        }
        else {
            throw ParseError.invalidValue("scaling")
        }
        
        // get layers
        let layerCount = try SyllableDetectorConfig.parseInt("layers", from: data)
        let layers = try (0..<layerCount).map {
            (i: Int) -> NeuralNetLayer in
            let inputs = try SyllableDetectorConfig.parseInt("layer\(i).inputs", from: data)
            let outputs = try SyllableDetectorConfig.parseInt("layer\(i).outputs", from: data)
            let weights = try SyllableDetectorConfig.parseFloatArray("layer\(i).weights", withCount: (inputs * outputs), from: data)
            let biases = try SyllableDetectorConfig.parseFloatArray("layer\(i).biases", withCount: outputs, from: data)
            
            // get transfer function
            let transferFunction: TransferFunction
            switch try SyllableDetectorConfig.parseString("layer\(i).transferFunction", from: data) {
            case "TanSig": transferFunction = TanSig()
            case "LogSig": transferFunction = LogSig()
            case "PureLin": transferFunction = PureLin()
            case "SatLin": transferFunction = SatLin()
            default: throw ParseError.invalidValue("layer\(i).transferFunction")
            }
            
            return NeuralNetLayer(inputs: inputs, weights: weights, biases: biases, outputs: outputs, transferFunction: transferFunction)
        }
        
        // get input mapping
        let processInputCount = try SyllableDetectorConfig.parseInt("processInputsCount", from: data)
        let processInputs = try (0..<processInputCount).map {
            (i: Int) -> InputProcessingFunction in
            return try SyllableDetectorConfig.parseInputProcessingFunction("processInputs\(i)", withCount: layers[0].inputs, from: data)
        }
        
        // get output mapping
        let processOutputCount = try SyllableDetectorConfig.parseInt("processOutputsCount", from: data)
        let processOutputs = try (0..<processOutputCount).map {
            (i: Int) -> OutputProcessingFunction in
            return try SyllableDetectorConfig.parseOutputProcessingFunction("processOutputs\(i)", withCount: layers[layerCount - 1].outputs, from: data)
        }
        
        // create network
        net = NeuralNet(layers: layers, inputProcessing: processInputs, outputProcessing: processOutputs)
    }
}
