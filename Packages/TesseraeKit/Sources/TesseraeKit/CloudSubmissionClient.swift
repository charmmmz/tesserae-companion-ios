import CoreFoundation
import Foundation

struct CloudSubmissionClient: Sendable {
    let transport: CloudAuthorizedTransport
    var writeTimeout: TimeInterval = 60

    func request(batch: CloudSubmissionBatch, task: CloudSubmissionTask, data: Data?) throws -> URLRequest {
        let base = transport.issuer.appending(path: "api/t")
        var request: URLRequest
        if let raster = task.raster {
            guard let data, !data.isEmpty, data.count <= 12_582_912,
                  !task.targetIDs.isEmpty, Set(task.targetIDs).count == task.targetIDs.count else {
                throw CloudSubmissionError.invalidPreparation
            }
            request = URLRequest(url: base.appending(path: "send/image"))
            let boundary = "tesserae-\(UUID().uuidString)"
            var body = Data()
            for (key, value) in [("devices", task.targetIDs.joined(separator: ",")), ("fit", "fit"), ("rotate", "0")] {
                body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
            }
            let ext = raster.format == .png ? "png" : "jpg"
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"photo.\(ext)\"\r\nContent-Type: \(raster.format.rawValue)\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8))
            request.httpBody = body
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        } else {
            guard batch.kind == .currentPage, task.targetIDs.count == 1,
                  let id = task.targetIDs.first, !id.isEmpty, id != ".", id != ".." else {
                throw CloudSubmissionError.invalidPreparation
            }
            request = URLRequest(url: base.appending(component: "devices").appending(component: id).appending(component: "render"))
        }
        request.httpMethod = "POST"
        request.timeoutInterval = writeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    func send(_ request: URLRequest, task: CloudSubmissionTask) async throws -> [CloudTargetResult] {
        let response = try await transport.send(request, timeout: writeTimeout, authorizationTimeout: 10)
        return Self.parse(response, targetIDs: task.targetIDs, isPhoto: task.raster != nil)
    }

    static func parse(_ response: TesseraeHTTPResponse, targetIDs: [String], isPhoto: Bool) -> [CloudTargetResult] {
        func unknown(_ id: String, _ message: String = "The service did not confirm this display's result.") -> CloudTargetResult {
            .init(id: id, outcome: .unknown(.invalidResponse, message: message))
        }
        let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        if response.statusCode != 200 {
            let bodyStatus = (json?["status"] as? NSNumber)?.intValue
            let error = (json?["error"] as? String).map(safeMessage)
            let oauthError = json?["error"] as? String
            let reason = json?["reason"] as? String
            let retryHeader = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
            let retry = retryHeader.flatMap { Double($0) }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            var refusal: CloudSubmissionProblem?
            switch response.statusCode {
            case 401 where oauthError == "invalid_token": refusal = .authorization
            case 403 where ["insufficient_scope", "membership_removed", "tenant_unavailable", "resource_mismatch"].contains(reason ?? oauthError ?? ""):
                refusal = .permission
            case 400, 413, 415:
                if bodyStatus == response.statusCode && error != nil { refusal = isPhoto ? .invalidImage : .noFrame }
            case 404 where bodyStatus == 404 && error != nil: refusal = .missingTarget
            case 402 where bodyStatus == 402 && error != nil && json?["limit"] is String: refusal = .quota
            case 429 where bodyStatus == 429 && error != nil: refusal = .rateLimited
            case 503 where bodyStatus == 503 && error != nil && retry == 20: refusal = .unavailable
            default: break
            }
            return targetIDs.map { id in
                if let refusal { return .init(id: id, outcome: .refused(refusal,
                    message: error ?? "This request was refused before frame generation.", retryAfter: retry)) }
                return .init(id: id, outcome: .unknown(response.statusCode == 503 ? .unavailable : .network,
                    message: "The request could not be confirmed (HTTP \(response.statusCode)). Check the display before sending again."))
            }
        }
        guard let json else { return targetIDs.map { unknown($0) } }
        if !isPhoto {
            guard targetIDs.count == 1, let frame = json["frame"] as? [String: Any], let evidence = frameEvidence(frame) else {
                return targetIDs.map { .init(id: $0, outcome: .unknown(.noFrame, message: "No new frame was confirmed.")) }
            }
            return [.init(id: targetIDs[0], outcome: .generated(evidence, warnings: []))]
        }
        guard let sent = json["sent"] as? [[String: Any]] else { return targetIDs.map { unknown($0) } }
        return targetIDs.map { id in
            let rows = sent.filter { $0["device_id"] as? String == id }
            guard rows.count == 1, let row = rows.first else { return unknown(id) }
            if let error = row["error"] as? String { return unknown(id, safeMessage(error)) }
            guard let evidence = frameEvidence(row), let warnings = row["errors"] as? [String] else { return unknown(id) }
            return .init(id: id, outcome: .generated(evidence, warnings: warnings.map(safeMessage)))
        }
    }

    private static func frameEvidence(_ json: [String: Any]) -> CloudFrameEvidence? {
        guard let digest = json["digest"] as? String, digest.count == 32,
              digest.allSatisfy({ $0.isHexDigit }), let bytes = json["bytes"] as? NSNumber,
              CFGetTypeID(bytes) != CFBooleanGetTypeID(), bytes.doubleValue.isFinite,
              bytes.doubleValue > 0, bytes.doubleValue.rounded() == bytes.doubleValue,
              let byteCount = Int(exactly: bytes.doubleValue), byteCount > 0 else { return nil }
        let date = (json["rendered_at"] as? NSNumber).flatMap { value -> Date? in
            guard value.doubleValue.isFinite, value.doubleValue > 0 else { return nil }
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        return .init(digest: digest, bytes: byteCount, renderedAt: date, pageID: json["page_id"] as? String)
    }

    private static func safeMessage(_ message: String) -> String {
        String(message.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(300))
    }
}
