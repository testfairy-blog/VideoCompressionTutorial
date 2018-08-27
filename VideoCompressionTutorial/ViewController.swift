//  Created by Diego Perini, TestFairy
//  License: Public Domain

import UIKit
import MobileCoreServices

class ViewController: UINavigationController, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    private var picker: UIImagePickerController?
    private var videoView: VideoView?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.view.frame = UIScreen.main.bounds
        self.videoView = VideoView(frame: UIScreen.main.bounds)
        self.view.addSubview(videoView!)
        
        DispatchQueue.main.async { [unowned self] in
            self.picker = UIImagePickerController()
            self.picker?.delegate = self
            self.picker?.sourceType = .photoLibrary
            self.picker?.mediaTypes = [kUTTypeMovie as String]
            self.present(self.picker!, animated: true)
        }
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [String : Any]) {
        self.picker?.dismiss(animated: true, completion: nil)
        
        // Get source video
        let videoToCompress = info["UIImagePickerControllerMediaURL"] as! URL
        
        // Declare destination path and remove anything exists in it
        let destinationPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("compressed.mp4")
        try? FileManager.default.removeItem(at: destinationPath)
        
        // Compress
        let cancelable = compressh264VideoInBackground(
            videoToCompress: videoToCompress,
            destinationPath: destinationPath,
            size: nil,
            compressionTransform: .keepSame,
            compressionConfig: .defaultConfig,
            completionHandler: { [weak self] path in
                print("---------------------------")
                print("Success", path)
                print("---------------------------")
                print("Original video size:")
                videoToCompress.verboseFileSizeInMB()
                print("---------------------------")
                print("Compressed video size:")
                path.verboseFileSizeInMB()
                print("---------------------------")
                
                self?.videoView?.configure(url: path.absoluteString)
                self?.videoView?.isLoop = true
                self?.videoView?.play()
            },
            errorHandler: { e in
                print("---------------------------")
                print("Error: ", e)
                print("---------------------------")
            },
            cancelHandler: {
                print("---------------------------")
                print("Cancel")
                print("---------------------------")
            }
        )
        
        // To cancel compression, use below example
        //////////////////////////////
        // cancelable.cancel = true
        //////////////////////////////

    }
}

// Utility to print file size to console
extension URL {
    func verboseFileSizeInMB() {
        let p = self.path
        
        let attr = try? FileManager.default.attributesOfItem(atPath: p)
        
        if let attr = attr {
            let fileSize = Float(attr[FileAttributeKey.size] as! UInt64) / (1024.0 * 1024.0)
            
            print(String(format: "FILE SIZE: %.2f MB", fileSize))
        } else {
            print("No file")
        }
    }
}

