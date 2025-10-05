Proyecto 2 – Dataset de prueba (interno del equipo)
===================================================

Propósito
---------
Este dataset permite a la Persona 2 (Data) correr benchmarks comparando
distribuciones (block, interleaved, dynamic) con llaves ubicadas en posiciones
distintas del espacio de búsqueda. Es interno; NO publicar estas llaves en el foro.

Formato de cifrado
------------------
- Cifrado: DES/ECB
- Padding: PKCS#7 a múltiplos de 8 bytes
- Conversión de llave: 56→64 bits con paridad impar por byte (idéntica a bruteforce)
- Palabra clave en el texto plano: ` the `  (en minúsculas y con espacios)

Archivos incluidos
------------------
- cipher_early.bin   → llave ~1% del rango
- cipher_middle.bin  → llave ~50% del rango
- cipher_late.bin    → llave ~99% del rango
- (opcional) encrypted_output.bin → ejemplo simple para el foro

Parámetros de generación (para reproducir)
------------------------------------------
- Límite de búsqueda usado: LIMIT = 2^28 = 268,435,456
- Llaves (decimales) elegidas respecto a LIMIT:
  * EARLY  = LIMIT/100             = 2,684,354
  * MIDDLE = LIMIT/2               = 134,217,728
  * LATE   = LIMIT - LIMIT/100     = 265,751,102

- Texto plano usado (doc.txt) contiene la keyword ` the `:
  "Save the planet and bring snacks. the mission depends on carbs."

Comandos para regenerar (si fuera necesario)
--------------------------------------------
# 1) Construir utilidades (desde la raíz del repo)
mpicc -O3 -Wall -Wextra -std=c11 src/mkcipher.c -lcrypto -o mkcipher
mpicc -O3 -Wall -Wextra -Wno-deprecated-declarations -std=c11 \
  -DGIT_COMMIT="$(git rev-parse --short HEAD)" src/bruteforce.c -lcrypto -o bruteforce

# 2) Variables
LIMIT=$((1<<28))
EARLY=$(( LIMIT / 100 ))
MIDDLE=$(( LIMIT / 2 ))
LATE=$(( LIMIT - LIMIT/100 ))

# 3) Generar los binarios
./mkcipher -k $EARLY  -i doc.txt -o dataset/cipher_early.bin
./mkcipher -k $MIDDLE -i doc.txt -o dataset/cipher_middle.bin
./mkcipher -k $LATE   -i doc.txt -o dataset/cipher_late.bin

Verificación rápida (debe encontrar la llave y mostrar 1 línea)
---------------------------------------------------------------
# Sugerido en WSL para evitar ruidos:
export OMPI_MCA_btl_base_warn_component_unused=0
export OMPI_MCA_rmaps_base_oversubscribe=1

# Probar con interleaved (también puedes usar block)
mpirun -np 4 ./bruteforce -i dataset/cipher_early.bin  -p " the " --limit $LIMIT --dist interleaved | grep -E '^np='
mpirun -np 4 ./bruteforce -i dataset/cipher_middle.bin -p " the " --limit $LIMIT --dist interleaved | grep -E '^np='
mpirun -np 4 ./bruteforce -i dataset/cipher_late.bin   -p " the " --limit $LIMIT --dist interleaved | grep -E '^np='

Notas para la Persona 2 (Data)
------------------------------
- Mantén el mismo LIMIT (=2^28) en las corridas para comparar peras con peras.
- Usa `scripts/bench_positions.sh` para barrer:
  np ∈ {1,2,4,8} × dist ∈ {block, interleaved, dynamic} × {early, middle, late}, runs=5
- Asegúrate de que los resúmenes no tengan `NA`. Si aparece ruido, revisa los logs
  `results/.last_run_np_*_r*.log` y re-lanza solo el np afectado.
- En el foro, se publica SOLO el binario cifrado y la keyword. NO publicar las llaves decimales de arriba.

Punto de partida recomendado
----------------------------
Trabajar desde el tag: v0.2-interleaved-ready
La salida del binario incluye GIT_COMMIT para trazabilidad.
