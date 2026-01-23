#
# Copyright (C) 2022-2024 Daniel Estevez <daniel@destevez.net>
#
# This file is part of maia-sdr
#
# SPDX-License-Identifier: MIT
#

from amaranth import *
import amaranth.back.verilog
import numpy as np

from .fft import FFT


class TopFFT(Elaboratable):
    """Top FFT Module - Outputs FFT bins directly to I/Q output bus

    This elaboratable uses an FFT to compute raw FFT output bins.
    The data is output directly via I and Q output signals with
    bit-reversal to produce naturally ordered bins.

    Parameters
    ----------
    domain_2x : str
        Name of the clock domain of the 2x clock.
    domain_3x : str
        Name of the clock domain of the 3x clock.

    Attributes
    ----------
    strobe_in : Signal(), in
        Strobe in for the input IQ samples.
    common_edge_2x : Signal(), in
        A signal that toggles with the 2x clock and is high immediately
        after the rising edge of the 1x clock.
    common_edge_3x : Signal(), in
        A signal that changes with the 3x clock and is high on the cycles
        immediately after the rising edge of the 1x clock.
    re_in : Signal(signed(12)), in
        Input samples real part.
    im_in : Signal(signed(12)), in
        Input samples imaginary part.
    strobe_out : Signal(), out
        Strobe signal indicating valid output data.
    re_out : Signal(signed(16)), out
        Output FFT bins real part (in natural order).
    im_out : Signal(signed(16)), out
        Output FFT bins imaginary part (in natural order).
    out_last : Signal(), out
        Pulsed when the last bin of an FFT frame is output.
    """
    def __init__(self, domain_2x='clk2x', domain_3x='clk3x'):
        self._domain_2x = domain_2x
        self.fft_order_log2 = 8
        self.width_in = 12
        self.width_out = 16

        self.strobe_in = Signal()
        self.common_edge_2x = Signal()
        self.re_in = Signal(signed(self.width_in))
        self.im_in = Signal(signed(self.width_in))

        self.strobe_out = Signal()
        self.re_out = Signal(signed(self.width_out))
        self.im_out = Signal(signed(self.width_out))
        self.out_last = Signal()

    def ports(self):
        return [
            self.strobe_in,
            self.common_edge_2x,
            self.re_in,
            self.im_in,
            self.strobe_out,
            self.re_out,
            self.im_out,
            self.out_last,
        ]

    def elaborate(self, platform):
        m = Module()

        # For FFT order 8 (256 points), we have 4 R22 stages
        # Each R22 stage adds 2 bits, but we truncate to control width
        # Input: 12 bits
        # Stage 1: 12 + 2 - 0 - 0 = 14
        # Stage 2: 14 + 2 - 0 - 0 = 16
        # Stage 3: 16 + 2 - 1 - 1 = 16
        # Stage 4: 16 + 2 - 1 - 1 = 16
        truncates = [[0, 0], [0, 0], [1, 1], [1, 1]]
        
        m.submodules.fft = fft = FFT(
            self.width_in, self.fft_order_log2, 'R22',
            width_twiddle=16, truncates=truncates,
            use_bram_reg=True, window='blackmanharris',
            cmult3x=False,
            domain_2x=self._domain_2x, domain_3x=None)
        width_fft_out = len(fft.re_out)
        assert width_fft_out == self.width_out, \
            f"FFT output width is {width_fft_out}, expected {self.width_out}"

        # Bit-reversal buffer to reorder FFT output bins
        # DIF FFT produces bit-reversed output, so we need to reorder
        fft_size = 2**self.fft_order_log2
        from amaranth.lib.memory import Memory
        m.submodules.buffer_re = buffer_re = Memory(
            shape=self.width_out, depth=fft_size, init=[])
        m.submodules.buffer_im = buffer_im = Memory(
            shape=self.width_out, depth=fft_size, init=[])
        
        wrport_re = buffer_re.write_port()
        wrport_im = buffer_im.write_port()
        rdport_re = buffer_re.read_port()
        rdport_im = buffer_im.read_port()

        # Generate output strobe delayed to match FFT output
        strobe_delay = Signal(fft.delay)
        with m.If(self.strobe_in):
            m.d.sync += strobe_delay.eq(Cat(1, strobe_delay[:-1]))
        with m.Else():
            m.d.sync += strobe_delay.eq(Cat(0, strobe_delay[:-1]))

        fft_strobe = strobe_delay[-1]

        # Write counter (natural order)
        write_counter = Signal(self.fft_order_log2)
        
        # Read counter (natural order)
        read_counter = Signal(self.fft_order_log2)
        
        # State machine for reading out the reordered data
        reading = Signal()
        
        # Bit-reverse the read counter to get the actual address
        # For an 8-bit address, bit 0 -> bit 7, bit 1 -> bit 6, etc.
        read_addr_reversed = Signal(self.fft_order_log2)
        for i in range(self.fft_order_log2):
            m.d.comb += read_addr_reversed[i].eq(
                read_counter[self.fft_order_log2 - 1 - i])

        # Write FFT output to sequential addresses
        with m.If(fft_strobe):
            m.d.sync += write_counter.eq(write_counter + 1)
        
        m.d.comb += [
            wrport_re.en.eq(fft_strobe),
            wrport_re.addr.eq(write_counter),
            wrport_re.data.eq(fft.re_out),
            wrport_im.en.eq(fft_strobe),
            wrport_im.addr.eq(write_counter),
            wrport_im.data.eq(fft.im_out),
        ]

        # Delay for memory read latency (1 cycle for synchronous read)
        read_valid = Signal(2)
        
        # Read state machine
        with m.If(fft.out_last & fft_strobe):
            # Start reading after full FFT frame is written
            m.d.sync += [
                reading.eq(1),
                read_counter.eq(0),
                read_valid.eq(0),
            ]
        with m.Elif(reading):
            m.d.sync += [
                read_counter.eq(read_counter + 1),
                read_valid.eq(Cat(1, read_valid[0])),
            ]
            with m.If(read_counter == fft_size - 1):
                m.d.sync += reading.eq(0)

        # Read from bit-reversed addresses
        m.d.comb += [
            rdport_re.en.eq(1),
            rdport_re.addr.eq(read_addr_reversed),
            rdport_im.en.eq(1),
            rdport_im.addr.eq(read_addr_reversed),
        ]

        # Output connections
        m.d.comb += [
            # FFT input connections
            fft.clken.eq(self.strobe_in),
            fft.common_edge_2x.eq(self.common_edge_2x),
            fft.re_in.eq(self.re_in),
            fft.im_in.eq(self.im_in),

            # Bit-reversed and reordered output
            # Valid after 1 cycle of memory read latency
            self.strobe_out.eq(read_valid[1]),
            self.re_out.eq(rdport_re.data),
            self.im_out.eq(rdport_im.data),
            self.out_last.eq(read_valid[1] & (read_counter == 0)),
        ]

        return m


if __name__ == '__main__':
    topfft = TopFFT()
    amaranth.cli.main(
        topfft, ports=topfft.ports())