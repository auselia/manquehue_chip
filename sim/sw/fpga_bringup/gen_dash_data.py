#!/usr/bin/env python3
# Writes the CSV files of the "croc AFE-ADC Chain Results" page from the ZedBoard tests of 9 Nov 2026: the measured
# tables (values as printed by adc_point.sh, wake_probe.tcl and step 5) and, from the logs, the averaged spectra and
# raw ADC blocks of the cavitation captures.
import csv, glob, os, re, sys, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util
spec = importlib.util.spec_from_file_location("cc", os.path.join(os.path.dirname(os.path.abspath(__file__)), "cav_compare.py"))
src = open(spec.origin).read().replace("\nmain()\n", "\n")
cc = {}; exec(compile(src, spec.origin, "exec"), cc)
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dash_data")
def w(name, head, rows):
    with open(os.path.join(OUT, name), "w", newline="") as f:
        c = csv.writer(f); c.writerow(head); c.writerows(rows)

# chain facts
w("chain_facts.csv", ["key", "value", "unit", "how"], [
 ["sample_rate", 1.000, "MSPS", "20 MHz / (18 + 2) clocks per ADC frame (adc_rdr.sv)"],
 ["mv_per_code", 0.403, "mV", "6.6 V / 16384 (ADS7057, 14 bit)"],
 ["codes_per_mv", 10.66, "codes/mV", "slope of the 250 kHz amplitude sweep"],
 ["gain_vs_sim", 4.7, "%", "1066 codes measured vs 1018 simulated at 250 kHz, 200 mVpp"],
 ["offset_open", 21, "codes", "input open, mean of 8 blocks"],
 ["noise_open", 2.0, "codes rms", "input open, fit residual"],
 ["wake_threshold", 50, "mV peak", "first WAKE_N event at 250 kHz, 45 to 49 mV: none"],
 ["wake_margin", 45, "dB", "35 mV rms threshold over 0.19 mV rms noise at SIG_IN"],
 ["fft_size", 128, "samples", "croc FFT, one block"],
 ["bin_width", 7.8125, "kHz", "1.000 MSPS / 128"],
 ["band_lo_khz", 250.0, "kHz", "band bins 32..39"],
 ["band_hi_khz", 312.5, "kHz", "band bins 32..39, upper edge"],
 ["uart_baud", 125000, "baud", "measured 8.0 us per bit"],
])
# frequency response, 200 mVpp, codes = sine fit amplitude (mean of 8 blocks)
sim = {10: -40.5, 30: -21.5, 100: -3.1, 250: 0.0}
fr = [(10, 10, 4.4, "not usable: 1.2 cycles per block, at the noise"), (30, 30, 72.8, ""), (100, 100, 727.2, ""),
      (250, 250, 1066.2, ""), (480, 480, 815.7, "500 kHz is Nyquist"), (1100, 100, 216.2, "folds to 100 kHz"),
      (1750, 250, 88.7, "folds to 250 kHz")]
w("freq_response.csv", ["gen_khz", "seen_khz", "codes", "adc_mv_pk", "db_rel_250k", "sim_db", "note"],
  [[g, s, c, round(c * 6600 / 16384, 1), round(20 * np.log10(c / 1066.2), 1), sim.get(g, ""), n] for g, s, c, n in fr])
# simulated response points from the test plan (relative to 250 kHz)
w("sim_response.csv", ["khz", "sim_db"], [[10, -40.5], [30, -21.5], [100, -3.1], [250, 0.0], [500, -2.8], [1000, -12.1], [2000, -24.0]])
# linearity at 250 kHz
lin = [(20, 212.0, 35.0, 36.1), (50, 537.1, 30.0, 32.9), (100, 1067.0, 47.1, 47.6), (200, 2125.9, 54.9, 59.0), (300, 3191.7, 58.7, 60.4)]
w("linearity.csv", ["sigin_mv_pk", "codes", "codes_per_mv", "adc_mv_pk", "sinad_min_db", "sinad_max_db"],
  [[m, c, round(c / m, 2), round(c * 6600 / 16384, 1), a, b] for m, c, a, b in lin])
# WAKE_N steps at 250 kHz
wk = [(10,0,0),(15,0,0),(20,0,0),(25,0,0),(28,0,0),(30,0,0),(32,0,0),(34,0,0),(36,0,0),(38,0,0),(40,0,0),(45,0,0),(46,0,0),
      (47,0,0),(48,0,0),(49,0,0),(50,1,3),(60,1,6),(80,1,18),(100,1,18),(110,1,20),(120,1,16),(150,1,19)]
w("wake_steps.csv", ["sigin_mv_pk", "wake_flag", "pin_low_of_20", "pin_low_pct"], [[m, f, p, p * 5] for m, f, p in wk])
# cavitation captures: ADC comparison and spectra
caps = ["20260922_144224_979_ch1_00011", "20260922_150847_731_ch1_00012", "20260922_165818_977_ch1_00015",
        "20260921_161120_805_ch1_00003", "20260921_162357_854_ch1_00006", "20260921_173740_614_ch1_00001",
        "20260921_190916_241_ch1_00005", "20260922_064636_764_ch1_00007"]
short = lambda c: c[:8] + " " + c[-5:]
summ, spec_rows, blk_rows = [], [], []
for c in caps:
    csvf = os.path.expanduser(f"~/Downloads/{c}_all.csv")
    log = os.path.join(os.path.dirname(OUT), "logs", f"cav_dump_{c}.log")
    pp = float(re.search(r"vpp \+?([0-9.E+-]+)", open(log + ".arb").read()).group(1)) * 1e3
    x = cc["expected"](csvf); bl = cc["croc_blocks"](log)
    L = 128 - cc["SKIP"]; ew = [np.roll(x, -s)[:L] for s in range(len(x))]
    se, sm = cc["avg_spec"](ew), cc["avg_spec"](bl); f = np.fft.rfftfreq(L, 1e-6)
    band = lambda S, a, b: float(np.sqrt(S[(f >= a) & (f < b) & (f > 0)].sum() * 2))
    kind = "cavitation band" if band(se, 150e3, 350e3) > band(se, 50e3, 150e3) * 3 else "low frequency"
    summ.append([short(c), kind, round(pp, 1), round(np.mean([e.std() for e in ew]), 1), round(np.mean([b.std() for b in bl]), 1),
                 round(f[1 + np.argmax(se[1:])] / 1e3, 1), round(f[1 + np.argmax(sm[1:])] / 1e3, 1),
                 round(band(se, 50e3, 150e3), 1), round(band(sm, 50e3, 150e3), 1), round(band(se, 150e3, 350e3), 1), round(band(sm, 150e3, 350e3), 1)])
    for k in range(1, len(f)):
        spec_rows.append([short(c), round(f[k] / 1e3, 2), round(10 * np.log10(se[k] + 1e-6), 2), round(10 * np.log10(sm[k] + 1e-6), 2)])
    if c.endswith(("00015", "00003")):
        raw = [b for b in open(log).read().split("block ")[1:2]][0]
        vals = [int(v, 16) for v in re.findall(r"\b[0-9a-f]{8}\b", raw)][2:130]  # skip block number and cycles
        for n, v in enumerate(vals):
            u = v & 0x3FFF; blk_rows.append([short(c), n, u - 0x4000 if u & 0x2000 else u])
w("cav_summary.csv", ["capture", "kind", "played_pp_mv", "rms_expected", "rms_croc", "peak_expected_khz", "peak_croc_khz",
  "band_50_150_expected", "band_50_150_croc", "band_150_350_expected", "band_150_350_croc"], summ)
w("cav_spectra.csv", ["capture", "f_khz", "expected_db", "croc_db"], spec_rows)
w("cav_block.csv", ["capture", "n", "code"], blk_rows)
# croc FFT features per block (step 5, decimal)
fft = {"00011": ([33]*5, [119879,131326,120020,128641,120751], [122735,132928,123138,130612,123659]),
       "00012": ([33]*5, [132250,95897,134855,98317,136508], [135159,128198,137693,130069,139210]),
       "00015": ([32]*5, [130776,111917,136198,108047,137818], [140428,120649,143344,118161,145186]),
       "00003": ([16,21,16,21,16], [148,44,110,37,75], [1691,1028,1554,1201,1658]),
       "00006": ([17,13,17,14,17], [94,30,73,51,70], [1542,618,1565,776,1352]),
       "00001": ([12,14,13,18,17], [208,136,171,93,119], [1503,641,1156,725,807]),
       "00005": ([17,22,17,22,17], [98,44,70,40,46], [1331,755,1087,719,902]),
       "00007": ([24,16,24,16,24], [58,120,67,134,88], [1223,1556,968,1535,780])}
rows = []
for c in caps:
    pb, be, te = fft[c[-5:]]
    for b in range(5):
        rows.append([short(c), b, pb[b], round(pb[b] * 7.8125, 1), be[b], te[b], round(100 * be[b] / te[b], 1)])
w("cav_fft.csv", ["capture", "block", "peak_bin", "peak_khz", "band_energy", "total_energy", "band_share_pct"], rows)
print("written:", sorted(os.listdir(OUT)))
