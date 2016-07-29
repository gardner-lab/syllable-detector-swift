//
//  Processor.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 7/28/16.
//  Copyright © 2016 Gardner Lab. All rights reserved.
//

import Foundation
import Accelerate
import ORSSerial

struct ProcessorEntry {
    let inputChannel: Int
    var network: String = ""
    var config: SyllableDetectorConfig?
    var resampler: Resampler?
    let outputChannel: Int
    
    init(inputChannel: Int, outputChannel: Int) {
        self.inputChannel = inputChannel
        self.outputChannel = outputChannel
    }
}

protocol Processor: AudioInputInterfaceDelegate {
    func setUp() throws
    func tearDown()
    
    func getInputForChannel(_ channel: Int) -> Double?
    func getOutputForChannel(_ channel: Int) -> Double?
}

class ProcessorBase: Processor, AudioInputInterfaceDelegate {
    // input interface
    let interfaceInput: AudioInputInterface
    
    // processor entries
    let entries: [ProcessorEntry]
    let detectors: [SyllableDetector]
    let channels: [Int]
    
    // stats
    let statInput: [SummaryStat]
    let statOutput: [SummaryStat]
    
    // dispatch queue
    let queueProcessing: DispatchQueue
    
    init(deviceInput: AudioInterface.AudioDevice, entries: [ProcessorEntry]) throws {
        // setup processor entries
        self.entries = entries.filter {
            return $0.config != nil
        }
        
        // setup processor detectors
        self.detectors = self.entries.map {
            return SyllableDetector(config: $0.config!)
        }
        
        // setup channels
        var channels = [Int](repeating: -1, count: 1 + (self.entries.map { return $0.inputChannel }.max() ?? -1))
        for (i, p) in self.entries.enumerated() {
            channels[p.inputChannel] = i
        }
        self.channels = channels
        
        // setup stats
        var statInput = [SummaryStat]()
        var statOutput = [SummaryStat]()
        for _ in 0..<self.detectors.count {
            statInput.append(SummaryStat(withStat: StatMax()))
            statOutput.append(SummaryStat(withStat: StatMax()))
        }
        self.statInput = statInput
        self.statOutput = statOutput
        
        // setup input and output devices
        interfaceInput = AudioInputInterface(deviceID: deviceInput.deviceID)
        
        // create queue
        queueProcessing = DispatchQueue(label: "ProcessorQueue", attributes: DispatchQueueAttributes.serial)
        
        // set self as delegate
        interfaceInput.delegate = self
    }
    
    deinit {
        DLog("deinit processor")
        
        interfaceInput.tearDownAudio()
    }
    
    func setUp() throws {
        try interfaceInput.initializeAudio()
    }
    
    func tearDown() {
        interfaceInput.tearDownAudio()
    }
    
    final func receiveAudioFrom(_ interface: AudioInputInterface, fromChannel channel: Int, withData data: UnsafeMutablePointer<Float>, ofLength length: Int) {
        // valid channel
        guard channel < channels.count else { return }
        
        // get index
        let index = channels[channel]
        guard index >= 0 else { return }
        
        // get audio data
        var sum: Float = 0.0
        vDSP_svesq(data, 1, &sum, vDSP_Length(length))
        statInput[index].writeValue(Double(sum) / Double(length))
        
        // resample
        if let r = entries[index].resampler {
            var resampledData = r.resampleVector(data, ofLength: length)
            
            // append audio samples
            detectors[index].appendAudioData(&resampledData, withSamples: resampledData.count)
        }
        else {
            // append audio samples
            detectors[index].appendAudioData(data, withSamples: length)
        }
        
        // process
        queueProcessing.async {
            // detector
            let d = self.detectors[index]
            
            // seen syllable
            var seen = false
            
            // while there are new values
            while self.detectors[index].processNewValue() {
                // send to output
                self.statOutput[index].writeValue(Double(d.lastOutputs[0]))
                
                // update detected
                if !seen && d.lastDetected {
                    seen = true
                }
            }
            
            // if seen, send output
            self.prepareOutputFor(index: index, seenSyllable: seen)
        }
    }
    
    func prepareOutputFor(index: Int, seenSyllable seen: Bool) {
        // log
        if seen {
            DLog("\(index) play")
        }
    }
    
    func getInputForChannel(_ channel: Int) -> Double? {
        // valid channel
        guard channel < channels.count else { return nil }
        
        // get index
        let index = channels[channel]
        guard index >= 0 else { return nil }
        
        // output stat
        if let meanSquareLevel = statInput[index].readStatAndReset() {
            return sqrt(meanSquareLevel) // RMS
        }
        
        return nil
    }
    
    func getOutputForChannel(_ channel: Int) -> Double? {
        // valid channel
        guard channel < channels.count else { return nil }
        
        // get index
        let index = channels[channel]
        guard index >= 0 else { return nil }
        
        // output stat
        return statOutput[index].readStatAndReset()
    }
}

final class ProcessorAudio: ProcessorBase {
    // output interface
    let interfaceOutput: AudioOutputInterface
    
    // high duration
    let highDuration = 0.001 // 1ms
    
    init(deviceInput: AudioInterface.AudioDevice, deviceOutput: AudioInterface.AudioDevice, entries: [ProcessorEntry]) throws {
        // set up output interface
        interfaceOutput = AudioOutputInterface(deviceID: deviceOutput.deviceID)
        
        // call parent
        try super.init(deviceInput: deviceInput, entries: entries)
    }
    
    deinit {
        DLog("deinit processorAudio")
        interfaceOutput.tearDownAudio()
    }
    
    override func setUp() throws {
        try interfaceOutput.initializeAudio()
        try super.setUp()
    }
    
    override func tearDown() {
        super.tearDown()
        interfaceOutput.tearDownAudio()
    }
    
    override func prepareOutputFor(index: Int, seenSyllable seen: Bool) {
        if seen {
            // create output high
            interfaceOutput.createHighOutput(entries[index].outputChannel, forDuration: highDuration)
        }
        
        // call super (just for logging)
        super.prepareOutputFor(index: index, seenSyllable: seen)
    }
}

final class ProcessorArduino: ProcessorBase {
    // output interface
    let interfaceOutput: ArduinoIO
    
    // high duration
    let highSteps = 20
    var highCount = [Int]()
    
    // triggering queue
    let queueTriggering: DispatchQueue
    
    init(deviceInput: AudioInterface.AudioDevice, deviceOutput: ORSSerialPort, entries: [ProcessorEntry]) throws {
        // create high count
        highCount = [Int](repeating: 0, count: entries.count)
        
        // create output interface
        interfaceOutput = ArduinoIO(serial: deviceOutput)
        
        // create triggering queue
        queueTriggering = DispatchQueue(label: "TriggerQueue", attributes: .serial)
        
        // call parent
        try super.init(deviceInput: deviceInput, entries: entries)
    }
    
    deinit {
        DLog("deinit processorArduino")
    }
    
    override func setUp() throws {
        // configure pins
        try entries.forEach {
            try interfaceOutput.setPinMode(7 + $0.outputChannel, to: .output)
        }
        
        try super.setUp()
    }
    
    override func prepareOutputFor(index: Int, seenSyllable seen: Bool) {
        if seen {
            // start high pulse
            if 0 == highCount[index] {
                do {
                    try self.interfaceOutput.writeTo(7 + entries[index].outputChannel, digitalValue: true)
                }
                catch {
                    DLog("ERROR: \(error)")
                }
            }
            
            // set counter
            highCount[index] = 20
        }
        else if 0 < highCount[index] {
            highCount[index] -= 1
            if 0 == highCount[index] {
                do {
                    try self.interfaceOutput.writeTo(7 + entries[index].outputChannel, digitalValue: false)
                }
                catch {
                    DLog("ERROR: \(error)")
                }
            }
        }
    }
}
