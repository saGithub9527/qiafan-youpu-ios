import UIKit
import MJRefresh
import XCTest
@testable import QiafanYoupu

private final class QFIngredientTestTransport: URLProtocol {
  static var requests: [URLRequest] = []
  static var failCatalog = false
  static let ingredientID = "71000000-0000-0000-0000-000000000001"
  static let recipeID = "72000000-0000-0000-0000-000000000001"
  static func name(_ language: String) -> String { ["zh-Hans":"番茄","zh-Hant":"番茄","en":"Tomato","ja":"トマト","ko":"토마토","ru":"Помидор","es":"Tomate","fr":"Tomate","de":"Tomate","pt-BR":"Tomate"][language] ?? "Tomato" }
  static func ingredient(_ id: String = ingredientID, language: String = "zh-Hans", category: String = "VEGETABLE") -> [String: Any] {
    ["id":id,"type":"INGREDIENT","title":name(language),"subtitle":"","materials":[],"steps":[],"categoryCode":category,"iconKey":"tomato","inStock":true]
  }
  static func lot(language: String = "zh-Hans") -> [String: Any] {
    ["id":"73000000-0000-0000-0000-000000000001","ingredientId":ingredientID,"ingredientName":name(language),"contentAvailable":true,"categoryCode":"VEGETABLE","iconKey":"tomato","unitCode":"g","initialQuantity":"500","currentQuantity":"500","location":"","status":"ACTIVE","revision":0]
  }
  static func combination(language: String = "zh-Hans") -> [String: Any] {
    ["recipeId":recipeID,"title":name(language),"minutes":15,"servings":2,"matchedCount":1,"plans":[],"materials":[["ingredientId":ingredientID,"name":name(language),"categoryCode":"VEGETABLE","iconKey":"tomato","quantityKind":"EXACT","quantityMin":"300","quantityMax":"300","unitCode":"g","availability":"AVAILABLE","availableQuantity":"500","missingQuantity":"0"],["name":name(language),"quantityKind":"TO_TASTE","quantityText":"—","availability":"UNCONFIRMED"]]]
  }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.requests.append(request); let path = request.url!.path
    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    let value: Any; let language = request.value(forHTTPHeaderField: "Accept-Language") ?? "zh-Hans"
    var code = 0
    if path.hasSuffix("app/config") { value = ["appName":"Test","serviceRegion":"cn","loginMethods":["quick":true,"apple":true],"agreements":["userAgreement":"test","privacyPolicy":"test"]] }
    else if path.hasSuffix("auth/quick/sessions") {
      let token = Data(repeating: 2, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
      value = ["session":["accessToken":token,"refreshToken":token,"accessTokenExpiresIn":3600,"refreshTokenExpiresIn":86400],"user":["userId":"ingredient-fixture-user","systemAccount":"sys_ingredient_test","accountNameBound":false,"passwordConfigured":false,"nickname":"Test","appleBound":false]]
    } else if path.hasSuffix("catalog") {
      if Self.failCatalog { code = 50300 }
      let page = Int(query.first { $0.name == "page" }?.value ?? "0") ?? 0
      let rows = (0..<20).map { index in Self.ingredient(index == 0 && page == 0 ? Self.ingredientID : String(format: "71000000-0000-0000-0000-%012d", page * 20 + index + 2), language: language, category: query.first { $0.name == "category" }?.value ?? "VEGETABLE") }
      value = ["items":rows,"total":40]
    } else if path.hasSuffix("me/inventory") { value = ["items":[Self.lot(language:language)],"total":1,"nearExpiryIngredientCount":0,"expiredIngredientCount":0] }
    else if path.hasSuffix("ingredient-combinations") { value = ["items":[Self.combination(language:language)],"total":1] }
    else { value = NSNull() }
    let bytes = try! JSONSerialization.data(withJSONObject: ["code":code,"message":"fixture","requestId":"test-ingredient","data":value])
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!,statusCode: code == 0 ? 200 : 503,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
    client?.urlProtocol(self,didLoad:bytes);client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
final class QFIngredientDiscoveryTests: XCTestCase {
  private var service = ""
  override func setUp() { super.setUp(); service = "com.talka.ingredients-test." + UUID().uuidString; QFIngredientTestTransport.requests = []; QFIngredientTestTransport.failCatalog = false }
  override func tearDownWithError() throws { for key in ["current","device-id","credential-test"] { try QFKeychainStore(service:service).remove(key) }; try super.tearDownWithError() }
  @MainActor private func session() async throws -> QFAppSession {
    let identity = QFDeviceIdentity(service: service), config = URLSessionConfiguration.ephemeral; config.protocolClasses = [QFIngredientTestTransport.self]
    let api = QFAPIClient(environment:QFAPIEnvironment(name:"ingredient-test",baseURL:URL(string:"https://ingredient.invalid/api/v1")),identity:identity,transportConfiguration:config);api.recordsRequests = false
    let app = QFAppSession(api:api,identity:identity,keychain:QFKeychainStore(service:service));await app.start();try await app.login(agreementAccepted:true);return app
  }
  @MainActor private func descendants<T:UIView>(_ type:T.Type,_ root:UIView)->[T] { ((root as? T).map{[$0]} ?? []) + root.subviews.flatMap{descendants(type,$0)} }
  @MainActor private func eventually(_ condition:()->Bool) async throws { let limit=Date().addingTimeInterval(5);while !condition() && Date()<limit { try await Task.sleep(nanoseconds:20_000_000) };XCTAssertTrue(condition());if !condition(){throw NSError(domain:"IngredientTestTimeout",code:1)} }
  @MainActor private func show(_ controller:UIViewController)->UIWindow { let scene=UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first;let window=scene.map{UIWindow(windowScene:$0)} ?? UIWindow(frame:UIScreen.main.bounds);window.rootViewController=QFNavigationController(rootViewController:controller);window.makeKeyAndVisible();controller.loadViewIfNeeded();window.layoutIfNeeded();return window }
  @MainActor private func tap(_ id:String,_ root:UIView) throws { try XCTUnwrap(descendants(UIButton.self,root).first{$0.accessibilityIdentifier==id}).sendActions(for:.touchUpInside) }
  @MainActor private func chooseFirstIngredient(_ controller:QFIngredientCombinationsViewController) async throws {
    try tap("combination.add",controller.view)
    let picker = try XCTUnwrap(controller.navigationController?.topViewController as? QFIngredientCatalogViewController)
    picker.loadViewIfNeeded();let list = try XCTUnwrap(descendants(UICollectionView.self,picker.view).first)
    try await eventually{(list.numberOfSections > 0 ? list.numberOfItems(inSection:0) : 0)>0}
    list.delegate?.collectionView?(list,didSelectItemAt:IndexPath(item:0,section:0))
    try await eventually{controller.navigationController?.topViewController===controller}
    try await eventually{self.descendants(UIButton.self,controller.view).contains{$0.accessibilityIdentifier == "combination.plan."+QFIngredientTestTransport.recipeID}}
  }
  @MainActor func testCatalogQueriesLocaleScopeAndCategory() async throws {
    let app=try await session();let original=app.interfaceLanguage;defer{_ = app.setInterfaceLanguage(original)};_ = app.setInterfaceLanguage("fr");let c=QFIngredientCatalogViewController(app:app);let window=show(c);defer{window.isHidden=true}
    let list=try XCTUnwrap(descendants(UICollectionView.self,c.view).first);try await eventually{(list.numberOfSections > 0 ? list.numberOfItems(inSection:0) : 0)==20}
    let request=try XCTUnwrap(QFIngredientTestTransport.requests.first{$0.url?.path.hasSuffix("catalog")==true});XCTAssertEqual(request.value(forHTTPHeaderField:"Accept-Language"),"fr");XCTAssertTrue(request.url!.query!.contains("inventoryScope=personal"))
    try tap("catalog.category.FRUIT",c.view);try await eventually{QFIngredientTestTransport.requests.contains{$0.url?.query?.contains("category=FRUIT")==true}}
  }
  @MainActor func testCatalogMJRefreshAppendsSecondPageWithoutDuplicates() async throws {
    let app=try await session(),c=QFIngredientCatalogViewController(app:app);let window=show(c);defer{window.isHidden=true}
    let list=try XCTUnwrap(descendants(UICollectionView.self,c.view).first);try await eventually{(list.numberOfSections > 0 ? list.numberOfItems(inSection:0) : 0)==20};await list.mj_footer?.beginRefreshing()
    try await eventually{(list.numberOfSections > 0 ? list.numberOfItems(inSection:0) : 0)==40};XCTAssertTrue(QFIngredientTestTransport.requests.contains{$0.url?.query?.contains("page=1")==true})
  }
  @MainActor func testFailedNewCategoryDoesNotShowPreviousResults() async throws {
    let app=try await session(),c=QFIngredientCatalogViewController(app:app);let window=show(c);defer{window.isHidden=true}
    let list=try XCTUnwrap(descendants(UICollectionView.self,c.view).first);try await eventually{(list.numberOfSections > 0 ? list.numberOfItems(inSection:0) : 0)==20};QFIngredientTestTransport.failCatalog=true;try tap("catalog.category.FRUIT",c.view)
    try await eventually{(list.numberOfSections > 0 ? list.numberOfItems(inSection:0) : 0)==0 && list.backgroundView != nil}
  }
  @MainActor func testCombinationWaitsForSelectionAndShowsUnconfirmedAmount() async throws {
    let app=try await session(),c=QFIngredientCombinationsViewController(app:app);let window=show(c);defer{window.isHidden=true}
    XCTAssertFalse(QFIngredientTestTransport.requests.contains{$0.url?.path.hasSuffix("ingredient-combinations")==true});try await chooseFirstIngredient(c)
    let request=try XCTUnwrap(QFIngredientTestTransport.requests.first{$0.url?.path.hasSuffix("ingredient-combinations")==true});XCTAssertTrue(request.url!.query!.contains(QFIngredientTestTransport.ingredientID))
    XCTAssertTrue(descendants(UILabel.self,c.view).contains{$0.text?.contains(app.text("用量待确认","Quantity needs confirmation"))==true})
    XCTAssertFalse(QFIngredientTestTransport.requests.contains{$0.httpMethod=="PUT" || $0.httpMethod=="DELETE"})
    try tap("combination.plan."+QFIngredientTestTransport.recipeID,c.view);XCTAssertTrue(c.navigationController?.topViewController is QFAddRecipePlanViewController)
    XCTAssertFalse(QFIngredientTestTransport.requests.contains{$0.httpMethod=="PUT"})
  }
  @MainActor func testFreeSelectionUsesCatalogInsteadOfOnlyInventory() async throws {
    let app=try await session(),c=QFIngredientCombinationsViewController(app:app);let window=show(c);defer{window.isHidden=true}
    let tabs=try XCTUnwrap(descendants(UISegmentedControl.self,c.view).first);tabs.selectedSegmentIndex=1;tabs.sendActions(for:.valueChanged);try await chooseFirstIngredient(c)
    XCTAssertTrue(QFIngredientTestTransport.requests.contains{$0.url?.path.hasSuffix("catalog")==true})
    XCTAssertFalse(QFIngredientTestTransport.requests.contains{$0.url?.path.hasSuffix("me/inventory")==true})
  }
  func testInventoryUnitChangeIsExactAndPreservesDraftAcrossRestart() throws {
    let lot=try JSONDecoder().decode(QFInventoryLot.self,from:JSONSerialization.data(withJSONObject:QFIngredientTestTransport.lot()))
    let units=[QFMeasurementUnit(code:"g",dimension:"MASS",symbol:"g",name:"g",factorToBase:"1",decimalAllowed:true),QFMeasurementUnit(code:"kg",dimension:"MASS",symbol:"kg",name:"kg",factorToBase:"1000",decimalAllowed:true)]
    var draft=QFInventoryInlineDraft(lot:lot);XCTAssertTrue(draft.convertUnit(to:units[1],units:units));XCTAssertEqual(draft.quantity,"0.5");XCTAssertEqual(draft.effectiveUnitCode,"kg")
    let recovered=try JSONDecoder().decode(QFInventoryInlineDraft.self,from:JSONEncoder().encode(draft));XCTAssertEqual(recovered.effectiveUnitCode,"kg");XCTAssertEqual(recovered.lot.currentQuantity,"500")
    let box=QFMeasurementUnit(code:"box",dimension:"COUNT",symbol:"box",name:"box",factorToBase:"1",decimalAllowed:false);XCTAssertFalse(draft.convertUnit(to:box,units:units+[box]))
  }
  @MainActor func testDedicatedArtworkUsesServerKeyWithUUID() throws {
    let tomato=QFInventoryArtwork.make(ingredientID:QFIngredientTestTransport.ingredientID,category:"VEGETABLE",iconKey:"tomato")
    let image=try XCTUnwrap(descendants(UIImageView.self,tomato).first?.image);XCTAssertEqual(image.pngData(),UIImage(named:"ingredient-tomato")?.pngData())
  }
  @MainActor func testTenLanguagesCatalogAndCombinationScreens() async throws {
    let app=try await session(), original=app.interfaceLanguage
    defer{_ = app.setInterfaceLanguage(original)}
    for language in ["zh-Hans","zh-Hant","en","ja","ko","ru","es","fr","de","pt-BR"] {
      _ = app.setInterfaceLanguage(language)
      let catalog=QFIngredientCatalogViewController(app:app),window=show(catalog);let list=try XCTUnwrap(descendants(UICollectionView.self,catalog.view).first);try await eventually{(list.numberOfSections > 0 ? list.numberOfItems(inSection:0) : 0)==20};window.layoutIfNeeded()
      let first=XCTAttachment(image:UIGraphicsImageRenderer(bounds:window.bounds).image{ _ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)});first.name="Ingredient02-"+language;first.lifetime = .keepAlways;add(first);window.isHidden=true
      let combination=QFIngredientCombinationsViewController(app:app),secondWindow=show(combination);try await chooseFirstIngredient(combination);secondWindow.layoutIfNeeded()
      let second=XCTAttachment(image:UIGraphicsImageRenderer(bounds:secondWindow.bounds).image{ _ in secondWindow.drawHierarchy(in:secondWindow.bounds,afterScreenUpdates:true)});second.name="Ingredient03-"+language;second.lifetime = .keepAlways;add(second);secondWindow.isHidden=true
    }
  }
}
