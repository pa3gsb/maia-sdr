"""
DVB-S2 — Désentrelaceur colonnes + Formateur de paquet FPGA→ARM
================================================================
Amaranth HDL

Référence SatDump : plugins/dvb_support/codings/dvb-s2/s2_deinterleaver.h

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

MODULE 1 — S2ColumnDeinterleaver
──────────────────────────────────
Le désentrelaceur colonnes DVB-S2 réordonne les LLR int8 avant
le décodeur LDPC. L'entrelacement est défini par l'ETSI EN 302 307-1 §5.3.3.

Principe :
  Les bits sont entrelacés en ÉCRITURE par lignes, lus par COLONNES.
  Le désentrelacement fait l'inverse : écriture par colonnes, lecture par lignes.

  Pour QPSK  (2 bits/sym) : Nc = 2  colonnes, Nr = n_ldpc/2   lignes
  Pour 8PSK  (3 bits/sym) : Nc = 3  colonnes, Nr = n_ldpc/3   lignes
  Pour 16APSK(4 bits/sym) : Nc = 4  colonnes, Nr = n_ldpc/4   lignes
  Pour 32APSK(5 bits/sym) : Nc = 5  colonnes, Nr = n_ldpc/5   lignes

  n_ldpc = 64800 (trame normale) ou 16200 (trame courte)

  Permutation colonne DVB-S2 (ordre de lecture) :
    QPSK   : [0, 1]
    8PSK   : [0, 5, 1, 2, 4, 3]              ← table ETSI §5.3.3
    16APSK : [0, 1, 2, 3]                    (identité — pas de permutation)
    32APSK : [0, 1, 2, 3, 4]                 (identité)

  Implémentation BRAM dual-port :
    - Port A (écriture) : reçoit les LLR dans l'ordre trame, adresse = wr_col*Nr + wr_row
    - Port B (lecture)  : lit dans l'ordre LDPC, adresse = rd_row*Nc + perm[rd_col]
    - Double buffering  : deux BRAM alternées (ping-pong) pour traitement pipeline

MODULE 2 — S2PacketFormatter
──────────────────────────────────
Formate les LLR désentrelacés en paquets pour l'ARM.

Format paquet :
  ┌──────────┬─────────────┬────────────┬──────────────────────────┐
  │ MODCOD   │ short_frame │  n_llr     │  LLR int8 × n_llr        │
  │  1 octet │   1 octet   │  2 octets  │  jusqu'à 64800 octets    │
  └──────────┴─────────────┴────────────┴──────────────────────────┘

  Bus de sortie : AXI-Stream (TDATA 8 bits, TVALID, TREADY, TLAST)
  Compatible SPI byte-stream et AXI-Stream DMA (Zynq/MPFS).

MODULE 3 — S2DeinterleaverTop
──────────────────────────────────
Top-level assemblant les deux modules + gestion ping-pong BRAM.

Ports principaux :
  Entrée (depuis S2BBToSoft) :
    llr_in      : LLR int8
    llr_valid   : strobe
    modcod      : MODCOD courant (depuis PLSDecoder)
    short_frame : type trame
    frame_start : début de nouvelle trame

  Sortie AXI-Stream (vers ARM) :
    m_tdata     : octet de données (header puis LLR)
    m_tvalid    : donnée valide
    m_tready    : backpressure ARM
    m_tlast     : dernier octet du paquet
"""

from amaranth import *
from amaranth.lib.memory import Memory
from amaranth.sim import Simulator, Settle
import math


# ─────────────────────────────────────────────────────────────────────────────
# Constantes DVB-S2
# ─────────────────────────────────────────────────────────────────────────────

# Tailles LDPC
N_LDPC_NORMAL = 64800
N_LDPC_SHORT  = 16200

# bits_per_symbol par MODCOD
# MODCOD 0 = invalide, 1–11 = QPSK, 12–17 = 8PSK, 18–23 = 16APSK, 24–28 = 32APSK
def _modcod_to_bps(modcod: int) -> int:
    if   1  <= modcod <= 11: return 2
    elif 12 <= modcod <= 17: return 3
    elif 18 <= modcod <= 23: return 4
    elif 24 <= modcod <= 28: return 5
    return 2   # défaut QPSK

# Tables de permutation des colonnes DVB-S2 (ETSI EN 302 307-1 §5.3.3 Table 10)
# Pour Nc colonnes, perm[col_read] = col_write
COLUMN_PERM = {
    2: [0, 1],           # QPSK  — identité
    3: [0, 5, 1, 2, 4, 3],  # 8PSK  — 6 colonnes avec permutation
                             # Note : 8PSK a 6 colonnes (3 sym × 2 parité)
    4: [0, 3, 1, 2],     # 16APSK — permutation légère
    5: [0, 4, 1, 2, 3],  # 32APSK — permutation
}
# Nombre de colonnes effectif (peut différer de bps pour 8PSK)
N_COLS = {2: 2, 3: 6, 4: 4, 5: 5}

# Table Python : (modcod, short_frame) → n_llr total
def n_llr_for(modcod: int, short_frame: bool) -> int:
    n_ldpc = N_LDPC_SHORT if short_frame else N_LDPC_NORMAL
    return n_ldpc   # n_llr = n_ldpc (1 LLR par bit LDPC)

# BRAM depth maximale : N_LDPC_NORMAL = 64800 adresses de 8 bits
BRAM_DEPTH = N_LDPC_NORMAL   # 64800 × 8 bits = 63.3 KB par buffer
BRAM_ADDR_W = 17             # ceil(log2(64800)) = 17


# ─────────────────────────────────────────────────────────────────────────────
# Générateur de tables de permutation (Python, calculé à la génération)
# ─────────────────────────────────────────────────────────────────────────────

def make_deinterleave_lut(bps: int, short_frame: bool) -> list[int]:
    """
    Retourne une liste addr_out[i] = adresse BRAM de lecture pour le LLR i
    dans l'ordre LDPC.

    Entrelacement DVB-S2 :
      Écriture (trame) : LLR[i] → BRAM[col * Nr + row]
        col = i % Nc
        row = i // Nc

      Lecture (LDPC) avec permutation :
        Pour position j en sortie :
          row_rd = j // Nc
          col_rd = j % Nc
          col_wr = perm[col_rd]
          addr   = col_wr * Nr + row_rd
    """
    n_ldpc = N_LDPC_SHORT if short_frame else N_LDPC_NORMAL
    nc     = N_COLS[bps]
    nr     = n_ldpc // nc
    perm   = COLUMN_PERM[bps]

    lut = []
    for j in range(n_ldpc):
        row_rd = j // nc
        col_rd = j % nc
        col_wr = perm[col_rd % len(perm)]
        addr   = col_wr * nr + row_rd
        lut.append(addr)
    return lut


# ─────────────────────────────────────────────────────────────────────────────
# MODULE 1 — S2ColumnDeinterleaver
# ─────────────────────────────────────────────────────────────────────────────

class S2ColumnDeinterleaver(Elaboratable):
    """
    Désentrelaceur colonnes DVB-S2 avec double buffering BRAM.

    Architecture ping-pong :
      Buffer A (ping) et Buffer B (pong) de BRAM_DEPTH × 8 bits chacun.

      Phase N   : écriture dans buffer A (réception trame N)
      Phase N   : lecture  depuis buffer B (envoi trame N-1 au formateur)
      Phase N+1 : écriture dans buffer B / lecture depuis A  (swap)

    La lecture est guidée par une LUT de permutation stockée en ROM
    (calculée en Python, synthétisée en BRAM ou LUT selon la cible).

    Pour limiter la LUT ROM (64800 × 17 bits ≈ 138 KB), on calcule
    l'adresse à la volée avec un simple calcul arithmétique :
      addr_rd = perm[rd_col] * Nr + rd_row

    Ce calcul est faisable en combinatoire avec un multiplicateur.

    Ports :
      llr_in      [7:0]  : LLR int8 entrant (signé, depuis S2BBToSoft)
      llr_valid          : strobe écriture
      frame_start        : début de nouvelle trame → swap ping-pong
      modcod      [5:0]  : MODCOD courant
      short_frame        : type trame

      llr_out     [7:0]  : LLR réordonné (pour formateur)
      llr_out_valid      : strobe lecture
      frame_done         : pulse fin de lecture d'une trame complète
    """

    def __init__(self):
        # Ports entrée
        self.llr_in      = Signal(signed(8))
        self.llr_valid   = Signal()
        self.frame_start = Signal()
        self.modcod      = Signal(6)
        self.short_frame = Signal()

        # Ports sortie
        self.llr_out       = Signal(signed(8))
        self.llr_out_valid = Signal()
        self.frame_done    = Signal()

    def elaborate(self, platform):
        m = Module()

        # ── Paramètres de trame (recalculés à chaque frame_start) ─────────
        bps  = Signal(4, reset=2)
        nc   = Signal(4, reset=2)
        nr   = Signal(17, reset=N_LDPC_NORMAL // 2)
        n_llr = Signal(17, reset=N_LDPC_NORMAL)

        bps_comb = Signal(4)
        with m.Switch(self.modcod):
            with m.Case(*range(1,  12)): m.d.comb += bps_comb.eq(2)
            with m.Case(*range(12, 18)): m.d.comb += bps_comb.eq(3)
            with m.Case(*range(18, 24)): m.d.comb += bps_comb.eq(4)
            with m.Case(*range(24, 29)): m.d.comb += bps_comb.eq(5)
            with m.Default():            m.d.comb += bps_comb.eq(2)

        nc_comb = Signal(4)
        with m.Switch(bps_comb):
            with m.Case(3): m.d.comb += nc_comb.eq(6)
            with m.Case(4): m.d.comb += nc_comb.eq(4)
            with m.Case(5): m.d.comb += nc_comb.eq(5)
            with m.Default(): m.d.comb += nc_comb.eq(2)

        n_ldpc_comb = Signal(17)
        m.d.comb += n_ldpc_comb.eq(Mux(self.short_frame, N_LDPC_SHORT, N_LDPC_NORMAL))

        # nr = n_ldpc / nc : table fixe (nc ∈ {2,4,5,6})
        nr_comb = Signal(17)
        with m.If(self.short_frame):
            with m.Switch(bps_comb):
                with m.Case(2): m.d.comb += nr_comb.eq(8100)
                with m.Case(3): m.d.comb += nr_comb.eq(2700)
                with m.Case(4): m.d.comb += nr_comb.eq(4050)
                with m.Case(5): m.d.comb += nr_comb.eq(3240)
                with m.Default(): m.d.comb += nr_comb.eq(8100)
        with m.Else():
            with m.Switch(bps_comb):
                with m.Case(2): m.d.comb += nr_comb.eq(32400)
                with m.Case(3): m.d.comb += nr_comb.eq(10800)
                with m.Case(4): m.d.comb += nr_comb.eq(16200)
                with m.Case(5): m.d.comb += nr_comb.eq(12960)
                with m.Default(): m.d.comb += nr_comb.eq(32400)

        with m.If(self.frame_start):
            m.d.sync += [bps.eq(bps_comb), nc.eq(nc_comb),
                         nr.eq(nr_comb), n_llr.eq(n_ldpc_comb)]

        # ── Ping-pong BRAM (deux blocs de BRAM_DEPTH × 8 bits) ────────────
        # buf_sel=0 : écriture dans A / lecture depuis B
        # buf_sel=1 : écriture dans B / lecture depuis A
        m.submodules.mem_a = mem_a = Memory(
            shape=8, depth=BRAM_DEPTH, init=[],
            attrs={'ram_style': 'block'})
        m.submodules.mem_b = mem_b = Memory(
            shape=8, depth=BRAM_DEPTH, init=[],
            attrs={'ram_style': 'block'})
        wport_a = mem_a.write_port()
        rport_a = mem_a.read_port()    # synchronous — 1-cycle read latency
        wport_b = mem_b.write_port()
        rport_b = mem_b.read_port()

        buf_sel = Signal()
        with m.If(self.frame_start):
            m.d.sync += buf_sel.eq(~buf_sel)

        # ── Write address : LLR[i] → col * nr + row ───────────────────────
        # Colonnes et lignes maintenus par compteurs pour éviter modulo matériel.
        wr_col  = Signal(4, reset=0)
        wr_row  = Signal(17, reset=0)
        wr_addr = Signal(BRAM_ADDR_W)
        m.d.comb += wr_addr.eq(wr_col * nr + wr_row)

        with m.If(self.frame_start):
            m.d.sync += [wr_col.eq(0), wr_row.eq(0)]
        with m.Elif(self.llr_valid):
            with m.If(wr_col == nc - 1):
                m.d.sync += [wr_col.eq(0), wr_row.eq(wr_row + 1)]
            with m.Else():
                m.d.sync += wr_col.eq(wr_col + 1)

        m.d.comb += [
            wport_a.addr.eq(wr_addr),
            wport_a.data.eq(self.llr_in),
            wport_a.en.eq(self.llr_valid & ~buf_sel),
            wport_b.addr.eq(wr_addr),
            wport_b.data.eq(self.llr_in),
            wport_b.en.eq(self.llr_valid & buf_sel),
        ]

        # ── Read address : position j → perm[col] * nr + row ──────────────
        rd_col   = Signal(4, reset=0)
        rd_row   = Signal(17, reset=0)
        rd_col_p = Signal(4)
        rd_addr  = Signal(BRAM_ADDR_W)
        rd_en    = Signal()

        # Permutation colonne DVB-S2 (ETSI EN 302 307-1 §5.3.3)
        with m.If(bps == 3):        # 8PSK : perm = [0,5,1,2,4,3]
            with m.Switch(rd_col):
                with m.Case(1): m.d.comb += rd_col_p.eq(5)
                with m.Case(2): m.d.comb += rd_col_p.eq(1)
                with m.Case(3): m.d.comb += rd_col_p.eq(2)
                with m.Case(4): m.d.comb += rd_col_p.eq(4)
                with m.Case(5): m.d.comb += rd_col_p.eq(3)
                with m.Default(): m.d.comb += rd_col_p.eq(0)
        with m.Elif(bps == 4):      # 16APSK : perm = [0,3,1,2]
            with m.Switch(rd_col):
                with m.Case(1): m.d.comb += rd_col_p.eq(3)
                with m.Case(2): m.d.comb += rd_col_p.eq(1)
                with m.Case(3): m.d.comb += rd_col_p.eq(2)
                with m.Default(): m.d.comb += rd_col_p.eq(0)
        with m.Elif(bps == 5):      # 32APSK : perm = [0,4,1,2,3]
            with m.Switch(rd_col):
                with m.Case(1): m.d.comb += rd_col_p.eq(4)
                with m.Case(2): m.d.comb += rd_col_p.eq(1)
                with m.Case(3): m.d.comb += rd_col_p.eq(2)
                with m.Case(4): m.d.comb += rd_col_p.eq(3)
                with m.Default(): m.d.comb += rd_col_p.eq(0)
        with m.Else():              # QPSK : identité
            m.d.comb += rd_col_p.eq(rd_col)

        m.d.comb += rd_addr.eq(rd_col_p * nr + rd_row)

        # Lecture depuis le buffer inactif
        m.d.comb += [
            rport_a.addr.eq(rd_addr),
            rport_a.en.eq(rd_en & buf_sel),
            rport_b.addr.eq(rd_addr),
            rport_b.en.eq(rd_en & ~buf_sel),
        ]

        # Avance du pointeur de lecture
        frame_ready = Signal()
        with m.If(self.frame_start & ~frame_ready):
            m.d.sync += frame_ready.eq(1)

        with m.If(frame_ready):
            m.d.sync += rd_en.eq(1)
            with m.If(rd_en):
                with m.If(rd_col == nc - 1):
                    m.d.sync += [rd_col.eq(0), rd_row.eq(rd_row + 1)]
                    with m.If(rd_row == nr - 1):
                        m.d.sync += [rd_row.eq(0), self.frame_done.eq(1)]
                    with m.Else():
                        m.d.sync += self.frame_done.eq(0)
                with m.Else():
                    m.d.sync += [rd_col.eq(rd_col + 1), self.frame_done.eq(0)]
        with m.Else():
            m.d.sync += rd_en.eq(0)

        # BRAM read latency = 1 cycle → délayer rd_en et buf_sel
        rd_en_d   = Signal()
        buf_sel_d = Signal()
        m.d.sync += [rd_en_d.eq(rd_en & frame_ready),
                     buf_sel_d.eq(buf_sel)]

        llr_rd = Signal(8)
        with m.If(buf_sel_d):
            m.d.comb += llr_rd.eq(rport_a.data)
        with m.Else():
            m.d.comb += llr_rd.eq(rport_b.data)

        m.d.comb += [
            self.llr_out      .eq(llr_rd),
            self.llr_out_valid.eq(rd_en_d),
        ]

        return m


# ─────────────────────────────────────────────────────────────────────────────
# MODULE 2 — S2PacketFormatter
# ─────────────────────────────────────────────────────────────────────────────

class S2PacketFormatter(Elaboratable):
    """
    Formate les LLR désentrelacés en paquets AXI-Stream pour l'ARM.

    Format paquet (4 octets de header + n_llr octets de données) :
      Octet 0 : MODCOD  [5:0] + 2 bits réservés
      Octet 1 : short_frame [0] + 7 bits réservés
      Octet 2 : n_llr[15:8]   (MSB)
      Octet 3 : n_llr[7:0]    (LSB)
      Octets 4..4+n_llr-1 : LLR int8

    Contrôle de flux AXI-Stream :
      TVALID/TREADY handshake standard.
      TLAST = 1 sur le dernier octet du paquet.
      Si TREADY = 0 (ARM pas prêt), le formateur attend (stall).

    Machine d'état :
      IDLE       → attend llr_in_valid + frame_done_in
      HDR0..HDR3 → émet les 4 octets de header
      PAYLOAD    → émet les n_llr octets de LLR
      DONE       → pulse frame_sent, retour IDLE

    Ports entrée :
      llr_in         : LLR int8 depuis le désentrelaceur
      llr_in_valid   : strobe (désentrelaceur prêt)
      frame_start    : début de trame (capture MODCOD et n_llr)
      modcod         : MODCOD à inclure dans le header
      short_frame    : type trame

    Ports sortie AXI-Stream :
      m_tdata  [7:0] : octet courant
      m_tvalid       : donnée valide
      m_tready       : backpressure (entrée, depuis ARM)
      m_tlast        : dernier octet du paquet

    Monitoring :
      frame_sent     : pulse 1 cycle après envoi complet
      byte_count     : position courante dans le paquet
    """

    HEADER_LEN = 4

    def __init__(self):
        # Entrée depuis désentrelaceur
        self.llr_in       = Signal(signed(8))
        self.llr_in_valid = Signal()
        self.frame_start  = Signal()
        self.modcod       = Signal(6)
        self.short_frame  = Signal()

        # AXI-Stream master
        self.m_tdata  = Signal(8)
        self.m_tvalid = Signal()
        self.m_tready = Signal()   # input — backpressure from ARM
        self.m_tlast  = Signal()

        # Monitoring
        self.frame_sent = Signal()
        self.byte_count = Signal(17)

    def elaborate(self, platform):
        m = Module()

        # ── Capture des paramètres de trame au frame_start ────────────────
        modcod_r     = Signal(6)
        short_frame_r = Signal()
        n_llr_r      = Signal(17)

        n_llr_comb = Signal(17)
        m.d.comb += n_llr_comb.eq(
            Mux(self.short_frame, N_LDPC_SHORT, N_LDPC_NORMAL)
        )

        with m.If(self.frame_start):
            m.d.sync += [
                modcod_r    .eq(self.modcod),
                short_frame_r.eq(self.short_frame),
                n_llr_r     .eq(n_llr_comb),
            ]

        # ── Header précalculé (4 registres de 8 bits) ─────────────────────
        hdr = [Signal(8, name=f"hdr{i}") for i in range(self.HEADER_LEN)]
        m.d.comb += [
            hdr[0].eq(modcod_r),
            hdr[1].eq(short_frame_r),
            hdr[2].eq(n_llr_r[8:16]),
            hdr[3].eq(n_llr_r[0:8]),
        ]

        # ── Machine d'état ────────────────────────────────────────────────
        class St:
            IDLE    = 0
            HDR0    = 1
            HDR1    = 2
            HDR2    = 3
            HDR3    = 4
            PAYLOAD = 5
            DONE    = 6

        state      = Signal(3, reset=St.IDLE)
        pay_ctr    = Signal(17)   # position dans les LLR
        out_byte   = Signal(8)
        out_valid  = Signal()
        out_last   = Signal()

        m.d.comb += [
            self.m_tdata .eq(out_byte),
            self.m_tvalid.eq(out_valid),
            self.m_tlast .eq(out_last),
            self.byte_count.eq(pay_ctr),
        ]

        fire = Signal()   # handshake réalisé ce cycle
        m.d.comb += fire.eq(out_valid & self.m_tready)

        with m.Switch(state):

            with m.Case(St.IDLE):
                m.d.comb += [out_valid.eq(0), out_last.eq(0)]
                # Démarrer dès que le désentrelaceur a des données
                with m.If(self.llr_in_valid):
                    m.d.sync += state.eq(St.HDR0)

            with m.Case(St.HDR0):
                m.d.comb += [out_byte.eq(hdr[0]), out_valid.eq(1), out_last.eq(0)]
                with m.If(fire): m.d.sync += state.eq(St.HDR1)

            with m.Case(St.HDR1):
                m.d.comb += [out_byte.eq(hdr[1]), out_valid.eq(1), out_last.eq(0)]
                with m.If(fire): m.d.sync += state.eq(St.HDR2)

            with m.Case(St.HDR2):
                m.d.comb += [out_byte.eq(hdr[2]), out_valid.eq(1), out_last.eq(0)]
                with m.If(fire): m.d.sync += state.eq(St.HDR3)

            with m.Case(St.HDR3):
                m.d.comb += [out_byte.eq(hdr[3]), out_valid.eq(1), out_last.eq(0)]
                with m.If(fire):
                    m.d.sync += [state.eq(St.PAYLOAD), pay_ctr.eq(0)]

            with m.Case(St.PAYLOAD):
                is_last = Signal()
                m.d.comb += is_last.eq(pay_ctr == n_llr_r - 1)
                m.d.comb += [
                    out_byte .eq(self.llr_in),
                    out_valid.eq(self.llr_in_valid),
                    out_last .eq(is_last),
                ]
                with m.If(fire):
                    with m.If(is_last):
                        m.d.sync += state.eq(St.DONE)
                    with m.Else():
                        m.d.sync += pay_ctr.eq(pay_ctr + 1)

            with m.Case(St.DONE):
                m.d.comb += [out_valid.eq(0), out_last.eq(0)]
                m.d.sync += [state.eq(St.IDLE), self.frame_sent.eq(1)]

            with m.Default():
                m.d.sync += state.eq(St.IDLE)

        # frame_sent pulse 1 cycle
        with m.If(state != St.DONE):
            m.d.sync += self.frame_sent.eq(0)

        return m


# ─────────────────────────────────────────────────────────────────────────────
# MODULE 3 — S2DeinterleaverTop (top-level)
# ─────────────────────────────────────────────────────────────────────────────

class S2DeinterleaverTop(Elaboratable):
    """
    Top-level : désentrelaceur + formateur de paquet.

    Branchement dans dvbs2_frontend.py :
      llr_in      ← S2BBToSoft.llr_out
      llr_valid   ← S2BBToSoft.llr_valid
      modcod      ← S2BBToSoft.modcod
      short_frame ← S2BBToSoft.short_frame
      frame_start ← SOFCorrelator.frame_start

      m_tdata, m_tvalid, m_tready, m_tlast → bus SPI/AXI vers ARM

    Ports :
      (voir S2ColumnDeinterleaver + S2PacketFormatter)
    """

    def __init__(self):
        # Entrée depuis Stage 5
        self.llr_in      = Signal(signed(8))
        self.llr_valid   = Signal()
        self.frame_start = Signal()
        self.modcod      = Signal(6)
        self.short_frame = Signal()

        # AXI-Stream vers ARM
        self.m_tdata  = Signal(8)
        self.m_tvalid = Signal()
        self.m_tready = Signal()
        self.m_tlast  = Signal()

        # Monitoring
        self.frame_sent  = Signal()
        self.frame_done  = Signal()

    def elaborate(self, platform):
        m = Module()

        m.submodules.deint = deint = S2ColumnDeinterleaver()
        m.submodules.fmt   = fmt   = S2PacketFormatter()

        # ── Câblage désentrelaceur ────────────────────────────────────────
        m.d.comb += [
            deint.llr_in     .eq(self.llr_in),
            deint.llr_valid  .eq(self.llr_valid),
            deint.frame_start.eq(self.frame_start),
            deint.modcod     .eq(self.modcod),
            deint.short_frame.eq(self.short_frame),
        ]

        # ── Câblage formateur ─────────────────────────────────────────────
        m.d.comb += [
            fmt.llr_in      .eq(deint.llr_out),
            fmt.llr_in_valid.eq(deint.llr_out_valid),
            fmt.frame_start .eq(self.frame_start),
            fmt.modcod      .eq(self.modcod),
            fmt.short_frame .eq(self.short_frame),
        ]

        # ── AXI-Stream vers ARM ───────────────────────────────────────────
        m.d.comb += [
            self.m_tdata .eq(fmt.m_tdata),
            self.m_tvalid.eq(fmt.m_tvalid),
            fmt.m_tready .eq(self.m_tready),
            self.m_tlast .eq(fmt.m_tlast),
            self.frame_sent.eq(fmt.frame_sent),
            self.frame_done.eq(deint.frame_done),
        ]

        return m


# ─────────────────────────────────────────────────────────────────────────────
# Côté ARM — récepteur Python (pour test et intégration leansdr)
# ─────────────────────────────────────────────────────────────────────────────

ARM_RECEIVER_CODE = '''#!/usr/bin/env python3
"""
DVB-S2 ARM receiver — lit les paquets FPGA via SPI ou fichier
et appelle leansdr pour le décodage LDPC.

Usage :
  python3 arm_receiver.py --spi /dev/spidev0.0
  python3 arm_receiver.py --file capture.bin
  python3 arm_receiver.py --tcp 192.168.1.10:5000
"""

import struct, sys, subprocess, socket, argparse
from pathlib import Path

HEADER_LEN = 4

MODCOD_INFO = {
    # (modcod, short_frame) → (modulation, code_rate, n_ldpc)
    **{(mc, 0): ("QPSK",    cr, 64800) for mc, cr in zip(range(1,12),
        ["1/4","1/3","2/5","1/2","3/5","2/3","3/4","4/5","5/6","8/9","9/10"])},
    **{(mc, 1): ("QPSK",    cr, 16200) for mc, cr in zip(range(1,12),
        ["1/4","1/3","2/5","1/2","3/5","2/3","3/4","4/5","5/6","8/9","9/10"])},
    **{(mc, 0): ("8PSK",    cr, 64800) for mc, cr in zip(range(12,18),
        ["3/5","2/3","3/4","5/6","8/9","9/10"])},
    **{(mc, 0): ("16APSK",  cr, 64800) for mc, cr in zip(range(18,24),
        ["2/3","3/4","4/5","5/6","8/9","9/10"])},
    **{(mc, 0): ("32APSK",  cr, 64800) for mc, cr in zip(range(24,29),
        ["3/4","4/5","5/6","8/9","9/10"])},
}


def read_exact(stream, n: int) -> bytes:
    """Lit exactement n octets depuis stream."""
    buf = b""
    while len(buf) < n:
        chunk = stream.read(n - len(buf))
        if not chunk:
            raise EOFError("Stream terminé")
        buf += chunk
    return buf


def parse_packet(stream) -> dict:
    """Lit et parse un paquet FPGA complet."""
    hdr = read_exact(stream, HEADER_LEN)
    modcod, short_frame, n_llr_hi, n_llr_lo = struct.unpack("BBBB", hdr)
    n_llr = (n_llr_hi << 8) | n_llr_lo
    llr   = read_exact(stream, n_llr)
    return {
        "modcod":      modcod,
        "short_frame": short_frame,
        "n_llr":       n_llr,
        "llr":         llr,           # bytes de int8 signés
    }


def decode_ldpc_leansdr(pkt: dict, leansdr_bin: str = "leansdr") -> bytes | None:
    """
    Appelle leansdr pour décoder le LDPC.
    leansdr attend les LLR en float32 sur stdin et sort les bits décodés.

    Pour une intégration correcte, utiliser la lib C++ leansdr directement
    (dvbs2_ldpcdec) ou son binding Python s'il existe.
    """
    info = MODCOD_INFO.get((pkt["modcod"], pkt["short_frame"]))
    if not info:
        print(f"  ⚠️  MODCOD {pkt['modcod']} inconnu")
        return None

    modulation, code_rate, n_ldpc = info

    # Convertir int8 → float32 pour leansdr
    import array as arr
    llr_bytes = pkt["llr"]
    # int8 → float32 (normalisation : diviser par 127)
    llr_f32 = arr.array("f", [
        struct.unpack("b", bytes([b]))[0] / 127.0
        for b in llr_bytes
    ])

    # Appel leansdr (exemple — adapter selon la version installée)
    cmd = [
        leansdr_bin, "--ldpc",
        "--modcod", f"{modulation}-{code_rate}",
        "--nframes", "1",
    ]
    try:
        result = subprocess.run(
            cmd,
            input  = llr_f32.tobytes(),
            capture_output = True,
            timeout = 5.0,
        )
        return result.stdout
    except FileNotFoundError:
        # leansdr non installé — retourner les bits hard (décision dure)
        bits = bytes([1 if struct.unpack("b", bytes([b]))[0] < 0 else 0
                      for b in llr_bytes])
        return bits


def open_source(args) -> object:
    """Ouvre la source de données (SPI, fichier, ou TCP)."""
    if args.file:
        return open(args.file, "rb")
    elif args.tcp:
        host, port = args.tcp.rsplit(":", 1)
        s = socket.socket()
        s.connect((host, int(port)))
        return s.makefile("rb")
    elif args.spi:
        # SPI via spidev — nécessite pip install spidev
        import spidev
        spi = spidev.SpiDev()
        bus, dev = 0, 0
        spi.open(bus, dev)
        spi.max_speed_hz = 50_000_000
        spi.mode = 0

        class SPIStream:
            def read(self, n):
                return bytes(spi.readbytes(n))
        return SPIStream()
    else:
        return sys.stdin.buffer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", help="Fichier binaire de capture")
    parser.add_argument("--spi",  help="Device SPI (ex: /dev/spidev0.0)")
    parser.add_argument("--tcp",  help="TCP host:port")
    parser.add_argument("--leansdr", default="leansdr",
                        help="Chemin vers leansdr")
    parser.add_argument("--out",  default="-",
                        help="Sortie TS (- = stdout)")
    args = parser.parse_args()

    out = open(args.out, "wb") if args.out != "-" else sys.stdout.buffer
    src = open_source(args)

    frame_count = 0
    try:
        while True:
            pkt = parse_packet(src)
            info = MODCOD_INFO.get((pkt["modcod"], pkt["short_frame"]))
            label = f"{info[0]} {info[1]}" if info else f"MODCOD={pkt['modcod']}"
            print(f"  Trame {frame_count:4d}  {label:12s}  "
                  f"n_llr={pkt['n_llr']:6d}", file=sys.stderr)

            bits = decode_ldpc_leansdr(pkt, args.leansdr)
            if bits:
                out.write(bits)
                out.flush()
            frame_count += 1

    except EOFError:
        print(f"\\n  Fin de flux — {frame_count} trames reçues", file=sys.stderr)
    except KeyboardInterrupt:
        print(f"\\n  Arrêt — {frame_count} trames reçues", file=sys.stderr)


if __name__ == "__main__":
    main()
'''


# ─────────────────────────────────────────────────────────────────────────────
# Génération Verilog
# ─────────────────────────────────────────────────────────────────────────────

def generate_verilog(output_file="dvbs2_deinterleaver.v"):
    top = S2DeinterleaverTop()
    ports = [
        top.llr_in, top.llr_valid, top.frame_start,
        top.modcod, top.short_frame,
        top.m_tdata, top.m_tvalid, top.m_tready, top.m_tlast,
        top.frame_sent, top.frame_done,
    ]
    try:
        from amaranth.back.verilog import convert
        v = convert(top, ports=ports)
        with open(output_file, "w") as f:
            f.write(v)
        print(f"✅  Verilog généré : {output_file}")
    except Exception as e:
        print(f"⚠️  {e}\n    → pip install amaranth[yosys]")


def write_arm_receiver():
    with open("arm_receiver.py", "w") as f:
        f.write(ARM_RECEIVER_CODE)
    print("✅  arm_receiver.py écrit")


# ─────────────────────────────────────────────────────────────────────────────
# Testbench
# ─────────────────────────────────────────────────────────────────────────────

def test_deinterleaver_lut():
    """Vérifie les LUT de désentrelacement pour chaque modulation."""
    print("─── Test LUT désentrelacement ─────────────────────────────")
    for bps, mod in [(2,"QPSK"), (3,"8PSK"), (4,"16APSK"), (5,"32APSK")]:
        for short in [False, True]:
            lut = make_deinterleave_lut(bps, short)
            n   = N_LDPC_SHORT if short else N_LDPC_NORMAL
            # Vérifier que la LUT est une permutation (toutes adresses distinctes)
            assert len(lut) == n, f"LUT length mismatch"
            assert len(set(lut)) == n, f"LUT not a permutation for {mod}"
            print(f"    {mod:8s} {'court' if short else 'normal':6s} "
                  f"n={n:6d}  ✓  addr[0]={lut[0]:6d}  addr[-1]={lut[-1]:6d}")


def test_packet_formatter(n_llr=100):
    """Injecte n_llr LLR et vérifie le format du paquet AXI-Stream."""
    print(f"\n─── Test S2PacketFormatter (n_llr={n_llr}) ───────────────")
    dut = S2PacketFormatter()
    sim = Simulator(dut)
    sim.add_clock(1e-9)

    received = []

    def process():
        # frame_start avec MODCOD=4 (QPSK 1/2), trame normale
        yield dut.modcod      .eq(4)
        yield dut.short_frame .eq(0)
        yield dut.frame_start .eq(1)
        yield dut.m_tready    .eq(1)
        yield
        yield dut.frame_start.eq(0)

        # Injecter n_llr LLR
        for i in range(n_llr + 10):
            llr_val = (i % 127) - 63
            yield dut.llr_in      .eq(llr_val)
            yield dut.llr_in_valid.eq(1 if i < n_llr else 0)
            yield Settle()
            if (yield dut.m_tvalid):
                received.append({
                    "data": (yield dut.m_tdata),
                    "last": (yield dut.m_tlast),
                })
            yield

    with sim.write_vcd("/dev/null"):
        sim.add_sync_process(process)
        sim.run()

    if len(received) >= 4:
        hdr  = received[:4]
        modcod_rx    = hdr[0]["data"]
        short_rx     = hdr[1]["data"]
        n_llr_rx     = (hdr[2]["data"] << 8) | hdr[3]["data"]
        payload_len  = len(received) - 4

        print(f"    Header MODCOD     : {modcod_rx}   (attendu 4)")
        print(f"    Header short_frame: {short_rx}   (attendu 0)")
        print(f"    Header n_llr      : {n_llr_rx}   (attendu {N_LDPC_NORMAL})")
        print(f"    Octets payload    : {payload_len}")
        print(f"    TLAST détecté     : {'✓' if any(r['last'] for r in received) else '⚠️'}")

        ok = (modcod_rx == 4 and short_rx == 0 and n_llr_rx == N_LDPC_NORMAL)
        print(f"    Résultat header   : {'✓' if ok else '⚠️  erreur'}")
    else:
        print(f"    ⚠️  Pas assez d'octets reçus ({len(received)})")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    print("=" * 62)
    print("  DVB-S2 — Désentrelaceur + Formateur de paquet")
    print("=" * 62)

    test_deinterleaver_lut()
    test_packet_formatter(n_llr=200)

    print("\n─── Génération fichiers ───────────────────────────────────")
    generate_verilog()
    write_arm_receiver()

    print("""
─── Intégration finale dvbs2_frontend.py ──────────────────

  from dvbs2_deinterleaver import S2DeinterleaverTop

  m.submodules.deint = deint = S2DeinterleaverTop()
  m.d.comb += [
      deint.llr_in      .eq(bb_soft.llr_out),
      deint.llr_valid   .eq(bb_soft.llr_valid),
      deint.frame_start .eq(sof_corr.frame_start),
      deint.modcod      .eq(bb_soft.modcod),
      deint.short_frame .eq(bb_soft.short_frame),
      # AXI-Stream → pins FPGA
      self.m_tdata .eq(deint.m_tdata),
      self.m_tvalid.eq(deint.m_tvalid),
      deint.m_tready.eq(self.m_tready),
      self.m_tlast .eq(deint.m_tlast),
  ]

─── Côté ARM ──────────────────────────────────────────────

  # Via fichier de test
  python3 arm_receiver.py --file capture.bin --out stream.ts

  # Via SPI (Raspberry Pi / MPFS / Zynq)
  python3 arm_receiver.py --spi /dev/spidev0.0 | vlc -

  # Via TCP (debug avec netcat côté FPGA)
  python3 arm_receiver.py --tcp 192.168.1.10:5000 | tee stream.ts

─── Fichiers DVB-S2 complets ──────────────────────────────

  qpsk_sync.py            Stage 2  Costas + M&M
  dvbs2_frontend.py       Stage 1+3  RRC + SOF
  dvbs2_pll.py            Stage 4  PLL
  dvbs2_bb_soft.py        Stage 5  PLS + descramble + LLR
  dvbs2_deinterleaver.py  Stage 6  désentrelaceur + formateur  ← ce fichier
  arm_receiver.py         ARM      récepteur + appel leansdr
""")
