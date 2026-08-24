import Foundation
import Network

#if canImport(FlutterMacOS)
import FlutterMacOS
#else
import Flutter
#endif

/// A direct device-to-device link over Apple's peer-to-peer Wi-Fi, exposed to
/// Dart as an ordinary TCP port on localhost.
///
/// The point is to add a *link*, not a transport. QHTP already carries
/// manifests, folders, multi-file sessions, resume and checksums, and all of
/// it is tested; rebuilding that on top of some framework's own file-sending
/// API would throw the tested part away. So this moves bytes and nothing else:
///
///     sender                                    receiver
///     QHTP server on :P                         QHTP client
///          ▲                                         │
///          │ 127.0.0.1                    127.0.0.1  ▼
///     ┌────┴─────┐                            ┌──────┴───┐
///     │  host()  │◄═══ peer-to-peer Wi-Fi ═══►│  join()  │
///     └──────────┘                            └──────────┘
///
/// `join` hands Dart a localhost port. Everything written to it comes out of
/// the sender's QHTP port, so the existing client talks to 127.0.0.1 and is
/// otherwise untouched.
///
/// `includePeerToPeer` is what brings AWDL up — the same radio path AirDrop
/// uses, and the only one that works between two Apple devices with no router,
/// since neither iOS nor macOS can raise a hotspot for the other. If the two
/// happen to share a network, the system may route over that instead; either
/// way it is Wi-Fi speed rather than Bluetooth's.
public class PeerLinkPlugin: NSObject, FlutterStreamHandler {
  private static let serviceType = "_directdrop._tcp"

  private let queue = DispatchQueue(label: "quickshare.peerlink", qos: .userInitiated)
  private var eventSink: FlutterEventSink?

  /// Host role: accepts peers and forwards each one to the local QHTP port.
  private var peerListener: NWListener?
  /// Guest role: accepts local QHTP clients and forwards each one to the peer.
  private var localListener: NWListener?
  private var browser: NWBrowser?
  private var peerEndpoint: NWEndpoint?
  /// The AWDL interface the peer was seen on, when it was seen on one.
  private var peerInterface: NWInterface?
  private var bridges: [Bridge] = []

  private var forwardToPort: UInt16 = 0
  private var joinResult: FlutterResult?
  private var joinTimeout: DispatchWorkItem?

  /// Interfaces this link must never travel over, discovered at startup.
  private var excludedInterfaces: [NWInterface] = []
  private let pathMonitor = NWPathMonitor()

  /// Held open only long enough to let the direct path appear before settling
  /// for whatever else can reach the peer.
  private var graceTimer: DispatchWorkItem?
  private var fallbackCandidate: (endpoint: NWEndpoint, interfaces: [NWInterface])?

  override init() {
    super.init()
    // Which interfaces exist is not something to guess at connect time: a VPN
    // comes and goes, and its tunnel is exactly the path that must not be
    // taken. Watch continuously and keep the exclusion list current.
    pathMonitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      self.excludedInterfaces = path.availableInterfaces.filter(Self.isTunnel)
    }
    pathMonitor.start(queue: queue)
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PeerLinkPlugin()
    #if canImport(FlutterMacOS)
    let messenger = registrar.messenger
    #else
    let messenger = registrar.messenger()
    #endif
    let method = FlutterMethodChannel(name: "quickshare/peerlink", binaryMessenger: messenger)
    let events = FlutterEventChannel(name: "quickshare/peerlink/events", binaryMessenger: messenger)
    method.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
    events.setStreamHandler(instance)
    objc_setAssociatedObject(method, "peerlink.instance", instance, .OBJC_ASSOCIATION_RETAIN)
  }

  // MARK: FlutterStreamHandler

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func emit(_ payload: [String: Any]) {
    guard let sink = eventSink else { return }
    DispatchQueue.main.async { sink(payload) }
  }

  // MARK: Method dispatch

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "host":
      guard let args = call.arguments as? [String: Any],
            let name = args["serviceName"] as? String,
            let port = args["localPort"] as? Int,
            let localPort = UInt16(exactly: port) else {
        result(FlutterError(code: "BAD_ARGS", message: "serviceName/localPort required", details: nil))
        return
      }
      host(serviceName: name, forwardTo: localPort, result: result)

    case "join":
      guard let args = call.arguments as? [String: Any],
            let name = args["serviceName"] as? String else {
        result(FlutterError(code: "BAD_ARGS", message: "serviceName required", details: nil))
        return
      }
      let timeout = (args["timeoutMs"] as? Int) ?? 20000
      join(serviceName: name, timeoutMs: timeout, result: result)

    case "stop":
      stop()
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Host

  private func host(serviceName: String, forwardTo localPort: UInt16, result: @escaping FlutterResult) {
    stopHosting()
    forwardToPort = localPort

    do {
      let listener = try NWListener(using: self.peerParameters())
      listener.service = NWListener.Service(name: serviceName, type: Self.serviceType)

      listener.newConnectionHandler = { [weak self] incoming in
        guard let self else { return }
        // One localhost socket per peer connection: QHTP opens several, and
        // sharing one would interleave two HTTP conversations into nonsense.
        let local = NWConnection(
          host: "127.0.0.1",
          port: NWEndpoint.Port(rawValue: self.forwardToPort) ?? .any,
          using: Self.localParameters()
        )
        self.bridge(incoming, local)
      }

      listener.stateUpdateHandler = { [weak self] state in
        switch state {
        case .ready:
          self?.emit(["type": "hosting", "service": serviceName])
        case .failed(let error):
          self?.emit(["type": "failed", "error": "\(error)"])
        default:
          break
        }
      }

      listener.start(queue: queue)
      peerListener = listener
      result(nil)
    } catch {
      result(FlutterError(code: "HOST_FAILED", message: "\(error)", details: nil))
    }
  }

  // MARK: Join

  private func join(serviceName: String, timeoutMs: Int, result: @escaping FlutterResult) {
    stopJoining()
    joinResult = result

    let timeout = DispatchWorkItem { [weak self] in
      self?.finishJoin(.failure("no peer named \(serviceName) appeared"))
    }
    joinTimeout = timeout
    queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeout)

    let browser = NWBrowser(
      for: .bonjour(type: Self.serviceType, domain: nil),
      using: self.peerParameters()
    )
    browser.browseResultsChangedHandler = { [weak self] results, _ in
      guard let self, self.peerEndpoint == nil else { return }
      for found in results {
        guard case let .service(name, _, _, _) = found.endpoint, name == serviceName else { continue }

        let direct = found.interfaces.first(where: Self.isPeerToPeer)
        if direct == nil {
          // Seen, but not yet on the direct path. Taking it now is how a
          // transfer between two devices in one room ends up going out to a
          // VPN server, or down a USB cable, at a fraction of the speed the
          // radio would give. Bonjour answers over the direct link a moment
          // later than over an established route, so hold the first sighting
          // aside and give that moment a chance.
          if self.fallbackCandidate == nil {
            self.fallbackCandidate = (found.endpoint, found.interfaces)
            self.startGracePeriod(serviceName: serviceName)
          }
          continue
        }

        self.settle(on: found.endpoint,
                    interface: direct,
                    seenOn: found.interfaces,
                    serviceName: serviceName)
        return
      }
    }
    browser.stateUpdateHandler = { [weak self] state in
      if case .failed(let error) = state {
        self?.finishJoin(.failure("browsing failed: \(error)"))
      }
    }
    browser.start(queue: queue)
    self.browser = browser
  }

  /// Waits briefly for the direct path before accepting a lesser one.
  private func startGracePeriod(serviceName: String) {
    graceTimer?.cancel()
    let timer = DispatchWorkItem { [weak self] in
      guard let self, self.peerEndpoint == nil,
            let candidate = self.fallbackCandidate else { return }
      // No direct path appeared. Connect anyway rather than failing: a slower
      // link beats telling the user the other device is not there. The VPN is
      // still excluded outright below, so this is a route around it, never
      // through it.
      self.settle(on: candidate.endpoint,
                  interface: nil,
                  seenOn: candidate.interfaces,
                  serviceName: serviceName)
    }
    graceTimer = timer
    queue.asyncAfter(deadline: .now() + .milliseconds(2500), execute: timer)
  }

  private func settle(on endpoint: NWEndpoint,
                      interface: NWInterface?,
                      seenOn interfaces: [NWInterface],
                      serviceName: String) {
    graceTimer?.cancel()
    graceTimer = nil
    peerEndpoint = endpoint
    peerInterface = interface
    emit([
      "type": "peerFound",
      "service": serviceName,
      "direct": interface != nil,
      "interface": interface?.name ?? "none",
      "seenOn": interfaces.map(\.name).joined(separator: ","),
      "excluded": excludedInterfaces.map(\.name).joined(separator: ","),
    ])
    openLocalDoor()
  }

  /// Opens the localhost port Dart will point the QHTP client at.
  private func openLocalDoor() {
    do {
      let listener = try NWListener(using: Self.localParameters(), on: .any)

      listener.newConnectionHandler = { [weak self] local in
        guard let self, let endpoint = self.peerEndpoint else { return }
        let peer = NWConnection(
          to: endpoint,
          using: self.peerParameters(pinnedTo: self.peerInterface)
        )
        self.bridge(local, peer)
      }

      listener.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          guard let port = listener.port?.rawValue else {
            self.finishJoin(.failure("the local door opened without a port"))
            return
          }
          self.finishJoin(.success(Int(port)))
        case .failed(let error):
          self.finishJoin(.failure("could not open a local port: \(error)"))
        default:
          break
        }
      }

      listener.start(queue: queue)
      localListener = listener
    } catch {
      finishJoin(.failure("could not open a local port: \(error)"))
    }
  }

  private enum JoinOutcome {
    case success(Int)
    case failure(String)
  }

  private func finishJoin(_ outcome: JoinOutcome) {
    guard let pending = joinResult else { return }
    joinResult = nil
    joinTimeout?.cancel()
    joinTimeout = nil

    switch outcome {
    case .success(let port):
      emit(["type": "linked", "port": port])
      DispatchQueue.main.async { pending(port) }
    case .failure(let reason):
      emit(["type": "failed", "error": reason])
      DispatchQueue.main.async {
        pending(FlutterError(code: "JOIN_FAILED", message: reason, details: nil))
      }
    }
  }

  // MARK: Plumbing

  private func bridge(_ a: NWConnection, _ b: NWConnection) {
    let bridge = Bridge(a: a, b: b, queue: queue) { [weak self] finished in
      guard let self else { return }
      self.queue.async {
        self.bridges.removeAll { $0 === finished }
      }
    }
    bridges.append(bridge)
    bridge.start()
  }

  /// Torn down by role rather than all at once.
  ///
  /// A blanket teardown at the top of each entry point meant `join` killed an
  /// active `host`, which is only invisible because a device is normally one
  /// or the other. It is not invisible to a test that plays both parts on one
  /// machine to check the plumbing without a second device in the room.
  private func stopHosting() {
    peerListener?.cancel()
    peerListener = nil
  }

  private func stopJoining() {
    graceTimer?.cancel()
    graceTimer = nil
    fallbackCandidate = nil
    localListener?.cancel()
    localListener = nil
    browser?.cancel()
    browser = nil
    peerEndpoint = nil
    joinTimeout?.cancel()
    joinTimeout = nil
    joinResult = nil
  }

  private func stop() {
    stopHosting()
    stopJoining()
    for bridge in bridges { bridge.cancel() }
    bridges.removeAll()
  }

  /// Whether an interface is Apple's peer-to-peer Wi-Fi rather than an
  /// ordinary network.
  private static func isPeerToPeer(_ interface: NWInterface) -> Bool {
    interface.name.hasPrefix("awdl") || interface.name.hasPrefix("llw")
  }

  /// A VPN or other tunnel. Never a valid path for a link that exists
  /// precisely because the two devices can reach each other without one.
  private static func isTunnel(_ interface: NWInterface) -> Bool {
    interface.type == .other &&
      (interface.name.hasPrefix("utun") ||
       interface.name.hasPrefix("ipsec") ||
       interface.name.hasPrefix("ppp") ||
       interface.name.hasPrefix("tun"))
  }

  /// Parameters that let the system bring up peer-to-peer Wi-Fi.
  ///
  /// `includePeerToPeer` only *permits* the peer-to-peer path; it does not
  /// choose it. Left to itself the system takes whatever route already
  /// reaches the peer, and on a machine with a VPN up that route can be the
  /// tunnel — a transfer between two devices in the same room going out to a
  /// VPN server and back. Measured that way: 1.0 MB/s, with `awdl0` carrying
  /// no traffic at all while 53 MB went out over `utun18`.
  ///
  /// So when the peer was actually found on an AWDL interface, the connection
  /// is pinned to it. Nothing is lost by being explicit — that interface
  /// exists precisely because the two devices can talk directly.
  private func peerParameters(pinnedTo interface: NWInterface? = nil) -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
    if let interface {
      parameters.requiredInterface = interface
    }
    // Belt as well as braces. Pinning says where to go; this says where not
    // to, and it holds even when no direct interface was offered to pin to.
    // Without it a link between two devices in the same room can be routed
    // into a VPN tunnel and out to a server somewhere, which is both absurdly
    // slow and the opposite of what "direct" is supposed to mean.
    if !excludedInterfaces.isEmpty {
      parameters.prohibitedInterfaces = excludedInterfaces
    }
    if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
      // Bulk transfer in one direction: waiting to coalesce small writes only
      // adds latency to the far side's next request.
      tcp.noDelay = true
    }
    return parameters
  }

  /// Loopback only — the local half of the tunnel must never leave the device.
  private static func localParameters() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.requiredInterfaceType = .loopback
    if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
      tcp.noDelay = true
    }
    return parameters
  }
}

/// Copies bytes between two connections until either end goes away.
///
/// Deliberately dumb: it knows nothing about HTTP, QHTP, or files. Anything
/// that can talk to a TCP port can be carried, which is what keeps the tested
/// transfer code untouched.
private final class Bridge {
  private let a: NWConnection
  private let b: NWConnection
  private let queue: DispatchQueue
  private let onClose: (Bridge) -> Void

  private var readyCount = 0
  private var finishedDirections = 0
  private var closed = false

  init(a: NWConnection, b: NWConnection, queue: DispatchQueue, onClose: @escaping (Bridge) -> Void) {
    self.a = a
    self.b = b
    self.queue = queue
    self.onClose = onClose
  }

  func start() {
    for connection in [a, b] {
      connection.stateUpdateHandler = { [weak self] state in
        guard let self else { return }
        switch state {
        case .ready:
          self.readyCount += 1
          // Only once both halves exist is there anywhere to put the bytes.
          if self.readyCount == 2 {
            self.pump(from: self.a, to: self.b)
            self.pump(from: self.b, to: self.a)
          }
        case .failed, .cancelled:
          self.cancel()
        default:
          break
        }
      }
      connection.start(queue: queue)
    }
  }

  private func pump(from source: NWConnection, to sink: NWConnection) {
    // 64 KB at a time: large enough that the per-read overhead disappears
    // against the transfer, small enough not to sit on memory per connection.
    source.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
      guard let self, !self.closed else { return }

      if error != nil {
        self.cancel()
        return
      }

      if let data, !data.isEmpty {
        // `.contentProcessed` is the backpressure: the next read only starts
        // once this write has been handed off, so a slow side cannot make the
        // fast side queue the whole file in memory.
        sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
          guard let self, !self.closed else { return }
          if sendError != nil {
            self.cancel()
          } else if isComplete {
            self.halfClose(sink)
          } else {
            self.pump(from: source, to: sink)
          }
        })
        return
      }

      if isComplete {
        self.halfClose(sink)
      } else {
        self.pump(from: source, to: sink)
      }
    }
  }

  /// Passes on the end of one direction without killing the other.
  ///
  /// Tearing both connections down the moment either side said it was done
  /// cost the tail of every transfer: `cancel()` discards whatever is still
  /// queued, so the last bytes handed to the link never went out. Over
  /// loopback the queue drains instantly and it never showed; over the air a
  /// 64 MB transfer arrived 768 KB short and then hung waiting for the rest.
  ///
  /// TCP can close one direction at a time, which is exactly what is wanted
  /// here: flush what is queued, send the FIN, and let the other direction
  /// finish on its own terms.
  private func halfClose(_ sink: NWConnection) {
    sink.send(content: nil, contentContext: .finalMessage, isComplete: true,
              completion: .contentProcessed { [weak self] _ in
      guard let self else { return }
      self.finishedDirections += 1
      if self.finishedDirections >= 2 {
        self.cancel()
      }
    })
  }

  func cancel() {
    guard !closed else { return }
    closed = true
    a.cancel()
    b.cancel()
    onClose(self)
  }
}
