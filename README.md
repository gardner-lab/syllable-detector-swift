Syllable Detector
=================

The syllable detector is a Mac app that uses CoreAudio to perform low-latency
syllable detection based on a simple Matlab neural network trained using the
[training code](https://github.com/gardner-lab/syllable-detector-learn)
created by @bwpearre. Audio sampling is highly tunable to tradeoff between detection
latency/jitter and processing power. The app allows running multiple detectors through
multiple audio devices and/or channels.
