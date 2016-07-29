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
    
    var processorEntries = [ProcessorEntry]()
    var processor: Processor?
    
    // timer to redraw interface (saves time)
    var timerRedraw: Timer?
    
    var isRunning = false {
        didSet {
            if oldValue == isRunning { return }
            
            // update interface
            tableChannels.isEnabled = !isRunning
            buttonLoad.isEnabled = !isRunning
            buttonToggle.title = (isRunning ? "Stop" : "Start")
            
            // start or stop timer
            if isRunning {
                timerRedraw = Timer.scheduledTimer(timeInterval: 0.1, target: self, selector: #selector(ViewControllerProcessor.timerUpdateValues(_:)), userInfo: nil, repeats: true)
            }
            else {
                timerRedraw?.invalidate()
                timerRedraw = nil
            }
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableChannels.target = self
        tableChannels.doubleAction = #selector(ViewControllerProcessor.tableRowDoubleClicked)
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        
        if nil == deviceInput || nil == deviceOutput {
            fatalError("Input and output devices must be already defined.")
        }
        
        // reload table
        tableChannels.reloadData()
    }
    
    override func viewWillDisappear() {
        // clear processor
        processor = nil
        isRunning = false
        
        super.viewWillDisappear()
    }
    
    func setupEntries(input deviceInput: AudioInterface.AudioDevice, output deviceOutput: AudioInterface.AudioDevice) {
        // store input and output
        self.deviceInput = deviceInput
        self.deviceOutput = deviceOutput
        
        // get input pairs
        let inputChannels: Int
        if 0 < deviceInput.buffersInput.count {
            inputChannels = Int(deviceInput.buffersInput[0].mNumberChannels)
        }
        else {
            inputChannels = 0
        }
        
        let outputChannels: Int
        if 0 < deviceOutput.buffersOutput.count {
            outputChannels = Int(deviceOutput.buffersOutput[0].mNumberChannels)
        }
        else {
            outputChannels = 0
        }
        
        // for each pair, create an entry
        let numEntries = min(inputChannels, outputChannels)
        processorEntries = (0..<numEntries).map {
            return ProcessorEntry(inputChannel: $0, outputChannel: $0)
        }
    }
    
    @IBAction func toggle(_ sender: NSButton) {
        if isRunning {
            // tear down
            processor?.tearDown()
            
            // stop everything
            processor = nil
            
            // clear is running
            isRunning = false
        }
        else {
            // create process
            do {
                processor = try Processor(deviceInput: deviceInput, deviceOutput: deviceOutput, entries: processorEntries)
            }
            catch {
                // show an error message
                let alert = NSAlert()
                alert.messageText = "Unable to initialize audio"
                alert.informativeText = "There was an error initializing the audio interfaces: \(error)."
                alert.addButton(withTitle: "Ok")
                alert.beginSheetModal(for: self.view.window!, completionHandler:nil)
                return
            }
            
            // set as running
            isRunning = true
        }
    }
    
    func numberOfRows(in tableView: NSTableView) -> Int {
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
    
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> AnyObject? {
        guard let identifier = tableColumn?.identifier else { return nil }
        guard row < processorEntries.count else { return nil }
        
        switch identifier {
        case "ColumnInput", "ColumnOutput": return "Channel \(row + 1)"
        case "ColumnInLevel":
            if let p = processor {
                return NSNumber(value: 100.0 * (p.getInputForChannel(row) ?? 0.0))
            }
            return NSNumber(value: 0.00)
        case "ColumnOutLevel":
            if let p = processor {
                return NSNumber(value: 100.0 * (p.getOutputForChannel(row) ?? 0.0))
            }
            return NSNumber(value: 0.00)
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
    
    @IBAction func loadNetwork(_ sender: NSButton) {
        if 0 > tableChannels.selectedRow { // no row selected...
            // find next row needing a network
            for (i, p) in processorEntries.enumerated() {
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
    
    func loadNetworkForRow(_ row: Int) {
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
                if let url = panel.url, let path = url.path {
                    do {
                        // load file
                        let config = try SyllableDetectorConfig(fromTextFile: path)
                        
                        // check sampling rate
                        if (1 < abs(config.samplingRate - self.deviceInput.sampleRateInput)) {
                            DLog("Mismatched sampling rates. Expecting: \(config.samplingRate). Device: \(self.deviceInput.sampleRateInput).")
                            self.processorEntries[row].resampler = ResamplerLinear(fromRate: self.deviceInput.sampleRateInput, toRate: config.samplingRate)
                        }
                        
                        self.processorEntries[row].config = config
                        self.processorEntries[row].network = url.lastPathComponent ?? "Unknown Network"
                    }
                    catch {
                        // unable to load
                        let alert = NSAlert()
                        alert.messageText = "Unable to load"
                        alert.informativeText = "The text file could not be successfully loaded: \(error)."
                        alert.addButton(withTitle: "Ok")
                        alert.beginSheetModal(for: self.view.window!, completionHandler:nil)
                        
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
        panel.beginSheetModal(for: self.view.window!, completionHandler: cb)
    }
    
    func timerUpdateValues(_ timer: Timer!) {
        // create column indices
        let indexes = IndexSet([1, 4])
        
        // reload data
        tableChannels.reloadData(forRowIndexes: IndexSet(integersIn: NSRange(location: 0, length: processorEntries.count).toRange() ?? 0..<0), columnIndexes: indexes)
    }
}

