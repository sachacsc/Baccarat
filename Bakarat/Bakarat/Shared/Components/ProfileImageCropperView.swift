//
//  ProfileImageCropperView.swift
//  Bakarat
//
//  Crop 1:1 (cercle) pour la photo de profil. Pinch-to-zoom + drag-to-pan.
//  Porté depuis Zmeo/Core/Shared/View/ProfileImageCropperView.swift.
//

import SwiftUI
import UIKit

struct ProfileImageCropperView: View {
    @Binding var image: UIImage?
    @Binding var isPresented: Bool
    var onCropDone: (UIImage) -> Void

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        let sourceImage = image ?? UIImage()
        GeometryReader { geo in
            let canvasSize = geo.size
            let imageSize = aspectFitSize(for: sourceImage, in: canvasSize)
            let cropSize = min(imageSize.width, imageSize.height) - 20

            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: sourceImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageSize.width, height: imageSize.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                                withAnimation(.easeOut(duration: 0.2)) {
                                    clampOffset(imageSize: imageSize, cropSize: cropSize)
                                }
                            }
                    )
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1.0, lastScale * value)
                            }
                            .onEnded { value in
                                scale = max(1.0, lastScale * value)
                                lastScale = scale
                                withAnimation(.easeOut(duration: 0.2)) {
                                    clampOffset(imageSize: imageSize, cropSize: cropSize)
                                }
                            }
                    )

                cropOverlay(cropSize: cropSize, in: canvasSize)

                VStack {
                    Spacer()
                    HStack {
                        Button("Annuler") {
                            isPresented = false
                        }
                        .font(.system(size: 17))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())

                        Spacer()

                        Button("Choisir") {
                            let cropped = cropImage(sourceImage, imageSize: imageSize, cropSize: cropSize, canvasSize: canvasSize)
                            onCropDone(cropped)
                            isPresented = false
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        .statusBarHidden(true)
    }

    // MARK: - Overlay

    private func cropOverlay(cropSize: CGFloat, in canvasSize: CGSize) -> some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.black.opacity(0.6))
            )
            let origin = CGPoint(
                x: (size.width - cropSize) / 2,
                y: (size.height - cropSize) / 2
            )
            let circle = Path(ellipseIn: CGRect(origin: origin, size: CGSize(width: cropSize, height: cropSize)))
            context.blendMode = .destinationOut
            context.fill(circle, with: .color(.white))

            context.blendMode = .normal
            context.stroke(circle, with: .color(.white.opacity(0.6)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Helpers

    private func aspectFitSize(for image: UIImage, in bounds: CGSize) -> CGSize {
        let imageAspect = image.size.width / max(image.size.height, 1)
        let boundsAspect = bounds.width / max(bounds.height, 1)

        if imageAspect > boundsAspect {
            let width = bounds.width
            return CGSize(width: width, height: width / imageAspect)
        } else {
            let height = bounds.height
            return CGSize(width: height * imageAspect, height: height)
        }
    }

    private func clampOffset(imageSize: CGSize, cropSize: CGFloat) {
        let scaledW = imageSize.width * scale
        let scaledH = imageSize.height * scale
        let maxX = max(0, (scaledW - cropSize) / 2)
        let maxY = max(0, (scaledH - cropSize) / 2)

        let clampedW = min(maxX, max(-maxX, offset.width))
        let clampedH = min(maxY, max(-maxY, offset.height))
        offset = CGSize(width: clampedW, height: clampedH)
        lastOffset = offset
    }

    private func cropImage(_ source: UIImage, imageSize: CGSize, cropSize: CGFloat, canvasSize: CGSize) -> UIImage {
        let scaledW = imageSize.width * scale
        let scaledH = imageSize.height * scale

        let centerX = canvasSize.width / 2 + offset.width
        let centerY = canvasSize.height / 2 + offset.height

        let cropCenterX = canvasSize.width / 2
        let cropCenterY = canvasSize.height / 2

        let cropOriginInImageX = (cropCenterX - cropSize / 2) - (centerX - scaledW / 2)
        let cropOriginInImageY = (cropCenterY - cropSize / 2) - (centerY - scaledH / 2)

        let scaleToSource = source.size.width / scaledW
        let srcX = cropOriginInImageX * scaleToSource
        let srcY = cropOriginInImageY * scaleToSource
        let srcSize = cropSize * scaleToSource

        let cropRect = CGRect(x: srcX, y: srcY, width: srcSize, height: srcSize)

        guard let orientedImage = redrawWithOrientation(source),
              let cgImage = orientedImage.cgImage?.cropping(to: cropRect) else {
            return source
        }

        return UIImage(cgImage: cgImage)
    }

    private func redrawWithOrientation(_ image: UIImage) -> UIImage? {
        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }
}
