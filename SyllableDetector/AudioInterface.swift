//
//  AudioInterface.swift
//  SongDetector
//
//  Created by Nathan Perkins on 10/22/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Foundation
import AudioToolbox

// CONSTANT: frame size when reading in audio, decrease to lower latency and jitter but at the cost of higher CPU usage
let kFrameSize: UInt32 = 64

func renderOutput(inRefCon:UnsafeMutablePointer<Void>, actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>, busNumber: UInt32, frameCount: UInt32, data: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    
    // get audio out interface
    let aoi = unsafeBitCast(inRefCon, AudioOutputInterface.self)
    let usableBufferList = UnsafeMutableAudioBufferListPointer(data)
    let buffer = UnsafeMutablePointer<Float>(usableBufferList[0].mData)
    
    // high settings
    let highFor = aoi.outputHighFor
    let frameCountAsInt = Int(frameCount)
    
    // fill output
    for var i = 0; i < frameCountAsInt; ++i {
        buffer[i] = (i < highFor ? 1.0 : 0.0)
        buffer[i + frameCountAsInt] = (i < highFor ? 1.0 : 0.0)
    }
    
    // decrement high for count
    if 0 < highFor {
        aoi.outputHighFor -= min(highFor, frameCountAsInt)
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
    
    // receive audio
    aii.delegate?.receiveAudioFrom(aii, inBufferList: bufferList, withNumberOfSamples: Int(frameCount))
    
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
    var outputFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()
    
    var outputHighFor = 0
    
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
        
        // get the audio format
        var size: UInt32 = UInt32(sizeof(AudioStreamBasicDescription))
        try checkError(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, outputBus, &outputFormat, &size))
        
        // print format information for debugging
        assert(outputFormat.mFormatID == kAudioFormatLinearPCM)
        assert(0 < (outputFormat.mFormatFlags & kAudioFormatFlagsNativeFloatPacked))
        assert(0 == (outputFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved))
        assert(1 == outputFormat.mFramesPerPacket)
        assert(2 == outputFormat.mChannelsPerFrame)
        assert(8 == outputFormat.mBytesPerFrame)
        
        // set frame size
        var frameSize: UInt32 = kFrameSize
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
}

protocol AudioInputInterfaceDelegate: class
{
    func receiveAudioFrom(interface: AudioInputInterface, inBufferList bufferList: AudioBufferList, withNumberOfSamples numSamples: Int)
}

class AudioInputInterface: AudioInterface
{
    weak var delegate: AudioInputInterfaceDelegate? = nil
    
    var inputFormat: AudioStreamBasicDescription = AudioStreamBasicDescription()
    var buffer = UnsafeMutablePointer<Float>()
    var bufferLen: Int = 0
    
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
        
        // get default input device
        size = UInt32(sizeof(AudioDeviceID))
        var inputDevice = AudioDeviceID()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMaster)
        try checkError(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &inputDevice))
        
        // set input device
        try checkError(AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &inputDevice, UInt32(sizeof(AudioDeviceID))))
        
        // get the audio format
        size = UInt32(sizeof(AudioStreamBasicDescription))
        try checkError(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, inputBus, &inputFormat, &size))
        
        // print format information for debugging
        assert(inputFormat.mFormatID == kAudioFormatLinearPCM)
        assert(0 < (inputFormat.mFormatFlags & kAudioFormatFlagsNativeFloatPacked))
        assert(1 == inputFormat.mFramesPerPacket)
        
        // set the audio format
        size = UInt32(sizeof(AudioStreamBasicDescription))
        try checkError(AudioUnitSetProperty(audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, inputBus, &inputFormat, size))
        
        // get maximum frame size
        var maxFrameSize: UInt32 = 0
        size = UInt32(sizeof(UInt32))
        try checkError(AudioUnitGetProperty(audioUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrameSize, &size))
        
        // create buffer
        bufferLen = Int(maxFrameSize * inputFormat.mBytesPerPacket)
        buffer = UnsafeMutablePointer<Float>.alloc(bufferLen)
        
        // set frame size
        var frameSize: UInt32 = kFrameSize
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
    
}
