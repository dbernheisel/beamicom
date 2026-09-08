# Beamicom Host

Dependency-free contracts shared by Beamicom emulator cores and clients.

The host boundary is deliberately coarse. A core implements
`Beamicom.Host.System` to load media, run to its next output boundary, and
replace controller state. CPU instructions, bus accesses, timing, rendering,
and audio synthesis remain private to each core.

Core output is represented by `Beamicom.Host.VideoFrame` and
`Beamicom.Host.AudioChunk`. `Beamicom.Host.Output` fans those envelopes out to
sinks without making the emulator wait: video notifications are coalesced around
the latest frame, while every audio chunk is delivered. A subscriber has at most
one video notification waiting; reading the latest frame acknowledges it and
allows the next publish to send another notification.

`Beamicom.Host.Input` and `Beamicom.Host.InputCapabilities` let clients discover
and validate controls without assuming an NES controller layout.
