//
//  ViewController.swift
//  SyllableDetector
//
//  Created by Nathan Perkins on 10/28/15.
//  Copyright © 2015 Gardner Lab. All rights reserved.
//

import Cocoa

class ViewController: NSViewController {
    @IBOutlet var buttonToggle: NSButton!
    
    var syllableDetector: SyllableDetector?
    var aiInput: AudioInputInterface?
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    @IBAction func start(sender: NSButton) {
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
        
        NSApp.terminate(nil)
    }
    
    func setupAudioProcessorWithSyllableDetector() {
        // create interface
        aiInput = AudioInputInterface()
        
        // create syllabe detector
        let sd = SyllableDetector(config: SyllableDetectorConfig())
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
}

