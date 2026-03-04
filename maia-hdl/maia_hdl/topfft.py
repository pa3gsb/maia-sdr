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

        # 4 R22 stages for 256-point FFT (order_log2=8)
        # Input: 12 bits, truncate in last 2 stages to stay at 16:
        # 12 → 14 → 16 → 16 → 16
        truncates = [[0, 0], [0, 0], [1, 1], [1, 1]]

        m.submodules.fft = fft = FFT(
            self.width_in, self.fft_order_log2, 'R22',
            width_twiddle=None, truncates=truncates,
            use_bram_reg=True, window=None,
            cmult3x=False,
            domain_2x=self._domain_2x, domain_3x=None)
        width_fft_out = len(fft.re_out)
        assert width_fft_out == self.width_out, \
            f"FFT output width is {width_fft_out}, expected {self.width_out}"

        fft_size = 2**self.fft_order_log2
        from amaranth.lib.memory import Memory

        # Double-buffered memory for bit-reversal reordering.
        # Depth is 2*fft_size; the MSB of the address selects the bank.
        # This prevents read/write collisions: while one bank is being
        # read, the other is being written with the next FFT frame.
        mem_depth = 2 * fft_size
        m.submodules.buffer_re = buffer_re = Memory(
            shape=self.width_out, depth=mem_depth, init=[])
        m.submodules.buffer_im = buffer_im = Memory(
            shape=self.width_out, depth=mem_depth, init=[])

        wrport_re = buffer_re.write_port()
        wrport_im = buffer_im.write_port()
        rdport_re = buffer_re.read_port()
        rdport_im = buffer_im.read_port()

        # Derive fft_strobe by delaying strobe_in through a shift register
        # of length fft.delay. Assumes strobe_in is continuous (always 1).
        strobe_delay = Signal(fft.delay)
        with m.If(self.strobe_in):
            m.d.sync += strobe_delay.eq(Cat(1, strobe_delay[:-1]))
        with m.Else():
            m.d.sync += strobe_delay.eq(Cat(0, strobe_delay[:-1]))
        fft_strobe = strobe_delay[-1]

        # Double-buffer bank selection
        write_bank = Signal()
        frame_available = Signal()

        # Write counter (sequential addresses within current bank)
        write_counter = Signal(self.fft_order_log2)

        # Read state
        read_counter = Signal(self.fft_order_log2)
        reading = Signal()
        read_valid = Signal()
        # Marks that the next valid output is the last bin of the frame.
        # Set when out_last fires while a read is in progress, so the
        # pipeline tail (1 cycle behind) still needs to be output.
        last_output = Signal()
        # Marker flag: set on frame boundary, cleared after the first
        # valid output. Replaces bin 0 with 0x1234 as a frame marker.
        marker = Signal()

        # Bit-reverse the read counter
        read_addr_reversed = Signal(self.fft_order_log2)
        for i in range(self.fft_order_log2):
            m.d.comb += read_addr_reversed[i].eq(
                read_counter[self.fft_order_log2 - 1 - i])

        # Write address: {write_bank, write_counter}
        write_addr = Cat(write_counter, write_bank)
        # Read address: {~write_bank, bit_reversed_counter}
        # XOR LSB of bit-reversed address to apply fftshift
        # (swap first and second halves for DC-centered output)
        read_addr = Cat(read_addr_reversed ^ 1, ~write_bank)

        # Write FFT output to sequential addresses in current bank
        with m.If(fft_strobe):
            m.d.sync += write_counter.eq(write_counter + 1)

        m.d.comb += [
            wrport_re.en.eq(fft_strobe),
            wrport_re.addr.eq(write_addr),
            wrport_re.data.eq(fft.re_out),
            wrport_im.en.eq(fft_strobe),
            wrport_im.addr.eq(write_addr),
            wrport_im.data.eq(fft.im_out),
        ]

        # read_valid tracks reading with 1 fft_strobe cycle delay,
        # compensating for synchronous memory read latency.
        with m.If(fft_strobe):
            m.d.sync += read_valid.eq(reading)

        # Read state machine (gated by fft_strobe)
        with m.If(fft.out_last & fft_strobe):
            m.d.sync += [
                write_bank.eq(~write_bank),
                frame_available.eq(1),
                reading.eq(1),
                read_counter.eq(0),
                last_output.eq(reading),
                marker.eq(1),
            ]
        with m.Elif(fft_strobe):
            m.d.sync += last_output.eq(0)
            with m.If(reading):
                m.d.sync += read_counter.eq(read_counter + 1)
                with m.If(read_counter == fft_size - 1):
                    m.d.sync += reading.eq(0)

        # Read from bit-reversed addresses in opposite bank
        m.d.comb += [
            rdport_re.en.eq(1),
            rdport_re.addr.eq(read_addr),
            rdport_im.en.eq(1),
            rdport_im.addr.eq(read_addr),
        ]

        # Output connections
        strobe_out = (read_valid | last_output) & frame_available & fft_strobe
        m.d.comb += [
            fft.clken.eq(self.strobe_in),
            fft.common_edge_2x.eq(self.common_edge_2x),
            fft.re_in.eq(self.re_in),
            fft.im_in.eq(self.im_in),

            self.strobe_out.eq(strobe_out),
            self.out_last.eq(last_output & frame_available & fft_strobe),
        ]
        # Replace bin 0 of each frame with 0x1234 marker.
        # Use read_valid & ~last_output to target bin 0 of the NEW frame,
        # not the last_output tail cycle (which is the last bin of the
        # previous frame).
        marker_active = marker & read_valid & ~last_output & frame_available & fft_strobe
        with m.If(marker_active):
            m.d.comb += [
                self.re_out.eq(0x1234),
                self.im_out.eq(0x1234),
            ]
            m.d.sync += marker.eq(0)
        with m.Else():
            m.d.comb += [
                self.re_out.eq(rdport_re.data),
                self.im_out.eq(rdport_im.data),
            ]

        return m


if __name__ == '__main__':
    topfft = TopFFT()
    amaranth.cli.main(
        topfft, ports=topfft.ports())