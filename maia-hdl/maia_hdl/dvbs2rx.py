"""
DVB-S2 Receiver IP core
=======================
Wraps DVBS2Frontend (stages 1–6) as a packagable Amaranth IP core.

AXI4-Lite register map (byte addresses, 32-bit words)
------------------------------------------------------
0x00  config  (RW)
        [6:0]  pls_code     : modcod[4:0]<<2 | short_frame<<1 | pilots
                              0 = unknown → SOF + pilots only (default)
        [31:7] reserved

0x04  status  (R)
        [0]    carrier_locked
        [1]    timing_locked
        [2]    sof_locked
        [3]    pll_locked
        [8:4]  modcod[4:0]      detected MODCOD (from PLS decoder)
        [9]    short_frame       detected frame type
        [10]   pilots_en         detected pilot presence
        [31:11] reserved

Data ports
----------
Inputs
  i_in[15:0]  : ADC I channel, signed Q15, at sample_rate
  q_in[15:0]  : ADC Q channel, signed Q15, at sample_rate
  m_tready    : AXI-Stream backpressure from ARM

Outputs
  i_sym[15:0]      : Symbol I after timing/carrier recovery
  q_sym[15:0]      : Symbol Q
  sym_valid        : Symbol strobe (once per symbol)
  frame_start      : DVB-S2 frame boundary pulse
  sof_locked       : SOF correlator locked
  carrier_locked   : Costas carrier lock
  timing_locked    : M&M timing lock
  pll_locked       : Decision-directed PLL locked
  modcod[4:0]      : Detected MODCOD (from PLS header)
  pilots_en        : Detected pilot presence
  short_frame      : 1 = short LDPC frame (16200 bits)
  m_tdata[7:0]     : AXI-Stream byte (header then LLR int8)
  m_tvalid         : AXI-Stream valid
  m_tlast          : AXI-Stream last byte of packet

Clock domain: sync (single clock, name 'clk' in generated Verilog)
AXI4-Lite also uses the sync clock (single-clock design, no CDC needed).
"""

from amaranth import *
import amaranth.cli

from .axi4_lite import Axi4LiteRegisterBridge
from .register import Register, Registers, Field, Access
from .dvbs2_frontend import DVBS2Frontend


# AXI4-Lite address width: 1 bit → 2 word-addressed registers (0x00, 0x04)
_AXI_AW = 1


class DVBS2Rx(Elaboratable):
    """DVB-S2 Receiver IP core — full pipeline stages 1–6 + AXI4-Lite config.

    Parameters
    ----------
    sample_rate : float
        ADC sample rate in Hz (default 10 MHz).
    symbolrate : float
        DVB-S2 symbol rate in Hz (default 2 MHz).
    frequence : float
        Residual IF / carrier offset to track in Hz (default 0).
    alpha : float
        RRC roll-off factor (default 0.20).
    rrc_taps : int
        Number of RRC filter taps (default 33).
    frame_length : int
        DVB-S2 frame length in symbols, normal frame (default 32490).
    """

    def __init__(self,
                 sample_rate:  float = 10_000_000,
                 symbolrate:   float =  2_000_000,
                 frequence:    float =          0,
                 alpha:        float =       0.20,
                 rrc_taps:     int   =         33,
                 frame_length: int   =      32490):

        self._sample_rate  = sample_rate
        self._symbolrate   = symbolrate
        self._frequence    = frequence
        self._alpha        = alpha
        self._rrc_taps     = rrc_taps
        self._frame_length = frame_length

        DW = 16

        # ── AXI4-Lite register interface ─────────────────────────────────
        self.axi4lite = Axi4LiteRegisterBridge(_AXI_AW, name='s_axi_lite')

        self.registers = Registers(
            'dvbs2rx',
            {
                0b0: Register('config', [
                    # pls_code = modcod<<2 | short_frame<<1 | pilots
                    # 0 = unknown (SOF + pilots only)
                    Field('pls_code', Access.RW, 7, 0),
                ]),
                0b1: Register('status', [
                    Field('carrier_locked', Access.R, 1, 0),
                    Field('timing_locked',  Access.R, 1, 0),
                    Field('sof_locked',     Access.R, 1, 0),
                    Field('pll_locked',     Access.R, 1, 0),
                    Field('modcod',         Access.R, 5, 0),
                    Field('short_frame',    Access.R, 1, 0),
                    Field('pilots_en',      Access.R, 1, 0),
                ]),
            },
            _AXI_AW)

        # ── Data ports ───────────────────────────────────────────────────
        self.i_in  = Signal(signed(DW))
        self.q_in  = Signal(signed(DW))

        self.i_sym          = Signal(signed(DW))
        self.q_sym          = Signal(signed(DW))
        self.sym_valid      = Signal()
        self.frame_start    = Signal()
        self.sof_locked     = Signal()
        self.carrier_locked = Signal()
        self.timing_locked  = Signal()
        self.pll_locked     = Signal()
        self.modcod         = Signal(5)
        self.pilots_en      = Signal()
        self.short_frame    = Signal()

        # AXI-Stream master (LLR packets to ARM)
        self.m_tdata  = Signal(8)
        self.m_tvalid = Signal()
        self.m_tready = Signal()
        self.m_tlast  = Signal()

    def ports(self):
        return (
            self.axi4lite.axi.ports()
            + [
                self.i_in, self.q_in,
                self.i_sym, self.q_sym, self.sym_valid,
                self.frame_start, self.sof_locked,
                self.carrier_locked, self.timing_locked,
                self.pll_locked, self.modcod, self.pilots_en, self.short_frame,
                self.m_tdata, self.m_tvalid, self.m_tready, self.m_tlast,
            ]
        )

    def elaborate(self, platform):
        m = Module()

        # ── AXI4-Lite bridge (same sync clock, no CDC needed) ────────────
        # DomainRenamer maps the bridge's internal 'sync' → 's_axi_lite' so
        # Vivado auto-identifies the AXI clock; then we tie s_axi_lite = sync.
        m.submodules.axi4lite = DomainRenamer({'sync': 's_axi_lite'})(
            self.axi4lite)
        m.domains.s_axi_lite = ClockDomain('s_axi_lite')

        # ── Register bank (sync domain) ──────────────────────────────────
        m.submodules.registers = self.registers

        # Wire AXI bridge → register bus (single clock — direct connection)
        m.d.comb += [
            self.registers.ren    .eq(self.axi4lite.ren),
            self.registers.wstrobe.eq(self.axi4lite.wstrobe),
            self.registers.address.eq(self.axi4lite.address),
            self.registers.wdata  .eq(self.axi4lite.wdata),
            self.axi4lite.rdata   .eq(self.registers.rdata),
            self.axi4lite.rdone   .eq(self.registers.rdone),
            self.axi4lite.wdone   .eq(self.registers.wdone),
        ]

        # ── Register field aliases ────────────────────────────────────────
        pls_code_reg    = self.registers['config']['pls_code']

        status_reg      = self.registers['status']
        carrier_locked_r = status_reg['carrier_locked']
        timing_locked_r  = status_reg['timing_locked']
        sof_locked_r     = status_reg['sof_locked']
        pll_locked_r     = status_reg['pll_locked']
        modcod_r         = status_reg['modcod']
        short_frame_r    = status_reg['short_frame']
        pilots_en_r      = status_reg['pilots_en']

        # ── DVB-S2 frontend ───────────────────────────────────────────────
        m.submodules.frontend = fe = DVBS2Frontend(
            sample_rate  = self._sample_rate,
            symbolrate   = self._symbolrate,
            frequence    = self._frequence,
            alpha        = self._alpha,
            rrc_taps     = self._rrc_taps,
            frame_length = self._frame_length,
        )

        # ── Config register → frontend ────────────────────────────────────
        m.d.comb += fe.pls_code.eq(pls_code_reg)

        # ── Status register ← frontend ────────────────────────────────────
        m.d.comb += [
            carrier_locked_r.eq(fe.carrier_locked),
            timing_locked_r .eq(fe.timing_locked),
            sof_locked_r    .eq(fe.sof_locked),
            pll_locked_r    .eq(fe.pll_locked),
            modcod_r        .eq(fe.modcod),
            short_frame_r   .eq(fe.short_frame),
            pilots_en_r     .eq(fe.pilots_en),
        ]

        # ── Data path ────────────────────────────────────────────────────
        m.d.comb += [
            fe.i_in   .eq(self.i_in),
            fe.q_in   .eq(self.q_in),
            fe.m_tready.eq(self.m_tready),

            self.i_sym         .eq(fe.i_sym),
            self.q_sym         .eq(fe.q_sym),
            self.sym_valid     .eq(fe.sym_valid),
            self.frame_start   .eq(fe.frame_start),
            self.sof_locked    .eq(fe.sof_locked),
            self.carrier_locked.eq(fe.carrier_locked),
            self.timing_locked .eq(fe.timing_locked),
            self.pll_locked    .eq(fe.pll_locked),
            self.modcod        .eq(fe.modcod),
            self.pilots_en     .eq(fe.pilots_en),
            self.short_frame   .eq(fe.short_frame),
            self.m_tdata       .eq(fe.m_tdata),
            self.m_tvalid      .eq(fe.m_tvalid),
            self.m_tlast       .eq(fe.m_tlast),
        ]

        # s_axi_lite clock = sync clock (single-clock design)
        m.d.comb += [
            ClockSignal('s_axi_lite').eq(ClockSignal('sync')),
            ResetSignal('s_axi_lite').eq(ResetSignal('sync')),
        ]

        return m


if __name__ == '__main__':
    dut = DVBS2Rx()
    amaranth.cli.main(dut, ports=dut.ports())
