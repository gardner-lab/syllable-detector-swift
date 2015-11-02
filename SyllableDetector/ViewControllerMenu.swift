//
//  ViewController.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 10/28/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Cocoa
import AudioToolbox

class ViewControllerMenu: NSViewController, WindowControllerProcessorDelegate {
    @IBOutlet weak var selectInput: NSPopUpButton!
    @IBOutlet weak var selectOutput: NSPopUpButton!
    @IBOutlet weak var buttonLaunch: NSButton!
    
    var openProcessors = [NSWindowController]()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // reload devices
        buttonLaunch.enabled = false
        reloadDevices()
    }
    
    override func viewDidDisappear() {
        // terminate
        NSApp.terminate(nil)
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
        let selectedInput = selectInput.selectedTag()
        let selectedOutput = selectOutput.selectedTag()
        
        // rebuild inputs
        selectInput.removeAllItems()
        selectInput.addItemWithTitle("Input")
        for d in devices {
            if 0 < d.streamsInput {
                let item = NSMenuItem()
                item.title = d.deviceName
                item.tag = Int(d.deviceID)
                selectInput.menu?.addItem(item)
            }
        }
        selectInput.selectItemWithTag(selectedInput)
        selectInput.synchronizeTitleAndSelectedItem()
        
        // rebuild outputs
        selectOutput.removeAllItems()
        selectOutput.addItemWithTitle("Output")
        for d in devices {
            if 0 < d.streamsOutput {
                let item = NSMenuItem()
                item.title = d.deviceName
                item.tag = Int(d.deviceID)
                selectOutput.menu?.addItem(item)
            }
        }
        selectOutput.selectItemWithTag(selectedOutput)
        selectOutput.synchronizeTitleAndSelectedItem()
    }
    
    @IBAction func selectDevice(sender: NSPopUpButton) {
        buttonLaunch.enabled = (0 < selectInput.selectedTag() && 0 < selectOutput.selectedTag())
    }
    
    @IBAction func buttonLaunch(sender: NSButton) {
        guard let sb = storyboard, let controller = sb.instantiateControllerWithIdentifier("Processor") as? WindowControllerProcessor else { return }
        
        // get input device
        guard let deviceInput = AudioInterface.AudioDevice(deviceID: AudioDeviceID(selectInput.selectedTag())) else {
            DLog("input device no longer valid")
            reloadDevices()
            return
        }
        
        // get output device
        guard let deviceOutput = AudioInterface.AudioDevice(deviceID: AudioDeviceID(selectOutput.selectedTag())) else {
            DLog("output device no longer valid")
            reloadDevices()
            return
        }
        
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
    }
    
    func windowControllerDone(controller: WindowControllerProcessor) {
        // window controller closed, clean from open processor list
        openProcessors = openProcessors.filter {
            return $0 !== controller
        }
    }
}

