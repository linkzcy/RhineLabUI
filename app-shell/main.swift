// RHINE LAB · ANALYSIS OS — 原生 macOS 壳
// WKWebView + 内嵌 localhost HTTP 服务：
//   /            静态 Web 资源（dist）
//   /api/*       文稿目录扫描、文本读取、缩略图、Office 转 PDF、打开文件
//   /files/*     文稿内文件字节流（图片/PDF/音视频，支持 Range）
// 构建：swiftc -O -swift-version 5 main.swift -o RhineLab \
//   -framework AppKit -framework WebKit -framework Network \
//   -framework PDFKit -framework QuickLookThumbnailing -framework UniformTypeIdentifiers

import AppKit
import CryptoKit
import Foundation
import Network
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import WebKit

// MARK: - 基础工具

func sha256Hex(_ value: String) -> String {
  SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

func jsonData(_ dict: [String: Any]) -> Data {
  (try? JSONSerialization.data(
    withJSONObject: dict,
    options: [.withoutEscapingSlashes, .sortedKeys]
  )) ?? Data("{}".utf8)
}

let fileManager = FileManager.default
let docsRoot = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
  .first!.standardizedFileURL
let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
  .first!.appendingPathComponent("RhineLab", isDirectory: true)
let convertedRoot = supportRoot.appendingPathComponent("converted", isDirectory: true)
let webRoot = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)

enum AppError: Error, CustomStringConvertible {
  case message(String)
  var description: String { if case let .message(m) = self { return m }; return "unknown" }
}

func ensureDirs() {
  try? fileManager.createDirectory(at: convertedRoot, withIntermediateDirectories: true)
  try? fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)
}

/// 把 API 传入的路径安全地解析到 ~/Documents 内。
/// 绝对路径（如 --open 参数）要求落在文稿目录内；相对路径相对文稿根解析。
func resolveDocs(_ raw: String) -> URL? {
  let rel = raw.removingPercentEncoding ?? raw
  let url: URL
  if rel.hasPrefix("/") {
    url = URL(fileURLWithPath: rel).standardizedFileURL
  } else {
    url = docsRoot.appendingPathComponent(rel).standardizedFileURL
  }
  let rootPath = docsRoot.path
  if url.path == rootPath { return url }
  guard url.path.hasPrefix(rootPath + "/") else { return nil }
  return url
}

func contentType(_ url: URL) -> String {
  switch url.pathExtension.lowercased() {
  case "html": return "text/html; charset=utf-8"
  case "css": return "text/css; charset=utf-8"
  case "js", "mjs": return "text/javascript; charset=utf-8"
  case "json": return "application/json; charset=utf-8"
  case "svg": return "image/svg+xml"
  case "png": return "image/png"
  case "jpg", "jpeg": return "image/jpeg"
  case "gif": return "image/gif"
  case "webp": return "image/webp"
  case "heic": return "image/heic"
  case "avif": return "image/avif"
  case "bmp": return "image/bmp"
  case "tif", "tiff": return "image/tiff"
  case "ico": return "image/x-icon"
  case "pdf": return "application/pdf"
  case "mp3": return "audio/mpeg"
  case "wav", "wave": return "audio/wav"
  case "m4a": return "audio/mp4"
  case "aac": return "audio/aac"
  case "flac": return "audio/flac"
  case "ogg": return "audio/ogg"
  case "aiff", "aif": return "audio/aiff"
  case "mp4", "m4v": return "video/mp4"
  case "mov": return "video/quicktime"
  case "webm": return "video/webm"
  case "woff": return "font/woff"
  case "woff2": return "font/woff2"
  case "glb": return "model/gltf-binary"
  case "txt", "md", "markdown", "log", "csv", "tsv", "srt", "vtt", "lrc":
    return "text/plain; charset=utf-8"
  default: return "application/octet-stream"
  }
}

let OFFICE_EXTENSIONS: Set<String> = [
  "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf",
]
let TEXTKIT_EXTENSIONS: Set<String> = ["docx", "doc", "rtf", "txt", "rtfd"]

// MARK: - HTTP 层

struct Request {
  let method: String
  let rawTarget: String
  let path: String
  let query: [String: String]
  let headers: [String: String]
  let body: Data

  var decodedPath: String { path.removingPercentEncoding ?? path }
}

struct Response {
  let status: Int
  var headers: [String: String]
  let body: Data

  static func json(_ dict: [String: Any], status: Int = 200) -> Response {
    Response(
      status: status,
      headers: [
        "Content-Type": "application/json; charset=utf-8",
        "Cache-Control": "no-store",
      ],
      body: jsonData(dict)
    )
  }
  static func data(
    _ data: Data,
    type: String,
    status: Int = 200,
    extra: [String: String] = [:]
  ) -> Response {
    var headers = extra
    headers["Content-Type"] = type
    return Response(status: status, headers: headers, body: data)
  }
  static func error(_ message: String, status: Int = 400) -> Response {
    .json(["error": message], status: status)
  }
}

func parseRequest(headerData: Data, body: Data) -> Request? {
  guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
  let lines = headerText.components(separatedBy: "\r\n")
  guard let requestLine = lines.first else { return nil }
  let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
  guard parts.count >= 2 else { return nil }
  var headers: [String: String] = [:]
  for line in lines.dropFirst() {
    guard let colon = line.firstIndex(of: ":") else { continue }
    let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    headers[key] = value
  }
  let target = String(parts[1])
  let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
  let path = String(pieces[0])
  var query: [String: String] = [:]
  if pieces.count > 1 {
    for pair in pieces[1].split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let key = (kv.count > 0 ? String(kv[0]) : "").removingPercentEncoding ?? ""
      let value = (kv.count > 1 ? String(kv[1]) : "").removingPercentEncoding ?? ""
      query[key] = value
    }
  }
  return Request(
    method: String(parts[0]).uppercased(),
    rawTarget: target,
    path: path,
    query: query,
    headers: headers,
    body: body
  )
}

final class MiniServer {
  private var listener: NWListener?
  private let handler: (Request) -> Response
  private let queue = DispatchQueue(
    label: "rhine.http", qos: .userInitiated, attributes: .concurrent
  )
  private(set) var port: UInt16 = 0

  init(handler: @escaping (Request) -> Response) {
    self.handler = handler
  }

  /// 优先绑定固定端口（localStorage 的 origin 稳定，设置可跨启动保存）；
  /// 被占用时回退随机端口。
  func start(preferredPort: UInt16 = 47310) throws {
    if !(try startOnce(port: preferredPort)) {
      guard try startOnce(port: 0) else {
        throw AppError.message("本地服务启动失败")
      }
    }
  }

  private func startOnce(port: UInt16) throws -> Bool {
    let params = NWParameters.tcp
    params.allowLocalEndpointReuse = true
    params.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!
    )
    let candidate = try NWListener(using: params)
    let ready = DispatchSemaphore(value: 0)
    var failed = false
    candidate.stateUpdateHandler = { state in
      switch state {
      case .ready:
        ready.signal()
      case .failed:
        failed = true
        ready.signal()
      default:
        break
      }
    }
    candidate.newConnectionHandler = { [weak self] connection in
      guard let self = self else { connection.cancel(); return }
      connection.start(queue: self.queue)
      self.handle(connection)
    }
    candidate.start(queue: queue)
    ready.wait()
    if failed || candidate.port == nil {
      candidate.cancel()
      return false
    }
    self.listener = candidate
    self.port = candidate.port!.rawValue
    return true
  }

  private func handle(_ connection: NWConnection) {
    var buffer = Data()
    func readMore() {
      connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
        data, _, isComplete, error in
        if let data = data { buffer.append(data) }
        if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
          let headerBytes = buffer.subdata(in: 0..<headerEnd.lowerBound)
          var contentLength = 0
          if let headerText = String(data: headerBytes, encoding: .utf8) {
            for line in headerText.components(separatedBy: "\r\n") {
              let lower = line.lowercased()
              if lower.hasPrefix("content-length:") {
                contentLength =
                  Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
                  ?? 0
              }
            }
          }
          let bodyStart = headerEnd.upperBound
          if buffer.count >= bodyStart + contentLength {
            let body = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            if let request = parseRequest(headerData: headerBytes, body: body) {
              self.respond(connection, request)
            } else {
              self.send(connection, .error("Bad Request"))
            }
            return
          }
        }
        if isComplete || error != nil || buffer.count > 16 * 1024 * 1024 {
          connection.cancel()
          return
        }
        readMore()
      }
    }
    readMore()
  }

  private func respond(_ connection: NWConnection, _ request: Request) {
    let response = handler(request)
    send(connection, response)
  }

  private func send(_ connection: NWConnection, _ response: Response) {
    var headers = response.headers
    headers["Content-Length"] = String(response.body.count)
    headers["Connection"] = "close"
    headers["X-Content-Type-Options"] = "nosniff"
    var text = "HTTP/1.1 \(response.status) \(statusText(response.status))\r\n"
    for (key, value) in headers { text += "\(key): \(value)\r\n" }
    text += "\r\n"
    var payload = Data(text.utf8)
    payload.append(response.body)
    connection.send(
      content: payload,
      completion: .contentProcessed { error in
        if let error = error { NSLog("RHINE send error %@", error.localizedDescription) }
        connection.cancel()
      }
    )
  }

  private func statusText(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 206: return "Partial Content"
    case 400: return "Bad Request"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 416: return "Range Not Satisfiable"
    case 500: return "Internal Server Error"
    default: return "Status"
    }
  }
}

// MARK: - 文件服务 / 缩略图 / 转换

let thumbnailCache = NSCache<NSString, NSData>()
let pdfPageCountCache = NSCache<NSString, NSNumber>()
let conversionQueue = DispatchQueue(label: "rhine.convert", qos: .utility)
let thumbnailQueue = DispatchQueue(label: "rhine.thumb", qos: .utility)

func fileAttributes(_ url: URL) -> (size: Int64, modified: Int64, isDir: Bool)? {
  guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
  let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
  let modified = ((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000
  let isDir = (attrs[.type] as? FileAttributeType) == .typeDirectory
  return (size, Int64(modified), isDir)
}

func listDirectory(_ url: URL) -> Response {
  guard let names = try? fileManager.contentsOfDirectory(
    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
  ) else {
    return .error("无法读取目录：\(url.lastPathComponent)")
  }
  var dirs: [[String: Any]] = []
  var files: [[String: Any]] = []
  for child in names {
    let name = child.lastPathComponent
    guard name != ".DS_Store", !name.hasPrefix(".") else { continue }
    guard let attrs = fileAttributes(child) else { continue }
    let isDir = attrs.isDir
    let ext = isDir ? "" : child.pathExtension.uppercased()
    let rel = child.path.hasPrefix(docsRoot.path + "/")
      ? String(child.path.dropFirst(docsRoot.path.count + 1))
      : name
    let entry: [String: Any] = [
      "name": name,
      "kind": isDir ? "directory" : "file",
      "size": isDir ? 0 : attrs.size,
      "modified": attrs.modified,
      "extension": ext,
      "path": rel,
    ]
    if isDir { dirs.append(entry) } else { files.append(entry) }
  }
  dirs.sort { (a, b) in
    (a["name"] as? String ?? "").localizedStandardCompare(b["name"] as? String ?? "")
      == .orderedAscending
  }
  files.sort { (a, b) in
    (a["name"] as? String ?? "").localizedStandardCompare(b["name"] as? String ?? "")
      == .orderedAscending
  }
  return .json(["entries": dirs + files])
}

func readTextFile(_ url: URL, maxBytes: Int) -> Response {
  guard let attrs = fileAttributes(url), !attrs.isDir else {
    return .error("文件不存在或不是普通文件")
  }
  guard let handle = try? FileHandle(forReadingFrom: url) else {
    return .error("无法读取文件")
  }
  defer { try? handle.close() }
  let cap = max(1, min(maxBytes, 8 * 1024 * 1024))
  let truncated = attrs.size > Int64(cap)
  var data: Data
  if #available(macOS 10.15.4, *) {
    data = (try? handle.read(upToCount: cap)) ?? Data()
  } else {
    data = handle.readData(ofLength: cap)
  }
  var text = String(data: data, encoding: .utf8)
  if text == nil {
    let gb = String.Encoding(
      rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
      )
    )
    text = String(data: data, encoding: gb) ?? String(data: data, encoding: .isoLatin1)
  }
  return .json([
    "text": text ?? "",
    "truncated": truncated,
    "bytes": data.count,
  ])
}

func thumbnailData(_ url: URL, px: Int) -> Data? {
  let key = "\(url.path)|\(px)|\((try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" as NSString
  if let cached = thumbnailCache.object(forKey: key) { return cached as Data }
  guard let attrs = fileAttributes(url), !attrs.isDir, attrs.size < 256 * 1024 * 1024 else {
    return nil
  }
  let semaphore = DispatchSemaphore(value: 0)
  var result: Data?
  let size = CGSize(width: px, height: px)
  let request = QLThumbnailGenerator.Request(
    fileAt: url, size: size, scale: 1, representationTypes: .thumbnail
  )
  QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
    defer { semaphore.signal() }
    guard let rep = rep else { return }
    let image = rep.nsImage
    guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff)
    else { return }
    let png = bitmap.representation(using: .png, properties: [:])
    if let png = png {
      result = png
      thumbnailCache.setObject(png as NSData, forKey: key)
    }
  }
  _ = semaphore.wait(timeout: .now() + 6)
  return result
}

func convertedPdfPath(for source: URL) -> URL? {
  guard let attrs = fileAttributes(source) else { return nil }
  let key = sha256Hex("\(source.path)|\(attrs.size)|\(attrs.modified)")
  return convertedRoot.appendingPathComponent("\(key).pdf")
}

func libreOfficeConvert(_ input: URL, to output: URL) throws {
  let nodePath =
    "/Applications/DSH Desktop.app/Contents/Frameworks/DSH Desktop Helper.app/Contents/MacOS/DSH Desktop Helper"
  let cliPath = "/Applications/DSH Desktop.app/Contents/Resources/office-cli.mjs"
  guard fileManager.fileExists(atPath: nodePath), fileManager.fileExists(atPath: cliPath) else {
    throw AppError.message("本机未找到文档转换组件（LibreOffice Kit）")
  }
  let process = Process()
  process.executableURL = URL(fileURLWithPath: nodePath)
  process.arguments = [cliPath, "convert", "--input", input.path, "--output", output.path]
  var env = ProcessInfo.processInfo.environment
  env["ELECTRON_RUN_AS_NODE"] = "1"
  process.environment = env
  let errorPipe = Pipe()
  process.standardError = errorPipe
  process.standardOutput = Pipe()
  try process.run()
  let watchdog = DispatchWorkItem {
    if process.isRunning { process.terminate() }
  }
  DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: watchdog)
  process.waitUntilExit()
  watchdog.cancel()
  guard process.terminationStatus == 0, fileManager.fileExists(atPath: output.path) else {
    let message =
      String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    throw AppError.message(message?.isEmpty == false ? "转换失败：\(message!)" : "文档转换失败")
  }
}

func textKitHtml(_ url: URL) throws -> String {
  let attributed = try NSAttributedString(
    url: url, options: [:], documentAttributes: nil
  )
  let html = try attributed.data(
    from: NSRange(location: 0, length: attributed.length),
    documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
  )
  return String(data: html, encoding: .utf8) ?? ""
}

func pdfPageCount(_ url: URL) -> Int {
  let key = "\(url.path)|\((try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)" as NSString
  if let cached = pdfPageCountCache.object(forKey: key) { return cached.intValue }
  let count = PDFDocument(url: url)?.pageCount ?? 0
  pdfPageCountCache.setObject(NSNumber(value: count), forKey: key)
  return count
}

// MARK: - 路由

func serveFile(_ url: URL, request: Request, cacheControl: String) -> Response {
  guard let attrs = fileAttributes(url), !attrs.isDir else {
    return .error("文件不存在", status: 404)
  }
  let total = attrs.size
  let type = contentType(url)
  var extra: [String: String] = [
    "Accept-Ranges": "bytes",
    "Cache-Control": cacheControl,
  ]
  if url.pathExtension.lowercased() == "pdf" {
    extra["Content-Disposition"] = "inline"
  }
  guard let handle = try? FileHandle(forReadingFrom: url) else {
    return .error("无法读取文件", status: 500)
  }
  defer { try? handle.close() }
  if let rangeHeader = request.headers["range"], rangeHeader.hasPrefix("bytes=") {
    let spec = String(rangeHeader.dropFirst("bytes=".count))
    if let dash = spec.firstIndex(of: "-") {
      let startText = spec[..<dash]
      let endText = spec[spec.index(after: dash)...]
      if let start = Int64(startText) {
        let end = endText.isEmpty ? total - 1 : min(Int64(endText) ?? (total - 1), total - 1)
        guard start <= end, start < total else {
          var headers = extra
          headers["Content-Range"] = "bytes */\(total)"
          return Response(status: 416, headers: headers, body: Data())
        }
        let length = Int(end - start + 1)
        try? handle.seek(toOffset: UInt64(start))
        let data = handle.readData(ofLength: length)
        var headers = extra
        headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
        return .data(data, type: type, status: 206, extra: headers)
      }
    }
  }
  let data = handle.readData(ofLength: Int(total))
  return .data(data, type: type, extra: extra)
}

func route(_ request: Request) -> Response {
  let path = request.decodedPath
  let method = request.method

  // ---- 静态 Web 资源 ----
  let webFile: URL?
  if path == "/" || path == "/index.html" {
    webFile = webRoot.appendingPathComponent("index.html")
  } else if path.hasPrefix("/assets/") || path.hasPrefix("/fonts/")
    || path.hasPrefix("/archives/") || path.hasPrefix("/licenses/")
    || path == "/favicon.svg" || path == "/reference"
  {
    webFile = webRoot.appendingPathComponent(String(path.dropFirst()))
  } else {
    webFile = nil
  }
  if let webFile = webFile, fileManager.fileExists(atPath: webFile.path) {
    let cache = path.hasPrefix("/assets/") || path.hasPrefix("/fonts/")
      ? "public, max-age=31536000, immutable"
      : "no-cache"
    return serveFile(webFile, request: request, cacheControl: cache)
  }
  if webFile != nil { return .error("Not Found", status: 404) }

  // ---- API ----
  if path.hasPrefix("/api/") {
    let api = String(path.dropFirst("/api/".count))
    switch (api, method) {
    case ("info", "GET"):
      return .json([
        "app": true,
        "version": "1.1.0",
        "documentsLabel": "文稿",
        "documentsRoot": docsRoot.path,
        "homeLabel": NSHomeDirectory(),
      ])
    case ("list", "GET"):
      guard let raw = request.query["path"] else { return .error("缺少 path 参数") }
      guard let url = resolveDocs(raw) else { return .error("路径超出文稿目录范围", status: 403) }
      return listDirectory(url)
    case ("text", "GET"):
      guard let raw = request.query["path"] else { return .error("缺少 path 参数") }
      guard let url = resolveDocs(raw) else { return .error("路径超出文稿目录范围", status: 403) }
      let maxBytes = Int(request.query["max"] ?? "") ?? (512 * 1024)
      return readTextFile(url, maxBytes: maxBytes)
    case ("convert", "GET"):
      guard let raw = request.query["path"] else { return .error("缺少 path 参数") }
      guard let url = resolveDocs(raw) else { return .error("路径超出文稿目录范围", status: 403) }
      let ext = url.pathExtension.lowercased()
      guard OFFICE_EXTENSIONS.contains(ext) else {
        return .json(["ok": false, "error": "该格式不支持文档转换"])
      }
      if let cached = convertedPdfPath(for: url), fileManager.fileExists(atPath: cached.path) {
        return .json([
          "ok": true,
          "fileUrl": "/files/__cache__/\(cached.lastPathComponent)",
          "pages": pdfPageCount(cached),
        ])
      }
      var result: Response = .json(["ok": false, "error": "文档转换不可用"])
      conversionQueue.sync {
        do {
          if let output = convertedPdfPath(for: url) {
            try libreOfficeConvert(url, to: output)
            result = .json([
              "ok": true,
              "fileUrl": "/files/__cache__/\(output.lastPathComponent)",
              "pages": pdfPageCount(output),
            ])
          }
        } catch {
          if TEXTKIT_EXTENSIONS.contains(ext) {
            do {
              let html = try textKitHtml(url)
              result = .json(["ok": false, "html": html])
            } catch {
              result = .json([
                "ok": false,
                "error": "无法转换该文档，请用默认应用打开",
              ])
            }
          } else {
            result = .json([
              "ok": false,
              "error": error.localizedDescription,
            ])
          }
        }
      }
      return result
    case ("open", "POST"), ("reveal", "POST"):
      let raw = String(data: request.body, encoding: .utf8) ?? ""
      guard let url = resolveDocs(raw) else { return .error("路径超出文稿目录范围", status: 403) }
      guard fileManager.fileExists(atPath: url.path) else {
        return .error("文件不存在", status: 404)
      }
      DispatchQueue.main.async {
        if api == "open" {
          NSWorkspace.shared.open(url)
        } else {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      }
      return .json(["ok": true])
    default:
      return .error("未知接口", status: 404)
    }
  }

  // ---- 缩略图 ----
  if path.hasPrefix("/thumb/") {
    let raw = String(path.dropFirst("/thumb/".count))
    guard let url = resolveDocs(raw) else { return .error("路径超出文稿目录范围", status: 403) }
    let px = Int(request.query["px"] ?? "") ?? 640
    var data: Data?
    thumbnailQueue.sync { data = thumbnailData(url, px: px) }
    if let data = data {
      return .data(data, type: "image/png", extra: ["Cache-Control": "max-age=300"])
    }
    return .error("无法生成预览", status: 404)
  }

  // ---- 文件字节流 ----
  if path.hasPrefix("/files/") {
    let raw = String(path.dropFirst("/files/".count))
    if raw.hasPrefix("__cache__/") {
      let name = String(raw.dropFirst("__cache__/".count))
      let safe = name.range(of: #"^[0-9a-f]+\.pdf$"#, options: .regularExpression) != nil
      guard safe else { return .error("非法缓存文件", status: 403) }
      let url = convertedRoot.appendingPathComponent(name)
      return serveFile(url, request: request, cacheControl: "public, max-age=86400")
    }
    guard let url = resolveDocs(raw) else { return .error("路径超出文稿目录范围", status: 403) }
    return serveFile(url, request: request, cacheControl: "no-store")
  }

  return .error("Not Found", status: 404)
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
  var window: NSWindow!
  var webView: WKWebView!
  var server: MiniServer?
  var snapshotPath: String?
  var snapshotWait: TimeInterval = 8
  var didSnapshot = false
  var evalScript: String?

  func applicationDidFinishLaunching(_ notification: Notification) {
    ensureDirs()
    NSApp.setActivationPolicy(.regular)

    // 启动参数：--open <path> --scene <name> --snapshot <png> --wait <秒>
    var queryItems: [String] = []
    var args = Array(ProcessInfo.processInfo.arguments.dropFirst())
    while !args.isEmpty {
      let arg = args.removeFirst()
      switch arg {
      case "--open":
        if let value = args.first {
          queryItems.append(
            "open=" + value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
          args.removeFirst()
        }
      case "--scene":
        if let value = args.first {
          queryItems.append("scene=" + value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
          args.removeFirst()
        }
      case "--tab":
        if let value = args.first {
          queryItems.append("tab=" + value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
          args.removeFirst()
        }
      case "--eco":
        if let value = args.first {
          queryItems.append("eco=" + value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)
          args.removeFirst()
        }
      case "--snapshot":
        if let value = args.first {
          snapshotPath = value
          args.removeFirst()
        }
      case "--wait":
        if let value = args.first, let seconds = Double(value) {
          snapshotWait = seconds
          args.removeFirst()
        }
      case "--eval":
        if let value = args.first {
          evalScript = value
          args.removeFirst()
        }
      default:
        break
      }
    }

    do {
      let server = try MiniServer(handler: route)
      try server.start()
      self.server = server
      let suffix = queryItems.isEmpty ? "" : "?" + queryItems.joined(separator: "&")
      let url = URL(string: "http://127.0.0.1:\(server.port)/\(suffix)")!
      NSLog("RHINE serving on port %d → %@", server.port, url.absoluteString)

      let config = WKWebViewConfiguration()
      config.mediaTypesRequiringUserActionForPlayback = []
      if #available(macOS 14.0, *) {
        config.preferences.inactiveSchedulingPolicy = .throttle
      }
      let webView = WKWebView(frame: .zero, configuration: config)
      webView.navigationDelegate = self
      webView.uiDelegate = self
      webView.allowsMagnification = false
      webView.setValue(false, forKey: "drawsBackground")
      webView.underPageBackgroundColor = NSColor(
        calibratedRed: 0.91, green: 0.90, blue: 0.88, alpha: 1
      )
      self.webView = webView

      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
      )
      window.title = "RHINE LAB · ANALYSIS OS"
      window.minSize = NSSize(width: 1100, height: 690)
      window.center()
      window.contentView = webView
      window.setFrameAutosaveName("RhineLabMainWindow")
      window.makeKeyAndOrderFront(nil)
      self.window = window

      buildMenu()
      NSApp.activate(ignoringOtherApps: true)
      webView.load(URLRequest(url: url))
    } catch {
      let alert = NSAlert()
      alert.messageText = "RHINE LAB 启动失败"
      alert.informativeText = error.localizedDescription
      alert.runModal()
      NSApp.terminate(nil)
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }

  func buildMenu() {
    let mainMenu = NSMenu()
    let appItem = NSMenuItem()
    mainMenu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "关于 RHINE LAB", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "退出 RHINE LAB", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    mainMenu.addItem(editItem)
    let editMenu = NSMenu(title: "编辑")
    editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu

    let viewItem = NSMenuItem()
    mainMenu.addItem(viewItem)
    let viewMenu = NSMenu(title: "显示")
    viewMenu.addItem(
      withTitle: "重新载入", action: #selector(reload), keyEquivalent: "r")
    viewItem.submenu = viewMenu
    NSApp.mainMenu = mainMenu
  }

  @objc func reload() {
    webView.reload()
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    NSLog("RHINE didFailProvisional %@", error.localizedDescription)
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    NSLog("RHINE didFail %@", error.localizedDescription)
  }

  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
      NSWorkspace.shared.open(url)
    }
    return nil
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    NSLog("RHINE didFinish %@", webView.url?.absoluteString ?? "?")
    if let evalScript = evalScript {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
        webView.evaluateJavaScript(evalScript) { result, error in
          if let error = error {
            NSLog("RHINE EVAL ERROR %@", error.localizedDescription)
          } else {
            NSLog("RHINE EVAL RESULT %@", String(describing: result ?? "nil"))
          }
          guard let self = self, self.snapshotPath == nil else { return }
          NSApp.terminate(nil)
        }
      }
    }
    guard let snapshotPath = snapshotPath, !didSnapshot else { return }
    didSnapshot = true
    DispatchQueue.main.asyncAfter(deadline: .now() + snapshotWait) {
      let config = WKSnapshotConfiguration()
      config.rect = webView.bounds
      webView.takeSnapshot(with: config) { image, _ in
        if let image = image,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
        {
          try? png.write(to: URL(fileURLWithPath: snapshotPath))
          print("SNAPSHOT SAVED \(snapshotPath)")
        } else {
          print("SNAPSHOT FAILED")
        }
        NSApp.terminate(nil)
      }
    }
  }
}

ensureDirs()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
