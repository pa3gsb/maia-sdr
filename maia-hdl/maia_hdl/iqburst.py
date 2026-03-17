#
# Copyright (C) 2024
#
# SPDX-License-Identifier: MIT
#

from amaranth import *
import amaranth.cli

from .axi4_lite import Axi4LiteRegisterBridge
from .cdc import RegisterCDC
from .register import Access, Field, Registers, Register


class IQBurst(Elaboratable):
    """IQ Burst Capture IP core with AXI4-Lite control

    Captures bursts of IQ samples from two input channels and forwards them
    to two output channels.  Between bursts a configurable number of input
    samples is silently dropped.  Both the burst length and the drop count
    are set via AXI4-Lite registers.

    The state machine cycles endlessly:

        1. DROP  phase: accept ``drop_count`` input samples, suppress output.
           If ``drop_count`` == 0 this phase is skipped.
        2. BURST phase: forward ``burst_length`` input samples to the output.
           ``out_last`` is pulsed on the last sample of each burst.
           If ``burst_length`` == 0 this phase is skipped.

    Clock Domains
    -------------
    s_axi_lite : AXI4-Lite CPU bus (from PS or fabric interconnect).
    iq         : IQ sample processing clock.

    Parameters
    ----------
    iq_width : int
        Bit width of the IQ samples (default: 16).

    Attributes
    ----------
    axi4lite.axi : AxiInterface
        AXI4-Lite subordinate interface (s_axi_lite clock domain).
    re_in_0, im_in_0 : Signal(signed(iq_width)), in
        Channel 0 input I/Q (iq domain).
    re_in_1, im_in_1 : Signal(signed(iq_width)), in
        Channel 1 input I/Q (iq domain).
    strobe_in : Signal(), in
        Input valid strobe (iq domain).
    re_out_0, im_out_0 : Signal(signed(iq_width)), out
        Channel 0 output I/Q (iq domain).
    re_out_1, im_out_1 : Signal(signed(iq_width)), out
        Channel 1 output I/Q (iq domain).
    sync_in : Signal(), in
        Synchronisation input (iq domain).  A 0→1 transition resets the
        drop/burst counters and restarts from the DROP phase.
    strobe_out : Signal(), out
        Output valid strobe (iq domain).
    out_last : Signal(), out
        Pulsed on the last sample of each burst (iq domain).

    AXI-Lite Register Map  (byte address = word_addr * 4)
    -------------------------------------------------------
    0x00  control
          [0]     enable        RW  Module enable (0 = off, 1 = on).
    0x04  burst_length
          [31:0]  burst_length  RW  Number of samples to output per burst.
                                    0 = no output.
    0x08  drop_count
          [31:0]  drop_count    RW  Number of input samples to drop between
                                    bursts.  0 = no samples dropped.
    """

    def __init__(self, iq_width: int = 16):
        self.iq_w = iq_width

        # Clock domains managed by this module
        self.s_axi_lite = ClockDomain()
        self.iq = ClockDomain('iq')

        # AXI4-Lite bridge: 2-bit word address → 4 registers
        # (byte address width = 2 + 2 = 4, i.e. 0x00..0x0C)
        self.axi4lite = Axi4LiteRegisterBridge(2, name='s_axi_lite')

        # Register bank (3 registers, elaborated in iq domain)
        self.registers = Registers(
            'iqburst',
            {
                0b00: Register('control', [
                    Field('enable', Access.RW, 1, 0),
                ]),
                0b01: Register('burst_length', [
                    Field('burst_length', Access.RW, 32, 0),
                ]),
                0b10: Register('drop_count', [
                    Field('drop_count', Access.RW, 32, 0),
                ]),
            },
            2)  # 2-bit address

        # Input ports (sync domain)
        self.re_in_0 = Signal(signed(iq_width))
        self.im_in_0 = Signal(signed(iq_width))
        self.re_in_1 = Signal(signed(iq_width))
        self.im_in_1 = Signal(signed(iq_width))
        self.strobe_in = Signal()
        self.sync_in = Signal()

        # Output ports (sync domain)
        self.re_out_0 = Signal(signed(iq_width), reset_less=True)
        self.im_out_0 = Signal(signed(iq_width), reset_less=True)
        self.re_out_1 = Signal(signed(iq_width), reset_less=True)
        self.im_out_1 = Signal(signed(iq_width), reset_less=True)
        self.strobe_out = Signal()
        self.out_last = Signal()

    def ports(self):
        return (
            self.axi4lite.axi.ports()
            + [
                self.re_in_0, self.im_in_0,
                self.re_in_1, self.im_in_1,
                self.strobe_in,
                self.re_out_0, self.im_out_0,
                self.re_out_1, self.im_out_1,
                self.sync_in,
                self.strobe_out, self.out_last,
                self.s_axi_lite.clk, self.s_axi_lite.rst,
                self.iq.clk, self.iq.rst,
            ]
        )

    def elaborate(self, platform):
        m = Module()

        # ── Clock domains ─────────────────────────────────────────────────
        m.domains += [self.s_axi_lite, self.iq]

        # ── AXI4-Lite bridge (s_axi_lite domain) ─────────────────────────
        s_axi_lite_renamer = DomainRenamer({'sync': 's_axi_lite'})
        m.submodules.axi4lite = s_axi_lite_renamer(self.axi4lite)

        # ── RegisterCDC: s_axi_lite → iq ─────────────────────────────────
        m.submodules.reg_cdc = reg_cdc = RegisterCDC(
            's_axi_lite', 'iq', self.registers.aw)

        m.d.comb += [
            # AXI bridge output → CDC input (s_axi_lite domain)
            reg_cdc.i_ren.eq(self.axi4lite.ren),
            self.axi4lite.rdone.eq(reg_cdc.i_rdone),
            self.axi4lite.wdone.eq(reg_cdc.i_wdone),
            reg_cdc.i_wstrobe.eq(self.axi4lite.wstrobe),
            reg_cdc.i_address.eq(self.axi4lite.address),
            self.axi4lite.rdata.eq(reg_cdc.i_rdata),
            reg_cdc.i_wdata.eq(self.axi4lite.wdata),

            # CDC output → register bank (iq domain)
            self.registers.ren.eq(reg_cdc.o_ren),
            reg_cdc.o_rdone.eq(self.registers.rdone),
            self.registers.wstrobe.eq(reg_cdc.o_wstrobe),
            reg_cdc.o_wdone.eq(self.registers.wdone),
            self.registers.address.eq(reg_cdc.o_address),
            reg_cdc.o_rdata.eq(self.registers.rdata),
            self.registers.wdata.eq(reg_cdc.o_wdata),
        ]

        # ── Register bank (iq domain) ─────────────────────────────────────
        iq_renamer = DomainRenamer({'sync': 'iq'})
        m.submodules.registers = iq_renamer(self.registers)

        # Convenience aliases (all signals live in the iq domain)
        enable       = self.registers['control']['enable']
        burst_length = self.registers['burst_length']['burst_length']
        drop_count   = self.registers['drop_count']['drop_count']

        # ── Burst/drop state machine ──────────────────────────────────────
        # in_burst : 0 = DROP phase, 1 = BURST phase
        # drop_cnt  : counts samples consumed in the current DROP phase
        # burst_cnt : counts samples forwarded in the current BURST phase
        in_burst  = Signal()
        drop_cnt  = Signal(32)
        burst_cnt = Signal(32)

        # Rising-edge detector for sync_in
        sync_in_q = Signal()
        sync_rise = Signal()
        m.d.iq += sync_in_q.eq(self.sync_in)
        m.d.comb += sync_rise.eq(self.sync_in & ~sync_in_q)

        # Output data is always wired; strobe_out gates validity.
        m.d.comb += [
            self.re_out_0.eq(self.re_in_0),
            self.im_out_0.eq(self.im_in_0),
            self.re_out_1.eq(self.re_in_1),
            self.im_out_1.eq(self.im_in_1),
            self.strobe_out.eq(
                self.strobe_in & (~enable | (in_burst & enable))),
            self.out_last.eq(
                in_burst & self.strobe_in & enable
                & (burst_cnt == (burst_length - 1))),
        ]

        with m.If(sync_rise):
            m.d.iq += [
                in_burst.eq(0),
                drop_cnt.eq(0),
                burst_cnt.eq(0),
            ]
        with m.Elif(enable & self.strobe_in):
            with m.If(~in_burst):
                # ── DROP phase ────────────────────────────────────────────
                # Transition to BURST when the required number of samples
                # has been dropped, or immediately if drop_count == 0.
                with m.If((drop_count == 0) | (drop_cnt >= drop_count - 1)):
                    m.d.iq += [
                        in_burst.eq(1),
                        drop_cnt.eq(0),
                        burst_cnt.eq(0),
                    ]
                with m.Else():
                    m.d.iq += drop_cnt.eq(drop_cnt + 1)
            with m.Else():
                # ── BURST phase ───────────────────────────────────────────
                # Transition back to DROP when the burst is complete, or
                # immediately if burst_length == 0.
                with m.If((burst_length == 0) | (burst_cnt >= burst_length - 1)):
                    m.d.iq += [
                        in_burst.eq(0),
                        burst_cnt.eq(0),
                        drop_cnt.eq(0),
                    ]
                with m.Else():
                    m.d.iq += burst_cnt.eq(burst_cnt + 1)

        return m


if __name__ == '__main__':
    iqburst = IQBurst()
    amaranth.cli.main(iqburst, ports=iqburst.ports())
