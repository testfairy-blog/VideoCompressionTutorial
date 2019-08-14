# Video Compression Tutorial
iOS - Fine tuned video compression in Swift 5

Forked from [VideoCompressionTutorial](https://github.com/testfairy-blog/VideoCompressionTutorial)  
* Changes :  
    - Added Swift 5 support  
    - Added Compression Progress Handler  
    - Added Result type completion handler  
    - Handled device camera video orientation fix automatically  

## Features
* iOS 9+
* No dependencies
* Single file, single function
* Compression in background thread
* Cancelable
* Configurable a/v bitrate, video resolution, audio sample rate and many other fine tuning operations
* Proper orientation correction for back/front camera
* Low performance compression during [Background Execution](https://developer.apple.com/library/archive/documentation/iPhone/Conceptual/iPhoneOSProgrammingGuide/BackgroundExecution/BackgroundExecution.html), even when device is locked. (`Application.beginBackgroundTask` must be called explicitly)
* Progress Handling

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
    compressionConfig: .defaultConfig,
    progressQueue: .main,
    progressHandler: { progress in 
        // Handle Progress
    },
    completion: { [weak self] result in
        switch result {
        case .success(let url):
            // Handle destination URL
            
        case .failure(let error):
            // Handle Error
            
        case .cancelled:
            // Handle Cancelled case
        }
    }
)

// To cancel compression, set cancel flag to true and wait for handler invoke
cancelable.cancel = true
```

## How to initiate a background task (i.e while the phone is locked)
[Please refer to the discussion here.](https://github.com/testfairy-blog/VideoCompressionTutorial/issues/1#issuecomment-518109326)
