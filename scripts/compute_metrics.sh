#!/usr/bin/env bash
# compute_metrics.sh - Calcula speedup y eficiencia desde benchmark.csv
# Entrada: results/benchmark_summary.csv
# Salida: results/metrics.csv con speedup y eficiencia

set -euo pipefail

INPUT="results/quick_benchmark.csv"
OUTPUT="results/metrics.csv"

[[ -f "$INPUT" ]] || { echo "ERROR: Run simple_bench.sh first"; exit 1; }

awk -F',' '
NR==1 { print $0",speedup,efficiency_pct"; next }
NR>1 {
  np=$1; dist=$2; cipher=$3; time=$4; runs=$5;
  key=dist","cipher;

  # Almacenar todos los datos indexados por línea
  data[NR]=$0;
  np_val[NR]=np;
  time_val[NR]=time;
  key_val[NR]=key;

  # Guardar baseline (np=1)
  if (np==1) {
    base[key]=time;
  }
}
END {
  # Segunda pasada para calcular speedup
  for (i=2; i<=NR; i++) {
    k=key_val[i];
    np=np_val[i];
    t=time_val[i];

    if (k in base && base[k]>0 && base[k]!="NA" && t>0 && t!="NA") {
      speedup = base[k] / t;
      efficiency = (speedup / np) * 100;
      printf "%s,%.4f,%.2f\n", data[i], speedup, efficiency;
    } else {
      printf "%s,NA,NA\n", data[i];
    }
  }
}
' "$INPUT" > "$OUTPUT"

echo "✓ Métricas en: $OUTPUT"
echo ""
echo "=== SPEEDUP Y EFICIENCIA ==="
column -t -s',' "$OUTPUT"
