//
//  ViewController.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 10/28/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Cocoa

class ViewControllerProcessor: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    @IBOutlet weak var buttonLoad: NSButton!
    @IBOutlet weak var buttonToggle: NSButton!
    @IBOutlet weak var tableChannels: NSTableView!
    
    // devices
    var deviceInput: AudioInterface.AudioDevice!
    var deviceOutput: AudioInterface.AudioDevice!
    
    var syllableDetector: SyllableDetector?
    var aiInput: AudioInputInterface?
    
    var isRunning = false {
        didSet {
            tableChannels.enabled = !isRunning
            buttonLoad.enabled = !isRunning
            buttonToggle.title = (isRunning ? "Stop" : "Start")
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableChannels.target = self
        tableChannels.doubleAction = "tableRowDoubleClicked"
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        // reload table
        tableChannels.reloadData()
    }
    
    @IBAction func toggle(sender: NSButton) {
        if nil == syllableDetector {
            // set stop text
            buttonToggle.title = "Stop"
        
            // setup audio processor
            setupAudioProcessorWithSyllableDetector()
        }
        else {
            // set start text
            buttonToggle.title = "Start"
            
            // tear down audio processor
            tearDownAudioProcessor()
        }
    }
    
    override func viewDidDisappear() {
        // tear down
        tearDownAudioProcessor()
    }
    
    func setupAudioProcessorWithSyllableDetector() {
        let config: SyllableDetectorConfig
        do {
            config = try SyllableDetectorConfig(fromTextFile: "sample.txt")
        }
        catch {
            DLog("Unable to parse: \(error)")
            return
        }
        
        // create interface
        aiInput = AudioInputInterface()
        
        // create syllabe detector
        let sd = SyllableDetector(config: config)
        syllableDetector = sd
        
        // set delegate
        aiInput?.delegate = sd
        
        // start
        do {
            try aiInput?.initializeAudio()
        }
        catch {
            DLog("ERROR WITH INPUT: \(error)")
            return
        }
    }
    
    func tearDownAudioProcessor() {
        // tear down input
        aiInput?.tearDownAudio()
        aiInput = nil
        
        // free processors
        syllableDetector = nil
    }
    
    func numberOfRowsInTableView(tableView: NSTableView) -> Int {
        let inputChannels: Int, outputChannels: Int
        
        if nil != deviceInput && 0 < deviceInput.buffersInput.count {
            inputChannels = Int(deviceInput.buffersInput[0].mNumberChannels)
        }
        else {
            inputChannels = 0
        }
        
        if nil != deviceOutput && 0 < deviceOutput.buffersOutput.count {
            outputChannels = Int(deviceOutput.buffersOutput[0].mNumberChannels)
        }
        else {
            outputChannels = 0
        }
        
        return min(inputChannels, outputChannels)
    }
    
    func tableView(tableView: NSTableView, objectValueForTableColumn tableColumn: NSTableColumn?, row: Int) -> AnyObject? {
        guard let identifier = tableColumn?.identifier else { return nil }
        
        switch identifier {
        case "ColumnInput", "ColumnOutput": return "Channel \(row + 1)"
        case "ColumnInLevel", "ColumnOutLevel": return NSNumber(float: 0.0)
        case "ColumnNetwork": return "Not Selected"
        default: return nil
        }
    }
    
    func tableRowDoubleClicked() {
        guard !isRunning else { return } // can not select when running
        guard 0 <= tableChannels.clickedColumn else { return } // valid column
        guard "ColumnNetwork" == tableChannels.tableColumns[tableChannels.clickedColumn].identifier else { return } // double clicked network column
        
        // show network selector
        loadNetworkForRow(tableChannels.clickedRow)
    }
    
    @IBAction func loadNetwork(sender: NSButton) {
        // default to using selected row
        // TODO: write me
    }
    
    func loadNetworkForRow(row: Int) {
        
    }
}

