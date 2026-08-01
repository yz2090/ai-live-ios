import UIKit
import UniformTypeIdentifiers

// MARK: - UIKit 文档选择器（iOS15 上 SwiftUI fileImporter 有 bug 不弹窗，改用原生 present）
final class MusicDocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = MusicDocumentPicker()

    private var onPicked: (([URL]) -> Void)?
    private var onCancel: (() -> Void)?

    /// 弹出文件选择器（支持多选，自动复制到App沙盒）
    func present(
        from viewController: UIViewController?,
        allowedTypes: [UTType] = [.audio],
        allowsMultiple: Bool = true,
        onPicked: @escaping ([URL]) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.onPicked = onPicked
        self.onCancel = onCancel
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultiple
        picker.delegate = self
        viewController?.present(picker, animated: true)
    }

    // MARK: - UIDocumentPickerDelegate
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPicked?(urls)
        onPicked = nil
        onCancel = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onCancel?()
        onPicked = nil
        onCancel = nil
    }
}

// MARK: - 获取当前顶层 ViewController（用于 UIKit present）
extension UIApplication {
    static func topViewController(controller: UIViewController? = nil) -> UIViewController? {
        let controller = controller ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: { $0.isKeyWindow })?
            .rootViewController
        if let nav = controller as? UINavigationController {
            return topViewController(controller: nav.visibleViewController)
        }
        if let tab = controller as? UITabBarController {
            return topViewController(controller: tab.selectedViewController)
        }
        if let presented = controller?.presentedViewController {
            return topViewController(controller: presented)
        }
        return controller
    }
}
