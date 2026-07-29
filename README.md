# YeelightKit

A Swift package for discovering and controlling **Yeelight** smart lights over
the LAN — no cloud, no vendor SDK. Pure Swift with `async`/`await`, no UI
framework dependency, so it works in an app, a CLI or on a server.

> Unofficial. Not affiliated with or endorsed by Yeelight / Qingdao Yeelink.

```swift
let devices = await YeelightDiscovery().scan()

guard let light = devices.first else { return }
let connection = YeelightConnection(device: light)
try await connection.connect()

try await connection.setPower(true)
try await connection.setBrightness(60)

for await state in await connection.states() {
    print(state.isOn, state.brightness ?? 0)
}

await connection.close()   // release the device's connection slot
```

## Install

```swift
.package(url: "https://github.com/wakawakayashi/YeelightKit", from: "0.1.0")
```

Requires macOS 13 / iOS 16 or later.

## Why this exists

The protocol is simple but full of traps that cost real debugging time. The ones
this package handles for you:

**A device accepts only 4 simultaneous TCP connections.** Beyond that it accepts
the TCP handshake and then never answers, which looks exactly like a dead light.
An `NWConnection` that is dropped without being cancelled keeps its slot until
the device is power cycled. `YeelightConnection` cancels on `close()` and in
`deinit`.

**Each connection has a quota of 60 commands per minute.** Anything animated has
to pace itself — see `YeelightConnection.minimumCommandInterval`.

**Methods outside the device's `support` list are rejected.** Models differ
sharply: a Monitor Light Bar Pro (`lamp15`) has no `set_rgb` on its main light
and puts colour on its *background* light, while a colour bulb (`colore`) has
full RGB on the main light and no background light at all. Use
`device.colorMethod` or `setColorOnAvailableEndpoint(rgb:)` instead of assuming.

**`main_power` is not `power`.** On a device with a background light, `power`
describes the device as a whole and reads `"on"` whenever the ambient light is
lit, while `main_power` is the main light. Notifications carry only
`main_power`. Reading `power` alone shows a switched-off light bar as on.

**An unsupported property answers with `""`, not an error.** Empty values must
not be parsed as real state.

**Discovery needs one search per interface.** A Mac docked over Ethernet while
also on Wi-Fi has two interfaces on one subnet; a single multicast leaves
through whichever the routing table prefers, which is frequently not the one the
lights answer on.

`set_bright`, `set_ct_abx` and `set_rgb` are also only accepted **while the
light is on**.

## Local network permission

Discovery is SSDP multicast, and control opens a direct TCP connection, so an
app must declare `NSLocalNetworkUsageDescription` in its Info.plist. Without the
user's approval the system drops the traffic **silently** — no error, just no
devices found.

## Status

Early. The API may still change before 1.0.

- Discovery, connection, state streaming and the common commands are implemented
- 20 unit tests cover response parsing, capability routing, state merging,
  colour conversion and argument validation
- The behaviours documented above were established against real `lamp15` and
  `colore` hardware
- **End-to-end discovery is not yet verified from this package.** It returns no
  devices when run from a command-line test binary, while the identical socket
  sequence in another process succeeds at the same moment — consistent with the
  local network privacy gate, but unconfirmed. Verification from a host app that
  already holds the permission is the next step.

Not implemented yet: music mode (`set_music`, which lifts the command quota),
colour flow (`start_cf`), cron/sleep timers, scenes.

## Licence

MIT
