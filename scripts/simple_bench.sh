#!/usr/bin/env bash
# simple_bench.sh - Benchmark minimalista con salida CSV limpia
# Uso: bash scripts/simple_bench.sh [RUNS]

set -euo pipefail

RUNS=${1:-5}
LIMIT=$((1<<28))
BINARY="./bruteforce"
OUTCSV="results/benchmark.csv"

[[ -x "$BINARY" ]] || { echo "ERROR: compile first with 'make'"; exit 1; }

mkdir -p results
echo "np,dist,cipher,run,time_s,key,winner" > "$OUTCSV"

for np in 1 2 4 8; do
  for dist in block interleaved dynamic; do
    for cipher in early middle late; do
      cipher_file="dataset/cipher_${cipher}.bin"
      [[ -f "$cipher_file" ]] || { echo "SKIP: $cipher_file"; continue; }

      echo "==> np=$np dist=$dist cipher=$cipher"
      for run in $(seq 1 $RUNS); do
        # Ejecutar y capturar línea de salida
        output=$(mpirun -np $np $BINARY \
          -i "$cipher_file" -p " the " --limit $LIMIT --dist $dist 2>&1 \
          | grep '^np=' | tail -n1)

        # Parseo compatible con BSD grep (macOS): np=X; key=Y; winner=Z; t_total=W
        time=$(echo "$output" | sed -n 's/.*t_total=\([0-9.]*\).*/\1/p')
        key=$(echo "$output" | sed -n 's/.*key=\([0-9]*\).*/\1/p')
        winner=$(echo "$output" | sed -n 's/.*winner=\([0-9-]*\).*/\1/p')

        # Defaults si está vacío
        [[ -z "$time" ]] && time="NA"
        [[ -z "$key" ]] && key="NA"
        [[ -z "$winner" ]] && winner="NA"

        echo "$np,$dist,$cipher,$run,$time,$key,$winner" | tee -a "$OUTCSV"
      done
    done
  done
done

echo "✓ Resultados en: $OUTCSV"

# Generar resumen con awk (sin Python)
awk -F',' 'NR>1 {
  key=$1","$2","$3;
  sum[key]+=$5;
  count[key]++;
  times[key,count[key]]=$5;
}
END {
  print "np,dist,cipher,median_s,runs";
  for (k in count) {
    n=count[k];
    # Bubble sort simple para mediana
    for(i=1;i<=n;i++) {
      for(j=i+1;j<=n;j++) {
        if(times[k,i]>times[k,j]) {
          tmp=times[k,i];
          times[k,i]=times[k,j];
          times[k,j]=tmp;
        }
      }
    }
    mid = (n%2==1) ? times[k,int(n/2)+1] : (times[k,n/2]+times[k,n/2+1])/2;
    print k","mid","n;
  }
}' "$OUTCSV" > results/benchmark_summary.csv

echo ""
echo "=== RESUMEN ==="
column -t -s',' results/benchmark_summary.csv
