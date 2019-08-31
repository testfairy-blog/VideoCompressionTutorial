//  Created by Diego Perini, TestFairy
//  License: Public Domain

import AVFoundation
import AssetsLibrary
import QuartzCore
import UIKit

// Global Queue for All Compressions
fileprivate let compressQueue = DispatchQueue(label: "compressQueue", qos: .userInitiated)

// Compression Interruption Wrapper
class CancelableCompression {
    var cancel = false
}

// Compression Error Messages
struct CompressionError: LocalizedError {
    let title: String
    let code: Int
    
    init(title: String = "Compression Error", code: Int = -1) {
        self.title = title
        self.code = code
    }
}

// Compression Encode Parameters
struct CompressionConfig {
    let videoBitrate: Int
    let videomaxKeyFrameInterval: Int
    let avVideoProfileLevel: String
    let audioSampleRate: Int
    let audioBitrate: Int
    
    static let defaultConfig = CompressionConfig(
        videoBitrate: 2 * 1024 * 1024,  // 2 mbps
        videomaxKeyFrameInterval: 30,
        avVideoProfileLevel: AVVideoProfileLevelH264High41,
        audioSampleRate: 22050,
        audioBitrate: 80000             // 256 kbps
    )
}

// Compression Result
enum CompressionResult {
    case success(URL)
    case failure(Error)
    case cancelled
}

// Video Size
typealias CompressionSize = (width: Int, height: Int)


// Compression Operation (just call this)
func compressh264VideoInBackground(videoToCompress: URL, destinationPath: URL, size: CompressionSize?, compressionConfig: CompressionConfig, progressQueue: DispatchQueue, progressHandler: ((Progress)->())?, completion: @escaping (CompressionResult)->()) -> CancelableCompression {
    
    // Globals to store during compression
    class CompressionContext {
        var cgContext: CGContext?
        var pxbuffer: CVPixelBuffer?
        let colorSpace = CGColorSpaceCreateDeviceRGB()
    }
    
    // Draw Single Video Frame in Memory (will be used to loop for each video frame)
    func getCVPixelBuffer(_ i: CGImage?, compressionContext: CompressionContext) -> CVPixelBuffer? {
        // Allocate Temporary Pixel Buffer to Store Drawn Image
        weak var image = i!
        let imageWidth = image!.width
        let imageHeight = image!.height
        
        let attributes : [AnyHashable: Any] = [
            kCVPixelBufferCGImageCompatibilityKey : true as AnyObject,
            kCVPixelBufferCGBitmapContextCompatibilityKey : true as AnyObject
        ]
        
        if compressionContext.pxbuffer == nil {
            CVPixelBufferCreate(kCFAllocatorSystemDefault,
                                imageWidth,
                                imageHeight,
                                kCVPixelFormatType_32ARGB,
                                attributes as CFDictionary?,
                                &compressionContext.pxbuffer)
        }
        
        // Draw Frame to Newly Allocated Buffer
        if let _pxbuffer = compressionContext.pxbuffer {
            let flags = CVPixelBufferLockFlags(rawValue: 0)
            CVPixelBufferLockBaseAddress(_pxbuffer, flags)
            let pxdata = CVPixelBufferGetBaseAddress(_pxbuffer)
            
            if compressionContext.cgContext == nil {
                compressionContext.cgContext = CGContext(data: pxdata,
                                                         width: imageWidth,
                                                         height: imageHeight,
                                                         bitsPerComponent: 8,
                                                         bytesPerRow: CVPixelBufferGetBytesPerRow(_pxbuffer),
                                                         space: compressionContext.colorSpace,
                                                         bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            }
            
            if let _context = compressionContext.cgContext, let image = image {
                _context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            }
            else {
                CVPixelBufferUnlockBaseAddress(_pxbuffer, flags);
                return nil
            }
            
            CVPixelBufferUnlockBaseAddress(_pxbuffer, flags);
            return _pxbuffer;
        }
        
        return nil
    }
    
    // EXIF Orientation fix for Videos
    func getExifOrientationFix(for orientation: UIImage.Orientation) -> Int32 {
        switch orientation {
        case .up: return 6
        case .down: return 8
        case .left: return 3
        case .right: return 1
        case .upMirrored: return 2
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .rightMirrored: return 7
        @unknown default: return 1
        }
    }
    
    // Asset, Output File
    let avAsset = AVURLAsset(url: videoToCompress)
    let filePath = destinationPath
    
    do {
        // Reader and Writer
        let writer = try AVAssetWriter(outputURL: filePath, fileType: AVFileType.mp4)
        let reader = try AVAssetReader(asset: avAsset)
        
        // Tracks
        let videoTrack = avAsset.tracks(withMediaType: AVMediaType.video).first!
        let audioTrack = avAsset.tracks(withMediaType: AVMediaType.audio).first!
        
        // Video Output Configuration
        let videoCompressionProps: Dictionary<String, Any> = [
            AVVideoAverageBitRateKey : compressionConfig.videoBitrate,
            AVVideoMaxKeyFrameIntervalKey : compressionConfig.videomaxKeyFrameInterval,
            AVVideoProfileLevelKey : compressionConfig.avVideoProfileLevel
        ]
        
        let videoOutputSettings: Dictionary<String, Any> = [
            AVVideoWidthKey : size == nil ? videoTrack.naturalSize.width : size!.width,
            AVVideoHeightKey : size == nil ? videoTrack.naturalSize.height : size!.height,
            AVVideoCodecKey : AVVideoCodecType.h264,
            AVVideoCompressionPropertiesKey : videoCompressionProps
        ]
        let videoInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoOutputSettings)
        videoInput.expectsMediaDataInRealTime = false
        
        let sourcePixelBufferAttributesDictionary: Dictionary<String, Any> = [
            String(kCVPixelBufferPixelFormatTypeKey) : Int(kCVPixelFormatType_32RGBA),
            String(kCVPixelFormatOpenGLESCompatibility) : kCFBooleanTrue as Any
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: sourcePixelBufferAttributesDictionary)
        
        videoInput.performsMultiPassEncodingIfSupported = true
        guard writer.canAdd(videoInput) else {
            let error = CompressionError(title: "Cannot add video input")
            completion(.failure(error))
            return CancelableCompression()
        }
        writer.add(videoInput)
        
        // Audio Output Configuration
        var acl = AudioChannelLayout()
        acl.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        acl.mChannelBitmap = AudioChannelBitmap(rawValue: UInt32(0))
        acl.mNumberChannelDescriptions = UInt32(0)
        
        let acll = MemoryLayout<AudioChannelLayout>.size
        let audioOutputSettings: Dictionary<String, Any> = [
            AVFormatIDKey : UInt(kAudioFormatMPEG4AAC),
            AVNumberOfChannelsKey : UInt(2),
            AVSampleRateKey : compressionConfig.audioSampleRate,
            AVEncoderBitRateKey : compressionConfig.audioBitrate,
            AVChannelLayoutKey : NSData(bytes:&acl, length: acll)
        ]
        let audioInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioOutputSettings)
        audioInput.expectsMediaDataInRealTime = false
        
        guard writer.canAdd(audioInput) else {
            let error = CompressionError(title: "Cannot add audio input")
            completion(.failure(error))
            return CancelableCompression()
        }
        writer.add(audioInput)
        
        // Video Input Configuration
        let videoOptions: Dictionary<String, Any> = [
            kCVPixelBufferPixelFormatTypeKey as String : UInt(kCVPixelFormatType_422YpCbCr8_yuvs),
            kCVPixelBufferIOSurfacePropertiesKey as String : [:]
        ]
        let readerVideoTrackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOptions)
        
        readerVideoTrackOutput.alwaysCopiesSampleData = true
        
        guard reader.canAdd(readerVideoTrackOutput) else {
            let error = CompressionError(title: "Cannot add video output")
            completion(.failure(error))
            return CancelableCompression()
        }
        reader.add(readerVideoTrackOutput)
        
        // Audio Input Configuration
        let decompressionAudioSettings: Dictionary<String, Any> = [
            AVFormatIDKey: UInt(kAudioFormatLinearPCM)
        ]
        let readerAudioTrackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: decompressionAudioSettings)
        
        readerAudioTrackOutput.alwaysCopiesSampleData = true
        
        guard reader.canAdd(readerAudioTrackOutput) else {
            let error = CompressionError(title: "Cannot add audio output")
            completion(.failure(error))
            return CancelableCompression()
        }
        reader.add(readerAudioTrackOutput)
        
        // Orientation Fix for Videos Taken by Device Camera
        let orientationInt = getExifOrientationFix(for: avAsset.orientation)
        
        // Begin Compression
        reader.timeRange = CMTimeRangeMake(start: CMTime.zero, duration: avAsset.duration)
        writer.shouldOptimizeForNetworkUse = true
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: CMTime.zero)
        
        // Compress in Background
        let cancelable = CancelableCompression()
        compressQueue.async {
            // Allocate OpenGL Context to Draw and Transform Video Frames
            let glContext = EAGLContext(api: .openGLES2)!
            let context = CIContext(eaglContext: glContext)
            let compressionContext = CompressionContext()
            
            // Loop Video Frames
            var frameCount = 0
            var videoDone = false
            var audioDone = false
            
            // Total Frames
            let durationInSeconds = avAsset.duration.seconds
            let frameRate = videoTrack.nominalFrameRate
            let totalFrames = ceil(durationInSeconds * Double(frameRate))
            
            // Progress
            let totalUnits = Int64(totalFrames)
            let progress = Progress(totalUnitCount: totalUnits)
            
            while !videoDone || !audioDone {
                // Check for Writer Errors (out of storage etc.)
                if writer.status == .failed {
                    reader.cancelReading()
                    writer.cancelWriting()
                    compressionContext.pxbuffer = nil
                    compressionContext.cgContext = nil
                    
                    if let e = writer.error {
                        completion(.failure(e))
                        return
                    }
                }
                
                // Check for Reader Errors (source file corruption etc.)
                if reader.status == .failed {
                    reader.cancelReading()
                    writer.cancelWriting()
                    compressionContext.pxbuffer = nil
                    compressionContext.cgContext = nil
                    
                    if let e = reader.error {
                        completion(.failure(e))
                        return
                    }
                }
                
                // Check for Cancel
                if cancelable.cancel {
                    reader.cancelReading()
                    writer.cancelWriting()
                    compressionContext.pxbuffer = nil
                    compressionContext.cgContext = nil
                    completion(.cancelled)
                    return
                }
                
                // Check if enough data is ready for encoding a single frame
                if videoInput.isReadyForMoreMediaData {
                    // Copy a single frame from source to destination with applied transforms
                    if let vBuffer = readerVideoTrackOutput.copyNextSampleBuffer(), CMSampleBufferDataIsReady(vBuffer) {
                        frameCount += 1
                        
                        if let handler = progressHandler {
                            progress.completedUnitCount = Int64(frameCount)
                            progressQueue.async { handler(progress) }
                        }
                        
                        autoreleasepool {
                            let presentationTime = CMSampleBufferGetPresentationTimeStamp(vBuffer)
                            let pixelBuffer = CMSampleBufferGetImageBuffer(vBuffer)!
                            
                            CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue:0))
                            
                            let transformedFrame = CIImage(cvPixelBuffer: pixelBuffer).oriented(forExifOrientation: orientationInt)
                            let frameImage = context.createCGImage(transformedFrame, from: transformedFrame.extent)
                            let frameBuffer = getCVPixelBuffer(frameImage, compressionContext: compressionContext)
                            
                            CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
                            
                            _ = pixelBufferAdaptor.append(frameBuffer!, withPresentationTime: presentationTime)
                        }
                    } else {
                        // Video source is depleted, mark as finished
                        if !videoDone {
                            videoInput.markAsFinished()
                        }
                        videoDone = true
                    }
                }
                
                if audioInput.isReadyForMoreMediaData {
                    // Copy a single audio sample from source to destination
                    if let aBuffer = readerAudioTrackOutput.copyNextSampleBuffer(), CMSampleBufferDataIsReady(aBuffer) {
                        _ = audioInput.append(aBuffer)
                    } else {
                        // Audio source is depleted, mark as finished
                        if !audioDone {
                            audioInput.markAsFinished()
                        }
                        audioDone = true
                    }
                }
                
                // Let background thread rest for a while
                Thread.sleep(forTimeInterval: 0.001)
            }
            
            // Write everything to output file
            writer.finishWriting() {
                compressionContext.pxbuffer = nil
                compressionContext.cgContext = nil
                completion(.success(filePath))
            }
        }
        
        // Return a cancel wrapper for users to let them interrupt the compression
        return cancelable
    } catch {
        // Error During Reader or Writer Creation
        completion(.failure(error))
        return CancelableCompression()
    }
}



extension AVAsset {
    fileprivate var orientation: UIImage.Orientation {
        if let track = tracks(withMediaType: .video).first {
            let size = track.naturalSize
            let transform = track.preferredTransform
            switch (transform.tx, transform.ty) {
            case (0, 0): return .right
            case (size.width, size.height): return .left
            case (0, size.width): return .down
            default: return .up
            }
        }
        return .up
    }
}
