# Video Compression Tutorial
iOS - Fine tuned video compression in Swift 4

## Features
* iOS 9+
* No dependencies
* Single file, single function
* Compression in background thread
* Cancelable
* Configurable a/v bitrate, video resolution, audio sample rate and many other fine tuning operations
* Proper orientation correction for back/front camera
* Low performance compression during [Background Execution](https://developer.apple.com/library/archive/documentation/iPhone/Conceptual/iPhoneOSProgrammingGuide/BackgroundExecution/BackgroundExecution.html), even when device is locked. (`Application.beginBackgroundTask` must be called explicitly)

## Install

Copy [this](https://raw.githubusercontent.com/diegoperini/VideoCompressionTutorial/master/VideoCompressionTutorial/VideoCompression.swift) file to your project.

## Usage

```swift
// Get source video
let videoToCompress = //any valid URL pointing device storage

// Declare destination path and remove anything exists in it
let destinationPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("compressed.mp4")
try? FileManager.default.removeItem(at: destinationPath)

// Compress
let cancelable = compressh264VideoInBackground(
    videoToCompress: videoToCompress,
    destinationPath: destinationPath,
    size: nil, // nil preserves original,
    //size: (width: 1280, height: 720) 
    compressionTransform: .keepSame,
    compressionConfig: .defaultConfig,
    completionHandler: { [weak self] path in
        // use path
    },
    errorHandler: { e in
        print("Error: ", e)
    },
    cancelHandler: {
        print("Canceled.")
    }
)

// To cancel compression, set cancel flag to true and wait for handler invoke
cancelable.cancel = true
```
