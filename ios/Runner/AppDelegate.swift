import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let fileSaveHandler = NativeFileSaveHandler()
  private static let clipboardImageTypeIdentifiers = [
    "public.png",
    "public.jpeg",
    "public.jpg",
    "public.tiff",
    "public.heic",
    "public.heif",
    "public.image",
  ]

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let clipboardChannel = FlutterMethodChannel(name: "app.clipboard", binaryMessenger: controller.binaryMessenger)
      clipboardChannel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
        if call.method == "getClipboardImages" {
          DispatchQueue.global(qos: .userInitiated).async {
            let paths = self.readClipboardImagePaths()
            DispatchQueue.main.async {
              result(paths)
            }
          }
        } else {
          result(FlutterMethodNotImplemented)
        }
      }

      let fileSaveChannel = FlutterMethodChannel(name: "app.file_save", binaryMessenger: controller.binaryMessenger)
      fileSaveHandler.presentingViewController = controller
      fileSaveChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
        guard call.method == "saveFileFromPath" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.fileSaveHandler.handle(call: call, result: result)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func readClipboardImagePaths() -> [String] {
    let pasteboard = UIPasteboard.general

    if let image = pasteboard.image,
       let path = Self.persistClipboardImage(image) {
      return [path]
    }

    if let path = Self.readClipboardImageData(from: pasteboard) {
      return [path]
    }

    return Self.readClipboardImageItemProviders(from: pasteboard)
  }

  private static func readClipboardImageData(from pasteboard: UIPasteboard) -> String? {
    for typeIdentifier in clipboardImageTypeIdentifiers {
      guard let data = pasteboard.data(forPasteboardType: typeIdentifier), !data.isEmpty else {
        continue
      }
      if let path = persistClipboardImageData(data, preferredFileExtension: fileExtension(for: typeIdentifier)) {
        return path
      }
    }
    return nil
  }

  private static func readClipboardImageItemProviders(from pasteboard: UIPasteboard) -> [String] {
    guard !pasteboard.itemProviders.isEmpty else { return [] }

    let group = DispatchGroup()
    let lock = NSLock()
    var paths: [String] = []

    for provider in pasteboard.itemProviders {
      guard let typeIdentifier = clipboardImageTypeIdentifiers.first(where: {
        provider.hasItemConformingToTypeIdentifier($0)
      }) else {
        continue
      }

      group.enter()
      provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, _ in
        defer { group.leave() }
        guard let data, !data.isEmpty else { return }
        guard let path = persistClipboardImageData(
          data,
          preferredFileExtension: fileExtension(for: typeIdentifier)
        ) else {
          return
        }
        lock.lock()
        paths.append(path)
        lock.unlock()
      }
    }

    _ = group.wait(timeout: .now() + 1.5)
    return paths
  }

  private static func persistClipboardImage(_ image: UIImage) -> String? {
    if let data = image.pngData() {
      return persistClipboardImageData(data, preferredFileExtension: "png")
    }
    if let data = image.jpegData(compressionQuality: 0.95) {
      return persistClipboardImageData(data, preferredFileExtension: "jpg")
    }
    return nil
  }

  private static func persistClipboardImageData(
    _ data: Data,
    preferredFileExtension: String
  ) -> String? {
    let tmp = NSTemporaryDirectory()
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    let filename = "pasted_\(timestamp)_\(Int.random(in: 1000...9999)).\(preferredFileExtension)"
    let url = URL(fileURLWithPath: tmp).appendingPathComponent(filename)
    do {
      try data.write(to: url)
      return url.path
    } catch {
      return nil
    }
  }

  private static func fileExtension(for typeIdentifier: String) -> String {
    switch typeIdentifier {
    case "public.jpeg", "public.jpg":
      return "jpg"
    case "public.tiff":
      return "tiff"
    case "public.heic":
      return "heic"
    case "public.heif":
      return "heif"
    default:
      return "png"
    }
  }
}

private final class NativeFileSaveHandler: NSObject, UIDocumentPickerDelegate {
  weak var presentingViewController: UIViewController?
  private var pendingResult: FlutterResult?

  func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    if pendingResult != nil {
      result(FlutterError(code: "busy", message: "Another save operation is already in progress.", details: nil))
      return
    }

    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "invalid_args", message: "Arguments must be a map.", details: nil))
      return
    }

    let rawSourcePath = (args["sourcePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !rawSourcePath.isEmpty else {
      result(FlutterError(code: "invalid_args", message: "Missing sourcePath.", details: nil))
      return
    }

    let sourceURL = URL(fileURLWithPath: rawSourcePath)
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      result(FlutterError(code: "not_found", message: "Source file does not exist.", details: nil))
      return
    }

    guard let presenter = topViewController(from: presentingViewController) else {
      result(FlutterError(code: "unavailable", message: "Unable to present document picker.", details: nil))
      return
    }

    pendingResult = result

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }

      let picker: UIDocumentPickerViewController
      if #available(iOS 14.0, *) {
        picker = UIDocumentPickerViewController(forExporting: [sourceURL], asCopy: true)
      } else {
        picker = UIDocumentPickerViewController(url: sourceURL, in: .exportToService)
      }

      picker.delegate = self
      picker.modalPresentationStyle = .formSheet
      if let popover = picker.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        popover.permittedArrowDirections = []
      }

      presenter.present(picker, animated: true)
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    finish(with: false)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    finish(with: !urls.isEmpty)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentAt url: URL) {
    finish(with: true)
  }

  private func finish(with value: Bool) {
    let result = pendingResult
    pendingResult = nil
    result?(value)
  }

  private func topViewController(from controller: UIViewController?) -> UIViewController? {
    if let navigation = controller as? UINavigationController {
      return topViewController(from: navigation.visibleViewController)
    }
    if let tab = controller as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    if let presented = controller?.presentedViewController {
      return topViewController(from: presented)
    }
    return controller
  }
}
