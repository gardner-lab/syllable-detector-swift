//
//  ViewControllerSimulator.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 12/3/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Cocoa
import Foundation
import AVFoundation

class ViewControllerSimulator: NSViewController {
    @IBOutlet weak var buttonRun: NSButton!
    
    @IBOutlet weak var buttonLoadNetwork: NSButton!
    @IBOutlet weak var buttonLoadAudio: NSButton!
    
    @IBOutlet weak var pathNetwork: NSPathControl!
    @IBOutlet weak var pathAudio: NSPathControl!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // reload devices
        buttonRun.enabled = false
    }
    
    override func viewDidDisappear() {
        super.viewDidDisappear()
    }
    
    @IBAction func loadNetwork(sender: NSButton) {
        let panel = NSOpenPanel()
        panel.title = "Select Network Definition"
        panel.allowedFileTypes = ["txt"]
        panel.allowsOtherFileTypes = false
        
        // callback for handling response
        let cb = {
            (result: Int) -> Void in
            // make sure ok was pressed
            if NSFileHandlingPanelOKButton == result {
                if let url = panel.URL, let path = url.path {
                    do {
                        // load file
                        let _ = try SyllableDetectorConfig(fromTextFile: path)
                        
                        // confirm loaded
                        self.pathNetwork.URL = url
                        
                        // update buttons
                        self.buttonRun.enabled = (self.pathNetwork.URL != nil && self.pathAudio.URL != nil)
                    }
                    catch {
                        // unable to load
                        let alert = NSAlert()
                        alert.messageText = "Unable to load"
                        alert.informativeText = "The text file could not be successfully loaded: \(error)."
                        alert.addButtonWithTitle("Ok")
                        alert.beginSheetModalForWindow(self.view.window!, completionHandler:nil)
                    }
                }
            }
        }
        
        // show
        panel.beginSheetModalForWindow(self.view.window!, completionHandler: cb)
    }
    
    @IBAction func loadAudio(sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = [AVFileTypeWAVE, AVFileTypeAppleM4A]
        panel.title = "Select Audio File"
        
        // callback for handling response
        let cb = {
            (result: Int) -> Void in
            // make sure ok was pressed
            if NSFileHandlingPanelOKButton == result {
                if let url = panel.URL {
                    // store audio path
                    self.pathAudio.URL = url
                        
                    // update buttons
                    self.buttonRun.enabled = (self.pathNetwork.URL != nil && self.pathAudio.URL != nil)
                }
            }
        }
        
        // show
        panel.beginSheetModalForWindow(self.view.window!, completionHandler: cb)
    }
    
    @IBAction func run(sender: NSButton) {
        // confirm there are URLs
        guard let urlNetwork = pathNetwork.URL, let urlAudio = pathAudio.URL else {
            return
        }
        
        // diable all
        buttonRun.enabled = false
        buttonLoadAudio.enabled = false
        buttonLoadNetwork.enabled = false
        
        let panel = NSSavePanel()
        panel.allowedFileTypes = [AVFileTypeWAVE]
        panel.allowsOtherFileTypes = false
        panel.title = "Save Output File"
        
        // callback for handling response
        let cb = {
            (result: Int) -> Void in
            // make sure ok was pressed
            if NSFileHandlingPanelOKButton == result {
                if let url = panel.URL {
                    // simulate
                    self.simulateNetwork(urlNetwork, withAudio: urlAudio, writeTo: url)
                }
                
                // enable all
                self.buttonRun.enabled = true
                self.buttonLoadAudio.enabled = true
                self.buttonLoadNetwork.enabled = true
            }
        }
        
        // show
        panel.beginSheetModalForWindow(self.view.window!, completionHandler: cb)
    }
    
    func simulateNetwork(urlNetwork: NSURL, withAudio urlAudio: NSURL, writeTo urlOutput: NSURL) {
        // convert to path
        guard let pathNetwork = urlNetwork.path else { return }
        
        // 1. LOAD AUDIO INPUT
        let assetRead = AVAsset(URL: urlAudio)
        let avReader: AVAssetReader
        do {
            avReader = try AVAssetReader(asset: assetRead)
        }
        catch {
            DLog("\(error)")
            return
        }
        
        // get  number of audio tracks
        let tracksAudio = assetRead.tracksWithMediaType(AVMediaTypeAudio)
        guard 0 < tracksAudio.count else {
            DLog("no audio tracks")
            return
        }
        
        if 1 < tracksAudio.count {
            DLog("Only processing the first track")
        }
        
        // 2. LOAD SYLLABLE DETECTOR
        let config: SyllableDetectorConfig
        do {
            // load file
            config = try SyllableDetectorConfig(fromTextFile: pathNetwork)
        }
        catch {
            DLog("unable to load the syllabe detector")
            return
        }
        
        let sd = SyllableDetector(config: config)
        
        // 3. CONFIGURE READER
        // track reader
        let avReaderOutput = AVAssetReaderTrackOutput(track: tracksAudio[0], outputSettings: sd.audioSettings)
        if avReader.canAddOutput(avReaderOutput) {
            avReader.addOutput(avReaderOutput)
        }
        else {
            DLog("Unable to add reader output.")
            return
        }
        
        // 4. START WRITER
        // create asset and asset writer
        let avWriter: AVAssetWriter
        do {
            avWriter = try AVAssetWriter(URL: urlOutput, fileType: AVFileTypeWAVE)
        }
        catch {
            DLog("\(error)")
            return
        }
        
        // create channel layout
        var monoChannelLayout = AudioChannelLayout()
        monoChannelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        monoChannelLayout.mChannelBitmap = AudioChannelBitmap(rawValue: 0)
        monoChannelLayout.mNumberChannelDescriptions = 0
        
        // audio settings
        let compressionAudioSettings: [String: AnyObject] = [
            AVFormatIDKey: NSNumber(unsignedInt: kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: NSNumber(int: 16),
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: NSNumber(double: sd.config.samplingRate),
            AVChannelLayoutKey: NSData(bytes: &monoChannelLayout, length: sizeof(AudioChannelLayout)),
            AVNumberOfChannelsKey: NSNumber(unsignedInteger: 1)
        ]
        
        // make writer input
        let avWriterInput = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: compressionAudioSettings)
        avWriterInput.expectsMediaDataInRealTime = true
        if avWriter.canAddInput(avWriterInput) {
            avWriter.addInput(avWriterInput)
        }
        else {
            DLog("Can not add input to writer.")
            return
        }
        
        // 5. START PROCESSING
        if !avReader.startReading() {
            DLog("Unable to read: \(avReader.error)")
            return
        }
        
        // start writing
        if !avWriter.startWriting() {
            DLog("Unable to write: \(avWriter.error)")
            return
        }
        
        avWriter.startSessionAtSourceTime(kCMTimeZero)
        
        // DESCRIBE OUTPUT FORMAT
        
        // output format description
        var outputAudioFormatDescription = AudioStreamBasicDescription(mSampleRate: sd.config.samplingRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsAlignedHigh, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var outputFormatDescription: CMAudioFormatDescription? = nil
        var status = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &outputAudioFormatDescription, 0, nil, 0, nil, nil, &outputFormatDescription)
        assert(status == noErr)
        
        // processing
        var nextCount: Int = sd.config.windowLength + ((sd.config.windowLength - sd.config.windowOverlap) * (sd.config.timeRange - 1)), nextValue: Float = 0.0
        if sd.config.windowOverlap < 0 {
            nextCount = nextCount - sd.config.windowOverlap // since gap is applied even to the first data set
        }
        var samplePosition: Int64 = 0
        let gcdGroup = dispatch_group_create()
        let gcdQueue = dispatch_queue_create("Encode", DISPATCH_QUEUE_SERIAL)
        avWriterInput.requestMediaDataWhenReadyOnQueue(gcdQueue) {
            // probably not needed
            dispatch_group_enter(gcdGroup)
            defer {
                dispatch_group_leave(gcdGroup)
            }
            
            var completedOrFailed = false
            var status: OSStatus
            
            while avWriterInput.readyForMoreMediaData && !completedOrFailed {
                // copy next sample buffer
                guard let sampleBuffer = avReaderOutput.copyNextSampleBuffer() else {
                    completedOrFailed = true
                    break
                }
                
                // get number of samples
                let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
                guard 0 < numSamples else {
                    continue
                }
                
                DLog("READ: \(numSamples) samples")
                
                // run song detector
                sd.processSampleBuffer(sampleBuffer)
                
                // make floats
                // released by buffer block
                let newSamples = UnsafeMutablePointer<Float>.alloc(numSamples)
                
                // encode previous values
                var i = 0
                for ; 0 < nextCount && i < numSamples; ++i, --nextCount {
                    newSamples[i] = nextValue
                }
                
                // still more to write? don't process any
                while 0 == nextCount && sd.processNewValue() {
                    // value to write
                    var v = sd.lastOutput
                    if v > 1.0 {
                        v = 1.0
                    }
                    else if v < 0.0 {
                        v = 0.0
                    }
                    
                    // length
                    var l = sd.config.windowLength - sd.config.windowOverlap
                    
                    for ; 0 < l && i < numSamples; ++i, --l {
                        newSamples[i] = v
                    }
                    
                    if 0 < l {
                        nextCount = l
                        nextValue = v
                        break
                    }
                }
                
                // make block buffer
                var newBlockBuffer: CMBlockBuffer? = nil
                status = CMBlockBufferCreateWithMemoryBlock(nil, UnsafeMutablePointer<Void>(newSamples), numSamples * sizeof(Float), nil, nil, 0, numSamples * sizeof(Float), 0, &newBlockBuffer)
                assert(status == noErr)
                
                // timestamp for output
                let timestamp = CMTimeMake(samplePosition, Int32(outputAudioFormatDescription.mSampleRate))
                samplePosition += numSamples
                
                // get sample buffer
                var newSampleBuffer: CMSampleBuffer? = nil
                status = CMAudioSampleBufferCreateWithPacketDescriptions(kCFAllocatorDefault, newBlockBuffer, true, nil, nil, outputFormatDescription!, numSamples, timestamp, nil, &newSampleBuffer)
                assert(status == noErr)
                
                // append sample buffer
                if !avWriterInput.appendSampleBuffer(newSampleBuffer!) {
                    DLog("failed to write sample buffer \(avWriter.status) \(avWriter.error)")
                    avReader.cancelReading() // cancel reading
                    completedOrFailed = true
                }
            }
            
            if completedOrFailed {
                avWriterInput.markAsFinished()
                avWriter.finishWritingWithCompletionHandler {
                    DLog("done!")
                }
            }
        }
        
    }
}
