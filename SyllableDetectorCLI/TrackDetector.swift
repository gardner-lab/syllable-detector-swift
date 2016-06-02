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
    
    var nextOutput: Int // counter until next sd output
    var totalSamples: Int = 0
    var debounceUntil: Int = -1

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
        guard 0 < numSamples else {
            return
        }
        
        // get timing information
        var itemCount: CMItemCount = 0
        if noErr != CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, 0, nil, &itemCount) {
            fatalError("Unable to read timing information.")
        }
        
        var timingInfo = UnsafeMutablePointer<CMSampleTimingInfo>(malloc(sizeof(CMSampleTimingInfo) * itemCount))
        defer {
            free(timingInfo)
        }
        
        if noErr != CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, itemCount, timingInfo, &itemCount) {
           fatalError("Unable to read timing information.")
        }
        
        // process sample buffer
        detector.processSampleBuffer(sampleBuffer)
        
        // get output
        while detector.processNewValue() {
            // get curoutput sample number and increment next ouput sample number
            let curOutput = nextOutput
            nextOutput += detector.config.windowLength - detector.config.windowOverlap
            
            // detection
            if detector.lastDetected && debounceUntil < curOutput {
                // get sample number within current buffer
                let curSample = curOutput - totalSamples
                if curSample >= numSamples {
                    fatalError("Unexpected sample number.")
                }
                
                // get presentation time
                let tm = CMTimeGetSeconds(timingInfo[curSample].presentationTimeStamp)
                
                print("\(channel),\(curOutput),\(tm),\(detector.lastOutput)")
            }
        }
        
        // increment number of samples
        totalSamples += numSamples
    }
}
