import ImageIO
import PDFKit
import SwiftUI
import UIKit
import VeraDataCore

struct PhoneEvidenceView: View {
    let mark: EvidenceMark
    let record: VeraDataCore.Record
    let bytes: Data

    @PhoneState private var page: EvidencePage?
    @PhoneState private var finishedLoading = false

    var body: some View {
        Group {
            if let page {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        if page.pageCount > 1 {
                            Text(VeraText.format("Page %lld of %lld", mark.page + 1, page.pageCount))
                                .font(.subheadline)
                        }
                        ForEach(mark.fields.keys.sorted(), id: \.self) { key in
                            HStack {
                                Text(record.fieldDefinition(key).localizedLabel)
                                Spacer()
                                Text(VeraText.text(mark.matches(key, in: record) ? "Checked against source" : "Needs review"))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                    .padding([.top, .horizontal])
                    EvidenceZoomView(image: page.image, region: mark.region)
                        .accessibilityLabel(VeraText.text("Evidence document page"))
                }
            } else if finishedLoading {
                ContentUnavailableView(VeraText.text("Evidence could not be displayed"), systemImage: "doc.badge.exclamationmark")
            } else {
                ProgressView()
            }
        }
        .navigationTitle(mark.document.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            page = EvidencePage(mark: mark, bytes: bytes)
            finishedLoading = true
        }
    }
}

private struct EvidencePage {
    let image: UIImage
    let pageCount: Int

    init?(mark: EvidenceMark, bytes: Data) {
        switch mark.document.kind {
        case .pdf:
            guard let document = PDFDocument(data: bytes), !document.isLocked, mark.page < document.pageCount,
                  let page = document.page(at: mark.page) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
            let scale = 2000 / max(bounds.width, bounds.height)
            image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .cropBox)
            pageCount = document.pageCount
        case .image:
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2200,
            ]
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            image = UIImage(cgImage: thumbnail)
            pageCount = 1
        }
        guard image.size.width > 0, image.size.height > 0 else { return nil }
    }
}

/// Keep the outline in the same zooming view as the rendered page.
private struct EvidenceZoomView: UIViewRepresentable {
    let image: UIImage
    let region: EvidenceRegion

    func makeUIView(context: Context) -> EvidenceScrollView {
        EvidenceScrollView(image: image, region: region)
    }

    func updateUIView(_ view: EvidenceScrollView, context: Context) {}
}

private final class EvidenceScrollView: UIScrollView, UIScrollViewDelegate {
    private let page: UIImageView
    private var fittedBounds: CGSize = .zero

    init(image: UIImage, region: EvidenceRegion) {
        page = UIImageView(image: image)
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        contentInsetAdjustmentBehavior = .never
        delegate = self
        let size = image.size
        page.frame = CGRect(origin: .zero, size: size)
        let border = CAShapeLayer()
        border.path = UIBezierPath(rect: CGRect(x: CGFloat(region.x) * size.width, y: CGFloat(region.y) * size.height,
                                                width: CGFloat(region.width) * size.width,
                                                height: CGFloat(region.height) * size.height)).cgPath
        border.strokeColor = UIColor.systemRed.cgColor
        border.fillColor = UIColor.clear.cgColor
        border.lineWidth = max(size.width, size.height) / 440
        page.layer.addSublayer(border)
        addSubview(page)
        contentSize = size
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let size = page.image?.size, bounds.width > 0, bounds.height > 0,
              fittedBounds != bounds.size else { return }
        fittedBounds = bounds.size
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        maximumZoomScale = fit * 6
        minimumZoomScale = fit
        zoomScale = fit
        scrollViewDidZoom(self)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { page }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }
}
