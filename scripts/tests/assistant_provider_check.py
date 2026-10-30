#!/usr/bin/env python3
"""Shipping provider policy/request DTO; HTTP/multipart transport alone is substituted."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
source=(root/'QiafanYoupu/Core/Networking/QFAssistantStream.swift').read_text()
shipping=source[source.index('enum QFAssistantProvider:'):source.index('struct QFAssistantStreamResult:')]
ui=(root/'QiafanYoupu/Features/Assistant/QFDigitalAssistant.swift').read_text()
assert 'case gemini = "GEMINI"' in shipping
assert 'selectedProvider = app.defaultAssistantProvider' in ui
assert 'selectMode(provider: provider)' in ui
assert 'selectMode(cloud: false)' not in ui and 'useCloud = false' not in ui
assert 'self.selectedProvider == consentProvider' in ui
session=(root/'QiafanYoupu/Core/Session/QFAppSession.swift').read_text()
assert 'provider: QFAssistantProvider? = nil, providerRegion authorizedRegion: String? = nil' in session
assert 'provider == .gemini ? authorizedRegion : nil' in session
assert 'provider.available(in: configuration?.assistantCapabilities?.chatProviders,' in session
assert 'provider: provider.rawValue' in session
with tempfile.TemporaryDirectory(prefix='glm-provider-',dir=root/'.build') as folder:
 p=Path(folder); f=p/'Check.swift'
 f.write_text(r'''import Foundation
// Multipart transport boundary records the production DTO's fields without network/package resolution.
final class MultipartFormData {
 var parts:[String:Data]=[:]
 var contentType:String { "multipart/form-data; boundary=fixture" }
 func append(_ data:Data,withName name:String){precondition(parts[name]==nil);parts[name]=data}
 func append(_ data:Data,withName name:String,fileName:String,mimeType:String){append(data,withName:name)}
 func encode() throws -> Data { try JSONEncoder().encode(parts.mapValues{String(data:$0,encoding:.utf8) ?? "binary"}) }
}
enum QFOnDeviceInference { struct Turn:Codable { let role:String;let content:String } }
''' + shipping + r'''
@main enum Check {
 static func main() throws {
  precondition(QFAssistantProvider.allCases.map(\.rawValue)==["GLM_FREE","DEEPSEEK","GEMINI"])
  precondition(!QFAssistantProvider.glmFree.requiresCredits)
  precondition(QFAssistantProvider.deepSeek.requiresCredits)
  precondition(QFAssistantProvider.gemini.requiresCredits)
  precondition(QFAssistantProvider.preferred(defaultProvider:"GEMINI",availableProviders:["GEMINI"],regions:["GEMINI":"eu"]) == .gemini)
  precondition(QFAssistantProvider.preferred(defaultProvider:"GEMINI",availableProviders:["GLM_FREE"],regions:[:]) == .glmFree)
  precondition(QFAssistantProvider.preferred(defaultProvider:"DEEPSEEK",availableProviders:["DEEPSEEK"],regions:[:]) == .glmFree)
  precondition(!QFAssistantProvider.gemini.available(in:["GEMINI"]))
  precondition(!QFAssistantProvider.gemini.available(in:["GEMINI"],processingRegion:"global"))
  let frozenRegion = "us"
  precondition(QFAssistantProvider.gemini.matchesProcessingRegion(authorized:frozenRegion,configured:"us"))
  precondition(!QFAssistantProvider.gemini.matchesProcessingRegion(authorized:frozenRegion,configured:"eu"))
  precondition(!QFAssistantProvider.gemini.matchesProcessingRegion(authorized:nil,configured:"eu"))
  precondition(QFAssistantProvider.gemini.consentKey(scope:"a",processingRegion:"eu") != QFAssistantProvider.gemini.consentKey(scope:"a",processingRegion:"us"))
  for provider in QFAssistantProvider.allCases {
   precondition(!provider.available(in:nil));precondition(!provider.available(in:[]))
   precondition(provider.available(in:[provider.rawValue],processingRegion:"eu"))
   precondition(provider.consentKey(scope:"a") != provider.consentKey(scope:"b"))
   precondition(provider.consentKey(scope:"a") != "qf.assistant.cloud-consent.a")
   let request=QFAssistantChatRequest(text:"meal",allowCloud:true,allowWeb:true,
      history:[.init(role:"user",content:"old")],householdId:nil,timeZone:"Asia/Shanghai",provider:provider.rawValue,providerRegion:provider == .gemini ? "eu" : nil)
   let wire=try request.encoded(imageData:nil,mimeType:"image/jpeg")
   let json=try JSONSerialization.jsonObject(with:wire.body) as! [String:Any]
   precondition(json["provider"] as? String == provider.rawValue)
   precondition(json["allowWeb"] as? Bool == true && json["apiKey"] == nil)
   precondition(json["providerRegion"] as? String == (provider == .gemini ? "eu" : nil))
   let image=try request.encoded(imageData:Data([1,2,3]),mimeType:"image/jpeg")
   let multipart=try JSONSerialization.jsonObject(with:image.body) as! [String:String]
   precondition(multipart["provider"] == provider.rawValue && multipart["text"] == "meal")
   precondition(multipart["image"] != nil && multipart["history"]?.contains("old") == true)
   precondition(multipart["providerRegion"] == (provider == .gemini ? "eu" : nil))
   let again=try request.encoded(imageData:nil,mimeType:"image/jpeg")
   let replay=try JSONSerialization.jsonObject(with:again.body) as! [String:Any]
   precondition(replay["provider"] as? String == json["provider"] as? String)
  }
  precondition(QFAssistantProvider.glmFree.consentKey(scope:"a") != QFAssistantProvider.deepSeek.consentKey(scope:"a"))
  print("PASS: shipping provider policy, per-provider/account consent, JSON/multipart identity, no legacy paid fallback")
 }
}
''')
 subprocess.run(['xcrun','swiftc','-j','1','-parse-as-library','-module-cache-path',str(p/'modules'),str(f),'-o',str(p/'check')],check=True,timeout=45)
 subprocess.run([str(p/'check')],check=True,timeout=10)
