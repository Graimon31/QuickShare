import 'package:quickshare/core/network/direct_link_coordinator.dart';
import 'package:quickshare/features/receiver/data/transports/bluetooth_receiver_transport.dart';

/// The receiver side of the rendezvous' signal channel.
///
/// Directives come in over the metadata characteristic; the receiver never
/// sends one — it does not decide who hosts, it is told. What goes out is
/// the credentials of the network it was asked to raise.
class ReceiverLinkSignal implements DirectLinkSignal {
  final BleReceiver _transport;

  ReceiverLinkSignal(this._transport);

  @override
  Future<void> sendDirective(DirectLinkDirective directive) =>
      throw UnsupportedError('a receiver sends no directives');

  @override
  Stream<DirectLinkDirective> get directives => _transport.linkDirectives;

  @override
  Future<void> sendApOffer(String sealed) => _transport.sendApOffer(sealed);

  @override
  Stream<String> get apOffers => const Stream.empty();

  @override
  Future<void> sendKeyExchange(String publicKey) =>
      _transport.sendKeyExchange(publicKey);

  /// The sender's public half arrives inside the directive, not on a channel
  /// of its own — it is already travelling that way and one frame is one
  /// fewer thing to lose.
  @override
  Stream<String> get peerKeys => const Stream.empty();
}
