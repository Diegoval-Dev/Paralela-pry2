#!/usr/bin/env bash
set -euo pipefail

# scripts/bench_positions.sh
# Ejecuta la batería de tests y produce results_positions.csv y results_positions_summary.csv
# Uso: bash scripts/bench_positions.sh --nps "1 2 4 8" --dists "block interleaved dynamic" --runs 5 --limit $((1<<28)) --ciphers "early middle late" [--mpirun-flags "--oversubscribe"]

# Defaults
NPS="1 2 4 8"
DISTS="block interleaved dynamic"
RUNS=5
LIMIT=$((1<<28))
CIPHERS="early middle late"
OUT_DIR="results"
OUTCSV="${OUT_DIR}/results_positions.csv"
SUMCSV="${OUT_DIR}/results_positions_summary.csv"
BRUTE="./bruteforce"
BIN_DIR="./dataset"
MPIRUN_FLAGS=""

CHUNK=1000000

mkdir -p "${OUT_DIR}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nps) NPS="$2"; shift 2;;
    --dists) DISTS="$2"; shift 2;;
    --runs) RUNS="$2"; shift 2;;
    --limit) LIMIT="$2"; shift 2;;
    --ciphers) CIPHERS="$2"; shift 2;;
    --brute) BRUTE="$2"; shift 2;;
    --bindir) BIN_DIR="$2"; shift 2;;
    --mpirun-flags) MPIRUN_FLAGS="$2"; shift 2;;
    --chunk) CHUNK="$2"; shift 2;;
    *) echo "Unknown arg $1"; exit 1;;
  esac
done

# Header CSV
echo "ts,host,git,np,dist,cipher,run,time,rc,logfile" > "${OUTCSV}"

HOSTNAME=$(hostname -s)
GIT_COMMIT="nogit"
if git rev-parse --short HEAD &>/dev/null; then
  GIT_COMMIT=$(git rev-parse --short HEAD)
fi

# Loop
for np in ${NPS}; do
  for dist in ${DISTS}; do
    for cipher in ${CIPHERS}; do
      cipher_file="${BIN_DIR}/cipher_${cipher}.bin"
      if [[ ! -f "${cipher_file}" ]]; then
        echo "Warning: cipher file ${cipher_file} not found - skipping"
        continue
      fi
      for run in $(seq 1 ${RUNS}); do
        TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "Run np=${np} dist=${dist} cipher=${cipher} run=${run}"
        LOG="${OUT_DIR}/.last_run_np_${np}_${dist}_${cipher}_r${run}.log"

        # Ejecuta y captura salida
        set +e
        mpirun ${MPIRUN_FLAGS} -np "${np}" "${BRUTE}" -i "${cipher_file}" -p " the " --limit "${LIMIT}" --dist "${dist}" --chunk "${CHUNK}" 2>&1 | tee "${LOG}"
        rc=$?
        set -e

        # parse time from the single-line output "np=... key=... time=... "
        np_line=$(grep '^np=' "${LOG}" | tail -n 1 || true)
        time_val=""
        if [[ -n "$np_line" ]]; then
        # intenta time=...
        time_val=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^time=/){split($i,a,"="); print a[2]; exit}}' <<<"$np_line")
        # fallback t_total=...
        if [[ -z "$time_val" ]]; then
            time_val=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^t_total=/){split($i,a,"="); print a[2]; exit}}' <<<"$np_line")
        fi
        fi
        # si sigue vacio o es sospechosamente pequeño, márcalo NA
        if [[ -z "$time_val" ]]; then
        time_val="NA"
        else
        awk "BEGIN{t=$time_val+0; if(t>0 && t<1e-4) exit 1}" || time_val="NA"
        fi

        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s\n" \
        "${TS}" "${HOSTNAME}" "${GIT_COMMIT}" "${np}" "${dist}" "${cipher}" "${run}" "${time_val}" "${rc}" "${LOG}" \
        >> "${OUTCSV}"
      done
    done
  done
done

# Generate summary: median, p10, p90 + speedup vs np=1 y eficiencia
python3 - <<'PY'
import pandas as pd
import sys

IN = "results/results_positions.csv"
OUT = "results/results_positions_summary.csv"

df = pd.read_csv(IN)
# Filtra runs válidos: rc==0 y time numérico
df = df[(df['rc'] == 0) | (df['rc'] == '0')]
df['time'] = pd.to_numeric(df['time'], errors='coerce')
df = df.dropna(subset=['time'])
df['np'] = pd.to_numeric(df['np'], errors='coerce').astype('int32')

if df.empty:
    print("No numeric time data to summarize.")
    sys.exit(0)

grouped = df.groupby(['np','dist','cipher'])['time']
summary = grouped.agg(
    count='count',
    median='median',
    p10=lambda x: x.quantile(0.10),
    p90=lambda x: x.quantile(0.90),
).reset_index()

# speedup vs np=1 y eficiencia
base = summary[summary['np']==1][['dist','cipher','median']].rename(columns={'median':'base_median'})
summary = summary.merge(base, on=['dist','cipher'], how='left')

summary['speedup'] = summary['base_median'] / summary['median']
summary['efficiency_pct'] = 100.0 * summary['speedup'] / summary['np']

# Orden y guardado
cols = ['np','dist','cipher','count','median','p10','p90','speedup','efficiency_pct']
summary = summary[cols].sort_values(['dist','cipher','np']).reset_index(drop=True)

# Redondeos estéticos
for c in ['median','p10','p90','speedup','efficiency_pct']:
    summary[c] = summary[c].map(lambda v: f"{v:.6f}" if pd.notnull(v) else "NA")

summary.to_csv(OUT, index=False)
print("Summary written to", OUT)
PY
