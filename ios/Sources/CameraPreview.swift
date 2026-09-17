import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // セッションの構成が終わった後に接続ができるので、更新のたびに向きを合わせ直す。
        uiView.updateOrientation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass で型を固定しているので必ず成功する。
            layer as! AVCaptureVideoPreviewLayer
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateOrientation()
        }

        func updateOrientation() {
            guard let connection = previewLayer.connection,
                  connection.isVideoOrientationSupported,
                  let interface = window?.windowScene?.interfaceOrientation else { return }

            let target: AVCaptureVideoOrientation
            switch interface {
            case .portrait: target = .portrait
            case .portraitUpsideDown: target = .portraitUpsideDown
            case .landscapeLeft: target = .landscapeLeft
            case .landscapeRight: target = .landscapeRight
            default: return
            }
            if connection.videoOrientation != target {
                connection.videoOrientation = target
            }
        }
    }
}
