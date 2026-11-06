import Foundation
import PDFKit

/// Switches PDFKit's automatic page analysis (off by default).
///
/// On macOS 15+ PDFView runs `VNRecognizeDocumentsRequest` on every page that
/// becomes visible (`PDFPageAnalyzerV2`, from `visiblePagesChanged:`) to
/// detect form fields and tables in flat PDFs and to OCR scanned pages. On
/// the 500-page test PDF that is ~60% of all CPU while scrolling (20.7 G vs
/// 8.3 G instructions for the same scroll), ~105 MB of footprint (Vision and
/// Core ML models: 179 MB vs 74 MB) and an occasional late frame; on the first
/// run of a new app build it also queues a ~20 s Neural Engine model compile
/// right after launch that the `ocr` command then waits behind. Better
/// Preview has its own on-demand OCR and form handling, so this is off by
/// default; `set pdfkit-analysis true` turns it back on (applied on open and
/// whenever the option changes).
///
/// The switch (`documentAnalysisEnabled`) is not public API: it is set only
/// if PDFView still responds to its setter and getter, through KVC, so a
/// PDFKit that drops or renames it simply keeps analysing.
/// `BP_PDFKIT_ANALYSIS=1` forces PDFKit's behaviour (for comparison).
enum PDFKitTuning {
    /// True when the switch exists on this PDFKit.
    static func isAvailable(on view: PDFView) -> Bool {
        view.responds(to: NSSelectorFromString("setDocumentAnalysisEnabled:"))
            && view.responds(to: NSSelectorFromString("isDocumentAnalysisEnabled"))
    }

    /// What the view will be set to for the option value.
    static func effectiveAnalysis(option: Bool) -> Bool {
        option || ProcessInfo.processInfo.environment["BP_PDFKIT_ANALYSIS"] == "1"
    }

    /// Turns PDFKit's automatic analysis on or off (`pdfkit-analysis`).
    static func applyAnalysis(_ enabled: Bool, to view: PDFView) {
        guard isAvailable(on: view) else { return }
        let value = effectiveAnalysis(option: enabled)
        if (view.value(forKey: "documentAnalysisEnabled") as? Bool) != value {
            view.setValue(value, forKey: "documentAnalysisEnabled")
        }
    }

    /// The current state, nil when the switch does not exist.
    static func analysisEnabled(of view: PDFView) -> Bool? {
        guard isAvailable(on: view) else { return nil }
        return view.value(forKey: "documentAnalysisEnabled") as? Bool
    }
}
