import CoreGraphics
import Vision

public struct RecognizedLine: Sendable {
    public let text: String
    /// Normalized to the image, bottom-left origin (the same orientation as a PDF page).
    public let box: CGRect
}

/// On-device text recognition using Apple's Vision framework; nothing leaves the Mac.
public enum TextRecognizer {
    public static func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Not `automaticallyDetectsLanguage`: it adds 30–90 s of model loading to the first page in each launch and
        // read handwriting worse on a real ES-50 scan. The default uses the Mac's preferred languages.
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, box: observation.boundingBox)
        }
    }
}
