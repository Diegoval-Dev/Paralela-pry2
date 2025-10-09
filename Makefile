CC=mpicc
OPENSSL_PREFIX=$(shell brew --prefix openssl 2>/dev/null || echo "/usr")
CFLAGS=-O3 -Wall -Wextra -std=c11 -Wno-deprecated-declarations -I$(OPENSSL_PREFIX)/include
LDFLAGS=-L$(OPENSSL_PREFIX)/lib -lcrypto
GIT_COMMIT=$(shell git rev-parse --short HEAD 2>/dev/null || echo "nogit")

all: bruteforce mkcipher

bruteforce: bruteforce.c
	$(CC) $(CFLAGS) -DGIT_COMMIT="\"$(GIT_COMMIT)\"" $< $(LDFLAGS) -o $@

mkcipher: mkcipher.c
	$(CC) $(CFLAGS) $< $(LDFLAGS) -o $@

clean:
	rm -f bruteforce mkcipher

# Pruebas rápidas
test-early: bruteforce
	mpirun -np 4 ./bruteforce -i dataset/cipher_early.bin -p " the " --limit $$((1<<28)) --dist interleaved

test-middle: bruteforce
	mpirun -np 4 ./bruteforce -i dataset/cipher_middle.bin -p " the " --limit $$((1<<28)) --dist interleaved

test-late: bruteforce
	mpirun -np 4 ./bruteforce -i dataset/cipher_late.bin -p " the " --limit $$((1<<28)) --dist interleaved

.PHONY: all clean test-early test-middle test-late
