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

func renderOutput(inRefCon:UnsafeMutablePointer<Void>, actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>, busNumber: UInt32, frameCount: UInt32, data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    
    // get audio out interface
    let aoi = unsafeBitCast(inRefCon, AudioOutputInterface.self)
    let usableBufferList = UnsafeMutableAudioBufferListPointer(data)
    let buffer = UnsafeMutablePointer<Float>(usableBufferList[0].mData)
    
    // high settings
    let channelCountAsInt = Int(aoi.outputFormat.mChannelsPerFrame)
    let frameCountAsInt = Int(frameCount)
    
    // fill output
    var j = 0
    for var channel = 0; channel < channelCountAsInt; ++channel {
        // TODO: must be faster way to fill vectors using vDSP
        
        // create high
        for var i = 0; i < frameCountAsInt; ++i {
            buffer[j] = (i < aoi.outputHighFor[channel] ? 1.0 : 0.0)
            ++j
        }
        
        // decrement high for
        if 0 < aoi.outputHighFor[channel] {
            aoi.outputHighFor[channel] = aoi.outputHighFor[channel] - min(aoi.outputHighFor[channel], frameCountAsInt)
        }
    }
    
    return 0
}

func processInput(inRefCon:UnsafeMutablePointer<Void>, actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>, busNumber: UInt32, frameCount: UInt32, data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    
    // get audio in interface
    let aii = unsafeBitCast(inRefCon, AudioInputInterface.self)
    
    // build buffer
    var buffer = AudioBuffer()
    buffer.mDataByteSize = aii.inputFormat.mBytesPerFrame * frameCount
    buffer.mNumberChannels = aii.inputFormat.mChannelsPerFrame
    buffer.mData = UnsafeMutablePointer<Void>(aii.buffer)
    
    var bufferList = AudioBufferList()
    bufferList.mNumberBuffers = 1
    bufferList.mBuffers = buffer
    
    // render input
    let status = AudioUnitRender(aii.audioUnit, actionFlags, timeStamp, busNumber, frameCount, &bufferList)
    
    if noErr != status {
        return status
    }
    
    // data
    let data = UnsafeMutablePointer<Float>(buffer.mData)
    
    // number of channels
    let maxi = Int(aii.inputFormat.mChannelsPerFrame)
    
    // number of floats per channel
    let frameLength = Int(frameCount)
    
    // single channel? no interleaving
    if maxi == 1 {
        aii.delegate?.receiveAudioFrom(aii, fromChannel: 0, withData: data, ofLength: frameLength)
        return 0
    }
    
    // multiple channels? de-interleave
    var zero: Float = 0.0
    for var i = 0; i < maxi; ++i {
        // use vDSP to deinterleave
        vDSP_vsadd(data + i, vDSP_Stride(maxi), &zero, aii.buffer2, 1, vDSP_Length(frameLength))
        
        
        // call delegate
        aii.delegate?.receiveAudioFrom(aii, fromChannel: i, withData: aii.buffer2, ofLength: frameLength)
    }
    
    return 0
}

enum AudioInterfaceError: ErrorType {
    case NoComponentFound
    case UnsupportedFormat
    case ErrorResponse(String, Int, Int32)
}

private func checkError(status: OSStatus, type: AudioInterfaceError? = nil, funct: String = __FUNCTION__, line: Int = __LINE__) throws {
    if noErr != status {
        if let errType = type {
            throw errType
        }
        else {
            throw AudioInterfaceError.ErrorResponse(funct, line, status)
        }
    }
}

class AudioInterface
{
    struct AudioDevice {
        let deviceID: AudioDeviceID
        let deviceUID: String
        let deviceName: String
        let deviceManufacturer: String
        let streamsInput: Int
        let streamsOutput: Int
        let buffersInput: [AudioBuffer]
        let buffersOutput: [AudioBuffer]
        
        init?(deviceID: AudioDeviceID) {
            self.deviceID = deviceID
            
            // property address
            var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
            
            // size and status variables
            var status: OSStatus
            var size: UInt32 = UInt32(sizeof(CFStringRef))
            
            // get device UID
            var deviceUID: CFStringRef = ""
            propertyAddress.mSelector = kAudioDevicePropertyDeviceUID
            status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &deviceUID)
            guard noErr == status else { return nil }
            self.deviceUID = String(deviceUID)
            
            // get deivce name
            var deviceName: CFStringRef = ""
            propertyAddress.mSelector = kAudioDevicePropertyDeviceNameCFString
            status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &deviceName)
            guard noErr == status else { return nil }
            self.deviceName = String(deviceName)
            
            // get deivce manufacturer
            var deviceManufacturer: CFStringRef = ""
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
            self.streamsInput = Int(size) / sizeof(AudioStreamID)
            
            if 0 < self.streamsInput {
                // get stream configuration
                size = 0
                propertyAddress.mSelector = kAudioDevicePropertyStreamConfiguration
                status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size)
                guard noErr == status else { DLog("d \(status)"); return nil }
                
                // allocate
                var bufferList = UnsafeMutablePointer<AudioBufferList>(malloc(Int(size)))
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
            }
            
            propertyAddress.mSelector = kAudioDevicePropertyStreams
            propertyAddress.mScope = kAudioDevicePropertyScopeOutput
            status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size)
            guard noErr == status else { return nil }
            self.streamsOutput = Int(size) / sizeof(AudioStreamID)
            
            if 0 < self.streamsOutput {
                // get stream configuration
                size = 0
                propertyAddress.mSelector = kAudioDevicePropertyStreamConfiguration
                status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size)
                guard noErr == status else { DLog("d \(status)"); return nil }
                
                // allocate
                var bufferList = UnsafeMutablePointer<AudioBufferList>(malloc(Int(size)))
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
            }
        }
    }
    
    var audioUnit: AudioComponentInstance = nil
    
    static func devices() throws -> [AudioDevice] {
        // property address
        var propertyAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        var size: UInt32 = 0
        
        // get input size
        try checkError(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size))
        
        // number of devices
        let deviceCount = Int(size) / sizeof(AudioDeviceID)
        var audioDevices = [AudioDeviceID](count: deviceCount, repeatedValue: AudioDeviceID(0))
        
        // get device ids
        try checkError(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size, &audioDevices[0]))
        
        return audioDevices.flatMap {
            return AudioDevice(deviceID: $0)
        }
    }
}

class AudioOutputInterface: AudioInterface
{
    let deviceID: AudioDeviceID
    let frameSize: Int
    
    var outputFormat: AudioStreamBasicDescription = AudioStreamBasicDescription() // format of the actual audio hardware
    
    var outputHighFor = [Int]()
    
    init(deviceID: AudioDeviceID, frameSize: Int = 64) {
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
            throw AudioInterfaceError.NoComponentFound
        }
        
        // make audio unit
        try checkError(AudioComponentInstanceNew(outputComponent, &audioUnit))
        
        // set output device
        var outputDevice = deviceID
        try checkError(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &outputDevice, UInt32(sizeof(AudioDeviceID))))
        
        // get the audio format
        var size: UInt32 = UInt32(sizeof(AudioStreamBasicDescription))
        try checkError(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, outputBus, &outputFormat, &size))
        
        // print format information for debugging
        DLog("OUT \(outputFormat)")
        
        // check for expected format
        guard outputFormat.mFormatID == kAudioFormatLinearPCM && outputFormat.mFramesPerPacket == 1 && outputFormat.mFormatFlags == kAudioFormatFlagsNativeFloatPacked else {
            throw AudioInterfaceError.UnsupportedFormat
        }
        
        // set the audio format
        //size = UInt32(sizeof(AudioStreamBasicDescription))
        //try checkError(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, outputBus, &outputFormat, size))
        
        // initiate output array
        outputHighFor = [Int](count: Int(outputFormat.mChannelsPerFrame), repeatedValue: 0)
        
        // set frame size
        var frameSize = UInt32(self.frameSize)
        try checkError(AudioUnitSetProperty(audioUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, outputBus, &frameSize, UInt32(sizeof(UInt32))))
        
        // setup playback callback
        var callbackStruct = AURenderCallbackStruct(inputProc: renderOutput, inputProcRefCon: unsafeBitCast(unsafeAddressOf(self), UnsafeMutablePointer<Void>.self))
        try checkError(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, outputBus, &callbackStruct, UInt32(sizeof(AURenderCallbackStruct))))
        
        // initialize audio unit
        AudioUnitInitialize(audioUnit)
        
        // start playback
        AudioOutputUnitStart(audioUnit)
    }
    
    func tearDownAudio() {
        if nil == audioUnit {
            return
        }
        
        // stop playback
        AudioOutputUnitStop(audioUnit)
        
        // uninitialize audio unit
        AudioUnitUninitialize(audioUnit)
        
        // dispose
        AudioComponentInstanceDispose(audioUnit)
        
        audioUnit = nil
    }
    
    func createHighOutput(channel: Int, forDuration duration: Double) {
        guard channel < Int(outputFormat.mChannelsPerFrame) else { return }
        outputHighFor[channel] = Int(duration * outputFormat.mSampleRate)
    }
    
    static func defaultOutputDevice() throws -> AudioDeviceID {
        var size: UInt32
        size = UInt32(sizeof(AudioDeviceID))
        var outputDevice = AudioDeviceID()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        try checkError(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &outputDevice))
        return outputDevice
    }
}

protocol AudioInputInterfaceDelegate: class
{
    func receiveAudioFrom(interface: AudioInputInterface, fromChannel: Int, withData data: UnsafeMutablePointer<Float>, ofLength: Int)
}

class AudioInputInterface: AudioInterface
{
    let deviceID: AudioDeviceID
    let frameSize: Int
    
    weak var delegate: AudioInputInterfaceDelegate? = nil
    
    var inputFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()
    var buffer = UnsafeMutablePointer<Float>()
    var buffer2 = UnsafeMutablePointer<Float>() // used for de-interleaving data
    var bufferLen: Int = 0
    
    init(deviceID: AudioDeviceID, frameSize: Int = 64) {
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
            throw AudioInterfaceError.NoComponentFound
        }
        
        // make audio unit
        try checkError(AudioComponentInstanceNew(inputComponent, &audioUnit))
        
        var size: UInt32
        
        // enable input
        size = UInt32(sizeof(UInt32))
        var enableIO: UInt32 = 1
        try checkError(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, inputBus, &enableIO, size))
        
        // disable output
        enableIO = 0
        try checkError(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enableIO, size))
        
        // set input device
        var inputDevice = deviceID
        try checkError(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputDevice, UInt32(sizeof(AudioDeviceID))))
        
        // get the audio format
        size = UInt32(sizeof(AudioStreamBasicDescription))
        try checkError(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inputBus, &inputFormat, &size))
        
        // print format information for debugging
        DLog("IN \(inputFormat)")
        
        // check for expected format
        guard inputFormat.mFormatID == kAudioFormatLinearPCM && inputFormat.mFramesPerPacket == 1 && inputFormat.mFormatFlags == kAudioFormatFlagsNativeFloatPacked else {
            throw AudioInterfaceError.UnsupportedFormat
        }
        
        // set the audio format
        size = UInt32(sizeof(AudioStreamBasicDescription))
        try checkError(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &inputFormat, size))
        
        // get maximum frame size
        var maxFrameSize: UInt32 = 0
        size = UInt32(sizeof(UInt32))
        try checkError(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrameSize, &size))
        
        // create buffers
        bufferLen = Int(maxFrameSize * inputFormat.mBytesPerPacket)
        buffer = UnsafeMutablePointer<Float>.alloc(bufferLen)
        buffer2 = UnsafeMutablePointer<Float>.alloc(bufferLen)
        
        // set frame size
        var frameSize: UInt32 = UInt32(self.frameSize)
        try checkError(AudioUnitSetProperty(audioUnit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frameSize, UInt32(sizeof(UInt32))))
        
        // setup playback callback
        var callbackStruct = AURenderCallbackStruct(inputProc: processInput, inputProcRefCon: unsafeBitCast(unsafeAddressOf(self), UnsafeMutablePointer<Void>.self))
        try checkError(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callbackStruct, UInt32(sizeof(AURenderCallbackStruct))))
        
        // initialize audio unit
        AudioUnitInitialize(audioUnit)
        
        // start playback
        AudioOutputUnitStart(audioUnit)
    }
    
    func tearDownAudio() {
        if nil == audioUnit {
            return
        }
        
        // free buffer
        if 0 < bufferLen {
            buffer.dealloc(bufferLen)
            bufferLen = 0
        }
        
        // stop playback
        AudioOutputUnitStop(audioUnit)
        
        // uninitialize audio unit
        AudioUnitUninitialize(audioUnit)
        
        // dispose
        AudioComponentInstanceDispose(audioUnit)
        
        audioUnit = nil
    }
    
    static func defaultInputDevice() throws -> AudioDeviceID {
        var size: UInt32
        size = UInt32(sizeof(AudioDeviceID))
        var inputDevice = AudioDeviceID()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        try checkError(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &inputDevice))
        return inputDevice
    }
}
