// bruteforce.c — Persona 1 listo: CLI, block|interleaved, winner correcto, salida estable
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>
#include <getopt.h>
#include <mpi.h>
#include <openssl/des.h>

#ifndef GIT_COMMIT
#define GIT_COMMIT "nogit"
#endif

// --- Conversión 56->64 con paridad impar ---
static inline void key56_to_block(uint64_t key56, DES_cblock *out){
    uint64_t k = 0;
    for(int i=0;i<8;i++){
        key56 <<= 1;
        k |= (key56 & (0xFEull << (i*8)));
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

static inline int tryKey(uint64_t key, const unsigned char *ciph, int len, const char *pattern){
    unsigned char *tmp = (unsigned char*)malloc((size_t)len + 1);
    if(!tmp) return 0;
    memcpy(tmp, ciph, (size_t)len);
    tmp[len] = 0; 
    des_decrypt(key, tmp, len);
    int ok = (strstr((const char*)tmp, pattern) != NULL);
    free(tmp);
    return ok;
}

// --- Cipher embebido de respaldo (16B) ---
static unsigned char cipher_embedded[] = {
    108,245,65,63,125,200,150,66,17,170,207,170,34,31,70,215
};
static const int CIPH_LEN_EMB = (int)sizeof(cipher_embedded);

// --- Utilidades I/O ---
static unsigned char* read_all(const char *path, int *out_len){
    FILE *f = fopen(path, "rb");
    if(!f) return NULL;
    fseek(f,0,SEEK_END); long L = ftell(f); fseek(f,0,SEEK_SET);
    if(L<=0){ fclose(f); return NULL; }
    unsigned char *buf = (unsigned char*)malloc((size_t)L);
    if(!buf){ fclose(f); return NULL; }
    if(fread(buf,1,(size_t)L,f)!=(size_t)L){ fclose(f); free(buf); return NULL; }
    fclose(f);
    *out_len = (int)L;
    return buf;
}

// --- CLI ---
typedef enum { DIST_BLOCK=0, DIST_INTERLEAVED=1 } dist_t;

static void usage(const char *prog){
    fprintf(stderr,
    "Uso: %s [opciones]\n"
    "  -i <cipher.bin>    archivo binario (longitud múltiplo de 8). Si no se da, usa embebido.\n"
    "  -p <pattern>       patrón a buscar (default: \" the \")\n"
    "  --limit <ULL>      límite superior de claves (default: 2^56)\n"
    "  --dist <mode>      {block,interleaved} (default: block)\n"
    "  --check <N>        intervalo de MPI_Test (default: 2^18)\n", prog);
}

int main(int argc, char **argv){
    // ---- defaults ----
    const char *in_path = NULL;
    const char *pattern = " the ";
    uint64_t upper = (1ULL<<56);
    dist_t dist = DIST_BLOCK;
    uint64_t check_interval = (1ULL<<18);

    // ---- getopt_long ----
    static struct option longopts[] = {
        {"limit", required_argument, 0, 1},
        {"dist",  required_argument, 0, 2},
        {"check", required_argument, 0, 3},
        {0,0,0,0}
    };
    int opt, idx=0;
    while((opt=getopt_long(argc, argv, "i:p:", longopts, &idx))!=-1){
        if(opt=='i') in_path = optarg;
        else if(opt=='p') pattern = optarg;
        else if(opt==1){ upper = strtoull(optarg, NULL, 0); }
        else if(opt==2){
            if(strcmp(optarg,"block")==0) dist=DIST_BLOCK;
            else if(strcmp(optarg,"interleaved")==0) dist=DIST_INTERLEAVED;
            else { fprintf(stderr,"--dist debe ser block|interleaved\n"); return 1; }
        } else if(opt==3){ check_interval = strtoull(optarg,NULL,0); }
        else { usage(argv[0]); return 1; }
    }

    // ---- MPI init ----
    MPI_Init(&argc, &argv);
    MPI_Comm comm = MPI_COMM_WORLD;
    int N=0, id=0;
    MPI_Comm_size(comm, &N);
    MPI_Comm_rank(comm, &id);

    // ---- cargar cipher ----
    unsigned char *cipher = NULL;
    int ciphlen = 0;
    if(in_path){
        cipher = read_all(in_path, &ciphlen);
        if(!cipher){
            if(id==0) fprintf(stderr,"Error: no pude leer %s\n", in_path);
            MPI_Abort(comm, 2);
        }
        if((ciphlen % 8)!=0){
            if(id==0) fprintf(stderr,"Error: %s no es múltiplo de 8 (len=%d)\n", in_path, ciphlen);
            free(cipher);
            MPI_Abort(comm, 2);
        }
    } else {
        cipher = cipher_embedded;
        ciphlen = CIPH_LEN_EMB;
    }

    // ---- búsqueda ----
    const unsigned long long NOT_FOUND = ULLONG_MAX;
    unsigned long long found = NOT_FOUND;

    MPI_Request req;
    MPI_Status st;
    unsigned long long recv_buf = NOT_FOUND;
    MPI_Irecv(&recv_buf, 1, MPI_UNSIGNED_LONG_LONG, MPI_ANY_SOURCE, 0, comm, &req);

    double t0 = MPI_Wtime();

    int local_found_flag = 0;
    uint64_t tries = 0;

    if(dist == DIST_BLOCK){
        uint64_t range_per_node = upper / (uint64_t)N;
        uint64_t mylower = range_per_node * (uint64_t)id;
        uint64_t myupper = (id == N-1) ? upper : (range_per_node * (uint64_t)(id+1) - 1ULL);
        for(uint64_t k = mylower; k <= myupper && found==NOT_FOUND; ++k){
            if(tryKey(k, cipher, ciphlen, pattern)){
                found = k; local_found_flag = 1;
                for(int node=0; node<N; ++node){ if(node!=id)
                    MPI_Send(&found, 1, MPI_UNSIGNED_LONG_LONG, node, 0, comm);
                }
                break;
            }
            if((++tries % check_interval)==0){
                int flag=0; MPI_Test(&req,&flag,&st);
                if(flag){ found = recv_buf; break; }
            }
        }
    } else {
        for(uint64_t k = (uint64_t)id; k < upper && found==NOT_FOUND; k += (uint64_t)N){
            if(tryKey(k, cipher, ciphlen, pattern)){
                found = k; local_found_flag = 1;
                for(int node=0; node<N; ++node){ if(node!=id)
                    MPI_Send(&found, 1, MPI_UNSIGNED_LONG_LONG, node, 0, comm);
                }
                break;
            }
            if((++tries % check_interval)==0){
                int flag=0; MPI_Test(&req,&flag,&st);
                if(flag){ found = recv_buf; break; }
            }
        }
    }

    // recoger posible aviso pendiente
    if(found==NOT_FOUND){
        int flag=0; MPI_Test(&req,&flag,&st);
        if(flag) found = recv_buf;
    }

    // sincroniza el resultado global (y ganador consistente)
    unsigned long long my_found_val = (found!=NOT_FOUND)?found:ULLONG_MAX;
    unsigned long long global_found = ULLONG_MAX;
    MPI_Allreduce(&my_found_val, &global_found, 1, MPI_UNSIGNED_LONG_LONG, MPI_MIN, comm);

    int local_win_id1 = local_found_flag ? (id+1) : 0;
    int win_id1 = 0;
    MPI_Allreduce(&local_win_id1, &win_id1, 1, MPI_INT, MPI_MAX, comm);
    int winner = (win_id1>0) ? (win_id1-1) : -1;

    double t1 = MPI_Wtime();

    // rank 0 imprime única línea estable
    if(id==0){
        if(global_found==ULLONG_MAX){
            printf("np=%d; key=NOT_FOUND; winner=-1; t_total=%.6f s;\n", N, t1-t0);
        } else {
            // descifra copia para imprimir texto (hasta 64B seguros)
            unsigned char out[64]; memset(out,0,sizeof(out));
            int L = (ciphlen < (int)sizeof(out)) ? ciphlen : (int)sizeof(out);
            memcpy(out, cipher, L);
            des_decrypt(global_found, out, L);
            printf("np=%d; key=%llu; winner=%d; t_total=%.6f s; text=\"%.*s\"\n",
                N, (unsigned long long)global_found, winner, t1-t0, L, out);
        }
        fflush(stdout);
    }

    if(in_path && cipher && cipher!=cipher_embedded) free(cipher);
    MPI_Finalize();
    return 0;
}
