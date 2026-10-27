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
}

let samsung: UInt16 = 0x4C2D
// The G85SB reconnects as 0x72F2 when Game Mode is on, and macOS never adds a display with that EDID.
let identitiesToReplace: Set<Identity> = [Identity(vendor: samsung, product: 0x72F2)]

enum Verdict: String {
  case matchesReplacement = "matches the replacement EDID"
  case replace = "Game Mode identity macOS rejects"
  case leaveAlone = "left alone"
}

func verdict(_ edid: Data, replacement: Data) -> Verdict {
  if edid == replacement { return .matchesReplacement }
  guard let identity = Identity(edid: edid), identitiesToReplace.contains(identity) else { return .leaveAlone }
  return .replace
}

let replacementPath = ProcessInfo.processInfo.environment["ODYSSEY_G8_EDID_FILE"]
  ?? NSHomeDirectory() + "/Library/Application Support/odyssey-g8-mac-fix/replacement-edid.bin"

func loadReplacement() -> Data {
  guard let data = FileManager.default.contents(atPath: replacementPath) else {
    fail("Replacement EDID not found at \(replacementPath). Run install.sh.")
  }
  guard !data.isEmpty, data.count % 128 == 0 else {
    fail("Replacement EDID at \(replacementPath) is \(data.count) bytes. An EDID is a multiple of 128 bytes.")
  }
  return data
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

func report(_ display: Display, _ verdict: Verdict) {
  say("\(display.name): \(display.identity), \(verdict.rawValue)")
}

func reconcile(_ display: Display, replacement: Data) {
  let verdict = verdict(display.edid, replacement: replacement)
  report(display, verdict)
  guard verdict == .replace else { return }
  say("\(display.name): applied replacement EDID, IOReturn \(hex(setVirtualEDID(display.av, 1, replacement as CFData)))")
}

func watch(replacement: Data) {
  let port = IONotificationPortCreate(kIOMainPortDefault)
  CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
  let context = Unmanaged.passRetained(replacement as NSData).toOpaque()
  var iterator: io_iterator_t = 0
  let result = IOServiceAddMatchingNotification(
    port, kIOFirstMatchNotification, IOServiceMatching("DCPAVServiceProxy"),
    { context, iterator in
      let replacement = Unmanaged<NSData>.fromOpaque(context!).takeUnretainedValue() as Data
      eachExternalDisplay(iterator) { reconcile($0, replacement: replacement) }
    }, context, &iterator)
  guard result == KERN_SUCCESS else { fail("Could not watch for displays, IOReturn \(hex(result))") }
  say("watching for displays")
  eachExternalDisplay(iterator) { reconcile($0, replacement: replacement) }
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
  let url = URL(fileURLWithPath: replacementPath)
  do {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try display.edid.write(to: url, options: .atomic)
  } catch {
    fail("Could not save the EDID to \(replacementPath): \(error.localizedDescription)")
  }
  say("\(display.name): \(display.identity), saved to \(replacementPath)")
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

switch CommandLine.arguments.dropFirst().first {
case "watch":
  watch(replacement: loadReplacement())
case "apply":
  let replacement = loadReplacement()
  eachExternalDisplay(connectedServices()) { reconcile($0, replacement: replacement) }
case "status":
  let replacement = loadReplacement()
  eachExternalDisplay(connectedServices()) { report($0, verdict($0.edid, replacement: replacement)) }
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
