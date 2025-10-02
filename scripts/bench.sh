#!/usr/bin/env bash
# bench.sh — Reproducible benchmarking para bruteforce (MPI + OpenSSL)
# - Compila (opcional) y corre N corridas por cada np
# - Guarda resultados detallados en CSV y genera resumen (mediana, p10, p90, speedup, eficiencia)
# Requisitos: bash, mpicc, mpirun, openssl (libssl-dev), awk, sed, sort, lscpu (opcional)

set -Eeuo pipefail

# -------------------- Parámetros por defecto --------------------
SRC_DEFAULT="src/bruteforce.c"
[ -f "$SRC_DEFAULT" ] || SRC_DEFAULT="bruteforce.c"

BINARY="./bruteforce"
SRC="$SRC_DEFAULT"
OUTDIR="results"
OUTCSV="${OUTDIR}/results.csv"
SUMMARY="${OUTDIR}/results_summary.csv"
META="${OUTDIR}/_meta.txt"

RUNS=5
NP_LIST="1 2 4 8"
LIMIT=$((1<<28))              # Límite de búsqueda por defecto para pruebas base
BUILD=1                       # 1 = compilar antes de correr
MPIRUN_FLAGS=""               # e.g. "--bind-to core"
CFLAGS_EXTRA="-Wno-deprecated-declarations"  # silenciar deprecations OpenSSL 3.x

# -------------------- Ayuda --------------------
usage() {
  cat <<EOF
Uso: $0 [opciones]

Opciones:
  -b, --binary PATH          Ruta al binario (default: ${BINARY})
  -s, --src PATH             Ruta al fuente C (default: ${SRC_DEFAULT})
  -o, --outdir DIR           Carpeta de salida (default: ${OUTDIR})
  -r, --runs N               Corridas por np (default: ${RUNS})
  -n, --np "1 2 4 8"         Lista de tamaños de proceso (default: "${NP_LIST}")
  -l, --limit NUM            Límite superior de búsqueda pasada al binario (default: ${LIMIT})
      --no-build             No compilar; usar binario existente
      --mpirun-flags STR     Flags adicionales para mpirun (default: vacío)
  -h, --help                 Mostrar esta ayuda

Ejemplos:
  $0
  $0 -r 7 -n "1 2 4 8 16" -l \$((1<<30)) --mpirun-flags "--bind-to core"
  $0 --no-build -b ./bruteforce -o bench_out
EOF
  exit 1
}

# -------------------- Parseo de argumentos --------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--binary) BINARY="$2"; shift 2;;
    -s|--src) SRC="$2"; shift 2;;
    -o|--outdir) OUTDIR="$2"; shift 2;;
    -r|--runs) RUNS="$2"; shift 2;;
    -n|--np) NP_LIST="$2"; shift 2;;
    -l|--limit) LIMIT="$2"; shift 2;;
    --no-build) BUILD=0; shift 1;;
    --mpirun-flags) MPIRUN_FLAGS="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Opción desconocida: $1"; usage;;
  esac
done

# -------------------- Checks básicos --------------------
require_bin() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: se requiere '$1' en PATH" >&2; exit 1; }
}
require_bin mpirun
require_bin awk
require_bin sed
require_bin sort
require_bin date

if [[ "$BUILD" -eq 1 ]]; then
  require_bin mpicc
fi

mkdir -p "$OUTDIR"

# -------------------- Metadatos reproducibles --------------------
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "no-git")
HOST=$(hostname -s || echo "unknown-host")
KERNEL=$(uname -sr || true)
DISTRO=$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
CPU_MODEL=$(lscpu 2>/dev/null | awk -F: '/Model name|Nombre del modelo/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)
CPU_CORES=$(lscpu 2>/dev/null | awk -F: '/^CPU\(s\)|Procesador\(es\)/{gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)
MPIRUN_VER=$(mpirun --version 2>/dev/null | head -n1 || true)
OPENSSL_VER=$(openssl version 2>/dev/null || echo "openssl N/A")

# Gobernador (si está disponible)
GOVERNOR=""
if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
  GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
fi

{
  echo "# Bench metadata"
  echo "timestamp=$(date -Is)"
  echo "host=${HOST}"
  echo "kernel=${KERNEL}"
  echo "distro=${DISTRO}"
  echo "cpu_model=${CPU_MODEL}"
  echo "cpu_cores=${CPU_CORES}"
  echo "mpirun=${MPIRUN_VER}"
  echo "openssl=${OPENSSL_VER}"
  echo "cpu_governor=${GOVERNOR}"
  echo "git_commit=${GIT_COMMIT}"
  echo "np_list=${NP_LIST}"
  echo "runs=${RUNS}"
  echo "limit=${LIMIT}"
  echo "mpirun_flags=${MPIRUN_FLAGS}"
} | tee "${META}" >/dev/null

# -------------------- Compilación (opcional) --------------------
if [[ "$BUILD" -eq 1 ]]; then
  if [[ ! -f "$SRC" ]]; then
    echo "ERROR: no existe fuente C en: $SRC" >&2
    exit 1
  fi
  echo "[BUILD] Compilando ${SRC} -> ${BINARY}"
  mpicc -O3 -Wall -Wextra -std=c11 ${CFLAGS_EXTRA} \
    -DGIT_COMMIT="\"${GIT_COMMIT}\"" \
    "$SRC" -lcrypto -o "$BINARY"
fi

if [[ ! -x "$BINARY" ]]; then
  echo "ERROR: binario no encontrado o no ejecutable: $BINARY" >&2
  exit 1
fi

# -------------------- CSV de resultados --------------------
echo "ts,host,commit,np,key,winner,t_total_s,limit" > "$OUTCSV"

# tmp times por np (para stats)
declare -A TMP_NP_FILES
for NP in $NP_LIST; do
  TMP_NP_FILES["$NP"]="${OUTDIR}/.times_np_${NP}.txt"
  : > "${TMP_NP_FILES[$NP]}"
done

# Cleanup y resumen parcial ante Ctrl-C
cleanup() {
  echo
  echo "[INTERRUPT] Señal recibida. Se guardaron resultados parciales en:"
  echo " - ${OUTCSV}"
  if [[ -s "$SUMMARY" ]]; then
    echo " - ${SUMMARY}"
  else
    echo "Generando resumen parcial..."
    generate_summary || true
  fi
  exit 130
}
trap cleanup INT TERM

# -------------------- Loop principal de medición --------------------
for NP in $NP_LIST; do
  echo "[RUN] np=${NP}  runs=${RUNS}  limit=${LIMIT}"
  for r in $(seq 1 "$RUNS"); do
    TS=$(date -Is)
    # Ejecuta y captura una sola línea de salida
    LINE=$(mpirun ${MPIRUN_FLAGS} -np "${NP}" "${BINARY}" "${LIMIT}" | tail -n1 || true)

    # Parseo robusto (key, winner, t_total)
    KEY=$(sed -n 's/.*key=\([^;]*\).*/\1/p' <<< "$LINE")
    WIN=$(sed -n 's/.*winner=\([^;]*\).*/\1/p' <<< "$LINE")
    T=$(sed -n 's/.*t_total=\([^ ]*\).*/\1/p' <<< "$LINE")

    # Defaults si no se pudo parsear
    [[ -n "${KEY}" ]] || KEY="NA"
    [[ -n "${WIN}" ]] || WIN="NA"
    if [[ -z "${T}" ]]; then
      T="NaN"
      echo "WARN: no se pudo parsear t_total en línea: ${LINE}" >&2
    fi

    printf "%s,%s,%s,%s,%s,%s,%s\n" \
      "$TS" "$HOST" "$GIT_COMMIT" "$NP" "$KEY" "$WIN" "$T" \
      | awk -v L="$LIMIT" -F',' 'BEGIN{OFS=","} {print $1,$2,$3,$4,$5,$6,$7,L}' \
      | tee -a "$OUTCSV" >/dev/null

    # Guarda tiempo para stats si es numérico
    if awk "BEGIN{exit(!($T+0==$T))}"; then
      echo "$T" >> "${TMP_NP_FILES[$NP]}"
    fi
  done
done

# -------------------- Resumen (mediana, p10, p90, speedup, eficiencia) --------------------
generate_summary() {
  # Calcula estadísticas por NP leyendo los .times_np_*.txt
  # summary: np,runs,t_median,t_p10,t_p90,speedup_vs_np1_median,efficiency_pct
  echo "np,runs,t_median_s,t_p10_s,t_p90_s,speedup,efficiency_pct" > "$SUMMARY"

  # Función awk para p10/p50/p90 asumiendo input sorted
  stats_from_sorted() {
    awk '{
      a[++n]=$1
    } END {
      if (n==0) { print "NA NA NA"; exit }
      # Índices tipo numpy-ish: idx = floor((n-1)*p)+1
      i10=int((n-1)*0.10)+1
      i50=int((n-1)*0.50)+1
      i90=int((n-1)*0.90)+1
      printf("%.6f %.6f %.6f\n", a[i10], a[i50], a[i90])
    }'
  }

  declare -A MEDIAN
  declare -A RUNCOUNT

  # Primero calcula medianas, p10, p90
  for NP in $NP_LIST; do
    FILE="${TMP_NP_FILES[$NP]}"
    if [[ -s "$FILE" ]]; then
      read -r P10 MED P90 < <(sort -n "$FILE" | stats_from_sorted)
      MEDIAN["$NP"]="$MED"
      RUNCOUNT["$NP"]="$(wc -l < "$FILE" | tr -d ' ')"
      # speedup y eficiencia se calculan luego cuando sepamos la mediana de np=1
      echo "# NP=${NP} runs=${RUNCOUNT[$NP]} median=${MED} p10=${P10} p90=${P90}" >&2
      echo "${NP},${RUNCOUNT[$NP]},${MED},${P10},${P90},NA,NA" >> "$SUMMARY"
    else
      MEDIAN["$NP"]="NA"
      RUNCOUNT["$NP"]="0"
      echo "${NP},0,NA,NA,NA,NA,NA" >> "$SUMMARY"
    fi
  done

  # Ahora computa speedup y eficiencia usando la mediana de np=1
  BASE="${MEDIAN[1]:-NA}"
  if [[ "$BASE" != "NA" ]]; then
    tmp="${SUMMARY}.tmp"
    echo "np,runs,t_median_s,t_p10_s,t_p90_s,speedup,efficiency_pct" > "$tmp"
    tail -n +2 "$SUMMARY" | while IFS=',' read -r NP RUNS_ROW TMED TP10 TP90 S E; do
      if [[ "$TMED" != "NA" ]]; then
        SPEEDUP=$(awk -v b="$BASE" -v t="$TMED" 'BEGIN{ if(t==0){print "NA"} else {printf "%.6f", b/t} }')
        EFF=$(awk -v sp="$SPEEDUP" -v np="$NP" 'BEGIN{ if(sp=="NA"||np==0){print "NA"} else {printf "%.2f", (sp/np)*100} }')
        echo "${NP},${RUNS_ROW},${TMED},${TP10},${TP90},${SPEEDUP},${EFF}" >> "$tmp"
      else
        echo "${NP},${RUNS_ROW},${TMED},${TP10},${TP90},NA,NA" >> "$tmp"
      fi
    done
    mv "$tmp" "$SUMMARY"
  else
    echo "WARN: No hay mediana para np=1; no se calcularán speedup/eficiencia." >&2
  fi
}

generate_summary

# -------------------- Output final amigable --------------------
echo
echo "[OK] Resultados:"
echo " - Detalle:  $(readlink -f "$OUTCSV" 2>/dev/null || echo "$OUTCSV")"
echo " - Resumen:  $(readlink -f "$SUMMARY" 2>/dev/null || echo "$SUMMARY")"
echo " - Metadata: $(readlink -f "$META" 2>/dev/null || echo "$META")"
