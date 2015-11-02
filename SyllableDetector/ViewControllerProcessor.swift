//
//  ViewController.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 10/28/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Cocoa
import AudioToolbox

class ProcessorEntry {
    let inputBuffer: Int
    let inputChannel: Int
    var network: String = ""
    var config: SyllableDetectorConfig?
    var detector: SyllableDetector?
    let outputBuffer: Int
    let outputChannel: Int
    
    init(inputBuffer: Int, inputChannel: Int, outputBuffer: Int, outputChannel: Int) {
        self.inputBuffer = inputBuffer
        self.inputChannel = inputChannel
        self.outputBuffer = outputBuffer
        self.outputChannel = outputChannel
    }
}

class Processor {
    
}

class ViewControllerProcessor: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    @IBOutlet weak var buttonLoad: NSButton!
    @IBOutlet weak var buttonToggle: NSButton!
    @IBOutlet weak var tableChannels: NSTableView!
    
    // devices
    var deviceInput: AudioInterface.AudioDevice!
    var deviceOutput: AudioInterface.AudioDevice!
    
    var processorEntries = [ProcessorEntry]()
    
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
        
        if nil == deviceInput || nil == deviceOutput {
            fatalError("Input and output devices must be already defined.")
        }
        
        // reload table
        tableChannels.reloadData()
    }
    
    func setupEntries(input deviceInput: AudioInterface.AudioDevice, output deviceOutput: AudioInterface.AudioDevice) {
        // store input and output
        self.deviceInput = deviceInput
        self.deviceOutput = deviceOutput
        
        // get input pairs
        let inputPairs = deviceInput.buffersInput.enumerate().flatMap {
            (b: Int, buffer: AudioBuffer) -> [(Int, Int)] in
            return (0..<Int(buffer.mNumberChannels)).map { return (b, $0) }
        }
        
        // get output pairs
        let outputPairs = deviceOutput.buffersOutput.enumerate().flatMap {
            (b: Int, buffer: AudioBuffer) -> [(Int, Int)] in
            return (0..<Int(buffer.mNumberChannels)).map { return (b, $0) }
        }
        
        // for each pair, create an entry
        let numEntries = min(inputPairs.count, outputPairs.count)
        processorEntries = (0..<numEntries).map {
            return ProcessorEntry(inputBuffer: inputPairs[$0].0, inputChannel: inputPairs[$0].1, outputBuffer: outputPairs[$0].0, outputChannel: outputPairs[$0].1)
        }
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
            inputChannels = deviceInput.buffersInput.reduce(0) {
                return $0 + Int($1.mNumberChannels)
            }
        }
        else {
            inputChannels = 0
        }
        
        if nil != deviceOutput && 0 < deviceOutput.buffersOutput.count {
            outputChannels = deviceOutput.buffersOutput.reduce(0) {
                return $0 + Int($1.mNumberChannels)
            }
        }
        else {
            outputChannels = 0
        }
        
        return min(inputChannels, outputChannels)
    }
    
    func tableView(tableView: NSTableView, objectValueForTableColumn tableColumn: NSTableColumn?, row: Int) -> AnyObject? {
        guard let identifier = tableColumn?.identifier else { return nil }
        guard row < processorEntries.count else { return nil }
        
        switch identifier {
        case "ColumnInput":
            // support multiple buffers (will this ever happen?)
            if 1 < deviceInput.buffersInput.count {
                return "B \(1 + processorEntries[row].inputBuffer) Ch \(1 + processorEntries[row].inputChannel)"
            }
            return "Channel \(1 + processorEntries[row].inputChannel)"
        case "ColumnOutput":
            // support multiple buffers (will this ever happen?)
            if 1 < deviceOutput.buffersOutput.count {
                return "B \(1 + processorEntries[row].outputBuffer) Ch \(1 + processorEntries[row].outputChannel)"
            }
            return "Channel \(1 + processorEntries[row].outputChannel)"
        case "ColumnInLevel", "ColumnOutLevel": return NSNumber(float: 0.0)
        case "ColumnNetwork": return nil == processorEntries[row].config ? "Not Selected" : processorEntries[row].network
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
        
        if 0 > tableChannels.selectedRow {
            // find next row needing a network
            for (i, p) in processorEntries.enumerate() {
                if nil == p.config {
                    loadNetworkForRow(i)
                    break
                }
            }
        }
        else {
            // load network for row
            loadNetworkForRow(tableChannels.selectedRow)
        }
    }
    
    func loadNetworkForRow(row: Int) {
        guard !isRunning else { return } // can not select when running
        guard row < processorEntries.count else { return }
        
        let panel = NSOpenPanel()
        panel.title = "Select Network Definition"
        panel.allowedFileTypes = ["txt"]
        panel.allowsOtherFileTypes = false
        
        // callback for handling response
        let cb = {
            (result: Int) -> Void in
            // check again, just in case
            guard !self.isRunning else { return } // can not select when running
            guard row < self.processorEntries.count else { return }
            
            // make sure ok was pressed
            if NSFileHandlingPanelOKButton == result {
                if let url = panel.URL, let path = url.path {
                    do {
                        // load file
                        let config = try SyllableDetectorConfig(fromTextFile: path)
                        self.processorEntries[row].config = config
                        self.processorEntries[row].network = url.lastPathComponent ?? "Unknown Network"
                    }
                    catch {
                        // unable to load
                        let alert = NSAlert()
                        alert.messageText = "Unable to load"
                        alert.informativeText = "The text file could not be successfully loaded: \(error)."
                        alert.addButtonWithTitle("Ok")
                        alert.beginSheetModalForWindow(self.view.window!, completionHandler:nil)
                        
                        // clear selected
                        self.processorEntries[row].network = ""
                        self.processorEntries[row].config = nil
                    }
                    
                    // reload table
                    self.tableChannels.reloadData()
                }
            }
        }
        
        // show
        panel.beginSheetModalForWindow(self.view.window!, completionHandler: cb)
    }
}

