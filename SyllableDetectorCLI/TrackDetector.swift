//
//  TrackDetector.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 6/2/16.
//  Copyright © 2016 Gardner Lab. All rights reserved.
//

import Foundation
import AVFoundation

class TrackDetector
{
    let track: AVAssetTrack
    let reader: AVAssetReaderTrackOutput
    let detector: SyllableDetector
    let channel: Int
    var debounceFrames = 0
    var debounceTime: Double {
        get {
            return Double(debounceFrames) / detector.config.samplingRate
        }
        set {
            debounceFrames = Int(newValue * detector.config.samplingRate)
        }
    }
    
    private var nextOutput: Int // counter until next sd output
    private var totalSamples: Int = 0
    private var debounceUntil: Int = -1

    init(track: AVAssetTrack, config: SyllableDetectorConfig, channel: Int = 0) {
        detector = SyllableDetector(config: config)
        self.track = track
        self.reader = AVAssetReaderTrackOutput(track: track, outputSettings: detector.audioSettings)
        self.channel = channel
        
        // next output is equal to one full window, plus the non-overlapping value for each subsequent time range
        nextOutput = config.windowLength + ((config.windowLength - config.windowOverlap) * (config.timeRange - 1))
        if config.windowOverlap < 0 {
            nextOutput = nextOutput - config.windowOverlap // since gap is applied even to the first data set
        }
    }
    
    func process() {
        // copy next sample buffer
        guard let sampleBuffer = reader.copyNextSampleBuffer() else {
            return
        }
        
        // get number of samples
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        //print("\(numSamples)")
        guard 0 < numSamples else {
            return
        }
        
        // get timing information
        let presentationTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        // process sample buffer
        detector.processSampleBuffer(sampleBuffer)
        
        // get output
        while detector.processNewValue() {
            // get curoutput sample number and increment next ouput sample number
            let curOutput = nextOutput
            nextOutput += detector.config.windowLength - detector.config.windowOverlap
            
            // look for detection
            var hasDetection = false
            for (i, d) in detector.lastOutputs.enumerated() {
                if Double(d) >= detector.config.thresholds[i] {
                    hasDetection = true
                    break
                }
            }
            
            // detection
            if hasDetection && debounceUntil < curOutput {
                // get sample number within current buffer
                let curSample = curOutput - totalSamples
                if curSample >= numSamples {
                    fatalError("Unexpected sample number.")
                }
                
                // get presentation time
                let curTime = CMTime(value: presentationTimestamp.value + curSample, timescale: presentationTimestamp.timescale)
                let curTimeSeconds = CMTimeGetSeconds(curTime)
                
                // print results
                print("\(channel),\(curOutput),\(curTimeSeconds)", terminator: "")
                for d in detector.lastOutputs {
                    print(",\(d)", terminator: "")
                }
                print("")
                
                // start debounce counter
                debounceUntil = curOutput + debounceFrames
            }
        }
        
        // increment number of samples
        totalSamples += numSamples
    }
}
