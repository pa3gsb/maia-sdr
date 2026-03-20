# DVB-S2 Receiver — Amaranth HDL Implementation

## Overview

Full DVB-S2 receive pipeline implemented in Amaranth HDL, targeting Zynq-based SDR boards
(Pluto+, Fishball, SignalSDR Pro, Tezuka, …). The FPGA handles RF-to-LLR conversion;
the ARM/PS side runs LDPC decoding via leansdr or a compatible decoder (same split as SatDump).

```
ADC I/Q  →  [Stage 1] RRC filter
                └─► [Stage 2] Costas + M&M sync       (qpsk_sync.py)
                      └─► [Stage 3] SOF correlator     (dvbs2_frontend.py)
                            └─► [Stage 4] Decision-directed PLL  (dvbs2_pll.py)
                                  └─► [Stage 5] PLS decode + soft bits  (dvbs2_bb_soft.py)
                                        └─► [Stage 6] Packet formatter   (dvbs2_deinterleaver.py)
                                                  │
                                        AXI-Stream to ARM
                                                  │
                                    [PS] Column deinterleaver
                                                  │
                                    [PS] LDPC decoder (leansdr)
```

---

## Source Files

| File | Stage | Description |
|------|-------|-------------|
| `maia_hdl/qpsk_sync.py` | 2 | Costas carrier loop + Mueller-Müller timing recovery |
| `maia_hdl/dvbs2_frontend.py` | 1, 3, top | RRC filter, SOF correlator, pipeline top-level `DVBS2Frontend` |
| `maia_hdl/dvbs2_pll.py` | 4 | Decision-directed PLL (SOF / PLS / pilot windows) |
| `maia_hdl/dvbs2_bb_soft.py` | 5 | PLS decoder, LFSR descrambler, soft-bit demodulator |
| `maia_hdl/dvbs2_deinterleaver.py` | 6 | `S2PacketFormatter` (FPGA); `S2ColumnDeinterleaver` (PS reference) |
| `maia_hdl/dvbs2rx.py` | — | IP core wrapper (`DVBS2Rx`), `amaranth.cli` entry point |
| `ip/dvbs2rx/Makefile` | — | Build: generate Verilog → package Vivado IP |
| `ip/dvbs2rx/package_ip.tcl` | — | Vivado IP packaging TCL script |
| `test/test_dvbs2_frontend.py` | — | Integration test from IQ capture file |

---

## Stage-by-Stage Description

### Stage 1 — RRC Filter (`RRCFilter`)

Root Raised Cosine matched filter, one instance for I, one for Q.

- Fixed-point FIR, coefficients quantised to 16 bits
- Roll-off α = 0.20 (DVB-S2 default), configurable
- Default 33 taps; accumulator width = data + coeff + ceil(log2(N)) + 1 guard bits
- Output truncated back to 16 bits

### Stage 2 — QPSK Carrier + Timing Recovery (`QPSKSync`)

Two independent digital control loops sharing the same baseband signal.

**Costas loop (carrier)**
- Discriminant: `sign(I)·Q − sign(Q)·I`
- PI filter → NCO frequency word
- Lock detector: low-pass filtered discriminant magnitude below `lock_thr` for `lock_hold` cycles

**Mueller-Müller loop (timing)**
- Discriminant: `sign(I_prev)·I − sign(I)·I_prev + sign(Q_prev)·Q − sign(Q)·Q_prev`
- Fires once per symbol (NCO timing strobe)
- PI filter → timing NCO step

**Feedback from Stage 4**: `freq_external` port receives the PLL proportional correction
(`freq_prop_out`) to steer the Costas NCO toward the correct carrier frequency.

Parameters (set at elaboration time):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `sample_rate` | 10 MHz | ADC clock |
| `symbolrate` | 2 MHz | DVB-S2 symbol rate |
| `frequence` | 0 Hz | Initial carrier offset |
| `costas_kp/ki` | 10 / 20 | Costas PI loop gains (shifts) |
| `mm_kp/ki` | 12 / 22 | M&M PI loop gains (shifts) |
| `lock_thr` | 400 | Lock threshold |
| `lock_hold` | 256 | Lock hold cycles |

### Stage 3 — SOF Correlator (`SOFCorrelator`)

Detects the 26-symbol π/2-BPSK Start-Of-Frame sequence (ETSI EN 302 307-1 §5.5.2).

- Computes normalised cross-correlation `|Σ ref[k]·sym[k]|² / Σ |sym[k]|²` over 26 symbols
- Threshold comparison → peak detection
- Lock declared after `lock_count` (default 4) consecutive correctly-spaced peaks
- Outputs `frame_start` pulse at the first symbol after each SOF

### Stage 4 — Decision-Directed PLL (`S2PLLBlock`)

Phase-tracks the carrier using three known-symbol windows per frame.

- **SOF window** (26 sym): least-squares phase estimate immediately after lock
- **PLS window** (64 sym): refines frequency once MODCOD is known
- **Pilot windows** (36 sym every 1476 symbols, optional): maintains phase during the frame

State machine: `HUNT → SOF → PLS → DATA ↔ PILOT`

`PhaseEstimator` accumulates `I_known·Q_rx − Q_known·I_rx` over the window, then drives a PI filter.
`PhaseRotator` applies the resulting phase correction to I/Q.
`freq_prop_out` is fed back to Stage 2 (`QPSKSync.freq_external`).

### Stage 5 — PLS Decode + Soft-Bit Demodulator (`S2BBToSoft`)

Three sequential operations per frame:

**1. PLS decoder (`PLSDecoder`)**
- Receives 64 QPSK symbols of the Physical Layer Signalling header
- Computes Hamming distance against all 128 Reed-Muller (7,64) codewords
- Selects the minimum-distance word → decodes `modcod[5:0]` and `short_frame`
- MODCOD fed back to Stage 4

**2. LFSR descrambler (`DVBS2Scrambler`)**
- Gold sequence: polynomial x¹⁸ + x⁷ + 1, seed derived from MODCOD (ETSI §5.5.4)
- Rotates symbol phase by the scrambling sequence

**3. Soft-bit demodulator**
Four parallel constellation demodulators, selected by `modcod`:

| MODCOD range | Constellation | Bits/sym | LLR outputs |
|---|---|---|---|
| 1–11 | QPSK | 2 | `llr_b0`, `llr_b1` |
| 12–17 | 8PSK | 3 | `llr_b0..2` |
| 18–23 | 16APSK | 4 | `llr_b0..3` |
| 24–28 | 32APSK | 5 | `llr_b0..4` |

LLR approximation: min-sum (`min_dist_0 − min_dist_1`), clipped to int8 [−127, 127].

**LLR serialiser**: a 5-slot shift register drains the multi-bit LLR outputs sequentially between
`sym_valid` strobes, producing one `llr_out` byte per clock with `llr_valid` strobe.

### Stage 6 — Packet Formatter (`S2PacketFormatter`)

Assembles one AXI-Stream packet per DVB-S2 frame for DMA transfer to the ARM.

**Packet format** (4-byte header + payload):

```
Byte 0 : MODCOD[5:0]  | 00
Byte 1 : short_frame  | 0000000
Byte 2 : n_llr[15:8]  (MSB)
Byte 3 : n_llr[7:0]   (LSB)
Bytes 4 … 4+n_llr-1 : LLR int8 (raw, non-deinterleaved)
```

`n_llr` = 64 800 (normal frame) or 16 200 (short frame).

**AXI-Stream interface**: standard TDATA/TVALID/TREADY/TLAST handshake.
TREADY backpressure from the ARM stalls the formatter; the upstream LLR stream
must absorb or drop data during stalls (no FIFO in the formatter itself).

> **Design choice**: column deinterleaving is intentionally left to the PS side
> (like SatDump). Implementing the 64 800 × 8-bit ping-pong BRAM on the FPGA
> would consume ~63 KB × 2 = 126 KB of block RAM per stream, which exceeds the
> available BRAM budget on smaller Zynq-7010/7020 devices.

---

## PS-Side Processing (reference, not in FPGA)

`S2ColumnDeinterleaver` in `dvbs2_deinterleaver.py` contains the reference HDL
(BRAM-based, ping-pong) and a Python `make_deinterleave_lut()` helper for software
validation. On the ARM:

1. Receive DMA packet via AXI-Stream / AXI-DMA
2. Parse 4-byte header → `modcod`, `short_frame`, `n_llr`
3. Apply column deinterleaving (ETSI EN 302 307-1 §5.3.3, Table 10)
4. Feed reordered LLR bytes to leansdr or compatible LDPC decoder

Column permutations by modulation:

| Modulation | Nc | Column read order |
|---|---|---|
| QPSK | 2 | [0, 1] (identity) |
| 8PSK | 6 | [0, 5, 1, 2, 4, 3] |
| 16APSK | 4 | [0, 3, 1, 2] |
| 32APSK | 5 | [0, 4, 1, 2, 3] |

---

## IP Core (`dvbs2rx`)

Located in `ip/dvbs2rx/`. Follows the same packaging convention as `ip/fftraw` and
`ip/iqburst`.

### Build

```bash
make -C ip/dvbs2rx        # generate Verilog + package Vivado IP
make -C ip/dvbs2rx clean  # remove build artefacts
```

Requires: Python 3 with `amaranth >= 0.5`, Yosys, Vivado.

### Top-level ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | in | 1 | Processing clock (= `sync` domain) |
| `rst` | in | 1 | Active-high synchronous reset |
| `i_in` | in | 16 | ADC I, signed Q15, at `sample_rate` |
| `q_in` | in | 16 | ADC Q, signed Q15, at `sample_rate` |
| `i_sym` | out | 16 | Symbol I after timing+carrier recovery |
| `q_sym` | out | 16 | Symbol Q |
| `sym_valid` | out | 1 | Symbol strobe |
| `frame_start` | out | 1 | DVB-S2 frame boundary pulse |
| `sof_locked` | out | 1 | SOF correlator locked |
| `carrier_locked` | out | 1 | Costas carrier lock |
| `timing_locked` | out | 1 | M&M timing lock |
| `pll_locked` | out | 1 | Decision-directed PLL locked |
| `modcod` | out | 6 | Decoded MODCOD |
| `short_frame` | out | 1 | 1 = short LDPC frame (16 200 bits) |
| `m_tdata` | out | 8 | AXI-Stream byte (header then LLR) |
| `m_tvalid` | out | 1 | AXI-Stream valid |
| `m_tready` | in | 1 | AXI-Stream backpressure from ARM |
| `m_tlast` | out | 1 | AXI-Stream last byte of packet |

### Vivado bus interfaces

| Interface name | Type | Notes |
|---|---|---|
| `sync_clk` | `xilinx.com:signal:clock` | Maps to `clk` |
| `rst` | `xilinx.com:signal:reset` | Active-high, associated to `sync_clk` |
| `m` | AXI4-Stream master | Auto-detected from `m_t*` port naming |

---

## Integration Test

`test/test_dvbs2_frontend.py` feeds a real IQ capture file into an Amaranth simulation
of `DVBS2Frontend` and verifies:

1. `carrier_locked`, `timing_locked`, `sof_locked`, `pll_locked` all assert
   before 95% of `MAX_SAMPLES`
2. At least one complete AXI-Stream packet is received
3. Every packet header has `MODCOD ∈ [0, 27]` and `n_llr` is a valid DVB-S2
   LDPC block size; payload length equals `n_llr`

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `DVBS2_IQ_FILE` | *(required)* | Path to IQ capture — test **skipped** if not set |
| `DVBS2_IQ_FORMAT` | `cf32` | File format: `cf32` (GNU Radio), `cs16`, `cs8` |
| `DVBS2_SAMPLE_RATE` | `10000000` | ADC sample rate (Hz) |
| `DVBS2_SYMBOL_RATE` | `2000000` | DVB-S2 symbol rate (Hz) |
| `DVBS2_FREQ_OFFSET` | `0` | Expected carrier offset (Hz) |
| `DVBS2_MAX_SAMPLES` | `1000000` | Max samples to process |
| `DVBS2_VCD` | *(unset)* | If set, write VCD waveform to this path |

### Usage examples

```bash
# CF32 file (GNU Radio default), 10 MHz / 2 MBaud
DVBS2_IQ_FILE=signal.cf32 \
  python3 -m unittest test.test_dvbs2_frontend -v

# CS16 file at different rates
DVBS2_IQ_FILE=signal.cs16 DVBS2_IQ_FORMAT=cs16 \
  DVBS2_SAMPLE_RATE=4000000 DVBS2_SYMBOL_RATE=1000000 \
  python3 -m unittest test.test_dvbs2_frontend -v

# With VCD waveform dump for analysis
DVBS2_IQ_FILE=signal.cf32 DVBS2_VCD=/tmp/dvbs2.vcd \
  python3 -m unittest test.test_dvbs2_frontend -v
```

Input normalisation: the test scales the 99th-percentile sample magnitude to 80% of Q15
full-scale, giving headroom for noise peaks.

---

## Key Design Decisions

**Single-clock architecture**: the entire pipeline runs in one `sync` clock domain at the
ADC sample rate. No CDC crossings inside the DVB-S2 core.

**One sample per clock**: `DVBS2Frontend` processes exactly one I/Q sample per clock cycle.
The symbol rate emerges from the M&M timing NCO.

**Fixed-point throughout**: all internal signals are 16-bit signed integers (Q15).
Intermediate accumulators are widened as needed; results are truncated, not rounded
(except the LLR int8 clip).

**No hardware divider**: the `nr = n_ldpc / nc` computation (rows per column for the
deinterleaver) is a lookup table keyed on `(short_frame, bps)` — eight fixed cases.
Write and read column counters advance by incrementing, avoiding runtime modulo operations.

**BRAM for deinterleaver**: the PS-side `S2ColumnDeinterleaver` uses
`amaranth.lib.memory.Memory` with `attrs={'ram_style': 'block'}` to force BRAM inference.
A plain `Array([Signal(8)...] * 64800)` times out in Yosys at this depth.

**Deinterleaving on the PS**: column deinterleaving and LDPC decoding are intentionally
offloaded to the ARM. The FPGA outputs raw (non-deinterleaved) LLR bytes with a
4-byte header, matching the SatDump split architecture.

---

## Standards References

- ETSI EN 302 307-1 V1.4.1 — *Digital Video Broadcasting (DVB); Second generation
  framing structure, channel coding and modulation systems for Broadcasting,
  Interactive Services, News Gathering and other broadband satellite applications
  (DVB-S2)*
  - §5.3.3 Table 10 — Column interleaver permutations
  - §5.5.2 — Start-Of-Frame (SOF) sequence
  - §5.5.4 — Physical Layer Scrambler (Gold sequence)
  - Annex C Table C-2 — PLS Reed-Muller generator matrix
