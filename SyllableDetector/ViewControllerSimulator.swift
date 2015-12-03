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
                        try SyllableDetectorConfig(fromTextFile: path)
                        
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
                if let url = panel.URL, let path = url.path {
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
        
        
    }
}
