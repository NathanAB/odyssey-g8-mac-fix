import CoreGraphics
import Foundation
import IOKit

struct Identity: Hashable, CustomStringConvertible {
  let vendor: UInt16
  let product: UInt16

  var description: String { String(format: "vendor 0x%04X product 0x%04X", vendor, product) }
}

extension Identity {
  init?(edid: Data) {
    guard edid.count >= 128 else { return nil }
    vendor = UInt16(edid[8]) << 8 | UInt16(edid[9])
    product = UInt16(edid[11]) << 8 | UInt16(edid[10])
  }

  init(display: CGDirectDisplayID) {
    vendor = UInt16(truncatingIfNeeded: CGDisplayVendorNumber(display))
    product = UInt16(truncatingIfNeeded: CGDisplayModelNumber(display))
  }
}

let samsung: UInt16 = 0x4C2D
// The G85SB reconnects as 0x72F2 when Game Mode is on, and macOS never adds a display with that EDID.
let identitiesToReplace: Set<Identity> = [Identity(vendor: samsung, product: 0x72F2)]
// Highest refresh rate first. 0x72F5 (Game Mode off) runs at up to 120Hz, and 0x7306 (Input Signal Plus off) runs at up to 75Hz.
let preferenceOrder = [Identity(vendor: samsung, product: 0x72F5), Identity(vendor: samsung, product: 0x7306)]

struct SavedEDID {
  let identity: Identity
  let edid: Data
}

extension SavedEDID {
  init?(edid: Data) {
    guard edid.count % 128 == 0, let identity = Identity(edid: edid) else { return nil }
    self.init(identity: identity, edid: edid)
  }

  var fileName: String { String(format: "%04X.bin", identity.product) }
}

func inPreferenceOrder(_ saved: [SavedEDID]) -> [SavedEDID] {
  func rank(_ entry: SavedEDID) -> (Int, UInt16, UInt16) {
    (preferenceOrder.firstIndex(of: entry.identity) ?? preferenceOrder.count, entry.identity.vendor, entry.identity.product)
  }
  return saved.sorted { rank($0) < rank($1) }
}

enum Verdict: String {
  case matchesSaved = "matches a saved EDID"
  case replace = "Game Mode identity macOS rejects"
  case leaveAlone = "left alone"
}

func verdict(_ edid: Data, saved: [SavedEDID]) -> Verdict {
  if saved.contains(where: { $0.edid == edid }) { return .matchesSaved }
  guard let identity = Identity(edid: edid), identitiesToReplace.contains(identity) else { return .leaveAlone }
  return .replace
}

let edidDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ODYSSEY_G8_EDID_DIR"]
  ?? NSHomeDirectory() + "/Library/Application Support/odyssey-g8-mac-fix/edids")

func loadSavedEDIDs() -> [SavedEDID] {
  let files = (try? FileManager.default.contentsOfDirectory(at: edidDirectory, includingPropertiesForKeys: nil)) ?? []
  return inPreferenceOrder(files.filter { $0.pathExtension == "bin" }.map { file in
    guard let data = FileManager.default.contents(atPath: file.path), let saved = SavedEDID(edid: data) else {
      fail("\(file.path) is not an EDID. Delete it, then run capture again.")
    }
    return saved
  })
}

func save(_ edid: Data) -> URL {
  guard let saved = SavedEDID(edid: edid) else {
    fail("Could not save a \(edid.count)-byte EDID. An EDID is a multiple of 128 bytes.")
  }
  let url = edidDirectory.appendingPathComponent(saved.fileName)
  do {
    try FileManager.default.createDirectory(at: edidDirectory, withIntermediateDirectories: true)
    try edid.write(to: url, options: .atomic)
  } catch {
    fail("Could not save the EDID to \(url.path): \(error.localizedDescription)")
  }
  return url
}

// The first release saved one EDID as replacement-edid.bin, next to the folder that holds them now.
func importLegacyEDID() {
  let legacy = edidDirectory.deletingLastPathComponent().appendingPathComponent("replacement-edid.bin")
  guard let edid = FileManager.default.contents(atPath: legacy.path) else { return }
  say("moved \(legacy.path) to \(save(edid).path)")
  try? FileManager.default.removeItem(at: legacy)
}

func describe(_ saved: [SavedEDID]) -> String {
  guard !saved.isEmpty else { return "no saved EDIDs in \(edidDirectory.path)" }
  return "saved EDIDs, in the order the helper tries them: " + saved.map(\.identity.description).joined(separator: ", ")
}

let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

func privateFunction<T>(_ name: String, _: T.Type) -> T {
  guard let pointer = dlsym(iokit, name) else { fail("\(name) is missing from this version of macOS. Run uninstall.sh.") }
  return unsafeBitCast(pointer, to: T.self)
}

let createAVService = privateFunction(
  "IOAVServiceCreateWithService", (@convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?).self)
let copyEDID = privateFunction(
  "IOAVServiceCopyEDID", (@convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn).self)
let setVirtualEDID = privateFunction(
  "IOAVServiceSetVirtualEDIDMode", (@convention(c) (CFTypeRef, UInt32, CFData?) -> IOReturn).self)

struct Display {
  let name: String
  let av: CFTypeRef
  let edid: Data

  var identity: String { Identity(edid: edid).map(String.init(describing:)) ?? "unrecognized \(edid.count)-byte EDID" }
}

// The EDID may not be readable the instant a reconnecting monitor's service is published.
let edidAttempts = 10
let edidRetryDelay = 0.5

func readDisplay(_ service: io_service_t, name: String) -> Display? {
  for attempt in 1...edidAttempts {
    var out: Unmanaged<CFData>?
    if let av = createAVService(kCFAllocatorDefault, service)?.takeRetainedValue(),
      copyEDID(av, &out) == kIOReturnSuccess, let edid = out?.takeRetainedValue() as Data?
    {
      return Display(name: name, av: av, edid: edid)
    }
    say("\(name): EDID not readable yet, try \(attempt) of \(edidAttempts)")
    if attempt < edidAttempts { Thread.sleep(forTimeInterval: edidRetryDelay) }
  }
  say("\(name): EDID never became readable, left alone")
  return nil
}

func eachExternalDisplay(_ iterator: io_iterator_t, _ body: (Display) -> Void) {
  while case let service = IOIteratorNext(iterator), service != 0 {
    defer { IOObjectRelease(service) }
    let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue() as? String
    guard location == "External" else { continue }
    var id: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(service, &id)
    if let display = readDisplay(service, name: String(format: "service 0x%llx", id)) { body(display) }
  }
}

func connectedServices() -> io_iterator_t {
  var iterator: io_iterator_t = 0
  IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator)
  return iterator
}

func onlineIdentities() -> Set<Identity> {
  var displays = [CGDirectDisplayID](repeating: 0, count: 32)
  var count: UInt32 = 0
  guard CGGetOnlineDisplayList(UInt32(displays.count), &displays, &count) == .success else {
    fail("Could not ask macOS which displays are online.")
  }
  return Set(displays.prefix(Int(count)).map(Identity.init(display:)))
}

func report(_ display: Display, _ verdict: Verdict) {
  say("\(display.name): \(display.identity), \(verdict.rawValue)")
}

// Reads the saved EDIDs on every connect, so an EDID captured while the helper runs takes effect without a restart.
func reconcile(_ display: Display) {
  let saved = loadSavedEDIDs()
  let verdict = verdict(display.edid, saved: saved)
  report(display, verdict)
  guard verdict == .replace else { return }
  guard let replacement = saved.first else { return say("\(display.name): no saved EDID to apply") }
  say("\(display.name): applied saved \(replacement.identity), IOReturn \(hex(setVirtualEDID(display.av, 1, replacement.edid as CFData)))")
}

func watch() {
  let port = IONotificationPortCreate(kIOMainPortDefault)
  CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
  var iterator: io_iterator_t = 0
  let result = IOServiceAddMatchingNotification(
    port, kIOFirstMatchNotification, IOServiceMatching("DCPAVServiceProxy"),
    { _, iterator in eachExternalDisplay(iterator, reconcile) }, nil, &iterator)
  guard result == KERN_SUCCESS else { fail("Could not watch for displays, IOReturn \(hex(result))") }
  say("watching for displays, \(describe(loadSavedEDIDs()))")
  eachExternalDisplay(iterator, reconcile)
  CFRunLoopRun()
}

func capture() {
  var found: [Display] = []
  eachExternalDisplay(connectedServices()) { display in
    if Identity(edid: display.edid)?.vendor == samsung { found.append(display) }
  }
  guard let display = found.first else {
    fail("No Samsung monitor found. Connect the monitor with Game Mode off, wait for the picture, then run this again.")
  }
  guard found.count == 1 else {
    fail("Found \(found.count) Samsung monitors. Disconnect all but the Odyssey G8, then run this again.")
  }
  if let identity = Identity(edid: display.edid), identitiesToReplace.contains(identity) {
    fail("Game Mode is on. Turn Game Mode off in the monitor's menu, wait for the picture, then run this again.")
  }
  say("\(display.name): \(display.identity), saved to \(save(display.edid).path)")
  say(describe(loadSavedEDIDs()))
}

func hex(_ result: IOReturn) -> String { String(format: "0x%08X", UInt32(bitPattern: result)) }

func say(_ message: String, to stream: UnsafeMutablePointer<FILE> = stdout) {
  fputs("\(Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current))) \(message)\n", stream)
}

func fail(_ message: String) -> Never {
  say(message, to: stderr)
  exit(1)
}

// launchd points stdout at a file, which C buffers in blocks, so lines would reach the log late or never.
setvbuf(stdout, nil, _IOLBF, 0)

importLegacyEDID()

switch CommandLine.arguments.dropFirst().first {
case "watch":
  watch()
case "apply":
  eachExternalDisplay(connectedServices(), reconcile)
case "status":
  let saved = loadSavedEDIDs()
  let online = onlineIdentities()
  eachExternalDisplay(connectedServices()) { display in
    let verdict = verdict(display.edid, saved: saved)
    let isOnline = Identity(edid: display.edid).map(online.contains) ?? false
    say("\(display.name): \(display.identity), \(verdict.rawValue), \(isOnline ? "online" : "not online")")
  }
  say(describe(saved))
case "capture":
  capture()
case "reset":
  eachExternalDisplay(connectedServices()) { display in
    guard Identity(edid: display.edid)?.vendor == samsung else { return report(display, .leaveAlone) }
    say("\(display.name): reset to the monitor's own EDID, IOReturn \(hex(setVirtualEDID(display.av, 0, nil)))")
  }
default:
  fail("usage: odyssey-g8-mac-fix watch | apply | status | capture | reset")
}
