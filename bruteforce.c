#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>
#include <mpi.h>
#include <openssl/des.h>

#ifndef SELFTEST
#define SELFTEST 0   // pon 1 para autogenerar cipher con key chica y validar end-to-end
#endif

// --- Utilidades DES con OpenSSL ---

static inline void key56_to_block(uint64_t key56, DES_cblock *out){
    // Empaqueta 56 bits en 8 bytes dejando 1 bit de paridad por byte
    uint64_t k = 0;
    for(int i=0;i<8;i++){
        key56 <<= 1;                            // deja LSB libre para paridad
        k |= (key56 & (0xFEull << (i*8)));      // 7 bits útiles por byte
    }
    memcpy(out, &k, 8);
    DES_set_odd_parity(out);
}

static inline void des_decrypt(uint64_t key, unsigned char *buf, int len){
    DES_cblock cb; DES_key_schedule ks;
    key56_to_block(key, &cb);
    DES_set_key_unchecked(&cb, &ks);
    for(int i=0;i<len; i+=8){
        DES_ecb_encrypt((const_DES_cblock*)(buf+i), (DES_cblock*)(buf+i), &ks, DES_DECRYPT);
    }
}

static inline void des_encrypt(uint64_t key, unsigned char *buf, int len){
    DES_cblock cb; DES_key_schedule ks;
    key56_to_block(key, &cb);
    DES_set_key_unchecked(&cb, &ks);
    for(int i=0;i<len; i+=8){
        DES_ecb_encrypt((const_DES_cblock*)(buf+i), (DES_cblock*)(buf+i), &ks, DES_ENCRYPT);
    }
}

// --- Búsqueda patrón ---
static const char SEARCH[] = " the ";

static int tryKey(uint64_t key, const unsigned char *ciph, int len){
    // len debe ser múltiplo de 8
    unsigned char *tmp = (unsigned char*)malloc((size_t)len + 1);
    if(!tmp) return 0;
    memcpy(tmp, ciph, (size_t)len);
    tmp[len] = 0; // por si el texto es ASCII
    des_decrypt(key, tmp, len);
    int ok = (strstr((const char*)tmp, SEARCH) != NULL);
    free(tmp);
    return ok;
}

// --- Cipher embebido (tu arreglo), sin byte 0 al final ---
static unsigned char cipher_embedded[] = {
    108,245,65,63,125,200,150,66,17,170,207,170,34,31,70,215
};
// Si mantienes el 0 final, usa sizeof()-1; aquí lo quitamos:
static const int CIPH_LEN = (int)sizeof(cipher_embedded);

// Para SELFTEST: genera un cipher coherente con una llave chica y el patrón " the "
static void init_selftest_cipher(uint64_t key, unsigned char *dst, int len){
    // Llena dst con un texto conocido (múltiplo de 8) que contenga " the "
    // y lo cifra con 'key'. Para len=16 caben 16 chars.
    const char *plain16 = " in the room..."; // 16 bytes si recortas/ajustas
    unsigned char buf[16];
    memset(buf, 0, 16);
    memcpy(buf, plain16, 16);
    memcpy(dst, buf, 16);
    des_encrypt(key, dst, 16);
}

// --- Main ---

int main(int argc, char **argv){
    MPI_Init(&argc, &argv);

    MPI_Comm comm = MPI_COMM_WORLD;
    int N=0, id=0;
    MPI_Comm_size(comm, &N);
    MPI_Comm_rank(comm, &id);

    // Límite superior de claves: por defecto enorme; para pruebas pasa un menor en argv[1]
    uint64_t upper = (argc > 1) ? strtoull(argv[1], NULL, 0) : (1ULL << 56);

    // Buffer de ciphertext de trabajo (por defecto el embebido)
    unsigned char *cipher = cipher_embedded;
    int ciphlen = CIPH_LEN; // ¡no uses strlen() en binarios!

#if SELFTEST
    // Para validar end-to-end rápido: llave peque (p.ej. 0x123456)
    static unsigned char self_cipher[16];
    uint64_t self_key = 0x123456ULL;
    init_selftest_cipher(self_key, self_cipher, 16);
    cipher = self_cipher;
    ciphlen = 16;
    if(id==0){
        fprintf(stderr, "[SELFTEST] Generé cipher con key=%llu (hex=%llx)\n",
                (unsigned long long)self_key, (unsigned long long)self_key);
    }
#endif

    if((ciphlen % 8) != 0){
        if(id==0) fprintf(stderr, "Error: ciphlen=%d no es múltiplo de 8.\n", ciphlen);
        MPI_Abort(comm, 2);
    }

    // Partición por rangos contiguos
    uint64_t range_per_node = upper / (uint64_t)N;
    uint64_t mylower = range_per_node * (uint64_t)id;
    uint64_t myupper = (id == N-1) ? upper : (range_per_node * (uint64_t)(id+1) - 1ULL);

    const unsigned long long NOT_FOUND = ULLONG_MAX;
    unsigned long long found = NOT_FOUND;
    MPI_Request req;
    MPI_Status st;
    int flag = 0;

    // Recv no bloqueante para parada temprana
    MPI_Irecv(&found, 1, MPI_UNSIGNED_LONG_LONG, MPI_ANY_SOURCE, 0, comm, &req);

    double t0 = MPI_Wtime();

    // Búsqueda
    const uint64_t CHECK_INTERVAL = 1ULL << 18; // revisa mensajes cada ~262k intentos
    uint64_t counter = 0;

    for(uint64_t k = mylower; k <= myupper && found == NOT_FOUND; ++k){
        if(tryKey(k, cipher, ciphlen)){
            found = k;
            // Avisar a todos para detener
            for(int node=0; node<N; ++node){
                if(node == id) continue; // opcional
                MPI_Send(&found, 1, MPI_UNSIGNED_LONG_LONG, node, 0, comm);
            }
            break;
        }
        if((++counter & (CHECK_INTERVAL-1)) == 0){
            MPI_Test(&req, &flag, &st);
            if(flag) break; // alguien ya publicó la llave
        }
    }

    // Si rank 0 no encontró ni recibió aún, espera por si alguien avisó
    if(id==0 && found==NOT_FOUND){
        MPI_Test(&req, &flag, &st);
        if(!flag) MPI_Wait(&req, &st);
    }

    double t1 = MPI_Wtime();

    // Rank 0 reporta
    int winner = -1;
    if(found != NOT_FOUND){
        winner = (id==0 && st.MPI_SOURCE==MPI_ANY_SOURCE) ? 0 : st.MPI_SOURCE;
        // Si yo encontré, MPI_Test pudo no setear st: fuerza winner = id si no hubo recv
        if(winner < 0) winner = id;
    }

    // Reunir al rank 0 quién reporta
    int local_found = (found != NOT_FOUND) ? 1 : 0;
    int any_found = 0;
    MPI_Allreduce(&local_found, &any_found, 1, MPI_INT, MPI_LOR, comm);

    if(id==0){
        if(!any_found){
            printf("np=%d; key=NOT_FOUND; t_total=%.6f s\n", N, t1-t0);
        }else{
            // Descifrar copia para imprimir texto
            unsigned char out[64]; // alcanza para 16 bytes
            memset(out, 0, sizeof(out));
            int L = (ciphlen < (int)sizeof(out)) ? ciphlen : (int)sizeof(out);
            memcpy(out, cipher, L);
            des_decrypt(found, out, L);
            printf("np=%d; key=%llu; winner=%d; t_total=%.6f s; text=\"%.*s\"\n",
                   N, (unsigned long long)found, winner, t1-t0, L, out);
        }
        fflush(stdout);
    }

    MPI_Finalize();
    return 0;
}