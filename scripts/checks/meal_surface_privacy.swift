import Foundation
@main struct PrivacyChecks {
 @MainActor static func main() {
  let token = String(repeating: "f", count: 64)
  var failures = 0
  for suffix in ["", "/activities/activity-1"] {
    var request = URLRequest(url: URL(string: "https://example.invalid/api/v1/me/meal-surfaces/devices/04ee54a8-37dc-482d-826c-fca24d64b89a" + suffix)!)
    request.httpMethod = "PUT"
    request.httpBody = Data("{\"startToken\":\"\(token)\",\"pushToken\":\"\(token)\"}".utf8)
    if let body = QFRequestLogPreview.passwordSafeBody(request), String(data: body, encoding: .utf8)?.contains(token) == true { failures += 1 }
    request.httpBody = Data("unparseable sensitive payload \(token)".utf8)
    if let body = QFRequestLogPreview.passwordSafeBody(request), String(data: body, encoding: .utf8)?.contains(token) == true { failures += 1 }
  }
  var normal = URLRequest(url: URL(string: "https://example.invalid/api/v1/me/inventory/lots")!)
  normal.httpBody = Data("{\"quantity\":\"1\"}".utf8)
  if QFRequestLogPreview.passwordSafeBody(normal) != normal.httpBody { failures += 1 }
  print("5 Live Activity diagnostic privacy checks; failures: \(failures)")
  if failures > 0 { exit(1) }
 }
}
