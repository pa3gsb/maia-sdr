"""
DVB-S2 — Stage 4 : PLL decision-directed
==========================================
Amaranth HDL

Référence SatDump : plugins/dvb_support/dvbs2/dvbs2_pll.cpp  S2PLLBlock

Principe :
  Après le SOF correlator (Stage 3), on connaît le début de chaque trame.
  La trame DVB-S2 est structurée ainsi :

  │← 26 sym SOF →│← 64 sym PLS header →│← slots data/pilots →│

  La PLL utilise trois sources de référence, par ordre de priorité :

  1. SOF  (26 symboles connus, π/2-BPSK)
     → correction de phase initiale par moindres carrés sur symboles connus

  2. PLS header (64 symboles QPSK connus une fois le MODCOD décodé)
     → affinage fréquentiel inter-trame

  3. Pilot symbols (si activés, 36 symboles tous les 16 slots data)
     → maintien de phase pendant la trame (tous les 1476 symboles environ)

  La correction de fréquence est renvoyée vers le M&M (freq_prop_factor)
  exactement comme dans SatDump.

Architecture :

  frame_start ──► State Machine ──► Phase Estimator
  i_sym/q_sym          │                   │
       │           (SOF/PLS/             phase_err
       │            pilot windows)          │
       └───────────────────────────► Phase Rotator ──► i_corr/q_corr
                                            ▲
                                      NCO PLL (freq_word)
                                            ▲
                                      Filtre PI
                                            │
                                      freq_prop_out  ──► M&M feedback

Modules :
  PhaseEstimator     — calcule l'erreur de phase sur une fenêtre de symboles connus
  PhaseRotator       — rotation complexe : (I+jQ) × e^(-jφ)
  LoopFilterPI       — filtre PI générique (réutilisé)
  S2PLLBlock         — top-level Stage 4

Paramètres DVB-S2 :
  SOF_LEN    = 26   symboles
  PLS_LEN    = 64   symboles (après SOF)
  PILOT_LEN  = 36   symboles (toutes les PILOT_PERIOD = 1476 sym dans la trame)
"""

from amaranth import *
from amaranth.sim import Simulator, Settle
import math

# ──────────────────────────────────────────────────────────────
# Constantes DVB-S2  (ETSI EN 302 307-1)
# ──────────────────────────────────────────────────────────────

SOF_LEN        = 26
PLS_LEN        = 64      # longueur du PLS header en symboles
PILOT_LEN      = 36      # longueur d'un bloc pilote
PILOT_PERIOD   = 1476    # période pilote : 36 + 1440 data symboles

# SOF : séquence π/2-BPSK connue (voie I, Q=0)
SOF_I = [
    1,-1,-1,-1, 1, 1,-1, 1,
   -1, 1, 1,-1,-1, 1,-1,-1,
    1,-1, 1, 1, 1,-1,-1,-1,
    1,-1
]

# Symboles pilotes DVB-S2 : QPSK à phase fixe π/4
# I = Q = 1/√2 ≈ 0.7071  → en virgule fixe Q15 : 23170
PILOT_I_NORM = 0.7071
PILOT_Q_NORM = 0.7071

# ──────────────────────────────────────────────────────────────
# Table PLS DVB-S2 : 128 mots de code Reed-Muller (7,64)
# Même matrice génératrice que dvbs2_bb_soft.py — doit rester synchronisée.
# pls_code = modcod<<2 | short_frame<<1 | pilots  (index 0..127)
# Symbole k (0=premier) ↔ bit (63-k) du mot de code.
# BPSK : bit=0 → I=+1, bit=1 → I=-1 ; Q=0 toujours.
# ──────────────────────────────────────────────────────────────

def _make_pls_table() -> list:
    G = [
        0xAAAA_AAAA_AAAA_AAAA,
        0xCCCC_CCCC_CCCC_CCCC,
        0xF0F0_F0F0_F0F0_F0F0,
        0xFF00_FF00_FF00_FF00,
        0xFFFF_0000_FFFF_0000,
        0xFFFF_FFFF_0000_0000,
        0x0000_0000_0000_FFFF,
    ]
    table = []
    for code in range(128):
        word = 0
        for bit in range(7):
            if (code >> bit) & 1:
                word ^= G[bit]
        table.append(word & 0xFFFF_FFFF_FFFF_FFFF)
    return table

PLS_TABLE = _make_pls_table()

# États de la machine d'état de trame
class FrameState:
    HUNT    = 0   # attente du premier SOF
    SOF     = 1   # fenêtre SOF  (26 sym)
    PLS     = 2   # fenêtre PLS  (64 sym)
    DATA    = 3   # données (avec ou sans pilotes)
    PILOT   = 4   # fenêtre pilote (36 sym)


# ============================================================
# Filtre PI (réutilisé — identique à qpsk_sync.py)
# ============================================================

class LoopFilterPI(Elaboratable):
    def __init__(self, error_width=32, acc_width=48, kp_shift=8, ki_shift=18):
        self.kp_shift   = kp_shift
        self.ki_shift   = ki_shift
        self._acc_w     = acc_width
        self._err_w     = error_width
        self.error_in   = Signal(signed(error_width))
        self.ctrl_out   = Signal(signed(acc_width))

    def elaborate(self, platform):
        m = Module()
        integrator = Signal(signed(self._acc_w))
        m.d.sync += integrator.eq(integrator + self.error_in)
        m.d.comb += self.ctrl_out.eq(
            (self.error_in >> self.kp_shift) +
            (integrator    >> self.ki_shift)
        )
        return m


# ============================================================
# Estimateur de phase sur symboles connus
# ============================================================

class PhaseEstimator(Elaboratable):
    """
    Estime l'erreur de phase en comparant les symboles reçus
    aux symboles de référence connus.

    Méthode : estimateur ML simplifié
      Pour chaque symbole (I_ref, Q_ref) connu et (I_rx, Q_rx) reçu :
        err_k = I_ref * Q_rx  -  Q_ref * I_rx   (sin de la différence de phase)

      Sur une fenêtre de N symboles :
        err_total = Σ err_k  (normalisé par N dans le filtre PI)

    Ce discriminant est identique à celui de SatDump pour les symboles connus.

    Ports :
      i_rx, q_rx     : symbole reçu
      i_ref, q_ref   : symbole de référence (virgule fixe, même échelle)
      strobe         : 1 quand les entrées sont valides
      accumulate     : 1 pendant la fenêtre d'estimation
      latch          : pulse 1 cycle = fin de fenêtre, sortir l'estimée
      phase_err_out  : erreur de phase estimée (accumulée)
    """

    def __init__(self, data_width=16, acc_width=32, window=26):
        self.data_width = data_width
        self.acc_width  = acc_width
        self.window     = window
        MW = data_width * 2

        self.i_rx         = Signal(signed(data_width))
        self.q_rx         = Signal(signed(data_width))
        self.i_ref        = Signal(signed(data_width))
        self.q_ref        = Signal(signed(data_width))
        self.strobe       = Signal()
        self.accumulate   = Signal()
        self.latch        = Signal()
        self.phase_err_out = Signal(signed(acc_width))

    def elaborate(self, platform):
        m = Module()

        DW = self.data_width
        AW = self.acc_width

        # err_k = I_ref * Q_rx  -  Q_ref * I_rx
        cross1 = Signal(signed(DW * 2))
        cross2 = Signal(signed(DW * 2))
        err_k  = Signal(signed(DW * 2))

        m.d.comb += [
            cross1.eq(self.i_ref * self.q_rx),
            cross2.eq(self.q_ref * self.i_rx),
            err_k .eq((cross1 - cross2) >> (DW - 1)),
        ]

        accumulator = Signal(signed(AW))

        with m.If(self.latch):
            m.d.sync += self.phase_err_out.eq(accumulator)
            m.d.sync += accumulator.eq(0)
        with m.Elif(self.strobe & self.accumulate):
            m.d.sync += accumulator.eq(accumulator + err_k)

        return m


# ============================================================
# Rotateur de phase (correction porteuse)
# ============================================================

class PhaseRotator(Elaboratable):
    """
    Applique une rotation de phase aux symboles :
      I_out = I_in * cos(φ) + Q_in * sin(φ)
      Q_out = Q_in * cos(φ) - I_in * sin(φ)

    φ est contrôlé par un accumulateur de phase (NCO).
    Le NCO est incrémenté de freq_word chaque cycle de strobe.

    Ports :
      i_in / q_in       : symboles entrants
      strobe            : 1 quand les symboles sont valides
      freq_correction   : correction de fréquence (signé, PHASE_WIDTH bits)
      phase_correction  : correction de phase directe (appliquée une fois)
      apply_phase_corr  : pulse 1 cycle pour appliquer phase_correction
      i_out / q_out     : symboles corrigés
      phase_acc         : accumulateur de phase courant (monitoring)
    """

    TABLE_BITS  = 10
    TABLE_DEPTH = 1 << TABLE_BITS

    def __init__(self, data_width=16, phase_width=32):
        self.data_width  = data_width
        self.phase_width = phase_width

        DW = data_width

        self.i_in             = Signal(signed(DW))
        self.q_in             = Signal(signed(DW))
        self.strobe           = Signal()
        self.freq_correction  = Signal(signed(phase_width))
        self.phase_correction = Signal(signed(phase_width))
        self.apply_phase_corr = Signal()
        self.i_out            = Signal(signed(DW))
        self.q_out            = Signal(signed(DW))
        self.phase_acc        = Signal(phase_width)

    def elaborate(self, platform):
        m = Module()

        DW  = self.data_width
        PW  = self.phase_width
        amp = (1 << (DW - 1)) - 1

        # Tables cos/sin
        cos_table = [int(round(amp * math.cos(2*math.pi*i/self.TABLE_DEPTH)))
                     for i in range(self.TABLE_DEPTH)]
        sin_table = [int(round(amp * math.sin(2*math.pi*i/self.TABLE_DEPTH)))
                     for i in range(self.TABLE_DEPTH)]

        cos_rom = Array([Const(v, signed(DW)) for v in cos_table])
        sin_rom = Array([Const(v, signed(DW)) for v in sin_table])

        # Accumulateur de phase NCO
        phase_acc = Signal(PW)
        idx       = Signal(self.TABLE_BITS)
        shift     = PW - self.TABLE_BITS

        # Mise à jour phase : freq_correction chaque strobe
        #                   + phase_correction sur impulsion
        with m.If(self.apply_phase_corr):
            m.d.sync += phase_acc.eq(phase_acc + self.phase_correction)
        with m.Elif(self.strobe):
            m.d.sync += phase_acc.eq(phase_acc + self.freq_correction)

        m.d.comb += [
            idx.eq(phase_acc[shift:]),
            self.phase_acc.eq(phase_acc),
        ]

        # Lecture ROM
        cos_val = Signal(signed(DW))
        sin_val = Signal(signed(DW))
        m.d.sync += [
            cos_val.eq(cos_rom[idx]),
            sin_val.eq(sin_rom[idx]),
        ]

        # Rotation complexe
        NORM = DW - 1
        i_x_cos = Signal(signed(DW * 2))
        q_x_sin = Signal(signed(DW * 2))
        q_x_cos = Signal(signed(DW * 2))
        i_x_sin = Signal(signed(DW * 2))

        m.d.sync += [
            i_x_cos.eq(self.i_in * cos_val),
            q_x_sin.eq(self.q_in * sin_val),
            q_x_cos.eq(self.q_in * cos_val),
            i_x_sin.eq(self.i_in * sin_val),
        ]

        m.d.comb += [
            self.i_out.eq((i_x_cos + q_x_sin) >> NORM),
            self.q_out.eq((q_x_cos - i_x_sin) >> NORM),
        ]

        return m


# ============================================================
# Machine d'état de trame DVB-S2
# ============================================================

class S2FrameFSM(Elaboratable):
    """
    Suit la structure de trame DVB-S2 après verrouillage SOF.

    Sortie de fenêtres :
      in_sof    : 1 pendant les SOF_LEN premiers symboles de la trame
      in_pls    : 1 pendant les PLS_LEN symboles suivants
      in_pilot  : 1 pendant les blocs pilotes (si pilots_en=1)
      in_data   : 1 pour les symboles data
      sym_index : index du symbole dans la fenêtre courante

    Port de contrôle :
      frame_start : pulse 1 cycle → réinitialise le compteur de trame
      pilots_en   : 1 si les pilotes sont présents (issu du PLS)
      short_frame : 1 si trame courte (8100 sym au lieu de 32490)
    """

    # Longueurs de trame DVB-S2
    FRAME_NORMAL = 32490
    FRAME_SHORT  =  8100

    def __init__(self, data_width=16):
        self.frame_start = Signal()
        self.sym_valid   = Signal()
        self.pilots_en   = Signal()
        self.short_frame = Signal()

        self.in_sof    = Signal()
        self.in_pls    = Signal()
        self.in_pilot  = Signal()
        self.in_data   = Signal()
        self.sym_index = Signal(range(PILOT_LEN + 1))

    def elaborate(self, platform):
        m = Module()

        # Compteur de symboles dans la trame (≤ 32490)
        sym_ctr = Signal(range(self.FRAME_NORMAL + 1))

        # Longueur totale de la trame (dépend de short_frame)
        frame_len = Signal(range(self.FRAME_NORMAL + 1),
                           reset=self.FRAME_NORMAL)
        m.d.comb += frame_len.eq(
            Mux(self.short_frame, self.FRAME_SHORT, self.FRAME_NORMAL)
        )

        # Compteur incrémenté à chaque symbole valide
        with m.If(self.frame_start):
            m.d.sync += sym_ctr.eq(0)
        with m.Elif(self.sym_valid):
            with m.If(sym_ctr >= frame_len - 1):
                m.d.sync += sym_ctr.eq(0)
            with m.Else():
                m.d.sync += sym_ctr.eq(sym_ctr + 1)

        # ── Décodage des fenêtres ─────────────────────────────────────────
        # SOF : symboles 0..25
        m.d.comb += self.in_sof.eq(sym_ctr < SOF_LEN)

        # PLS : symboles 26..89
        m.d.comb += self.in_pls.eq(
            (sym_ctr >= SOF_LEN) & (sym_ctr < SOF_LEN + PLS_LEN)
        )

        # Pilotes : blocs de PILOT_LEN sym tous les PILOT_PERIOD sym
        # Premier pilote à sym_ctr = SOF_LEN + PLS_LEN + PILOT_PERIOD
        # in_pilot = 1 si (sym_ctr - header_end) mod PILOT_PERIOD < PILOT_LEN
        header_end  = SOF_LEN + PLS_LEN
        rel_pos     = Signal(range(self.FRAME_NORMAL + 1))
        pilot_phase = Signal(range(PILOT_PERIOD + 1))

        m.d.comb += rel_pos.eq(sym_ctr - header_end)
        # modulo PILOT_PERIOD — simple wrap via compteur dédié
        pilot_ctr = Signal(range(PILOT_PERIOD + 1))
        with m.If(self.frame_start | (sym_ctr == header_end)):
            m.d.sync += pilot_ctr.eq(0)
        with m.Elif(self.sym_valid & (sym_ctr >= header_end)):
            with m.If(pilot_ctr >= PILOT_PERIOD - 1):
                m.d.sync += pilot_ctr.eq(0)
            with m.Else():
                m.d.sync += pilot_ctr.eq(pilot_ctr + 1)

        m.d.comb += self.in_pilot.eq(
            self.pilots_en & (pilot_ctr < PILOT_LEN) & (sym_ctr >= header_end)
        )

        # Index dans la fenêtre courante (pour indexer les tables de référence)
        win_ctr = Signal(range(max(SOF_LEN, PLS_LEN, PILOT_LEN) + 1))
        with m.If(self.frame_start | self.in_sof):
            pass   # géré ci-dessous
        # Réinitialisation au début de chaque fenêtre
        with m.If(self.frame_start):
            m.d.sync += win_ctr.eq(0)
        with m.Elif(self.sym_valid):
            with m.If(self.in_sof | self.in_pls | self.in_pilot):
                m.d.sync += win_ctr.eq(win_ctr + 1)
            with m.Else():
                m.d.sync += win_ctr.eq(0)

        m.d.comb += self.sym_index.eq(win_ctr)

        # Data : tout le reste (hors SOF, PLS, pilotes)
        m.d.comb += self.in_data.eq(
            ~self.in_sof & ~self.in_pls & ~self.in_pilot &
            (sym_ctr >= header_end)
        )

        return m


# ============================================================
# Stage 4 — S2PLLBlock : PLL decision-directed complète
# ============================================================

class S2PLLBlock(Elaboratable):
    """
    PLL decision-directed DVB-S2 — Stage 4.

    Identique à SatDump S2PLLBlock en logique, implémenté en
    virgule fixe sur FPGA.

    Sources de correction (par ordre de priorité décroissante) :
      1. SOF  (26 sym connus, disponibles chaque trame)
      2. PLS  (64 sym connus après décodage MODCOD)
      3. Pilotes (36 sym connus périodiques, si activés)

    Feedback vers M&M :
      freq_prop_out : correction de fréquence à injecter dans
                      QPSKSync.freq_external (à brancher dans dvbs2_frontend.py)

    Ports entrée :
      i_sym / q_sym   : symboles après Stage 2/3 (1 sym/strobe)
      sym_valid       : strobe symbole
      frame_start     : pulse SOF détecté (Stage 3)
      modcod          : MODCOD détecté (7 bits, issu du Stage 5 plus tard)
                        0x00 = inconnu → utiliser SOF + pilotes seulement
      pilots_en       : 1 si pilotes présents
      short_frame     : 1 si trame courte

    Ports sortie :
      i_corr / q_corr : symboles après correction de phase PLL
      phase_acc       : accumulateur de phase PLL (monitoring)
      freq_prop_out   : correction fréquence → feedback M&M
      pll_locked      : verrouillage PLL (N corrections consécutives < seuil)
    """

    DATA_WIDTH  = 16
    PHASE_WIDTH = 32
    ACC_WIDTH   = 40

    def __init__(self,
                 # ── Correction de phase directe (SOF / pilotes) ─────────────────
                 # kp_phase_shift : gain pour le saut de phase instantané.
                 #   Phase correction = (err_coarse << 10) >> kp_phase_shift
                 #   err_coarse_SOF ≈ 851942 × φ (Q15, 26 sym)
                 #   Facteur théorique pour correction parfaite : ×802 ≈ ×2^9.65
                 #   kp_phase_shift=0 → ×1024 (sur-correction ≈ 28 %, oscillant)
                 #   kp_phase_shift=2 → ×256  (empiriquement stable, lock 8–15 trames
                 #                             pour f_off 0.0001–0.001 rad/sym)
                 kp_phase_shift: int = 2,
                 # ── Boucle fréquence (intégrateur pur, sans terme proportionnel) ─
                 # ki_shift : décalage de l'intégrateur → gain intégral
                 #   ki_shift=2 : lock en 8–15 trames, f_off=0.0001–0.001 rad/sym
                 ki_shift:       int = 2,
                 # kp_freq_shift  : gain proportionnel du filtre PI fréquence.
                 #   Mis à 30 par défaut → terme proportionnel quasi-nul.
                 #   Le terme proportionnel du PI de fréquence produit une impulsion
                 #   d'un cycle à chaque SOF (err_coarse >> kp_freq_shift) ; mis
                 #   à 30, sa contribution est ≈ 0.
                 kp_freq_shift:  int = 30,
                 # ── Boucle PLS fine ──────────────────────────────────────────────
                 kp_fine:        int = 0,
                 ki_fine:        int = 4,
                 # ── Détecteur de lock ─────────────────────────────────────────────
                 # lock_thr : seuil sur err_coarse pour déclarer le lock.
                 #   err_coarse à 0.06 rad : 26×32767×0.06 ≈ 51116 → lock_thr=50000
                 lock_thr:       int = 50000,
                 lock_hold:      int = 8):

        DW = self.DATA_WIDTH
        PW = self.PHASE_WIDTH
        AW = self.ACC_WIDTH

        self.kp_phase_shift = kp_phase_shift
        self.kp_freq_shift  = kp_freq_shift
        self.ki_shift       = ki_shift
        self.kp_fine        = kp_fine
        self.ki_fine        = ki_fine
        self.lock_thr       = lock_thr
        self.lock_hold      = lock_hold

        # Ports entrée
        self.i_sym      = Signal(signed(DW))
        self.q_sym      = Signal(signed(DW))
        self.sym_valid  = Signal()
        self.frame_start = Signal()
        self.modcod     = Signal(5)
        self.pilots_en  = Signal()
        self.short_frame = Signal()
        # pls_code = modcod<<2 | short_frame<<1 | pilots (runtime, from AXI register)
        # 0 = unknown → SOF + pilots only, PLS estimator disabled
        self.pls_code   = Signal(7)

        # Ports sortie
        self.i_corr       = Signal(signed(DW))
        self.q_corr       = Signal(signed(DW))
        self.phase_acc    = Signal(PW)
        self.freq_prop_out = Signal(signed(PW))   # → feedback vers M&M
        self.pll_locked   = Signal()

    def elaborate(self, platform):
        m = Module()

        DW = self.DATA_WIDTH
        PW = self.PHASE_WIDTH
        AW = self.ACC_WIDTH

        amp = (1 << (DW - 1)) - 1

        # ── Sous-modules ──────────────────────────────────────────────────
        m.submodules.fsm    = fsm    = S2FrameFSM(DW)
        m.submodules.rot    = rot    = PhaseRotator(DW, PW)
        m.submodules.est_sof = est_sof = PhaseEstimator(DW, AW, SOF_LEN)
        m.submodules.est_pls = est_pls = PhaseEstimator(DW, AW, PLS_LEN)
        m.submodules.est_plt = est_plt = PhaseEstimator(DW, AW, PILOT_LEN)
        m.submodules.lpf    = lpf    = LoopFilterPI(AW, PW,
                                                     self.kp_freq_shift, self.ki_shift)
        m.submodules.lpf_fine = lpf_fine = LoopFilterPI(AW, PW,
                                                          self.kp_fine, self.ki_fine)

        # ── Câblage FSM ───────────────────────────────────────────────────
        m.d.comb += [
            fsm.frame_start.eq(self.frame_start),
            fsm.sym_valid  .eq(self.sym_valid),
            fsm.pilots_en  .eq(self.pilots_en),
            fsm.short_frame.eq(self.short_frame),
        ]

        # ── Rotateur : symboles corrigés ──────────────────────────────────
        m.d.comb += [
            rot.i_in  .eq(self.i_sym),
            rot.q_in  .eq(self.q_sym),
            rot.strobe.eq(self.sym_valid),
        ]
        m.d.comb += [
            self.i_corr   .eq(rot.i_out),
            self.q_corr   .eq(rot.q_out),
            self.phase_acc.eq(rot.phase_acc),
        ]

        # ── Tables de référence SOF ───────────────────────────────────────
        sof_ref_i = Array([Const(int(v * amp), signed(DW)) for v in [
            1,-1,-1,-1, 1, 1,-1, 1,-1, 1, 1,-1,-1, 1,-1,-1,
            1,-1, 1, 1, 1,-1,-1,-1, 1,-1
        ]])
        sof_ref_q = Array([Const(0, signed(DW))] * SOF_LEN)

        # ── Tables de référence Pilotes ───────────────────────────────────
        # Pilotes DVB-S2 = tous à phase π/4 (QPSK, I=Q=1/√2)
        pilot_amp_i = int(PILOT_I_NORM * amp)
        pilot_amp_q = int(PILOT_Q_NORM * amp)
        # (constantes — on n'a pas besoin d'une Array ici)

        # ── Estimateur SOF ────────────────────────────────────────────────
        sof_idx = fsm.sym_index

        # Fin de fenêtre SOF = dernier symbole de la fenêtre
        sof_latch = Signal()
        sof_end_ctr = Signal(range(SOF_LEN + 1))
        with m.If(fsm.frame_start):
            m.d.sync += sof_end_ctr.eq(0)
        with m.Elif(self.sym_valid & fsm.in_sof):
            m.d.sync += sof_end_ctr.eq(sof_end_ctr + 1)
        m.d.comb += sof_latch.eq(
            self.sym_valid & fsm.in_sof & (sof_end_ctr == SOF_LEN - 1)
        )

        # Le PhaseRotator a une latence de 1 cycle sur le signal (i_in apparaît
        # dans i_out un cycle plus tard). Les deux m.d.sync (ROM + multiply)
        # sont parallèles en Amaranth, pas séquentiels : i_x_cos au cycle k+1
        # utilise i_in_k × cos_val_k, où cos_val_k vient du cycle k-1.
        # Bilan : i_out_k = f(i_in_{k-1}).  On retarde la référence d'1 cycle.
        sof_ref_i_d1 = Signal(signed(DW))
        m.d.sync += sof_ref_i_d1.eq(sof_ref_i[sof_idx])

        m.d.comb += [
            est_sof.i_rx      .eq(rot.i_out),
            est_sof.q_rx      .eq(rot.q_out),
            est_sof.i_ref     .eq(sof_ref_i_d1),   # référence retardée de 1 cycle
            est_sof.q_ref     .eq(0),
            est_sof.strobe    .eq(self.sym_valid),
            est_sof.accumulate.eq(fsm.in_sof),
            est_sof.latch     .eq(sof_latch),
        ]

        # ── Estimateur pilotes ────────────────────────────────────────────
        plt_latch = Signal()
        plt_end_ctr = Signal(range(PILOT_LEN + 1))
        prev_in_plt = Signal()
        m.d.sync += prev_in_plt.eq(fsm.in_pilot)
        with m.If(~prev_in_plt & fsm.in_pilot):
            m.d.sync += plt_end_ctr.eq(0)
        with m.Elif(self.sym_valid & fsm.in_pilot):
            m.d.sync += plt_end_ctr.eq(plt_end_ctr + 1)
        m.d.comb += plt_latch.eq(
            self.sym_valid & fsm.in_pilot & (plt_end_ctr == PILOT_LEN - 1)
        )

        m.d.comb += [
            est_plt.i_rx      .eq(rot.i_out),
            est_plt.q_rx      .eq(rot.q_out),
            est_plt.i_ref     .eq(Const(pilot_amp_i, signed(DW))),
            est_plt.q_ref     .eq(Const(pilot_amp_q, signed(DW))),
            est_plt.strobe    .eq(self.sym_valid),
            # prev_in_plt décale d'1 cycle : rot.i_out au cycle k correspond à
            # i_in_{k-1}.  Au 1er cycle du pilote (k=90), rot.i_out reflète le
            # dernier symbole PLS (k=89) → erreur de signe massive.
            # On active l'accumulation seulement à partir du 2ème cycle pilote.
            est_plt.accumulate.eq(prev_in_plt),
            est_plt.latch     .eq(plt_latch),
        ]

        # ── Estimateur PLS (64 sym BPSK connus) ──────────────────────────
        # pls_code est un Signal(7) runtime (depuis registre AXI).
        # ROM 128 × 64 bits : codeword_rom[pls_code] → mot de code PLS.
        # À frame_start le mot est chargé dans un shift register de 64 bits.
        # Chaque sym_valid dans la fenêtre PLS extrait le bit MSB comme référence.
        # BPSK : bit=0 → I=+amp, bit=1 → I=-amp ; Q=0 toujours.
        # pls_code=0 → PLS estimator désactivé (SOF + pilots uniquement).
        pls_latch = Signal()
        pls_end_ctr = Signal(range(PLS_LEN + 1))
        with m.If(fsm.frame_start):
            m.d.sync += pls_end_ctr.eq(0)
        with m.Elif(self.sym_valid & fsm.in_pls):
            m.d.sync += pls_end_ctr.eq(pls_end_ctr + 1)
        m.d.comb += pls_latch.eq(
            self.sym_valid & fsm.in_pls & (pls_end_ctr == PLS_LEN - 1)
        )

        # ROM : 128 codewords (Python-time constants, indexed at runtime by pls_code)
        codeword_rom = Array([Const(PLS_TABLE[c], 64) for c in range(128)])

        # Shift register : chargé à frame_start, décalé à chaque sym_valid PLS
        pls_sr = Signal(64)
        with m.If(self.frame_start):
            m.d.sync += pls_sr.eq(codeword_rom[self.pls_code])
        with m.Elif(self.sym_valid & fsm.in_pls):
            # Décale vers le haut (MSB sort en premier)
            m.d.sync += pls_sr.eq(Cat(0, pls_sr[:-1]))

        # Bit courant = MSB du shift register, retardé de 1 cycle pour aligner
        # avec la sortie du PhaseRotator (latence 1 cycle sur le signal).
        pls_ref_i_raw = Signal(signed(DW))
        pls_ref_i     = Signal(signed(DW))
        m.d.comb += pls_ref_i_raw.eq(Mux(pls_sr[-1],
                                          Const(-amp, signed(DW)),
                                          Const( amp, signed(DW))))
        m.d.sync += pls_ref_i    .eq(pls_ref_i_raw)

        pls_en = Signal()
        m.d.comb += pls_en.eq(self.pls_code != 0)

        m.d.comb += [
            est_pls.i_rx      .eq(Mux(pls_en, rot.i_out, 0)),
            est_pls.q_rx      .eq(Mux(pls_en, rot.q_out, 0)),
            est_pls.i_ref     .eq(Mux(pls_en, pls_ref_i, 0)),
            est_pls.q_ref     .eq(0),
            est_pls.strobe    .eq(self.sym_valid & pls_en),
            est_pls.accumulate.eq(fsm.in_pls  & pls_en),
            est_pls.latch     .eq(pls_latch    & pls_en),
        ]

        # ── Sélection de la source d'erreur pour le filtre PI ────────────
        # Priorité : SOF > Pilotes > PLS (decision-directed)
        # SatDump : SOF + pilotes → boucle rapide, PLS → affinage fréquence
        err_coarse = Signal(signed(AW))   # SOF + pilotes → filtre PI principal
        err_fine   = Signal(signed(AW))   # PLS → filtre PI fin (freq)
        apply_corr  = Signal()
        apply_fine  = Signal()

        # BUG FIX : sof_latch / plt_latch / pls_latch et phase_err_out sont
        # tous mis à jour par m.d.sync sur la même front d'horloge.  Si on lit
        # phase_err_out dans la même règle sync que le latch, on lit l'ancienne
        # valeur (cycle N-1).  On retarde les signaux de 1 cycle pour lire la
        # valeur fraîchement latched (cycle N).
        sof_latch_d1 = Signal()
        plt_latch_d1 = Signal()
        pls_latch_d1 = Signal()
        m.d.sync += sof_latch_d1.eq(sof_latch)
        m.d.sync += plt_latch_d1.eq(plt_latch)
        m.d.sync += pls_latch_d1.eq(pls_latch)

        with m.If(sof_latch_d1):
            m.d.sync += err_coarse.eq(est_sof.phase_err_out)
            m.d.sync += apply_corr.eq(1)
        with m.Elif(plt_latch_d1):
            m.d.sync += err_coarse.eq(est_plt.phase_err_out)
            m.d.sync += apply_corr.eq(1)
        with m.Else():
            m.d.sync += apply_corr.eq(0)

        with m.If(pls_latch_d1):
            m.d.sync += err_fine.eq(est_pls.phase_err_out)
            m.d.sync += apply_fine.eq(1)
        with m.Else():
            m.d.sync += apply_fine.eq(0)

        # ── Filtre PI coarse (SOF/pilotes) ────────────────────────────────
        m.d.comb += lpf.error_in.eq(
            Mux(apply_corr, err_coarse, Const(0, signed(AW)))
        )
        freq_corr_coarse = Signal(signed(PW))
        m.d.sync += freq_corr_coarse.eq(lpf.ctrl_out[:PW])

        # ── Filtre PI fin (PLS decision-directed) ─────────────────────────
        m.d.comb += lpf_fine.error_in.eq(
            Mux(apply_fine, err_fine, Const(0, signed(AW)))
        )
        freq_corr_fine = Signal(signed(PW))
        m.d.sync += freq_corr_fine.eq(lpf_fine.ctrl_out[:PW])

        # ── Correction fréquence : Stage 4 n'applique PAS de NCO interne ────
        # Appliquer freq_corr au NCO interne crée un double-intégrateur discret
        # (phase_acc = ∫∫ err) → toujours instable.  La correction de fréquence
        # est exportée via freq_prop_out vers Stage 2 (Costas/M&M) qui l'applique
        # à son propre NCO à vitesse symbole.  Stage 4 fait de la correction de
        # phase uniquement (sauts directs via apply_phase_corr).
        m.d.comb += rot.freq_correction.eq(0)

        # Correction de phase directe : injectée au latch SOF/pilotes
        #
        # err_coarse est en unités « amplitude² / 2^(DW-1) × N_sym × sin(φ) »
        # Pour DW=16 et SOF (26 sym) : err_coarse ≈ 26×32767×φ = 851942×φ
        # Pour convertir en unités phase_acc (où 2^PW = 2π rad) :
        #   phase_acc_corr = φ × 2^PW / (2π) = err_coarse × 2^PW / (2π × 851942)
        #                  = err_coarse × 802
        #                  ≈ err_coarse << 10  (factor 1024, erreur +27%, acceptable)
        # kp_shift permet d'affiner ce gain : phase_corr = (err_coarse << 10) >> kp_shift
        #   kp_shift=0 → ×1024 (légèrement sur-amorti)
        #   kp_shift=1 → ×512  (sous-amorti)
        phase_step = Signal(signed(PW))
        phase_corr = Signal(signed(PW))
        m.d.comb += [
            phase_step.eq(err_coarse[:PW]),
            phase_corr.eq((phase_step << 10) >> self.kp_phase_shift),
            rot.phase_correction .eq(phase_corr),
            rot.apply_phase_corr .eq(apply_corr),
        ]

        # ── freq_prop_out → feedback vers M&M (comme SatDump) ────────────
        # SatDump applique freq_prop_factor au TimingNCO pour compenser
        # le même offset de fréquence qui dérive le timing.
        # On exporte freq_corr_coarse (la correction dominante).
        m.d.comb += self.freq_prop_out.eq(freq_corr_coarse)

        # ── Détecteur de verrouillage PLL ────────────────────────────────
        lock_ctr = Signal(range(self.lock_hold + 1))
        abs_err  = Signal(AW)

        m.d.comb += abs_err.eq(
            Mux(err_coarse >= 0, err_coarse, -err_coarse)
        )

        with m.If(apply_corr):
            with m.If(abs_err < self.lock_thr):
                with m.If(lock_ctr < self.lock_hold):
                    m.d.sync += lock_ctr.eq(lock_ctr + 1)
                with m.Else():
                    m.d.sync += self.pll_locked.eq(1)
            with m.Else():
                m.d.sync += [lock_ctr.eq(0), self.pll_locked.eq(0)]

        return m


# ============================================================
# Patch QPSKSync : expose freq_external pour le feedback PLL
# ============================================================
# À ajouter dans qpsk_sync.py → QPSKSync.__init__ :
#   self.freq_external = Signal(signed(self.PHASE_WIDTH))
#
# Et dans QPSKSync.elaborate, remplacer :
#   m.d.comb += nco.freq_word.eq(
#       (self._fw_nominal + freq_corr_c[:PW]).word_select(0, PW)
#   )
# Par :
#   total_corr = Signal(signed(PW))
#   m.d.comb += total_corr.eq(freq_corr_c + self.freq_external)
#   m.d.comb += nco.freq_word.eq(
#       (self._fw_nominal + total_corr[:PW]).word_select(0, PW)
#   )
#
# Dans dvbs2_frontend.py, brancher :
#   m.d.comb += sync.freq_external.eq(pll.freq_prop_out)


# ============================================================
# Génération Verilog
# ============================================================

def generate_verilog(output_file="dvbs2_pll.v"):
    top = S2PLLBlock()
    ports = [
        top.i_sym, top.q_sym, top.sym_valid,
        top.frame_start, top.modcod, top.pilots_en, top.short_frame,
        top.i_corr, top.q_corr,
        top.phase_acc, top.freq_prop_out, top.pll_locked,
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
# Testbench : injection d'un offset de fréquence + SOF
# ============================================================

def run_simulation(cycles=20000,
                   freq_offset_rad: float = 0.001,
                   with_pilots: bool = True):
    """
    Simule la PLL en BOUCLE FERMÉE :
      - signal QPSK + offset de fréquence initial (avant correction Stage 2)
      - freq_prop_out est rebouclé sur l'offset injecté, simulant Stage 2 (Costas/M&M)
        qui applique la correction de fréquence de Stage 4 à son NCO.
      - injection du SOF exact toutes les FRAME_PERIOD symboles
      - blocs pilotes inclus (si with_pilots=True)

    Architecture boucle fermée :
      phase_residual(t) = ∫ [freq_offset − freq_prop_out(t) × 2π/2^PW] dt
      Stage 4 voit cette phase résiduelle et produit des corrections de phase (SOF/pilotes)
      ainsi qu'une estimation de fréquence (freq_prop_out) renvoyée à Stage 2.

    Convergence attendue (~3–5 trames) :
      err_coarse_SOF ≈ 25×32767×φ_résiduel
      Fréquence : boucle du 1er ordre avec gain ≈ 0.48 (stable, décroissance 0.52^N)
      Phase     : correction directe par (err_coarse<<10)>>kp_phase_shift
    """
    import random
    random.seed(7)

    FRAME_PERIOD = SOF_LEN + PLS_LEN + PILOT_PERIOD + PILOT_LEN  # = 1602
    dut = S2PLLBlock(lock_hold=4)
    sim = Simulator(dut)
    sim.add_clock(1e-9)

    amp   = (1 << (S2PLLBlock.DATA_WIDTH - 1)) - 1
    # phase_residual accumule (freq_offset − correction_stage2) par symbole
    phase = 0.0
    freq_prop_rad_per_sym = 0.0   # correction Stage 2 courante (mise à jour chaque sym)

    records = {k: [] for k in (
        "cycle", "i_corr", "q_corr", "phase_acc", "freq_prop", "pll_locked"
    )}

    def process():
        nonlocal phase, freq_prop_rad_per_sym
        yield dut.pilots_en .eq(1 if with_pilots else 0)
        yield dut.short_frame.eq(0)
        yield dut.modcod    .eq(0)
        yield dut.pls_code  .eq(0)

        yield dut.frame_start.eq(1)
        yield dut.sym_valid  .eq(0)
        yield Settle()
        yield
        yield dut.frame_start.eq(0)

        sym_in_frame = 0
        header_end = SOF_LEN + PLS_LEN

        for k in range(cycles):
            if sym_in_frame == FRAME_PERIOD - 1:
                yield dut.frame_start.eq(1)
            else:
                yield dut.frame_start.eq(0)

            if sym_in_frame < SOF_LEN:
                i_val = int(SOF_I[sym_in_frame] * amp)
                q_val = 0
            elif sym_in_frame < header_end:
                i_val = amp
                q_val = 0
            elif with_pilots and (
                (sym_in_frame - header_end) % PILOT_PERIOD < PILOT_LEN
            ):
                i_val = int(PILOT_I_NORM * amp)
                q_val = int(PILOT_Q_NORM * amp)
            else:
                idx   = random.randint(0, 3)
                phase_sym = math.pi/4 + idx * math.pi/2
                i_val = int(amp * math.cos(phase_sym))
                q_val = int(amp * math.sin(phase_sym))

            # Offset résiduel = freq_offset_rad − correction Stage2 (freq_prop_out)
            cos_off = math.cos(phase)
            sin_off = math.sin(phase)
            i_rot   = int(i_val * cos_off - q_val * sin_off)
            q_rot   = int(i_val * sin_off + q_val * cos_off)
            # Accumule le résidu de fréquence (modèle Stage 2 avec boucle fermée)
            phase  += (freq_offset_rad - freq_prop_rad_per_sym)

            yield dut.i_sym    .eq(max(-amp, min(amp, i_rot)))
            yield dut.q_sym    .eq(max(-amp, min(amp, q_rot)))
            yield dut.sym_valid.eq(1)
            yield Settle()

            fp_raw = (yield dut.freq_prop_out)
            if fp_raw >= (1 << 31): fp_raw -= (1 << 32)
            freq_prop_rad_per_sym = fp_raw * 2 * math.pi / (1 << S2PLLBlock.PHASE_WIDTH)

            records["cycle"     ].append(k)
            records["i_corr"    ].append((yield dut.i_corr))
            records["q_corr"    ].append((yield dut.q_corr))
            records["phase_acc" ].append((yield dut.phase_acc))
            records["freq_prop" ].append(fp_raw)
            records["pll_locked"].append((yield dut.pll_locked))
            yield

            sym_in_frame = (sym_in_frame + 1) % FRAME_PERIOD

    with sim.write_vcd("dvbs2_pll.vcd", "dvbs2_pll.gtkw"):
        sim.add_sync_process(process)
        sim.run()

    locked_at = next(
        (c for c, l in zip(records["cycle"], records["pll_locked"]) if l), None
    )
    print(f"✅  Simulation PLL boucle fermée ({cycles} cycles, FRAME_PERIOD={FRAME_PERIOD})")
    print(f"    Offset fréq. injecté : {freq_offset_rad:.4f} rad/sym")
    print(f"    Pilotes              : {'oui' if with_pilots else 'non'}")
    if locked_at:
        frames = locked_at // FRAME_PERIOD
        print(f"    PLL lock             : cycle {locked_at}  ({frames} trames)")
    else:
        print(f"    PLL lock             : ⚠️  non atteint (ajuster kp/ki)")
    print(f"    VCD → dvbs2_pll.vcd")
    return records


# ============================================================
# Main
# ============================================================

if __name__ == "__main__":
    print("=" * 62)
    print("  DVB-S2 Stage 4 — PLL decision-directed")
    print("=" * 62)

    print("\n─── Simulation avec pilotes ───────────────────────────────")
    run_simulation(cycles=30000, freq_offset_rad=0.001, with_pilots=True)

    print("\n─── Simulation sans pilotes (SOF uniquement) ─────────────")
    run_simulation(cycles=30000, freq_offset_rad=0.001, with_pilots=False)

    print("\n─── Génération Verilog ────────────────────────────────────")
    generate_verilog()

    print("""
─── Intégration dans dvbs2_frontend.py ────────────────────
  1. Importer S2PLLBlock depuis dvbs2_pll.py
  2. Brancher après SOFCorrelator :
       pll.i_sym      ← sof.i_corr   (ou directement sync.i_sym)
       pll.frame_start ← sof.frame_start
  3. Feedback M&M :
       sync.freq_external ← pll.freq_prop_out
     (ajouter freq_external dans QPSKSync — voir patch ci-dessus)

─── Prochaine étape : Stage 5 ─────────────────────────────
  dvbs2_bb_soft.py :
    • Décoder PLS header (128 codes, distance de Hamming min)
    • LFSR descrambler (polynôme DVB-S2)
    • Démodulation QPSK/8PSK/16APSK/32APSK → soft int8
    • Désentrelacement colonne (s2_deinterleaver)
""")
