# Proyecto 2: Brute Force Paralelo con MPI

Implementación paralela de búsqueda exhaustiva de claves DES (56 bits) usando OpenMPI.

## Requisitos

- **MPI**: OpenMPI (mpicc, mpirun)
- **OpenSSL**: libcrypto (libssl-dev en Linux, openssl en macOS vía Homebrew)
- **Herramientas**: bash, awk, sed, column

## Compilación

### Método rápido

```bash
make
```

### Método manual

```bash
mpicc -O3 -Wall -Wextra -std=c11 -Wno-deprecated-declarations \
  -I$(brew --prefix openssl)/include \
  -DGIT_COMMIT="$(git rev-parse --short HEAD)" \
  bruteforce.c \
  -L$(brew --prefix openssl)/lib -lcrypto \
  -o bruteforce
```

## Ejecución Rápida

### Prueba simple (4 procesos, distribución interleaved)

```bash
mpirun -np 4 ./bruteforce \
  -i dataset/cipher_middle.bin \
  -p " the " \
  --limit $((1<<28)) \
  --dist interleaved
```

**Salida esperada:**

```
np=4; key=134217728; winner=2; t_total=0.123456; git=5998619; plain="Save the planet..."
```

### Pruebas con dataset incluido

```bash
make test-early    # Llave en el primer ~1% del rango
make test-middle   # Llave en el ~50% del rango
make test-late     # Llave en el ~99% del rango
```

## Opciones del Programa

```
-i <file>           Archivo cifrado binario (default: cipher embebido)
-p <pattern>        Palabra clave a buscar (default: " the ")
--limit <N>         Límite superior de búsqueda (default: 2^56)
--dist <mode>       Distribución: {block|interleaved|dynamic} (default: block)
--chunk <N>         Tamaño de chunk para dynamic (default: 1000000)
--check <N>         Intervalo de chequeo para block/interleaved (default: 2^18)
```

### Distribuciones

- **block**: Partición contigua del espacio de búsqueda (rendimiento depende de posición de llave)
- **interleaved**: Partición entrelazada (mejor balance de carga)
- **dynamic**: Master/worker con chunks dinámicos (más consistente, overhead de comunicación)

## Benchmarking

### Benchmark rápido (validación)

```bash
bash scripts/quick_bench.sh 2
```

Ejecuta con límite reducido (2^22) para validación rápida:
- np ∈ {1, 2, 4}
- dist ∈ {block, interleaved, dynamic}
- cipher ∈ {early, middle}
- 2 corridas por configuración (~2 min total)

### Benchmark completo

```bash
bash scripts/simple_bench.sh 5
```

Ejecuta con límite completo (2^28):
- np ∈ {1, 2, 4, 8}
- dist ∈ {block, interleaved, dynamic}
- cipher ∈ {early, middle, late}
- 5 corridas por configuración (~20-30 min total)

**Salida:**
- `results/benchmark.csv` - Tiempos detallados
- `results/benchmark_summary.csv` - Medianas por configuración

### Calcular métricas de speedup y eficiencia

```bash
bash scripts/compute_metrics.sh
```

**Salida:**
- `results/metrics.csv` - Speedup y eficiencia vs baseline (np=1)

## Estructura del Proyecto

```
.
├── bruteforce.c              # Código principal MPI
├── mkcipher.c                # Generador de archivos cifrados
├── Makefile                  # Compilación y tests rápidos
├── dataset/
│   ├── cipher_early.bin      # Llave ~1% del rango
│   ├── cipher_middle.bin     # Llave ~50% del rango
│   ├── cipher_late.bin       # Llave ~99% del rango
│   ├── doc.txt               # Texto plano original
│   └── README.txt            # Documentación del dataset
├── scripts/
│   ├── simple_bench.sh       # Benchmark minimalista
│   └── compute_metrics.sh    # Cálculo de speedup/eficiencia
└── results/                  # Salidas de benchmarking
```

## Ejemplo de Flujo de Trabajo

```bash
# 1. Compilar
make clean && make

# 2. Probar ejecución básica
make test-middle

# 3. Benchmark rápido (validación - 2 min)
bash scripts/quick_bench.sh 2

# 4. Calcular métricas
bash scripts/compute_metrics.sh

# 5. Ver resultados
column -t -s',' results/metrics.csv

# 6. Benchmark completo (producción - 20-30 min)
bash scripts/simple_bench.sh 5
bash scripts/compute_metrics.sh
```

## Dataset de Prueba

Los archivos en `dataset/` fueron generados con `mkcipher` para probar la consistencia del algoritmo en diferentes posiciones del espacio de búsqueda:

- **cipher_early.bin**: Llave 2684354 (~0.0047% del rango total)
- **cipher_middle.bin**: Llave 134217728 (50% del rango)
- **cipher_late.bin**: Llave 72057594037927935 (~99.99% del rango)

Todos contienen el texto "Save the planet and bring snacks..." cifrado con DES/ECB.

## Notas Técnicas

- **Formato de salida**: `np=X; key=Y; winner=Z; t_total=W; git=...; plain="..."`
- **Parada temprana**: Block/interleaved usan `MPI_Allreduce` periódico; dynamic usa mensajes master/worker
- **Conversión de clave**: 56 bits efectivos → 64 bits con paridad impar (estándar DES)
- **Padding**: PKCS#7 aplicado por `mkcipher`

## Troubleshooting

### Error: `openssl/des.h` not found

En macOS:
```bash
brew install openssl
```

El Makefile detecta automáticamente la ruta vía `brew --prefix openssl`.

### np=8 produce tiempos inconsistentes

Verificar que no haya oversubscribe en WSL (el Makefile agrega flags apropiados automáticamente).

## Referencias

- [OpenMPI Documentation](https://www.open-mpi.org/doc/)
- [OpenSSL DES API](https://www.openssl.org/docs/man1.1.1/man3/DES_set_key.html)
