//
//  main.swift
//  SyllableDetectorCLI
//
//  Created by Nathan Perkins on 6/2/16.
//  Copyright © 2016 Gardner Lab. All rights reserved.
//

import Foundation
import AVFoundation

// UTILITY

private var stderr = StandardErrorOutputStream()

// PARSE COMMAND LINE

let cli = CommandLine()

let networkPath = StringOption(shortFlag: "n", longFlag: "net", required: true, helpMessage: "Path to trained network file.")
let audioPaths = MultiStringOption(shortFlag: "a", longFlag: "audio", required: true, helpMessage: "Path to the audio file to process.")
let debounceTime = DoubleOption(shortFlag: "d", longFlag: "debounce", helpMessage: "Number of seconds to debounce triggers.")
let help = BoolOption(shortFlag: "h", longFlag: "help", helpMessage: "Prints a help message.")

cli.addOptions(networkPath, audioPaths, debounceTime, help)

do {
    try cli.parse()
}
catch {
    // if help
    if !help.value {
        cli.printUsage(error)
        exit(EX_USAGE)
    }
}

// print usage
if help.value {
    cli.printUsage()
    print("The command line will write a comma separated list to standard out of detection events (when the network has at least one output above threshold). For exampling, it might output:")
    print("")
    print("\t0,1593298,36.1292063492063,0.918557")
    print("")
    print("The columns are:")
    print("1.\tThe track or channel number from the audio file (starting with 0).")
    print("2.\tThe sample number from the audio when detection occurred.")
    print("3.\tThe timestamp from the audio when detection occurred.")
    print("4.\tThe first neural network output. Note that there may be additional columns for additional outputs.")
    exit(EX_OK)
}

// RUN

// 1. load network

let config: SyllableDetectorConfig
do {
    // load file
    config = try SyllableDetectorConfig(fromTextFile: networkPath.value!)
}
catch {
    print("Unable to load the network configuration: \(error)", toStream: &stderr)
    fatalError()
}

// 2. read in the audio

audioPaths.value!.forEach {
    audioPath in
    
    // 2b. open asset
    
    let assetRead = AVAsset(URL: NSURL(fileURLWithPath: audioPath))
    let avReader: AVAssetReader
    do {
        avReader = try AVAssetReader(asset: assetRead)
    }
    catch {
        print("Unable to read \(audioPath): \(error)", toStream: &stderr)
        return
    }
    
    // get  number of audio tracks
    let tracksAudio = assetRead.tracksWithMediaType(AVMediaTypeAudio)
    guard 0 < tracksAudio.count else {
        print("No audio tracks found in \(audioPath).", toStream: &stderr)
        return
    }
    
    // make detectors
    let potentialTrackDetectors = tracksAudio.enumerate().map {
        (i, track) in
        return TrackDetector(track: track, config: config, channel: i)
    }
    
    // validate
    let trackDetectors = potentialTrackDetectors.filter {
        return avReader.canAddOutput($0.reader)
    }
    if trackDetectors.count == 0 {
        print("Can not read audio tracks found in \(audioPath).", toStream: &stderr)
        return
    }
    if trackDetectors.count < potentialTrackDetectors.count {
        print("Can not read from \(potentialTrackDetectors.count - trackDetectors.count) audio track(s) in \(audioPath). Skipping those tracks.", toStream: &stderr)
    }
    
    // add all
    trackDetectors.forEach {
        // configure
        if let seconds = debounceTime.value {
            $0.debounceTime = seconds
        }
        
        // add it
        avReader.addOutput($0.reader)
    }
    
    // start reading
    if !avReader.startReading() {
        print("Can not start reading \(audioPath): \(avReader.error).", toStream: &stderr)
        return
    }
    
    // 2c. iterate over audio
    
    if 1 < audioPaths.value!.count {
        print("\(audioPath)")
    }
    
    while avReader.status == AVAssetReaderStatus.Reading {
        for trackDetector in trackDetectors {
            trackDetector.process()
        }
    }
}

