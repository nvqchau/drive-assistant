import AVFoundation
import SwiftUI
import UIKit
import os

struct CameraPreview: UIViewRepresentable {
    let camera: CameraManager

    func makeUIView(context: Context) -> PreviewView {
        PreviewView(camera: camera)
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.updatePreviewLayout()
    }
}

final class PreviewView: UIView {
    private let camera: CameraManager
    private var orientationObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "vn.ai.driveassistant", category: "Preview")

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }

    init(camera: CameraManager) {
        self.camera = camera
        super.init(frame: .zero)
        configurePreview()
    }

    required init?(coder: NSCoder) {
        self.camera = CameraManager()
        super.init(coder: coder)
        configurePreview()
    }

    private func configurePreview() {
        backgroundColor = .black
        isOpaque = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let previewLayer = previewLayer {
            previewLayer.session = camera.session
            previewLayer.videoGravity = .resizeAspectFill
        }
        logger.info("Preview created; bounds=\(self.bounds.debugDescription, privacy: .public)")

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updatePreviewLayout()
            }
        }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVCaptureSessionDidStartRunning,
            object: camera.session,
            queue: .main
        ) { [weak self] _ in
            self?.updatePreviewLayout()
        }
    }

    deinit {
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
        }
        if let sessionObserver {
            NotificationCenter.default.removeObserver(sessionObserver)
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updatePreviewLayout()
    }

    func updatePreviewLayout() {
        guard let previewLayer = previewLayer else { return }
        previewLayer.frame = bounds
        previewLayer.videoGravity = .resizeAspectFill
        camera.updateVideoOrientation()
        logger.debug("Preview layout; bounds=\(self.bounds.debugDescription, privacy: .public) orientation=\(String(describing: self.camera.videoOrientation), privacy: .public)")
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = camera.videoOrientation
        }
    }
}
