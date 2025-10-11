#!/usr/bin/env bash
# comprehensive_bench.sh - Resume only "message_secret" (keyword: Alan)
# Reanuda OUTCSV si existe, usa baseline desde CSV cuando sea posible, y no toca los casos ya medidos.

set -euo pipefail

# Evitar "illegal byte sequence" en macOS/BSD
export LC_ALL=C
export LANG=C

# ----------------------------------------
# Configuración
# ----------------------------------------
RUNS=${1:-10}
LIMIT=$((1<<28))
BINARY="./bruteforce"
OUTCSV="results/comprehensive_benchmark.csv"
SUMMARY_CSV="results/comprehensive_summary.csv"

# Solo este cipher (lo que falta)
CIPHER_FILES=(message_secret)

# Variaciones de procesos y distribuciones
PROCESS_COUNTS=(1 2 3 4 5 6 7 8 10)
DISTRIBUTIONS=(block interleaved dynamic)

# Timeout opcional (0 = deshabilitado). Útil si no hay match.
TIMEOUT_SECS=${TIMEOUT_SECS:-0}
# DEBUG=1 para ver por qué falla un parseo
DEBUG=${DEBUG:-0}

# ----------------------------------------
# Funciones auxiliares
# ----------------------------------------
get_keyword() {
    local cipher="$1"
    case "$cipher" in
        message_secret) echo "Alan" ;;
        *)              echo "Alan" ;;
    esac
}

run_cmd() {
    if [[ "$TIMEOUT_SECS" -gt 0 ]]; then
        timeout "${TIMEOUT_SECS}s" "$@"
    else
        "$@"
    fi
}

# De toda la salida, toma la última línea que contenga "np=", limpiando ANSI y \r
extract_stat_line() {
    awk '
        {
            line=$0
            gsub(/\r/,"",line)
            gsub(/\x1B\[[0-9;]*[mK]/,"",line)
            if (line ~ /np=/) last=line
        }
        END{ if (last!="") print last }
    '
}

# Parsea "np=..; key=..; winner=..; t_total=.."; devuelve: "time key winner"
parse_stat_fields() {
    awk -v debug='"$DEBUG"' '
        function trim(s){gsub(/^[ \t]+|[ \t]+$/,"",s); return s}
        {
            line=$0
            gsub(/"/,"",line)
            n=split(line, arr, /[; ,]+/)
            time=""; key=""; winner=""
            for(i=1;i<=n;i++){
                split(arr[i], kv, /=/)
                k=trim(kv[1]); v=trim(kv[2])
                if (k=="t_total") time=v
                else if (k=="key") key=v
                else if (k=="winner") winner=v
            }
            if (time!=""){
                print time, key, winner
            } else if (debug=="1") {
                print "[DEBUG] parse_stat_fields no encontró t_total en: " line > "/dev/stderr"
            }
        }
    '
}

# Ejecuta y parsea; imprime "time key winner" si OK
run_and_parse() {
    local np="$1" cipher_file="$2" keyword="$3" dist="$4"
    local raw line parsed
    if ! raw=$(run_cmd mpirun -np "$np" "$BINARY" -i "$cipher_file" -p "$keyword" --limit "$LIMIT" --dist "$dist" 2>&1); then
        return 1
    fi
    line=$(printf '%s\n' "$raw" | extract_stat_line || true)
    if [[ -z "${line:-}" ]]; then
        [[ "$DEBUG" -eq 1 ]] && printf '[DEBUG] No se encontró línea con np=. Raw:\n%s\n' "$raw" >&2
        return 2
    fi
    parsed=$(printf '%s\n' "$line" | parse_stat_fields || true)
    if [[ -z "${parsed:-}" ]]; then
        [[ "$DEBUG" -eq 1 ]] && printf '[DEBUG] No se pudo parsear. Línea:\n%s\n' "$line" >&2
        return 3
    fi
    printf '%s\n' "$parsed"
    return 0
}

# Baselines persistidos (np=1) en archivo temporal
BASELINE_FILE="results/baseline_times.tmp"
touch "$BASELINE_FILE"

store_baseline() {
    local key="$1" avg="$2"
    grep -v "^${key}:" "$BASELINE_FILE" > "${BASELINE_FILE}.new" || true
    mv "${BASELINE_FILE}.new" "$BASELINE_FILE"
    echo "${key}:${avg}" >> "$BASELINE_FILE"
}

get_baseline() {
    local key="$1"
    grep "^$key:" "$BASELINE_FILE" 2>/dev/null | cut -d: -f2 || echo ""
}

# Cargar baselines existentes desde el CSV (np=1)
load_existing_baselines_from_csv() {
    [[ -f "$OUTCSV" ]] || return 0
    awk -F',' 'NR>1 && $3=="1" {
        key=$1"_"$4
        sum[key]+=$6
        cnt[key]++
    }
    END {
        for(k in cnt){
            printf "%s:%.10f\n", k, sum[k]/cnt[k]
        }
    }' "$OUTCSV" | while IFS=: read -r k v; do
        store_baseline "$k" "$v"
    done
}

# Añadir fila al CSV
append_csv_row() {
    local row="$1"
    echo "$row" >> "$OUTCSV"
}

# ¿Ya existe una corrida (cipher,keyword,np,dist,run)?
exists_row_in_csv() {
    local cipher="$1" keyword="$2" np="$3" dist="$4" run="$5"
    [[ -f "$OUTCSV" ]] || return 1
    awk -F',' -v c="$cipher" -v k="$keyword" -v n="$np" -v d="$dist" -v r="$run" '
        $1==c && $2==k && $3==n && $4==d && $5==r {found=1}
        END{exit found?0:1}
    ' "$OUTCSV"
}

# ----------------------------------------
# Preparación
# ----------------------------------------
mkdir -p results

# Encabezado del CSV si no existe/está vacío
if [[ ! -s "$OUTCSV" ]]; then
    echo "cipher,keyword,np,dist,run,time_s,key,winner,speedup,efficiency" > "$OUTCSV"
    echo "Creado nuevo CSV: $OUTCSV"
else
    echo "Reanudando, no se sobrescribirá: $OUTCSV"
fi

# Cargar baselines previos del CSV
load_existing_baselines_from_csv

echo "=== RESUME BENCHMARK (message_secret: 'Alan') ==="
echo "Process counts: ${PROCESS_COUNTS[*]}"
echo "Distributions: ${DISTRIBUTIONS[*]}"
echo "Runs per configuration: $RUNS"
[[ "$TIMEOUT_SECS" -gt 0 ]] && echo "Timeout por corrida: ${TIMEOUT_SECS}s"
echo

# ----------------------------------------
# Bucle principal (solo message_secret)
# ----------------------------------------
for cipher in "${CIPHER_FILES[@]}"; do
    keyword=$(get_keyword "$cipher")
    cipher_file="dataset/${cipher}.bin"

    if [[ ! -f "$cipher_file" ]]; then
        echo "SKIP: $cipher_file not found"
        continue
    fi

    echo "=== Testing $cipher with keyword '$keyword' ==="

    # Sanity check (np=1, dist=block) con parser robusto
    echo "  Sanity check (np=1, dist=block)..."
    if ! run_and_parse 1 "$cipher_file" "$keyword" "block" >/dev/null; then
        echo "  Aviso: no se pudo validar salida parseable en sanity check. Continuando."
    fi

    for dist in "${DISTRIBUTIONS[@]}"; do
        echo "  Distribution: $dist"

        baseline_key="${cipher}_${dist}"
        baseline_val="$(get_baseline "$baseline_key")"

        # Baseline np=1 (solo corridas faltantes)
        if [[ -z "$baseline_val" ]]; then
            echo "    Collecting baseline (np=1, solo runs faltantes)..."
            baseline_sum=0
            baseline_count=0

            for run in $(seq 1 "$RUNS"); do
                if exists_row_in_csv "$cipher" "$keyword" "1" "$dist" "$run"; then
                    t=$(awk -F',' -v c="$cipher" -v k="$keyword" -v d="$dist" -v r="$run" '
                        $1==c && $2==k && $3==1 && $4==d && $5==r {print $6}
                    ' "$OUTCSV")
                    if [[ -n "${t:-}" ]]; then
                        baseline_sum=$(awk "BEGIN{print ${baseline_sum} + ${t}}")
                        baseline_count=$((baseline_count+1))
                    fi
                    continue
                fi

                echo -n "      Run $run/$RUNS... [searching...]"
                if read -r time key_found winner < <(run_and_parse 1 "$cipher_file" "$keyword" "$dist"); then
                    baseline_sum=$(awk "BEGIN {print $baseline_sum + $time}")
                    baseline_count=$((baseline_count + 1))
                    append_csv_row "$cipher,$keyword,1,$dist,$run,$time,$key_found,$winner,1.0,1.0"
                    echo " ${time}s"
                else
                    echo " FAILED (parsing/execution)"
                fi
            done

            if [[ $baseline_count -gt 0 ]]; then
                baseline_avg=$(awk "BEGIN {print $baseline_sum / $baseline_count}")
                store_baseline "$baseline_key" "$baseline_avg"
                echo "    Baseline average (nuevo): ${baseline_avg}s (de $baseline_count corridas)"
                baseline_val="$baseline_avg"
            else
                maybe_avg=$(awk -F',' -v c="$cipher" -v k="$keyword" -v d="$dist" '
                    NR>1 && $1==c && $2==k && $3==1 && $4==d {s+=$6; n++}
                    END { if(n>0) printf "%.10f", s/n; }
                ' "$OUTCSV")
                if [[ -n "${maybe_avg:-}" ]]; then
                    store_baseline "$baseline_key" "$maybe_avg"
                    baseline_val="$maybe_avg"
                    echo "    Baseline average (desde CSV existente): ${baseline_val}s"
                else
                    echo "    ERROR: No baseline válido para $cipher $dist"
                    continue
                fi
            fi
        else
            echo "    Baseline average (existente): ${baseline_val}s"
        fi

        # np > 1: solo corridas faltantes
        for np in "${PROCESS_COUNTS[@]}"; do
            [[ $np -eq 1 ]] && continue
            echo "    Testing np=$np..."

            # Sumar runs existentes
            time_sum_existing=$(awk -F',' -v c="$cipher" -v k="$keyword" -v n="$np" -v d="$dist" '
                NR>1 && $1==c && $2==k && $3==n && $4==d {s+=$6}
                END{ if(s=="") s=0; print s}
            ' "$OUTCSV")
            valid_existing=$(awk -F',' -v c="$cipher" -v k="$keyword" -v n="$np" -v d="$dist" '
                NR>1 && $1==c && $2==k && $3==n && $4==d {cnt++}
                END{ if(cnt=="") cnt=0; print cnt}
            ' "$OUTCSV")

            time_sum="$time_sum_existing"
            valid_runs="$valid_existing"

            for run in $(seq 1 "$RUNS"); do
                if exists_row_in_csv "$cipher" "$keyword" "$np" "$dist" "$run"; then
                    continue
                fi

                echo -n "      Run $run/$RUNS... [searching...]"
                if read -r time key_found winner < <(run_and_parse "$np" "$cipher_file" "$keyword" "$dist"); then
                    speedup=$(awk "BEGIN {print $baseline_val / $time}")
                    efficiency=$(awk "BEGIN {print $speedup / $np}")
                    time_sum=$(awk "BEGIN {print $time_sum + $time}")
                    valid_runs=$((valid_runs + 1))

                    append_csv_row "$cipher,$keyword,$np,$dist,$run,$time,$key_found,$winner,$speedup,$efficiency"
                    printf " %.6fs (speedup: %.2f, efficiency: %.2f)\n" "$time" "$speedup" "$efficiency"
                else
                    echo " FAILED (parsing/execution)"
                fi
            done

            if [[ $valid_runs -gt 0 ]]; then
                avg_time=$(awk "BEGIN {print $time_sum / $valid_runs}")
                avg_speedup=$(awk "BEGIN {print $baseline_val / $avg_time}")
                avg_efficiency=$(awk "BEGIN {print $avg_speedup / $np}")
                echo "      Average (incl. runs previas): ${avg_time}s (speedup: $(printf "%.2f" "$avg_speedup"), efficiency: $(printf "%.2f" "$avg_efficiency"))"
            fi
        done
    done
    echo
done

echo "✓ Raw results appended to: $OUTCSV"

# ----------------------------------------
# Resumen (a partir del CSV actual)
# ----------------------------------------
echo "Generating summary statistics..."
awk -F',' '
BEGIN {
    print "cipher,keyword,np,dist,avg_time_s,avg_speedup,avg_efficiency,valid_runs,total_runs"
}
NR>1 {
    key = $1","$2","$3","$4
    if ($6 != "NA" && $6 != "") {
        sum_time[key] += $6
        sum_speedup[key] += $9
        sum_efficiency[key] += $10
        valid_count[key]++
    }
    total_count[key]++
}
END {
    for (k in total_count) {
        if (valid_count[k] > 0) {
            avg_time = sum_time[k] / valid_count[k]
            avg_speedup = sum_speedup[k] / valid_count[k]
            avg_efficiency = sum_efficiency[k] / valid_count[k]
            printf "%s,%.4f,%.4f,%.4f,%d,%d\n", k, avg_time, avg_speedup, avg_efficiency, valid_count[k], total_count[k]
        }
    }
}' "$OUTCSV" | sort -t',' -k1,1 -k3,3n -k4,4 > "$SUMMARY_CSV"

echo "✓ Summary saved to: $SUMMARY_CSV"
echo
echo "=== PERFORMANCE SUMMARY ==="
echo "Format: cipher | keyword | np | dist | avg_time | speedup | efficiency | runs"
column -t -s',' "$SUMMARY_CSV"

echo
echo "=== SPEEDUP ANALYSIS ==="
awk -F',' '
NR>1 {
    # SUMMARY_CSV: cipher,keyword,np,dist,avg_time_s,avg_speedup,avg_efficiency,valid_runs,total_runs
    cipher = $1
    dist = $4
    np = $3 + 0
    sp = $6 + 0
    ef = $7 + 0

    key = cipher "_" dist
    seen[key]=1

    if (np > 1 && sp > 0) {
        if (!(key in max_speedup) || sp > max_speedup[key]) {
            max_speedup[key] = sp
            max_speedup_np[key] = np
        }
    }
    if (np > 1 && ef > 0) {
        if (!(key in max_eff) || ef > max_eff[key]) {
            max_eff[key] = ef
            max_eff_np[key] = np
        }
    }
}
END {
    print "Best performance by cipher and distribution:"
    print "cipher_dist,max_speedup,at_np,max_efficiency,at_np"
    for (k in seen) {
        ms = (k in max_speedup) ? max_speedup[k] : 0
        msn = (k in max_speedup_np) ? max_speedup_np[k] : 0
        me = (k in max_eff) ? max_eff[k] : 0
        men = (k in max_eff_np) ? max_eff_np[k] : 0
        printf "%s,%.2f,%d,%.2f,%d\n", k, ms, msn, me, men
    }
}' "$SUMMARY_CSV"

echo
echo "Benchmark completed! Solo se añadió 'Alan' (message_secret) al CSV existente."
