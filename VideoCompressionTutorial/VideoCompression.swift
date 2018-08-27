//  Created by Diego Perini, TestFairy
//  License: Public Domain

import AVFoundation
import AssetsLibrary
import Foundation
import QuartzCore
import UIKit

// Global Queue for All Compressions
fileprivate let compressQueue = DispatchQueue(label: "compressQueue", qos: .background)

// Angle Conversion Utility
extension Int {
    fileprivate var degreesToRadiansCGFloat: CGFloat { return CGFloat(Double(self) * Double.pi / 180) }
}

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

// Compression Transformation Configuration
enum CompressionTransform {
    case keepSame
    case fixForBackCamera
    case fixForFrontCamera
}

// Compression Encode Parameters
struct CompressionConfig {
    let videoBitrate: Int
    let videomaxKeyFrameInterval: Int
    let avVideoProfileLevel: String
    let audioSampleRate: Int
    let audioBitrate: Int
    
    static let defaultConfig = CompressionConfig(
        videoBitrate: 1024 * 750,
        videomaxKeyFrameInterval: 30,
        avVideoProfileLevel: AVVideoProfileLevelH264High41,
        audioSampleRate: 22050,
        audioBitrate: 80000
    )
}

// Video Size
typealias CompressionSize = (width: Int, height: Int)

// Compression Operation (just call this)
func compressh264VideoInBackground(videoToCompress: URL, destinationPath: URL, size: CompressionSize?, compressionTransform: CompressionTransform, compressionConfig: CompressionConfig, completionHandler: @escaping (URL)->(), errorHandler: @escaping (Error)->(), cancelHandler: @escaping ()->()) -> CancelableCompression {
    
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
            String(kCVPixelFormatOpenGLESCompatibility) : kCFBooleanTrue
        ]
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: sourcePixelBufferAttributesDictionary)
        
        videoInput.performsMultiPassEncodingIfSupported = true
        guard writer.canAdd(videoInput) else {
            errorHandler(CompressionError(title: "Cannot add video input"))
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
            errorHandler(CompressionError(title: "Cannot add audio input"))
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
            errorHandler(CompressionError(title: "Cannot add video output"))
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
            errorHandler(CompressionError(title: "Cannot add video output"))
            return CancelableCompression()
        }
        reader.add(readerAudioTrackOutput)
        
        // Orientation Fix for Videos Taken by Device Camera
        var appliedTransform: CGAffineTransform
        switch compressionTransform {
        case .fixForFrontCamera:
            appliedTransform = CGAffineTransform(rotationAngle: 90.degreesToRadiansCGFloat).scaledBy(x:-1.0, y:1.0)
        case .fixForBackCamera:
            appliedTransform = CGAffineTransform(rotationAngle: 270.degreesToRadiansCGFloat)
        case .keepSame:
            appliedTransform = CGAffineTransform.identity
        }
        
        // Begin Compression
        reader.timeRange = CMTimeRangeMake(kCMTimeZero, avAsset.duration)
        writer.shouldOptimizeForNetworkUse = true
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: kCMTimeZero)
        
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
            
            while !videoDone || !audioDone {
                // Check for Writer Errors (out of storage etc.)
                if writer.status == AVAssetWriterStatus.failed {
                    reader.cancelReading()
                    writer.cancelWriting()
                    compressionContext.pxbuffer = nil
                    compressionContext.cgContext = nil
                    
                    if let e = writer.error {
                        errorHandler(e)
                        return
                    }
                }
                
                // Check for Reader Errors (source file corruption etc.)
                if reader.status == AVAssetReaderStatus.failed {
                    reader.cancelReading()
                    writer.cancelWriting()
                    compressionContext.pxbuffer = nil
                    compressionContext.cgContext = nil
                    
                    if let e = reader.error {
                        errorHandler(e)
                        return
                    }
                }
                
                // Check for Cancel
                if cancelable.cancel {
                    reader.cancelReading()
                    writer.cancelWriting()
                    compressionContext.pxbuffer = nil
                    compressionContext.cgContext = nil
                    cancelHandler()
                    return
                }
                
                // Check if enough data is ready for encoding a single frame
                if videoInput.isReadyForMoreMediaData {
                    // Copy a single frame from source to destination with applied transforms
                    if let vBuffer = readerVideoTrackOutput.copyNextSampleBuffer(), CMSampleBufferDataIsReady(vBuffer) {
                        frameCount += 1
                        print("Encoding frame: ", frameCount)
                        
                        autoreleasepool {
                            let presentationTime = CMSampleBufferGetPresentationTimeStamp(vBuffer)
                            let pixelBuffer = CMSampleBufferGetImageBuffer(vBuffer)!
                            
                            CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue:0))
                            
                            let transformedFrame = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: appliedTransform)
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
            writer.finishWriting(completionHandler: {
                compressionContext.pxbuffer = nil
                compressionContext.cgContext = nil
                completionHandler(filePath)
            })
        }
        
        // Return a cancel wrapper for users to let them interrupt the compression
        return cancelable
    } catch {
        // Error During Reader or Writer Creation
        errorHandler(error)
        return CancelableCompression()
    }
}
