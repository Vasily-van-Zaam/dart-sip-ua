typedef RawSipHook = void Function(String direction, String data);

/// Global hook to tap raw SIP transport messages.
///
/// Direction values:
/// - 'OUTGOING' — before sending to the network
/// - 'INCOMING' — after receiving from the network
///
/// This is intentionally left nullable; production apps can leave it unset.
RawSipHook? rawSipHook;


