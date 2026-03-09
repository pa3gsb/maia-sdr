#
# Copyright (C) 2024
#
# SPDX-License-Identifier: MIT
#

from amaranth import *
from amaranth.lib.memory import Memory
import amaranth.cli
import amaranth.back.verilog

import numpy as np

from .axi4_lite import Axi4LiteRegisterBridge
from .cdc import RegisterCDC
from .clknx import ClkNxCommonEdge
from .mixer import Mixer
from .pluto_platform import PlutoPlatform
from .register import Access, Field, Registers, Register


class Modulator(Elaboratable):
    """TX Modulator with AXI4-Lite CPU control

    This module implements a TX upconverter that accepts baseband IQ samples
    from either a stream interface or CPU-written registers, shifts them to a
    configurable carrier frequency using an NCO-based Mixer (reused from
    maia-sdr), and outputs modulated IQ at the sync clock rate.

    Submodules reused from maia-sdr
    --------------------------------
    Mixer              : NCO + Cmult3x complex upconverter
    Axi4LiteRegisterBridge : AXI4-Lite to internal register bus bridge
    Registers          : register bank with field access
    RegisterCDC        : register bus clock-domain crossing
    ClkNxCommonEdge    : 3x/1x common-edge strobe generator

    Clock Domains
    -------------
    s_axi_lite   : AXI4-Lite CPU bus (from PS or fabric interconnect)
    sync         : main processing clock (1x)
    <domain_3x>  : 3x clock used internally by the Mixer/Cmult3x

    Parameters
    ----------
    domain_3x : str
        Name of the 3x clock domain (must run at 3x the sync clock).
    iq_width : int
        Bit width of the input/output IQ samples.
    nco_width : int
        Width of the NCO frequency accumulator.

    Attributes
    ----------
    axi4lite.axi : AxiInterface
        AXI4-Lite subordinate interface (s_axi_lite clock domain).
    re_in : Signal(signed(iq_width)), in
        Stream input real part (sync domain). Used when source_sel == 0.
    im_in : Signal(signed(iq_width)), in
        Stream input imaginary part (sync domain). Used when source_sel == 0.
    strobe_in : Signal(), in
        Stream valid strobe (sync domain). Sampled only when source_sel == 0.
    symbol : Signal(16), in
        Symbol word (sync domain). Lower bits address the constellation LUT.
        Used when source_sel == 2.
    symbol_strobe : Signal(), in
        Valid strobe for symbol. One pulse per symbol to modulate.
    re_out : Signal(signed(iq_width)), out
        Modulated output real part (sync domain).
    im_out : Signal(signed(iq_width)), out
        Modulated output imaginary part (sync domain).
    strobe_out : Signal(), out
        Output valid strobe, delayed from the input strobe by the Mixer
        pipeline latency (mixer.delay sync clock cycles).

    AXI-Lite Register Map  (byte address = word_addr * 4)
    -------------------------------------------------------
    0x00  control
          [0]    enable      RW   Module enable (0 = off, 1 = on).
          [2:1]  source_sel  RW   IQ source selector.
                                  0 = stream_in  (re_in/im_in + strobe_in)
                                  1 = cpu_iq     (continuous from cpu_re/cpu_im)
                                  2 = symbol     (symbol bus → constellation LUT)
                                  3 = reserved
    0x04  tx_frequency
          [nco_width-1:0]  frequency  RW
                                  NCO frequency word.
                                  f_Hz = frequency / 2**nco_width * f_sync
    0x08  gain
          [3:0]  shift_right  RW  Arithmetic right-shift applied to IQ before
                                  the mixer (0 = no attenuation, 15 = >>15).
    0x0C  cpu_re
          [iq_width-1:0]  cpu_re  RW  CPU IQ real  part (signed).
    0x10  cpu_im
          [iq_width-1:0]  cpu_im  RW  CPU IQ imaginary part (signed).
    0x14  modulation
          [1:0]  mod_sel  RW   Constellation for symbol mode.
                                0 = BPSK   (symbol[0],   2 points)
                                1 = QPSK   (symbol[1:0], 4 points, Gray)
                                2 = 8PSK   (symbol[2:0], 8 points, Gray)
                                3 = 16QAM  (symbol[3:0], 16 points, Gray)
    """

    def __init__(self, domain_3x: str = 'clk3x', *,
                 iq_width: int = 16,
                 nco_width: int = 28):
        self._3x = domain_3x
        self.iq_w = iq_width
        self.nco_width = nco_width

        # Clock domains managed by this module
        self.s_axi_lite = ClockDomain()
        self.sync = ClockDomain()
        self._clk3x_domain = ClockDomain(name=domain_3x)

        # AXI4-Lite bridge: 3-bit word address → up to 8 registers
        # (byte address width = 3 + 2 = 5, i.e., 0x00..0x1C)
        self.axi4lite = Axi4LiteRegisterBridge(3, name='s_axi_lite')

        # Register bank (5 registers, elaborated in sync domain)
        self.registers = Registers(
            'modulator',
            {
                0b000: Register('control', [
                    Field('enable',     Access.RW, 1, 0),
                    Field('source_sel', Access.RW, 2, 0),  # 0=stream 1=cpu_iq 2=symbol
                ]),
                0b001: Register('tx_frequency', [
                    Field('frequency', Access.RW, nco_width, 0),
                ]),
                0b010: Register('gain', [
                    Field('shift_right', Access.RW, 4, 0),
                ]),
                0b011: Register('cpu_re', [
                    Field('cpu_re', Access.RW, iq_width, 0),
                ]),
                0b100: Register('cpu_im', [
                    Field('cpu_im', Access.RW, iq_width, 0),
                ]),
                0b101: Register('modulation', [
                    Field('mod_sel', Access.RW, 2, 0),  # 0=BPSK 1=QPSK 2=8PSK 3=16QAM
                ]),
            },
            3)  # 3-bit address, matching the AXI4-Lite bridge

        # Mixer: reused from maia-sdr. Runs on sync (1x) + domain_3x (3x).
        self.mixer = Mixer(domain_3x, iq_width, nco_width=nco_width)

        # Number of symbol bits used as LUT address (supports up to 16QAM)
        self._sym_bits = 4
        # Number of modulation types in the LUT (BPSK, QPSK, 8PSK, 16QAM)
        self._n_mods = 4

        # Processing ports (sync domain)
        self.re_in     = Signal(signed(iq_width))
        self.im_in     = Signal(signed(iq_width))
        self.strobe_in = Signal()

        # Symbol input (source_sel == 2): drives the constellation LUT
        self.symbol        = Signal(16)
        self.symbol_strobe = Signal()

        self.re_out     = Signal(signed(iq_width), reset_less=True)
        self.im_out     = Signal(signed(iq_width), reset_less=True)
        self.strobe_out = Signal()

    @staticmethod
    def _build_lut(iq_width, n_mods, sym_bits):
        """Precompute the constellation LUT.

        Layout: address = {mod_sel[1:0], symbol[sym_bits-1:0]}
        Data  : bits [iq_width-1:0]         = re (signed)
                bits [2*iq_width-1:iq_width] = im (signed)

        Modulations (mod_sel):
          0 = BPSK   — symbol[0]
          1 = QPSK   — symbol[1:0], Gray coded, points at ±45° / ±135°
          2 = 8PSK   — symbol[2:0], Gray coded
          3 = 16QAM  — symbol[3:0], Gray coded, normalized average power
        """
        depth  = n_mods * (2 ** sym_bits)
        scale  = 2 ** (iq_width - 1) - 1
        mask   = (1 << iq_width) - 1
        lut    = [0] * depth

        def pack(re_f, im_f):
            re = int(np.clip(np.round(re_f * scale), -(scale + 1), scale))
            im = int(np.clip(np.round(im_f * scale), -(scale + 1), scale))
            return ((im & mask) << iq_width) | (re & mask)

        stride = 2 ** sym_bits

        # BPSK (mod=0): symbol[0] → 0° or 180°
        for s in range(2):
            lut[0 * stride + s] = pack(1.0 - 2.0 * s, 0.0)

        # QPSK (mod=1): symbol[1:0] Gray coded, phase = 45° + k*90°
        gray4 = [0, 1, 3, 2]
        for s in range(4):
            angle = np.pi / 4 + gray4[s] * np.pi / 2
            lut[1 * stride + s] = pack(np.cos(angle), np.sin(angle))

        # 8PSK (mod=2): symbol[2:0] Gray coded, phase = k*45°
        gray8 = [0, 1, 3, 2, 6, 7, 5, 4]
        for s in range(8):
            angle = gray8[s] * np.pi / 4
            lut[2 * stride + s] = pack(np.cos(angle), np.sin(angle))

        # 16QAM (mod=3): symbol[3:0] Gray coded, normalized average power
        qam_levels = np.array([-3, -1, 1, 3], dtype=float) / (3.0 * np.sqrt(2))
        for s in range(16):
            i_val = qam_levels[gray4[(s >> 2) & 3]]
            q_val = qam_levels[gray4[s & 3]]
            lut[3 * stride + s] = pack(i_val, q_val)

        return lut

    def ports(self):
        return (
            self.axi4lite.axi.ports()
            + [
                self.re_in, self.im_in, self.strobe_in,
                self.symbol, self.symbol_strobe,
                self.re_out, self.im_out, self.strobe_out,
                self.s_axi_lite.clk, self.s_axi_lite.rst,
                self.sync.clk, self.sync.rst,
                self._clk3x_domain.clk,
            ]
        )

    def elaborate(self, platform):
        m = Module()

        # ── Clock domains ─────────────────────────────────────────────────
        m.domains += [self.s_axi_lite, self.sync, self._clk3x_domain]

        # ── AXI4-Lite bridge (s_axi_lite domain) ─────────────────────────
        s_axi_lite_renamer = DomainRenamer({'sync': 's_axi_lite'})
        m.submodules.axi4lite = s_axi_lite_renamer(self.axi4lite)

        # ── RegisterCDC: s_axi_lite → sync ───────────────────────────────
        m.submodules.reg_cdc = reg_cdc = RegisterCDC(
            's_axi_lite', 'sync', self.registers.aw)

        m.d.comb += [
            # AXI bridge output → CDC input (s_axi_lite domain)
            reg_cdc.i_ren.eq(self.axi4lite.ren),
            self.axi4lite.rdone.eq(reg_cdc.i_rdone),
            self.axi4lite.wdone.eq(reg_cdc.i_wdone),
            reg_cdc.i_wstrobe.eq(self.axi4lite.wstrobe),
            reg_cdc.i_address.eq(self.axi4lite.address),
            self.axi4lite.rdata.eq(reg_cdc.i_rdata),
            reg_cdc.i_wdata.eq(self.axi4lite.wdata),

            # CDC output → register bank (sync domain)
            self.registers.ren.eq(reg_cdc.o_ren),
            reg_cdc.o_rdone.eq(self.registers.rdone),
            self.registers.wstrobe.eq(reg_cdc.o_wstrobe),
            reg_cdc.o_wdone.eq(self.registers.wdone),
            self.registers.address.eq(reg_cdc.o_address),
            reg_cdc.o_rdata.eq(self.registers.rdata),
            self.registers.wdata.eq(reg_cdc.o_wdata),
        ]

        # ── Register bank (sync domain) ───────────────────────────────────
        m.submodules.registers = self.registers

        # Convenience aliases — all signals live in the sync domain
        enable      = self.registers['control']['enable']
        source_sel  = self.registers['control']['source_sel']
        frequency   = self.registers['tx_frequency']['frequency']
        shift_right = self.registers['gain']['shift_right']
        cpu_re      = self.registers['cpu_re']['cpu_re']
        cpu_im      = self.registers['cpu_im']['cpu_im']
        mod_sel     = self.registers['modulation']['mod_sel']

        # ── ClkNxCommonEdge: 3x/1x alignment signal ───────────────────────
        m.submodules.common_edge = common_edge_gen = ClkNxCommonEdge(
            'sync', self._3x, 3)

        # ── Mixer (sync + clk3x) ──────────────────────────────────────────
        m.submodules.mixer = mixer = self.mixer

        # ── Constellation LUT (source_sel == 2) ───────────────────────────
        # ROM: address = {mod_sel[1:0], symbol[sym_bits-1:0]}
        # Data: {im[iq_width-1:0], re[iq_width-1:0]}  (both signed)
        # Synthesised as distributed LUTs (64 × 32-bit entries).
        lut_init = self._build_lut(self.iq_w, self._n_mods, self._sym_bits)
        m.submodules.lut = lut_mem = Memory(
            shape=2 * self.iq_w,
            depth=self._n_mods * 2 ** self._sym_bits,
            init=lut_init,
            attrs={'rom_style': 'distributed'},
        )
        lut_rd = lut_mem.read_port()

        # Address is combinational; data appears 1 sync cycle later (port reg).
        m.d.comb += [
            lut_rd.en.eq(Const(1)),
            lut_rd.addr.eq(Cat(self.symbol[:self._sym_bits], mod_sel)),
        ]

        lut_re = Signal(signed(self.iq_w), reset_less=True)
        lut_im = Signal(signed(self.iq_w), reset_less=True)
        m.d.comb += [
            lut_re.eq(lut_rd.data[:self.iq_w].as_signed()),
            lut_im.eq(lut_rd.data[self.iq_w:].as_signed()),
        ]

        # Delay symbol_strobe by 1 cycle to align with LUT read latency.
        lut_strobe = Signal()
        m.d.sync += lut_strobe.eq(self.symbol_strobe & enable)

        # ── IQ source MUX (3-way) ─────────────────────────────────────────
        # source_sel == 0 : stream  — re_in/im_in gated by strobe_in
        # source_sel == 1 : cpu_iq — cpu_re/cpu_im, continuous every cycle
        # source_sel == 2 : symbol — constellation LUT output
        mux_re     = Signal(signed(self.iq_w))
        mux_im     = Signal(signed(self.iq_w))
        mux_strobe = Signal()

        with m.Switch(source_sel):
            with m.Case(0):
                m.d.comb += [
                    mux_re.eq(self.re_in),
                    mux_im.eq(self.im_in),
                    mux_strobe.eq(enable & self.strobe_in),
                ]
            with m.Case(1):
                m.d.comb += [
                    mux_re.eq(cpu_re),
                    mux_im.eq(cpu_im),
                    mux_strobe.eq(enable),
                ]
            with m.Case(2):
                m.d.comb += [
                    mux_re.eq(lut_re),
                    mux_im.eq(lut_im),
                    mux_strobe.eq(lut_strobe),
                ]
            with m.Default():
                m.d.comb += mux_strobe.eq(0)

        # ── Gain: arithmetic right-shift (barrel shifter) ─────────────────
        shifted_re = Signal(signed(self.iq_w))
        shifted_im = Signal(signed(self.iq_w))
        m.d.comb += [
            shifted_re.eq(mux_re >> shift_right),
            shifted_im.eq(mux_im >> shift_right),
        ]

        # ── Wire Mixer ────────────────────────────────────────────────────
        m.d.comb += [
            mixer.common_edge.eq(common_edge_gen.common_edge),
            mixer.clken.eq(mux_strobe),
            mixer.frequency.eq(frequency),
            mixer.re_in.eq(shifted_re),
            mixer.im_in.eq(shifted_im),
        ]

        # ── Output ────────────────────────────────────────────────────────
        # Delay the strobe by mixer.delay sync cycles so strobe_out aligns
        # with the valid pipeline output in re_out / im_out.
        # mixer.delay is a Python integer (Cmult3x.delay + 1 = 3 or 4 cycles).
        n_delay = mixer.delay
        strobe_pipe = [
            Signal(name=f'strobe_d{i}', reset_less=True)
            for i in range(n_delay)
        ]
        m.d.sync += strobe_pipe[0].eq(mux_strobe)
        for j in range(1, n_delay):
            m.d.sync += strobe_pipe[j].eq(strobe_pipe[j - 1])

        m.d.comb += [
            self.re_out.eq(mixer.re_out),
            self.im_out.eq(mixer.im_out),
            self.strobe_out.eq(strobe_pipe[-1]),
        ]

        return m


if __name__ == '__main__':
    mod = Modulator('clk3x')
    amaranth.cli.main(mod, ports=mod.ports(), platform=PlutoPlatform())
