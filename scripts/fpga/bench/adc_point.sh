#!/bin/bash
# One frequency-response point: WaveGen sine at <freq Hz> and <Vpp>, croc boots the dump step from the flash
# (./load.sh boot), the AD2 captures the UART, adc_fit.py fits the blocks. Also prints the scope Vpp on CH1 and CH2.
#   ./adc_point.sh 250e3 0.2 [out.log]
# Needs: the s3_adc -DDUMP build in the flash (./load.sh s3_adc once), the WaveGen BNC on SIG_IN.
set -e
cd "$(dirname "${BASH_SOURCE[0]}")"
F=${1:?freq}; V=${2:?vpp}; OUT=${3:-logs/point_${F}_${V}_$(date +%H%M%S).log}
mkdir -p "$(dirname "$OUT")"
python3 -I scope.py ":WGEN:FUNC SIN" ":WGEN:OUTP:LOAD ONEM" ":WGEN:VOLT:OFFS 0" ":WGEN:FREQ $F" ":WGEN:VOLT $V" \
  ":WGEN:OUTP 1" ":WGEN:FREQ?" ":WGEN:VOLT?" > "$OUT.scope"
sleep 1
python3 -I scope.py ":MEAS:VPP? CHAN1" ":MEAS:VPP? CHAN2" ":MEAS:FREQ? CHAN1" >> "$OUT.scope"
python3 -I ad2_uart.py 12 "$OUT" > /dev/null 2> "$OUT.err" &
RP=$!
for i in $(seq 50); do [ -f "$OUT.ready" ] && break; sleep 0.1; done
timeout 40 ./load.sh boot > /dev/null 2>&1
wait $RP
grep -vE "errors|LOAD|OFFS|FUNC" "$OUT.scope" | sed 's/^/scope: /'
python3 -I adc_fit.py "$OUT" "$F"
