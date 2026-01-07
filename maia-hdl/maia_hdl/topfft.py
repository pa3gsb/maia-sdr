from amaranth import *
from .fft import FFT # Assumes fft.py is in the same directory

class TopFFT(Elaboratable):
    def __init__(self):
        # Configuration
        self.n_log2 = 12            # 4096-point FFT
        self.width_in = 12          # Input bit width
        self.width_out = 16         # Target output bit width
        
        # Ports: Inputs
        self.clken = Signal()
        self.re_in = Signal(signed(self.width_in))
        self.im_in = Signal(signed(self.width_in))
        
        # Ports: Outputs
        self.re_out = Signal(signed(self.width_out))
        self.im_out = Signal(signed(self.width_out))
        self.strobe_out = Signal() # High when valid data is present
        self.last_out = Signal()   # High on the last bin of the frame

        # Clock Domain Names (standard for maia-sdr FFT)
        self.domain_2x = "clk2x"
        self.domain_3x = "clk3x"
        self.common_edge_2x = Signal()
        self.common_edge_3x = Signal()

    def elaborate(self, platform):
        m = Module()

        # Truncation Logic:
        # Total growth for 4096 FFT is 12 bits. 
        # To get from 12 bits to 16 bits, we allow 4 bits of growth.
        # Therefore, we must truncate 8 bits total (12 - 4 = 8).
        # We distribute the 8 truncations across the first 4 stages of the R22 FFT.
        truncates = [
            [1, 1], # Stage 0: -2 bits
            [1, 1], # Stage 1: -2 bits
            [1, 1], # Stage 2: -2 bits
            [1, 1], # Stage 3: -2 bits
            [0, 0], # Stage 4: 0
            [0, 0]  # Stage 5: 0
        ]

        # Instantiate the FFT submodule
        m.submodules.fft = fft = FFT(
            width_in=self.width_in,
            order_log2=self.n_log2,
            radix='R22',
            width_twiddle=16,
            truncates=truncates,
            use_bram_reg=True,
            window='blackmanharris', # Built-in windowing
            cmult3x=True,             # Efficient multiplier use
            domain_2x=self.domain_2x,
            domain_3x=self.domain_3x
        )

        # Connection Logic
        m.d.comb += [
            # Inputs to FFT
            fft.clken.eq(self.clken),
            fft.re_in.eq(self.re_in),
            fft.im_in.eq(self.im_in),
            fft.common_edge_2x.eq(self.common_edge_2x),
            fft.common_edge_3x.eq(self.common_edge_3x),

            # Outputs from FFT to Top Level Ports
            self.re_out.eq(fft.re_out),
            self.im_out.eq(fft.im_out),
            self.strobe_out.eq(self.clken),
            self.last_out.eq(fft.out_last)
        ]

        # Verification check: Ensure math results in 16 bits
        # Width = 12 (in) + 12 (growth) - 8 (truncations) = 16
        assert len(fft.re_out) == self.width_out

        return m

    def ports(self):
        """Returns a list of signals for Verilog generation."""
        return [
            self.clken, self.re_in, self.im_in,
            self.common_edge_2x, self.common_edge_3x,
            self.re_out, self.im_out, self.strobe_out, self.last_out
        ]

# CLI Entry point for Verilog generation
if __name__ == "__main__":
    from amaranth.back import verilog
    top = TopFFT()
    with open("top_fft.v", "w") as f:
        f.write(verilog.convert(top, ports=top.ports()))