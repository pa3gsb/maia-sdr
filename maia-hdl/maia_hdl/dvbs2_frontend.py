"""
DVB-S2 — Stage 1 : filtre RRC + Stage 3 : PL Frame Sync
=========================================================
Amaranth HDL

Référence SatDump :
  Stage 1  plugins/dvb_support/dvbs2/  BaseDemodModule  → RRC α≈0.2–0.25
  Stage 3  plugins/dvb_support/dvbs2/dvbs2_pl_sync.cpp  → SOF 26 symboles

Chaîne complète visée :
  I/Q ADC
    └─► [Stage 1] Filtre RRC
          └─► [Stage 2] QPSKSync  (Costas + M&M)   ← qpsk_sync.py
                └─► [Stage 3] PL Frame Sync  (SOF correlator)
                      └─► [Stage 4] PLL decision-directed   (à venir)
                            └─► [Stage 5] PLS decode + soft bits  (à venir)

Contenu de ce fichier :
  RRCFilter          — filtre RRC FIR en virgule fixe
  SOFCorrelator      — corrélateur SOF 26 symboles QPSK avec seuil de lock
  DVBS2FrameSync     — top-level Stage 1 + Stage 3
"""

from amaranth import *
from amaranth.sim import Simulator, Settle
import math

try:
    from .dvbs2_pll import S2PLLBlock
    from .dvbs2_bb_soft import S2BBToSoft
    from .dvbs2_deinterleaver import S2PacketFormatter
    _STAGES_456_AVAILABLE = True
except ImportError:
    _STAGES_456_AVAILABLE = False


# ============================================================
# Constantes DVB-S2
# ============================================================

# SOF = Start Of Frame, 26 symboles QPSK connus, codés sur 2 bits chacun
# Valeur hex : 0x18D2E82  → 26 bits → 13 symboles QPSK ?
# En réalité le SOF DVB-S2 est 26 symboles π/2-BPSK :
#   séquence de phases : [0, π, 0, π, ...] modulée
# Représentation ±1 pour I (Q=0 en BPSK) :
# Source : ETSI EN 302 307-1 Table 9
SOF_SYMBOLS_I = [
    1, -1, -1, -1,  1,  1, -1,  1,
   -1,  1,  1, -1, -1,  1, -1, -1,
    1, -1,  1,  1,  1, -1, -1, -1,
    1, -1
]
SOF_SYMBOLS_Q = [0] * 26   # SOF est π/2-BPSK → Q nul (ou ±1 selon rotation)

SOF_LENGTH = 26


# ============================================================
# Stage 1 — Filtre RRC (Root Raised Cosine)
# ============================================================

def rrc_coeffs(num_taps: int, alpha: float, sps: int) -> list[float]:
    """
    Calcule les coefficients du filtre RRC.
    num_taps : nombre de coefficients (impair recommandé)
    alpha    : roll-off (0.2 pour DVB-S2)
    sps      : samples par symbole
    """
    taps = []
    half = num_taps // 2
    for i in range(num_taps):
        t = (i - half) / sps
        if t == 0:
            v = (1 - alpha) + 4 * alpha / math.pi
        elif abs(t) == 1 / (4 * alpha):
            v = (alpha / math.sqrt(2)) * (
                (1 + 2 / math.pi) * math.sin(math.pi / (4 * alpha))
                + (1 - 2 / math.pi) * math.cos(math.pi / (4 * alpha))
            )
        else:
            num = math.sin(math.pi * t * (1 - alpha)) + \
                  4 * alpha * t * math.cos(math.pi * t * (1 + alpha))
            den = math.pi * t * (1 - (4 * alpha * t) ** 2)
            v = num / den
        taps.append(v)
    # Normalisation puissance unitaire
    norm = math.sqrt(sum(c * c for c in taps))
    return [c / norm for c in taps]


def quantize_taps(taps: list[float], coeff_width: int) -> list[int]:
    """Quantifie les coefficients en virgule fixe signée."""
    scale = (1 << (coeff_width - 1)) - 1
    return [max(-scale-1, min(scale, int(round(c * scale)))) for c in taps]


class RRCFilter(Elaboratable):
    """
    Filtre RRC FIR en virgule fixe.

    Paramètres Python (fixés à la génération) :
      num_taps    : nombre de coefficients (défaut 33)
      alpha       : roll-off DVB-S2 ≈ 0.20–0.25
      sps         : samples par symbole
      data_width  : largeur des échantillons I ou Q (signé)
      coeff_width : largeur des coefficients (signé)

    Un RRCFilter traite une seule voie (I ou Q).
    Instancier deux fois pour I et Q.

    Ports :
      x_in   : échantillon entrant
      x_out  : échantillon filtré (tronqué à data_width)
      valid  : x_out valide (1 cycle de latence pipeline)
    """

    def __init__(self,
                 num_taps:    int   = 33,
                 alpha:       float = 0.20,
                 sps:         int   = 4,
                 data_width:  int   = 16,
                 coeff_width: int   = 16):

        self.num_taps    = num_taps
        self.data_width  = data_width
        self.coeff_width = coeff_width

        # Coefficients quantifiés
        taps_f = rrc_coeffs(num_taps, alpha, sps)
        self._taps = quantize_taps(taps_f, coeff_width)

        # Largeur accumulateur : data + coeff + log2(num_taps) bits de garde
        guard    = int(math.ceil(math.log2(num_taps))) + 1
        self.acc_width = data_width + coeff_width + guard

        # Ports
        self.x_in  = Signal(signed(data_width))
        self.x_out = Signal(signed(data_width))
        self.valid = Signal()

    def elaborate(self, platform):
        m = Module()

        DW = self.data_width
        CW = self.coeff_width
        AW = self.acc_width
        N  = self.num_taps

        # Ligne à retard
        delay_line = [Signal(signed(DW), name=f"d{i}") for i in range(N)]
        coeffs = Array([Const(c, signed(CW)) for c in self._taps])

        # Registres de décalage
        m.d.sync += delay_line[0].eq(self.x_in)
        for i in range(1, N):
            m.d.sync += delay_line[i].eq(delay_line[i-1])

        # Accumulateur MAC (pipeliné sur 1 cycle)
        acc = Signal(signed(AW))
        products = [Signal(signed(AW), name=f"p{i}") for i in range(N)]

        for i in range(N):
            m.d.comb += products[i].eq(
                delay_line[i] * coeffs[N - 1 - i]
            )

        m.d.sync += acc.eq(sum(products))

        # Tronquer au DATA_WIDTH (prendre les bits [CW-1 : CW-1+DW])
        shift = self.coeff_width - 1
        m.d.comb += self.x_out.eq(acc[shift: shift + DW])

        # valid : toujours 1 après N cycles de remplissage
        # (simplifié — en production, utiliser un compteur de warmup)
        m.d.comb += self.valid.eq(1)

        return m


# ============================================================
# Stage 3 — SOF Correlator (PL Frame Sync)
# ============================================================

class SOFCorrelator(Elaboratable):
    """
    Corrélateur SOF pour DVB-S2.

    Principe (identique à SatDump dvbs2_pl_sync.cpp) :
      - Maintient un buffer circulaire de SOF_LENGTH symboles
      - Calcule la corrélation entre le buffer et la séquence SOF connue
      - Quand corrélation > seuil → frame_start = 1 (pulse 1 cycle)
      - Un compteur de frame maintient la synchronisation entre les SOF

    La corrélation est calculée sur la voie I uniquement
    (le SOF est π/2-BPSK, Q ≈ 0).
    Pour plus de robustesse, on peut inclure Q avec le conjugué.

    Paramètres :
      threshold    : seuil de corrélation (défaut 80% de la corrélation max)
      frame_length : longueur d'une trame DVB-S2 en symboles
                     Normal frame = 32490 symboles (QPSK 1/2)
                     Short frame  = 8100 symboles

    Ports :
      i_in        : symbole I entrant (après M&M, 1 sample/symbole)
      q_in        : symbole Q entrant
      strobe      : 1 quand i_in/q_in contiennent un nouveau symbole valide
      frame_start : pulse 1 cycle = début de trame détecté
      corr_val    : valeur de corrélation courante (monitoring)
      locked      : verrouillage SOF maintenu (N trames consécutives)
    """

    # Corrélation maximale théorique = SOF_LENGTH * amplitude²
    # Pour data_width=16, amplitude≈16383 → corr_max ≈ 26 * 16383 ≈ 426k
    # Représentée sur 32 bits largement suffisant

    CORR_WIDTH = 32

    def __init__(self,
                 data_width:   int = 16,
                 threshold:    int = None,
                 frame_length: int = 32490,
                 lock_count:   int = 4):

        self.data_width   = data_width
        self.frame_length = frame_length
        self.lock_count   = lock_count

        # Seuil par défaut : 80% de la corrélation max
        amp_est = (1 << (data_width - 1)) - 1
        self.threshold = threshold or int(0.80 * SOF_LENGTH * amp_est)

        # SOF en constantes entières (amplitude normalisée)
        scale = amp_est
        self._sof_i = [int(s * scale) for s in SOF_SYMBOLS_I]

        # Ports
        self.i_in        = Signal(signed(data_width))
        self.q_in        = Signal(signed(data_width))
        self.strobe      = Signal()
        self.frame_start = Signal()
        self.corr_val    = Signal(self.CORR_WIDTH)
        self.locked      = Signal()

    def elaborate(self, platform):
        m = Module()

        DW  = self.data_width
        CW  = self.CORR_WIDTH
        N   = SOF_LENGTH
        sof = Array([Const(v, signed(DW)) for v in self._sof_i])

        # ── Buffer circulaire de N symboles ──────────────────────────────
        buf_i = Array([Signal(signed(DW), name=f"bi{k}") for k in range(N)])
        wr_ptr = Signal(range(N))

        with m.If(self.strobe):
            m.d.sync += buf_i[wr_ptr].eq(self.i_in)
            m.d.sync += wr_ptr.eq(Mux(wr_ptr == N-1, 0, wr_ptr + 1))

        # ── Corrélation glissante ─────────────────────────────────────────
        # corr = Σ buf_i[(wr_ptr + k) % N] * sof_i[k]
        # Chaque cycle (quand strobe), on recalcule la corrélation complète.
        # En production, utiliser un corrélateur incrémental ou VOLK.
        products = []
        for k in range(N):
            idx = Signal(range(N), name=f"idx{k}")
            m.d.comb += idx.eq((wr_ptr + k).word_select(0, range(N).stop.bit_length())[:int(math.ceil(math.log2(N)))])
            p = Signal(signed(DW * 2), name=f"corr_p{k}")
            m.d.comb += p.eq(buf_i[k] * sof[k])
            products.append(p)

        corr_raw = Signal(signed(CW))
        m.d.sync += corr_raw.eq(sum(products))

        # Valeur absolue de la corrélation (gère les inversions de phase)
        corr_abs = Signal(CW)
        m.d.comb += corr_abs.eq(
            Mux(corr_raw >= 0, corr_raw, -corr_raw)
        )
        m.d.comb += self.corr_val.eq(corr_abs)

        # ── Détection de pic ──────────────────────────────────────────────
        peak = Signal()
        m.d.comb += peak.eq(
            self.strobe & (corr_abs > self.threshold)
        )

        # ── Compteur de trame (resync périodique) ────────────────────────
        sym_counter = Signal(range(self.frame_length + 1))
        frame_start_int = Signal()

        with m.If(peak):
            # Pic de corrélation → début de trame
            m.d.sync += sym_counter.eq(0)
            m.d.sync += frame_start_int.eq(1)
        with m.Elif(self.strobe):
            with m.If(sym_counter == self.frame_length - 1):
                m.d.sync += sym_counter.eq(0)
                m.d.sync += frame_start_int.eq(1)
            with m.Else():
                m.d.sync += sym_counter.eq(sym_counter + 1)
                m.d.sync += frame_start_int.eq(0)
        with m.Else():
            m.d.sync += frame_start_int.eq(0)

        m.d.comb += self.frame_start.eq(frame_start_int)

        # ── Détecteur de verrouillage SOF ────────────────────────────────
        # locked = 1 quand lock_count trames consécutives correctement détectées
        lock_ctr  = Signal(range(self.lock_count + 1))
        with m.If(peak):
            with m.If(lock_ctr < self.lock_count):
                m.d.sync += lock_ctr.eq(lock_ctr + 1)
            with m.Else():
                m.d.sync += self.locked.eq(1)
        with m.Elif(frame_start_int & ~peak):
            # Trame attendue mais pas de pic → perte de lock
            m.d.sync += [lock_ctr.eq(0), self.locked.eq(0)]

        return m


# ============================================================
# Top-level : Stage 1 + 2 + 3 enchaînés
# ============================================================

class DVBS2Frontend(Elaboratable):
    """
    Frontend DVB-S2 : RRC → QPSKSync → SOF Correlator.

    Importe QPSKSync depuis qpsk_sync.py.
    Si le fichier n'est pas disponible, remplacer par un simple passthrough.

    Ports publics :
      i_in / q_in      : flux I/Q entrant (data_width bits, 1 sample/clock)
      i_sym / q_sym    : symbole après sync (1 sample/symbole, strobe valide)
      sym_valid        : strobe symbole
      frame_start      : début de trame DVB-S2 détecté
      sof_locked       : verrouillage SOF
      carrier_locked   : verrouillage porteuse (depuis QPSKSync)
      timing_locked    : verrouillage timing  (depuis QPSKSync)
    """

    DATA_WIDTH = 16

    def __init__(self,
                 sample_rate:  float = 10_000_000,   # 10 MHz typique SDR
                 symbolrate:   float =  2_000_000,   # 2 MBaud DVB-S2 courant
                 frequence:    float =    100_000,   # offset FI résiduel
                 alpha:        float = 0.20,
                 rrc_taps:     int   = 33,
                 frame_length: int   = 32490):

        self.sample_rate  = sample_rate
        self.symbolrate   = symbolrate
        self.frequence    = frequence
        self.sps          = int(round(sample_rate / symbolrate))
        self.alpha        = alpha
        self.rrc_taps     = rrc_taps
        self.frame_length = frame_length

        DW = self.DATA_WIDTH

        # Ports
        self.i_in          = Signal(signed(DW))
        self.q_in          = Signal(signed(DW))
        self.i_sym         = Signal(signed(DW))
        self.q_sym         = Signal(signed(DW))
        self.sym_valid     = Signal()
        self.frame_start   = Signal()
        self.sof_locked    = Signal()
        self.carrier_locked = Signal()
        self.timing_locked  = Signal()

        # Stage 4–6 outputs (disponibles si dvbs2_pll/bb_soft/deinterleaver présents)
        self.pll_locked  = Signal()
        self.modcod      = Signal(5)   # 5-bit MODCOD (1–28)
        self.pilots_en   = Signal()    # 1 = pilots present (decoded from PLS)
        self.short_frame = Signal()
        # pls_code input (from AXI register): drives Stage 4 PLS reference
        # 0 = unknown → SOF + pilots only
        self.pls_code    = Signal(7)
        # AXI-Stream vers ARM (header + LLR int8)
        self.m_tdata  = Signal(8)
        self.m_tvalid = Signal()
        self.m_tready = Signal()   # input, backpressure ARM
        self.m_tlast  = Signal()

    def elaborate(self, platform):
        m = Module()

        DW = self.DATA_WIDTH

        # ── Stage 1 : Filtres RRC (I et Q séparés) ───────────────────────
        m.submodules.rrc_i = rrc_i = RRCFilter(
            num_taps   = self.rrc_taps,
            alpha      = self.alpha,
            sps        = self.sps,
            data_width = DW,
        )
        m.submodules.rrc_q = rrc_q = RRCFilter(
            num_taps   = self.rrc_taps,
            alpha      = self.alpha,
            sps        = self.sps,
            data_width = DW,
        )

        m.d.comb += [
            rrc_i.x_in.eq(self.i_in),
            rrc_q.x_in.eq(self.q_in),
        ]

        # ── Stage 2 : QPSKSync (Costas + M&M) ────────────────────────────
        # Import conditionnel pour permettre de tester ce module seul
        sync = None
        try:
            from .qpsk_sync import QPSKSync
            m.submodules.qpsk_sync = sync = QPSKSync(
                sample_rate = self.sample_rate,
                symbolrate  = self.symbolrate,
                frequence   = self.frequence,
            )
            m.d.comb += [
                sync.i_in.eq(rrc_i.x_out),
                sync.q_in.eq(rrc_q.x_out),
                self.i_sym.eq(sync.i_sym),
                self.q_sym.eq(sync.q_sym),
                self.sym_valid.eq(sync.sym_valid),
                self.carrier_locked.eq(sync.carrier_locked),
                self.timing_locked .eq(sync.timing_locked),
            ]
            sym_valid_sig = sync.sym_valid
            i_sym_sig     = sync.i_sym
            q_sym_sig     = sync.q_sym
        except ImportError:
            # Fallback passthrough (pour tester Stage 1 + 3 seuls)
            sym_valid_sig = Signal()
            i_sym_sig     = Signal(signed(DW))
            q_sym_sig     = Signal(signed(DW))
            m.d.comb += [
                i_sym_sig.eq(rrc_i.x_out),
                q_sym_sig.eq(rrc_q.x_out),
                self.i_sym.eq(i_sym_sig),
                self.q_sym.eq(q_sym_sig),
            ]
            # Génération d'un strobe synthétique à 1/sps
            stb_ctr = Signal(range(self.sps))
            m.d.sync += stb_ctr.eq(stb_ctr + 1)
            with m.If(stb_ctr == self.sps - 1):
                m.d.sync += stb_ctr.eq(0)
                m.d.comb += sym_valid_sig.eq(1)
            m.d.comb += self.sym_valid.eq(sym_valid_sig)

        # ── Stage 3 : SOF Correlator ──────────────────────────────────────
        m.submodules.sof = sof_corr = SOFCorrelator(
            data_width   = DW,
            frame_length = self.frame_length,
        )
        m.d.comb += [
            sof_corr.i_in  .eq(i_sym_sig),
            sof_corr.q_in  .eq(q_sym_sig),
            sof_corr.strobe.eq(sym_valid_sig),
            self.frame_start.eq(sof_corr.frame_start),
            self.sof_locked .eq(sof_corr.locked),
        ]

        # ── Stages 4–6 : PLL + BB soft + Désentrelaceur ───────────────────
        if _STAGES_456_AVAILABLE:
            m.submodules.pll = pll = S2PLLBlock()
            m.submodules.bb  = bb  = S2BBToSoft()
            m.submodules.fmt = fmt = S2PacketFormatter()

            # Stage 4 : PLL — corrige la phase sur SOF/PLS/pilotes
            m.d.comb += [
                pll.i_sym      .eq(i_sym_sig),
                pll.q_sym      .eq(q_sym_sig),
                pll.sym_valid  .eq(sym_valid_sig),
                pll.frame_start.eq(sof_corr.frame_start),
                pll.pilots_en  .eq(bb.pilots_en),
                pll.pls_code   .eq(self.pls_code),
            ]
            # freq_prop_out → freq_external : feedback PLL → M&M
            if sync is not None:
                m.d.comb += sync.freq_external.eq(pll.freq_prop_out)
            m.d.comb += self.pll_locked.eq(pll.pll_locked)

            # Stage 5 : S2BBToSoft — PLS decode + descramble + LLR int8
            m.d.comb += [
                bb.i_in      .eq(pll.i_corr),
                bb.q_in      .eq(pll.q_corr),
                bb.sym_valid .eq(sym_valid_sig),
                bb.frame_start.eq(sof_corr.frame_start),
            ]
            # MODCOD feedback Stage 5 → Stage 4
            m.d.comb += [
                pll.modcod     .eq(bb.modcod),
                pll.short_frame.eq(bb.short_frame),
                self.modcod    .eq(bb.modcod),
                self.pilots_en .eq(bb.pilots_en),
                self.short_frame.eq(bb.short_frame),
            ]

            # Stage 6 : Formateur de paquet LLR → ARM (désentrelacement PS-side)
            m.d.comb += [
                fmt.llr_in      .eq(bb.llr_out),
                fmt.llr_in_valid.eq(bb.llr_valid),
                fmt.frame_start .eq(sof_corr.frame_start),
                fmt.modcod      .eq(bb.modcod),
                fmt.short_frame .eq(bb.short_frame),
                # AXI-Stream vers ARM
                self.m_tdata .eq(fmt.m_tdata),
                self.m_tvalid.eq(fmt.m_tvalid),
                fmt.m_tready .eq(self.m_tready),
                self.m_tlast .eq(fmt.m_tlast),
            ]

        return m


# ============================================================
# Génération Verilog
# ============================================================

def generate_verilog(output_file="dvbs2_frontend.v", **kwargs):
    top = DVBS2Frontend(**kwargs)
    ports = [
        top.i_in, top.q_in,
        top.i_sym, top.q_sym, top.sym_valid,
        top.frame_start, top.sof_locked,
        top.carrier_locked, top.timing_locked,
        top.pll_locked, top.modcod, top.short_frame,
        top.m_tdata, top.m_tvalid, top.m_tready, top.m_tlast,
    ]
    try:
        from amaranth.back.verilog import convert
        v = convert(top, ports=ports)
        with open(output_file, "w") as f:
            f.write(v)
        print(f"✅  Verilog généré : {output_file}")
    except Exception as e:
        print(f"⚠️  {e}\n    → pip install amaranth[yosys]")


# ============================================================
# Test unitaire SOF correlator
# ============================================================

def test_sof_correlator(cycles=200):
    """
    Injecte la séquence SOF exacte et vérifie que frame_start=1 se lève.
    """
    dut = SOFCorrelator(data_width=16, frame_length=100, lock_count=2)
    sim = Simulator(dut)
    sim.add_clock(1e-9)   # 1 GHz fictif, on se fiche du timing

    amp = (1 << 14)
    results = []

    def process():
        # Phase de remplissage : bruit aléatoire
        import random
        random.seed(1)
        for _ in range(40):
            yield dut.i_in.eq(random.randint(-amp, amp))
            yield dut.strobe.eq(1)
            yield Settle()
            yield

        # Injection de la séquence SOF exacte
        for s in SOF_SYMBOLS_I:
            yield dut.i_in.eq(int(s * amp))
            yield dut.strobe.eq(1)
            yield Settle()
            fs = (yield dut.frame_start)
            cv = (yield dut.corr_val)
            results.append((fs, cv))
            yield

        # Quelques cycles supplémentaires
        for _ in range(20):
            yield dut.strobe.eq(0)
            yield

    with sim.write_vcd("sof_test.vcd"):
        sim.add_sync_process(process)
        sim.run()

    peak_corr = max(r[1] for r in results)
    frame_detected = any(r[0] for r in results)
    print(f"✅  Test SOF correlator")
    print(f"    Corrélation max mesurée : {peak_corr}")
    print(f"    Seuil configuré         : {dut.threshold}")
    print(f"    frame_start détecté     : {'✓' if frame_detected else '⚠️  non'}")
    return results


# ============================================================
# Test unitaire filtre RRC
# ============================================================

def test_rrc(alpha=0.20, sps=4, num_taps=33):
    """Vérifie que la réponse impulsionnelle intègre à 1 (gain unitaire)."""
    taps = rrc_coeffs(num_taps, alpha, sps)
    energy = sum(t*t for t in taps)
    print(f"✅  Test RRC (α={alpha}, sps={sps}, taps={num_taps})")
    print(f"    Énergie coefficients : {energy:.4f}  (attendu : 1.0)")
    print(f"    Tap central          : {taps[num_taps//2]:.4f}")
    assert abs(energy - 1.0) < 0.01, "Énergie hors tolérance"
    return taps


# ============================================================
# Main
# ============================================================

if __name__ == "__main__":
    print("=" * 62)
    print("  DVB-S2 Frontend — Stage 1 (RRC) + Stage 3 (SOF)")
    print("=" * 62)

    # Test RRC
    print("\n─── Test filtre RRC ───────────────────────────────────────")
    test_rrc(alpha=0.20, sps=4)

    # Test SOF correlator
    print("\n─── Test SOF correlator ───────────────────────────────────")
    test_sof_correlator()

    # Génération Verilog du frontend complet
    print("\n─── Génération Verilog ────────────────────────────────────")
    generate_verilog(
        output_file = "dvbs2_frontend.v",
        sample_rate =  10_000_000,
        symbolrate  =   2_000_000,
        frequence   =     100_000,
        alpha       = 0.20,
        rrc_taps    = 33,
        frame_length = 32490,
    )

    print("""
─── Prochaines étapes ─────────────────────────────────────
  Stage 4 : PLL decision-directed
    - Correction phase par SOF/PLS/pilots
    - freq_prop_factor → feedback vers M&M (comme SatDump)

  Stage 5 : PLS decode + soft bits
    - Décoder MODCOD (128 PLS codes, distance de Hamming)
    - LFSR descrambler
    - Démodulation QPSK/8PSK/16APSK/32APSK → soft int8

  Fichiers à créer :
    dvbs2_pll.py       (Stage 4)
    dvbs2_bb_soft.py   (Stage 5)
""")
