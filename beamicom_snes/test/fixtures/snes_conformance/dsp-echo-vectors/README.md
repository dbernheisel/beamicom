# S-DSP echo vectors

These are original, data-only vectors for `Beamicom.SNES.DSP.Echo`. They do not
copy emulator source or third-party binary fixtures.

The expected arithmetic and phase ordering were derived independently from two
source-level implementations:

- [Blargg `snes_spc` accurate DSP](https://github.com/blarggs-audio-libraries/snes_spc/blob/master/snes_spc/SPC_DSP.cpp#L558-L704)
- [ares SFC DSP echo](https://github.com/ares-emulator/ares/blob/master/ares/sfc/dsp/echo.cpp)

The vectors pin these observable rules:

- phases 22 and 23 read left and right 16-bit echo RAM samples;
- RAM samples enter the FIR history after an arithmetic shift by one;
- FIR0 reads the oldest history slot and FIR7 reads the newly fetched sample;
- taps zero through six wrap to signed 16-bit before tap seven is added,
  clamped, and rounded down to an even value;
- echo feedback is added to the independently saturated EON voice bus, then
  clamped and rounded down to an even value;
- FLG bit 5 suppresses writes but not reads, history, filtering, or ring
  advancement;
- the left write uses the phase-28 FLG latch and the right write uses the
  phase-29 latch;
- ESA takes effect on the next sample, while EDL takes effect when the current
  ring offset is zero;
- EDL zero repeatedly targets the first four bytes at ESA.

Run with:

```console
mix test test/beamicom/snes/dsp_echo_test.exs
```

## Integration contract

The top-level DSP/APU integrator should keep an `Echo.State` in clock state and
perform the following operations on the shared timeline:

1. At phase 22, resolve the left `read_effects/1` entry against the RAM visible
   at that clock.
2. At phase 23, resolve the right entry. Decode the four bytes with
   `decode_ram_sample/4`.
3. Route each voice's already volume-scaled stereo contribution through
   `route_voice/4`, using the sample's EON latch, while retaining the independent
   main bus.
4. Once the voice buses and both RAM reads are available, call
   `process_sample/6`. Preserve the returned state and PCM and schedule its two
   returned write effects.
5. At phases 29 and 30, apply the left and right write effects respectively.
   Disabled effects remain in traces but do not mutate RAM.
6. When `scalar_required?/1` is true, bypass both Nx synthesis and Nx-only
   mixing. Continue using the established renderer path when it is false so
   echo-off output remains bit-identical.

The existing `DSP.clock/4` returns no RAM, so echo writeback cannot be integrated
correctly by dropping write effects inside that API. The integrator needs a
RAM-threading clock variant (for example `{dsp, ram, pcm}`) for APU use while
retaining the existing compatibility wrapper. Clock spans must stop at echo
read/write phases and SPC RAM events so a write immediately before a read is
visible and a write immediately after it is not.
