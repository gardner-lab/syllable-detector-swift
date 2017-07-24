//
//  ViewController.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 10/28/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Cocoa
import AudioToolbox
import ORSSerial

class ViewControllerMenu: NSViewController, WindowControllerProcessorDelegate {
    @IBOutlet weak var selectInput: NSPopUpButton!
    @IBOutlet weak var selectOutput: NSPopUpButton!
    @IBOutlet weak var buttonLaunch: NSButton!
    
    var openProcessors = [NSWindowController]()
    var openSimulators = [NSWindowController]()
    
    @objc class DeviceRepresentation: NSObject {
        var audioDeviceID: AudioDeviceID?
        var arduinoDevicePath: String?
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // reload devices
        buttonLaunch.isEnabled = false
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        // listen for serial changes
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(ViewControllerMenu.serialPortsWereConnected(_:)), name: NSNotification.Name.ORSSerialPortsWereConnected, object: nil)
        nc.addObserver(self, selector: #selector(ViewControllerMenu.serialPortsWereDisconnected(_:)), name: NSNotification.Name.ORSSerialPortsWereDisconnected, object: nil)
        
        // listen
        do {
            try AudioInterface.createListenerForDeviceChange({
                DLog("refreshing device")
                self.reloadDevices()
                }, withIdentifier: self)
        }
        catch {
            DLog("Unable to add device change listener: \(error)")
        }
        
        // reload devices
        reloadDevices()
    }
    
    override func viewDidDisappear() {
        // remove notification center
        NotificationCenter.default.removeObserver(self)
        
        // remove listener
        AudioInterface.destroyListenerForDeviceChange(withIdentifier: self)
        
        // terminate
        if 0 == openProcessors.count && 0 == openSimulators.count {
            NSApp.terminate(nil)
        }
    }
    
    // serial port
    @objc func serialPortsWereConnected(_ notification: Notification) {
        if let userInfo = (notification as NSNotification).userInfo {
            let connectedPorts = userInfo[ORSConnectedSerialPortsKey] as! [ORSSerialPort]
            DLog("Ports were connected: \(connectedPorts)")
            reloadDevices()
        }
    }
    
    @objc func serialPortsWereDisconnected(_ notification: Notification) {
        if let userInfo = (notification as NSNotification).userInfo {
            let disconnectedPorts: [ORSSerialPort] = userInfo[ORSDisconnectedSerialPortsKey] as! [ORSSerialPort]
            DLog("Ports were disconnected: \(disconnectedPorts)")
            reloadDevices()
        }
    }
    
    func reloadDevices() {
        // fetch list of devices
        let devices: [AudioInterface.AudioDevice]
        do {
            devices = try AudioInterface.devices()
        }
        catch {
            DLog("Unable to reload devices: \(error)")
            return
        }
        
        // get input
//        let selectedInput = selectInput.selectedItem?.representedObject
//        let selectedOutput = selectOutput.selectedItem?.representedObject
        
        // rebuild inputs
        selectInput.removeAllItems()
        selectInput.addItem(withTitle: "Input")
        for d in devices {
            if 0 < d.streamsInput {
                // representation
                let obj = DeviceRepresentation()
                obj.audioDeviceID = d.deviceID
                
                // menu item
                let item = NSMenuItem()
                item.title = d.deviceName
                item.representedObject = obj
                selectInput.menu?.addItem(item)
            }
        }
//        selectInput.selectItem(withTag: selectedInput)
        selectInput.synchronizeTitleAndSelectedItem()
        
        // rebuild outputs
        selectOutput.removeAllItems()
        selectOutput.addItem(withTitle: "Output")
        for d in devices {
            if 0 < d.streamsOutput {
                // representation
                let obj = DeviceRepresentation()
                obj.audioDeviceID = d.deviceID
                
                // menu item
                let item = NSMenuItem()
                item.title = d.deviceName
                item.representedObject = obj
                selectOutput.menu?.addItem(item)
            }
        }
        for port in ORSSerialPortManager.shared().availablePorts {
            // representation
            let obj = DeviceRepresentation()
            obj.arduinoDevicePath = port.path
            
            // menu item
            let item = NSMenuItem()
            item.title = "Arduino (\(port.name))"
            item.representedObject = obj
            selectOutput.menu?.addItem(item)
        }
//        selectOutput.selectItem(withTag: selectedOutput)
        selectOutput.synchronizeTitleAndSelectedItem()
    }
    
    @IBAction func selectDevice(_ sender: NSPopUpButton) {
        buttonLaunch.isEnabled = (nil != selectInput.selectedItem?.representedObject && nil != selectOutput.selectedItem?.representedObject)
    }
    
    @IBAction func buttonSimulate(_ sender: NSButton) {
        guard let sb = storyboard, let controller = sb.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier(rawValue: "Simulator")) as? NSWindowController else { return }
        
        // launch
        controller.showWindow(sender)
        openSimulators.append(controller)
    }
    
    @IBAction func buttonLaunch(_ sender: NSButton) {
        guard let sb = storyboard, let controller = sb.instantiateController(withIdentifier: NSStoryboard.SceneIdentifier(rawValue: "Processor")) as? WindowControllerProcessor else { return }
        
        // get input device representation
        guard let menuItemInput = selectInput.selectedItem, let objInput = menuItemInput.representedObject, let deviceRepresentationInput = objInput as? DeviceRepresentation else {
            return
        }
        
        // get output device representation
        guard let menuItemOutput = selectOutput.selectedItem, let objOutput = menuItemOutput.representedObject, let deviceRepresentationOutput = objOutput as? DeviceRepresentation else {
            return
        }
        
        // get input device
        guard let inputAudioID = deviceRepresentationInput.audioDeviceID, let deviceInput = AudioInterface.AudioDevice(deviceID: inputAudioID) else {
            DLog("input device no longer valid")
            reloadDevices()
            return
        }
        
        // get output device
        let deviceOutput: ViewControllerProcessor.OutputDevice
        if let outputAudioID = deviceRepresentationOutput.audioDeviceID {
            guard let o = AudioInterface.AudioDevice(deviceID: outputAudioID) else {
                DLog("output device no longer valid")
                reloadDevices()
                return
            }
            deviceOutput = .audio(interface: o)
        }
        else if let outputArduinoPath = deviceRepresentationOutput.arduinoDevicePath {
            guard let o = ORSSerialPort(path: outputArduinoPath) else {
                DLog("output device no longer valid")
                reloadDevices()
                return
            }
            deviceOutput = .arduino(port: o)
        }
        else {
            DLog("no output device found")
            return
        }
        
        DLog("\(deviceOutput)")
        
        // setup controller
        if let vc = controller.contentViewController, let vcp = vc as? ViewControllerProcessor {
            vcp.setupEntries(input: deviceInput, output: deviceOutput)
        }
        else {
            DLog("unknown error")
            return
        }
        
        controller.delegate = self // custom delegate used to clean up open processor list when windows are closed
        controller.showWindow(sender)
        openProcessors.append(controller)
        
        // reset selector
        selectInput.selectItem(at: 0)
        selectOutput.selectItem(at: 0)
        buttonLaunch.isEnabled = false
    }
    
    func windowControllerDone(_ controller: WindowControllerProcessor) {
        // window controller closed, clean from open processor list
        openProcessors = openProcessors.filter {
            return $0 !== controller
        }
    }
}

