Syllable Detector
=================

The syllable detector is a Mac app that uses CoreAudio to perform low-latency 
syllable detection based on a simple Matlab neural network trained using the 
[training code](https://github.com/gardner-lab/syllable-detector-learn) 
created by @bwpearre. Audio sampling is highly tunable to tradeoff between detection 
latency/jitter and processing power. The app allows running multiple detectors through 
multiple audio devices and/or channels.

Installation
------------

A binary version of the software can be downloaded from the 
[**releases** tab](https://github.com/gardner-lab/syllable-detector-swift/releases). 

Usage
-----

**Connection:** The syllable detector software can process any standard audio input
source. As a result, you can either connect a microphone or a line in to the 
standard ports on the computer, or you can use an external audio interface. If the 
input source supports multiple channels, instances of the detector can be 
specified independently for each channel.

To generate an output TTL signal, the application supports two options. An output signal
can be sent via an audio channel through any valid audio interface (headphone jack or an
external audio interface). The audio output must have at least the same number of 
channels as the input. Because of mixing and signal processing, the audio output signal
can introduce an added delay of up to 5ms.

Alternatively, the output TTL signal can be sent via an Arduino pin. Load the MATLAB 
Arduino IO sketch onto the Arduino (the sketch is available in this repository, and
enables controlling pins through a basic serial interface). Connect the Arduino to the
computer via USB. Output TTL pulses for the first channel will be sent via pin 7, for the second channel via pin 8, etc.

**Preparing the network:** After 
[using the training code](https://github.com/gardner-lab/syllable-detector-learn) to 
train a detector, use the `convert_to_text.m` file included in the repository to convert
the detect to a text format that can be easily read by the Swift software.

**Running:**

1. Launch the software.
2. The first window will provide a network to select an input source (listing all audio 
   sources available), as well as an output source (listing both audio outputs and any
   detected Arduino serial ports).
3. Once you select both an input and output, a new window launches. From here, you can
   see all available input and output channels. Double click a channel to load a text
   version of a trained detector.
4. Once configured, press run to begin monitoring the inputs.

