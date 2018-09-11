//
//  AudioInterface.swift
//  SongDetector
//
//  Created by Nathan Perkins on 10/22/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Foundation
import AudioToolbox
import Accelerate

func renderOutput(_ inRefCon:UnsafeMutableRawPointer, actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>, busNumber: UInt32, frameCount: UInt32, data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    
    // get audio out interface
    let aoi = unsafeBitCast(inRefCon, to: AudioOutputInterface.self)
    let usableBufferList = UnsafeMutableAudioBufferListPointer(data!)
    
    // number of frames
    let frameCountAsInt = Int(frameCount)
    
    // fill output
    for (channel, buffer) in usableBufferList.enumerated() {
        let data = buffer.mData!.bindMemory(to: Float.self, capacity: frameCountAsInt)
        let high = aoi.outputHighFor[channel]
        
        // decrement high for
        if 0 < high {
            aoi.outputHighFor[channel] = high - min(high, frameCountAsInt)
        }
        
        // write data out
        for i in 0..<frameCountAsInt {
            data[i] = (i < high ? 1.0 : 0.0)
        }
        
    }
    
    return 0
}

func processInput(_ inRefCon:UnsafeMutableRawPointer, actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>, busNumber: UInt32, frameCount: UInt32, data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    
    // get audio in interface
    let aii = unsafeBitCast(inRefCon, to: AudioInputInterface.self)
    
    // number of channels
    let numberOfChannels = Int(aii.inputFormat.mChannelsPerFrame)
    
    // set buffer data size
    for channel in 0..<numberOfChannels {
        aii.bufferList[channel].mDataByteSize = aii.inputFormat.mBytesPerFrame * frameCount
    }
    
    // render input
    let status = AudioUnitRender(aii.audioUnit!, actionFlags, timeStamp, busNumber, frameCount, aii.bufferList.unsafeMutablePointer)
    
    if noErr != status {
        DLog("error rendering input \(status)")
        return status
    }
    
    // number of floats per channel
    let frameCountAsInteger = Int(frameCount)
    
    // multiple channels
    for channel in 0..<numberOfChannels {
        // call delegate
        aii.delegate?.receiveAudioFrom(aii, fromChannel: channel, withData: aii.bufferList[channel].mData!.bindMemory(to: Float.self, capacity: frameCountAsInteger), ofLength: frameCountAsInteger)
    }
    
    return 0
}

enum AudioInterfaceError: Error {
    case noComponentFound
    case unsupportedFormat
    case errorResponse(String, Int, Int32)
}

private func checkError(_ status: OSStatus, type: AudioInterfaceError? = nil, funct: String = #function, line: Int = #line) throws {
    if noErr != status {
        if let errType = type {
            throw errType
        }
        else {
            throw AudioInterfaceError.errorResponse(funct, line, status)
        }
    }
}

class AudioInterface
{
    // event listeners
    static var listeners = [AudioObjectPropertySelector: Array<(Int, (() -> Void))>]()
    
    struct AudioDevice {
        let deviceID: AudioDeviceID
        let deviceUID: String
        let deviceName: String
        let deviceManufacturer: String
        let streamsInput: Int
        let streamsOutput: Int
        let sampleRateInput: Float64
        let sampleRateOutput: Float64
        let buffersInput: [AudioBuffer]
        let buffersOutput: [AudioBuffer]
        
        init?(deviceID: AudioDeviceID) {
            self.deviceID = deviceID
            
            // property address
            var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
            
            // size and status variables
            var status: OSStatus
            var size: UInt32 = UInt32(MemoryLayout<CFString>.size)
            
            // get device UID
            var deviceUID = "" as CFString
            propertyAddress.mSelector = kAudioDevicePropertyDeviceUID
            status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &deviceUID)
            guard noErr == status else { return nil }
            self.deviceUID = String(deviceUID)
            
            // get deivce name
            var deviceName = "" as CFString
            propertyAddress.mSelector = kAudioDevicePropertyDeviceNameCFString
            status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &deviceName)
            guard noErr == status else { return nil }
            self.deviceName = String(deviceName)
            
            // get deivce manufacturer
            var deviceManufacturer = "" as CFString
            propertyAddress.mSelector = kAudioDevicePropertyDeviceManufacturerCFString
            status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &deviceManufacturer)
            guard noErr == status else { return nil }
            self.deviceManufacturer = String(deviceManufacturer)
            
            // get number of streams
            // LAST AS IT CHANGES THE SCOPE OF THE PROPERTY ADDRESS
            propertyAddress.mSelector = kAudioDevicePropertyStreams
            propertyAddress.mScope = kAudioDevicePropertyScopeInput
            status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size)
            guard noErr == status else { return nil }
            self.streamsInput = Int(size) / MemoryLayout<AudioStreamID>.size
            
            if 0 < self.streamsInput {
                // get sample rate
                size = UInt32(MemoryLayout<Float64>.size)
                var sampleRateInput: Float64 = 0.0
                propertyAddress.mSelector = kAudioDevicePropertyNominalSampleRate
                status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &sampleRateInput)
                guard noErr == status else { return nil }
                self.sampleRateInput = sampleRateInput
                
                // get stream configuration
                size = 0
                propertyAddress.mSelector = kAudioDevicePropertyStreamConfiguration
                status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size)
                guard noErr == status else { DLog("d \(status)"); return nil }
                
                // allocate
                // is it okay to assume binding? or should bind (but if so, what capacity)?
                var bufferList = UnsafeMutableRawPointer.allocate(bytes: Int(size), alignedTo: MemoryLayout<AudioBufferList>.alignment).assumingMemoryBound(to: AudioBufferList.self)
                status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, bufferList)
                defer {
                    free(bufferList)
                }
                guard noErr == status else { DLog("e"); return nil }
                
                // turn into something swift usable
                let usableBufferList = UnsafeMutableAudioBufferListPointer(bufferList)
                
                // add device buffers
                var buffersInput = [AudioBuffer]()
                for ab in usableBufferList {
                    buffersInput.append(ab)
                }
                self.buffersInput = buffersInput
            }
            else {
                self.buffersInput = []
                self.sampleRateInput = 0.0
            }
            
            propertyAddress.mSelector = kAudioDevicePropertyStreams
            propertyAddress.mScope = kAudioDevicePropertyScopeOutput
            status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size)
            guard noErr == status else { return nil }
            self.streamsOutput = Int(size) / MemoryLayout<AudioStreamID>.size
            
            if 0 < self.streamsOutput {
                // get sample rate
                size = UInt32(MemoryLayout<Float64>.size)
                var sampleRateOutput: Float64 = 0.0
                propertyAddress.mSelector = kAudioDevicePropertyNominalSampleRate
                status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &sampleRateOutput)
                guard noErr == status else { return nil }
                self.sampleRateOutput = sampleRateOutput
                
                // get stream configuration
                size = 0
                propertyAddress.mSelector = kAudioDevicePropertyStreamConfiguration
                status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size)
                guard noErr == status else { DLog("d \(status)"); return nil }
                
                // allocate
                // is it okay to assume binding? or should bind (but if so, what capacity)?
                var bufferList = UnsafeMutableRawPointer.allocate(bytes: Int(size), alignedTo: MemoryLayout<AudioBufferList>.alignment).assumingMemoryBound(to: AudioBufferList.self)
                status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, bufferList)
                defer {
                    free(bufferList)
                }
                guard noErr == status else { DLog("e"); return nil }
                
                // turn into something swift usable
                let usableBufferList = UnsafeMutableAudioBufferListPointer(bufferList)
                
                // add device buffers
                var buffersOutput = [AudioBuffer]()
                for ab in usableBufferList {
                    buffersOutput.append(ab)
                }
                self.buffersOutput = buffersOutput
            }
            else {
                self.buffersOutput = []
                self.sampleRateOutput = 0.0
            }
        }
    }
    
    var audioUnit: AudioComponentInstance? = nil
    
    static func devices() throws -> [AudioDevice] {
        // property address
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        var size: UInt32 = 0
        
        // get input size
        try checkError(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size))
        
        // number of devices
        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var audioDevices = [AudioDeviceID](repeating: AudioDeviceID(0), count: deviceCount)
        
        // get device ids
        try checkError(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size, &audioDevices[0]))
        
        return audioDevices.flatMap {
            return AudioDevice(deviceID: $0)
        }
    }
    
    static func createListenerForDeviceChange<T: Hashable>(_ cb: @escaping () -> Void, withIdentifier unique: T) throws {
        let selector = kAudioHardwarePropertyDevices
        
        // alread has listener
        if var cur = listeners[selector] {
            // add callback
            cur.append((unique.hashValue, cb))
            
            // update listeners
            listeners[selector] = cur
            
            return
        }
        
        // property address
        var propertyAddress = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        let onAudioObject = AudioObjectID(bitPattern: kAudioObjectSystemObject)
        
        // create listener
        try checkError(AudioObjectAddPropertyListenerBlock(onAudioObject, &propertyAddress, nil, dispatchEvent))
        
        // create callbacks array
        let cbs: Array<(Int, (() -> Void))> = [(unique.hashValue, cb)]
        listeners[selector] = cbs
    }
    
    static func destroyListenerForDeviceChange<T: Hashable>(withIdentifier unique: T) {
        let selector = kAudioHardwarePropertyDevices
        
        guard var cur = listeners[selector] else {
            // nothing to remove
            return
        }
        
        // hash to remove
        let hashToRemove = unique.hashValue
        
        // remove from listeners
        cur = cur.filter() {
            return $0.0 != hashToRemove
        }
        
        // if empty
        if cur.isEmpty {
            // remove listener
            listeners.removeValue(forKey: selector)
            
            // property address
            var propertyAddress = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
            let onAudioObject = AudioObjectID(bitPattern: kAudioObjectSystemObject)
            
            do {
                try checkError(AudioObjectRemovePropertyListenerBlock(onAudioObject, &propertyAddress, nil, dispatchEvent))
            }
            catch {
                DLog("unable to remove listener")
            }
        }
        else {
            // update listeners
            listeners[selector] = cur
        }
    }
    
    static func dispatchEvent(_ numAddresses: UInt32, addresses: UnsafePointer<AudioObjectPropertyAddress>) {
        for i: UInt32 in 0..<numAddresses {
            let selector = addresses[Int(i)].mSelector
            if let listenersForSelector = listeners[selector] {
                for entry in listenersForSelector {
                    DispatchQueue.main.async(execute: entry.1)
                }
            }
        }
    }
}

class AudioOutputInterface: AudioInterface
{
    let deviceID: AudioDeviceID
    let frameSize: Int
    
    var outputFormat: AudioStreamBasicDescription = AudioStreamBasicDescription() // format of the actual audio hardware
    var inputFormat: AudioStreamBasicDescription = AudioStreamBasicDescription() // format of the data read from the audio hardware
    
    var outputHighFor = [Int]()
    
    init(deviceID: AudioDeviceID, frameSize: Int = 32) {
        self.deviceID = deviceID
        self.frameSize = frameSize
    }
    
    deinit {
        tearDownAudio()
    }
    
    func initializeAudio() throws {
        // set output bus
        let outputBus: AudioUnitElement = 0
        
        // describe component
        var componentDescription = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_DefaultOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        
        // get output component
        let outputComponent = AudioComponentFindNext(nil, &componentDescription)
        
        // check found
        if nil == outputComponent {
            throw AudioInterfaceError.noComponentFound
        }
        
        // make audio unit
        try checkError(AudioComponentInstanceNew(outputComponent!, &audioUnit))
        
        // set output device
        var outputDevice = deviceID
        try checkError(AudioUnitSetProperty(audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outputDevice, UInt32(MemoryLayout<AudioDeviceID>.size)))
        
        // get the audio format
        var size: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkError(AudioUnitGetProperty(audioUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, outputBus, &outputFormat, &size))
        
        // print format information for debugging
        //DLog("OUT:OUT \(outputFormat)")
        
        // check for expected format
        guard outputFormat.mFormatID == kAudioFormatLinearPCM && outputFormat.mFramesPerPacket == 1 && outputFormat.mFormatFlags == kAudioFormatFlagsNativeFloatPacked else {
            throw AudioInterfaceError.unsupportedFormat
        }
        
        // get the audio format
        //size = UInt32(sizeof(AudioStreamBasicDescription))
        //try checkError(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, outputBus, &inputFormat, &size))
        //DLog("OUT:INi \(inputFormat)")
        
        // configure input format
        inputFormat.mFormatID = kAudioFormatLinearPCM
        inputFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kLinearPCMFormatFlagIsNonInterleaved
        inputFormat.mSampleRate = outputFormat.mSampleRate
        inputFormat.mFramesPerPacket = 1
        inputFormat.mBytesPerPacket = UInt32(MemoryLayout<Float>.size)
        inputFormat.mBytesPerFrame = UInt32(MemoryLayout<Float>.size)
        inputFormat.mChannelsPerFrame = outputFormat.mChannelsPerFrame
        inputFormat.mBitsPerChannel = UInt32(8 * MemoryLayout<Float>.size)
        
        // print format information for debugging
        //DLog("OUT:IN \(inputFormat)")
        
        // set the audio format
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkError(AudioUnitSetProperty(audioUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, outputBus, &inputFormat, size))
        
        // initiate output array
        outputHighFor = [Int](repeating: 0, count: Int(outputFormat.mChannelsPerFrame))
        
        // set frame size
        var frameSize = UInt32(self.frameSize)
        try checkError(AudioUnitSetProperty(audioUnit!, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, outputBus, &frameSize, UInt32(MemoryLayout<UInt32>.size)))
        
        // setup playback callback
        var callbackStruct = AURenderCallbackStruct(inputProc: renderOutput, inputProcRefCon: unsafeBitCast(Unmanaged.passUnretained(self), to: UnsafeMutableRawPointer.self))
        try checkError(AudioUnitSetProperty(audioUnit!, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, outputBus, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        
        // initialize audio unit
        AudioUnitInitialize(audioUnit!)
        
        // start playback
        AudioOutputUnitStart(audioUnit!)
    }
    
    func tearDownAudio() {
        if nil == audioUnit {
            return
        }
        
        // stop playback
        AudioOutputUnitStop(audioUnit!)
        
        // uninitialize audio unit
        AudioUnitUninitialize(audioUnit!)
        
        // dispose
        AudioComponentInstanceDispose(audioUnit!)
        
        audioUnit = nil
    }
    
    func createHighOutput(_ channel: Int, forDuration duration: Double) {
        guard channel < Int(outputFormat.mChannelsPerFrame) else { return }
        outputHighFor[channel] = Int(duration * outputFormat.mSampleRate)
    }
    
    static func defaultOutputDevice() throws -> AudioDeviceID {
        var size: UInt32
        size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var outputDevice = AudioDeviceID()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        try checkError(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &outputDevice))
        return outputDevice
    }
}

protocol AudioInputInterfaceDelegate: class
{
    func receiveAudioFrom(_ interface: AudioInputInterface, fromChannel: Int, withData data: UnsafeMutablePointer<Float>, ofLength: Int)
}

class AudioInputInterface: AudioInterface
{
    let deviceID: AudioDeviceID
    let frameSize: Int
    
    weak var delegate: AudioInputInterfaceDelegate? = nil
    
    var inputFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()
    var outputFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()
    
    var bufferList: UnsafeMutableAudioBufferListPointer!
    
    init(deviceID: AudioDeviceID, frameSize: Int = 32) {
        self.deviceID = deviceID
        self.frameSize = frameSize
    }
    
    deinit {
        tearDownAudio()
    }
    
    func initializeAudio() throws {
        // set output bus
        let inputBus: AudioUnitElement = 1
        
        // describe component
        var componentDescription = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        
        // get input component
        let inputComponent = AudioComponentFindNext(nil, &componentDescription)
        
        // check found
        if nil == inputComponent {
            throw AudioInterfaceError.noComponentFound
        }
        
        // make audio unit
        try checkError(AudioComponentInstanceNew(inputComponent!, &audioUnit))
        
        var size: UInt32
        
        // enable input
        size = UInt32(MemoryLayout<UInt32>.size)
        var enableIO: UInt32 = 1
        try checkError(AudioUnitSetProperty(audioUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, &enableIO, size))
        
        // disable output
        enableIO = 0
        try checkError(AudioUnitSetProperty(audioUnit!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, size))
        
        // set input device
        var inputDevice = deviceID
        try checkError(AudioUnitSetProperty(audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputDevice, UInt32(MemoryLayout<AudioDeviceID>.size)))
        
        // get the audio format
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkError(AudioUnitGetProperty(audioUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inputBus, &inputFormat, &size))
        
        // print format information for debugging
        //DLog("IN:IN \(inputFormat)")
        
        // check for expected format
        guard inputFormat.mFormatID == kAudioFormatLinearPCM && inputFormat.mFramesPerPacket == 1 && inputFormat.mFormatFlags == kAudioFormatFlagsNativeFloatPacked else {
            throw AudioInterfaceError.unsupportedFormat
        }
        
        // get the audio format
        //size = UInt32(sizeof(AudioStreamBasicDescription))
        //try checkError(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &outputFormat, &size))
        //DLog("IN:OUTi \(outputFormat)")
        
        // configure output format
        outputFormat.mFormatID = kAudioFormatLinearPCM
        outputFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kLinearPCMFormatFlagIsNonInterleaved
        outputFormat.mSampleRate = inputFormat.mSampleRate
        outputFormat.mFramesPerPacket = 1
        outputFormat.mBytesPerPacket = UInt32(MemoryLayout<Float>.size)
        outputFormat.mBytesPerFrame = UInt32(MemoryLayout<Float>.size)
        outputFormat.mChannelsPerFrame = inputFormat.mChannelsPerFrame
        outputFormat.mBitsPerChannel = UInt32(8 * MemoryLayout<Float>.size)
        
        // print format information for debugging
        //DLog("IN:OUT \(outputFormat)")
        
        // set the audio format
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkError(AudioUnitSetProperty(audioUnit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &outputFormat, size))
        
        // get maximum frame size
        var maxFrameSize: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        try checkError(AudioUnitGetProperty(audioUnit!, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrameSize, &size))
        
        // create buffers
        bufferList = AudioBufferList.allocate(maximumBuffers: Int(outputFormat.mChannelsPerFrame))
        bufferList.count = Int(outputFormat.mChannelsPerFrame)
        for channel in 0 ..< Int(outputFormat.mChannelsPerFrame) {
            // build buffer
            var buffer = AudioBuffer()
            buffer.mDataByteSize = outputFormat.mBytesPerFrame * maxFrameSize
            buffer.mNumberChannels = 1 // since non-interleaved
            buffer.mData = malloc(Int(outputFormat.mBytesPerFrame * maxFrameSize))
            bufferList[channel] = buffer
        }
        
        // set frame size
        var frameSize: UInt32 = UInt32(self.frameSize)
        try checkError(AudioUnitSetProperty(audioUnit!, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frameSize, UInt32(MemoryLayout<UInt32>.size)))
        
        // setup playback callback
        var callbackStruct = AURenderCallbackStruct(inputProc: processInput, inputProcRefCon: unsafeBitCast(Unmanaged.passUnretained(self), to: UnsafeMutableRawPointer.self))
        try checkError(AudioUnitSetProperty(audioUnit!, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        
        // initialize audio unit
        AudioUnitInitialize(audioUnit!)
        
        // start playback
        AudioOutputUnitStart(audioUnit!)
    }
    
    func tearDownAudio() {
        if nil == audioUnit {
            return
        }
        
        // free buffer
        for b in bufferList {
            free(b.mData)
        }
        free(bufferList.unsafeMutablePointer)
        
        // stop playback
        AudioOutputUnitStop(audioUnit!)
        
        // uninitialize audio unit
        AudioUnitUninitialize(audioUnit!)
        
        // dispose
        AudioComponentInstanceDispose(audioUnit!)
        
        audioUnit = nil
    }
    
    static func defaultInputDevice() throws -> AudioDeviceID {
        var size: UInt32
        size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var inputDevice = AudioDeviceID()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        try checkError(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &inputDevice))
        return inputDevice
    }
}
