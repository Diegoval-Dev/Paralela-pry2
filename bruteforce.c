// bruteforce.c — v0.2 + dynamic minimal (master/worker por chunks)
// Mantiene block|interleaved con parada temprana y añade --dist dynamic --chunk N
// Salida estable (una línea):  np=... key=... time=... [git=...] [plain="..."]

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

// -------------------- DES helpers --------------------
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

// -------------------- Cipher embebido (fallback) --------------------
static unsigned char cipher_embedded[] = {
    108,245,65,63,125,200,150,66,17,170,207,170,34,31,70,215
};
static const int CIPH_LEN_EMB = (int)sizeof(cipher_embedded);

// -------------------- I/O --------------------
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

// -------------------- CLI --------------------
typedef enum { DIST_BLOCK=0, DIST_INTERLEAVED=1, DIST_DYNAMIC=2 } dist_t;

static void usage(const char *prog){
    fprintf(stderr,
    "Uso: %s [opciones]\n"
    "  -i <cipher.bin>    archivo binario (múltiplo de 8); si no se da, usa embebido\n"
    "  -p <pattern>       patrón a buscar (default: \" the \")\n"
    "  --limit <ULL>      límite superior de claves (default: 2^56)\n"
    "  --dist <mode>      {block,interleaved,dynamic} (default: block)\n"
    "  --check <N>        intervalo de chequeo en block/interleaved (default: 2^18)\n"
    "  --chunk <N>        tamaño de chunk en dynamic (default: 1000000)\n", prog);
}

// -------------------- main --------------------
int main(int argc, char **argv){
    // defaults v0.2
    const char *in_path = NULL;
    const char *pattern = " the ";
    uint64_t upper = (1ULL<<56);
    dist_t dist = DIST_BLOCK;
    uint64_t check_interval = (1ULL<<18);

    // nuevo para dynamic
    uint64_t chunk = 1000000ULL;

    static struct option longopts[] = {
        {"limit", required_argument, 0, 1},
        {"dist",  required_argument, 0, 2},
        {"check", required_argument, 0, 3},
        {"chunk", required_argument, 0, 4},
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
            else if(strcmp(optarg,"dynamic")==0) dist=DIST_DYNAMIC;
            else { if(!strcmp(optarg,"dyn")) dist=DIST_DYNAMIC;
                   else { fprintf(stderr,"--dist debe ser block|interleaved|dynamic\n"); return 1; } }
        } else if(opt==3){ check_interval = strtoull(optarg,NULL,0); }
        else if(opt==4){ chunk = strtoull(optarg,NULL,0); }
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

    // receptor no bloqueante para block/interleaved
    MPI_Request req;
    MPI_Status st;
    unsigned long long recv_buf = NOT_FOUND;
    MPI_Irecv(&recv_buf, 1, MPI_UNSIGNED_LONG_LONG, MPI_ANY_SOURCE, 0, comm, &req);

    double t0 = MPI_Wtime();

    int local_found_flag = 0;
    uint64_t tries = 0;

    if(dist == DIST_DYNAMIC){
        // Fallback secuencial para np=1 (evita key=0/time~0)
        if(N==1){
            for(uint64_t k=0; k<upper; ++k){
                if(tryKey(k, cipher, ciphlen, pattern)){
                    found = k; local_found_flag = 1; break;
                }
            }
        }else{
            // Master/worker por chunks
            const int TAG_REQ   = 1;
            const int TAG_ASSIGN= 2;
            const int TAG_FOUND = 3;
            const unsigned long long TERM = ULLONG_MAX;

            if(id==0){
                // MASTER
                unsigned long long next = 0;
                int workers_done = 0;
                int global_stop = 0;
                while(workers_done < (N-1) && !global_stop){
                    MPI_Status s;
                    MPI_Probe(MPI_ANY_SOURCE, MPI_ANY_TAG, comm, &s);
                    if(s.MPI_TAG==TAG_FOUND){
                        unsigned long long k;
                        MPI_Recv(&k,1,MPI_UNSIGNED_LONG_LONG,s.MPI_SOURCE,TAG_FOUND,comm,MPI_STATUS_IGNORE);
                        found = k; local_found_flag = 1;
                        // mandar terminación a todos
                        for(int w=1; w<N; ++w){
                            unsigned long long msg[2]={TERM,0};
                            MPI_Send(msg,2,MPI_UNSIGNED_LONG_LONG,w,TAG_ASSIGN,comm);
                        }
                        global_stop = 1;
                    }else if(s.MPI_TAG==TAG_REQ){
                        int src = s.MPI_SOURCE;
                        MPI_Recv(NULL,0,MPI_BYTE,src,TAG_REQ,comm,MPI_STATUS_IGNORE);
                        unsigned long long msg[2];
                        if(next < upper && !global_stop){
                            unsigned long long s0 = next;
                            unsigned long long e0 = next + chunk;
                            if(e0 > upper) e0 = upper;
                            next = e0;
                            msg[0]=s0; msg[1]=e0;
                            MPI_Send(msg,2,MPI_UNSIGNED_LONG_LONG,src,TAG_ASSIGN,comm);

                            //fprintf(stderr, "[MASTER] asign: %llu..%llu -> %d\n",
                            //        (unsigned long long)msg[0], (unsigned long long)msg[1], src);
                            //fflush(stderr);

                        }else{
                            msg[0]=TERM; msg[1]=0;
                            MPI_Send(msg,2,MPI_UNSIGNED_LONG_LONG,src,TAG_ASSIGN,comm);
                            workers_done++;
                        }
                    }else{
                        // drenar cualquier cosa inesperada
                        MPI_Recv(NULL,0,MPI_BYTE,s.MPI_SOURCE,s.MPI_TAG,comm,MPI_STATUS_IGNORE);
                    }
                }
            }else{
                // WORKER
                const uint64_t PROBE_MASK = (check_interval ? (check_interval-1) : ( (1u<<18)-1 ));
                while(1){
                    // pedir trabajo
                    MPI_Send(NULL,0,MPI_BYTE,0,TAG_REQ,comm);
                    unsigned long long msg[2];
                    MPI_Recv(msg,2,MPI_UNSIGNED_LONG_LONG,0,TAG_ASSIGN,comm,&st);
                    //fprintf(stderr, "[WORKER %d] recv assign: %llu..%llu\n",
                     //       id, (unsigned long long)msg[0], (unsigned long long)msg[1]);
                    //fflush(stderr);
                    if(msg[0]==TERM) {
                        local_found_flag = 1;
                        break;
                    }
                    unsigned long long s0=msg[0], e0=msg[1];
                    uint64_t cnt=0;
                    for(uint64_t k=s0; k<e0; ++k){
                        if(tryKey(k, cipher, ciphlen, pattern)){
                            found = k; local_found_flag = 1;
                            MPI_Send(&k,1,MPI_UNSIGNED_LONG_LONG,0,TAG_FOUND,comm);
                            // dejamos que master corte a todos
                            goto dyn_done_chunk;
                        }
                        if(check_interval && ((++cnt & PROBE_MASK)==0)){
                            // ¿nos llegó terminación mientras trabajábamos?
                            int flag=0; MPI_Status ps;
                            MPI_Iprobe(0,TAG_ASSIGN,comm,&flag,&ps);
                            if(flag){
                                unsigned long long termmsg[2];
                                MPI_Recv(termmsg,2,MPI_UNSIGNED_LONG_LONG,0,TAG_ASSIGN,comm,MPI_STATUS_IGNORE);
                                if(termmsg[0]==TERM){
                                    local_found_flag = 1;
                                    goto dyn_done_chunk;
                                }
                                // Si no era TERM (raro), reasignamos y seguimos
                                s0=termmsg[0]; e0=termmsg[1]; k=s0; cnt=0;
                            }
                        }
                    }
                    dyn_done_chunk: ;
                    if(local_found_flag) break;
                } // while worker
            }
            // Fin dynamic 
        }
    }
    else if(dist == DIST_BLOCK){
        // Partición contigua con parada temprana (Allreduce periódico)
        uint64_t per = upper / (uint64_t)N;
        uint64_t mylower = per * (uint64_t)id;
        uint64_t myupper = (id == N-1) ? upper-1ULL : (per * (uint64_t)(id+1) - 1ULL);

        unsigned long long local_key=0, global_key=0;
        int local_found=0, global_found=0;

        uint64_t cnt=0;
        const uint64_t PROBE_MASK = (check_interval ? (check_interval-1) : ( (1u<<18)-1 ));
        for(uint64_t k=mylower; k<=myupper; ++k){
            if(!local_found && tryKey(k, cipher, ciphlen, pattern)){
                local_found=1; local_key=k;
            }
            if(((cnt++) & PROBE_MASK)==0 || local_found){
                MPI_Allreduce(&local_found,&global_found,1,MPI_INT,MPI_LOR,comm);
                MPI_Allreduce(&local_key,&global_key,1,MPI_UNSIGNED_LONG_LONG,MPI_MAX,comm);
                if(global_found){ found=global_key; break; }
            }
        }
        if(!global_found){
            // último chequeo
            MPI_Allreduce(&local_found,&global_found,1,MPI_INT,MPI_LOR,comm);
            MPI_Allreduce(&local_key,&global_key,1,MPI_UNSIGNED_LONG_LONG,MPI_MAX,comm);
            if(global_found) found=global_key;
        }
        local_found_flag = local_found;
    }
    else { // DIST_INTERLEAVED
        unsigned long long local_key=0, global_key=0;
        int local_found=0, global_found=0;

        uint64_t cnt=0;
        const uint64_t PROBE_MASK = (check_interval ? (check_interval-1) : ( (1u<<18)-1 ));
        for(uint64_t k=(uint64_t)id; k<upper; k+=(uint64_t)N){
            if(!local_found && tryKey(k, cipher, ciphlen, pattern)){
                local_found=1; local_key=k;
            }
            if(((cnt++) & PROBE_MASK)==0 || local_found){
                MPI_Allreduce(&local_found,&global_found,1,MPI_INT,MPI_LOR,comm);
                MPI_Allreduce(&local_key,&global_key,1,MPI_UNSIGNED_LONG_LONG,MPI_MAX,comm);
                if(global_found){ found=global_key; break; }
            }
        }
        if(!global_found){
            MPI_Allreduce(&local_found,&global_found,1,MPI_INT,MPI_LOR,comm);
            MPI_Allreduce(&local_key,&global_key,1,MPI_UNSIGNED_LONG_LONG,MPI_MAX,comm);
            if(global_found) found=global_key;
        }
        local_found_flag = local_found;
    }

    // ---- sincronización final ----
    unsigned long long my_found_val = (found!=NOT_FOUND)?found:ULLONG_MAX;
    unsigned long long global_found = ULLONG_MAX;
    MPI_Allreduce(&my_found_val, &global_found, 1, MPI_UNSIGNED_LONG_LONG, MPI_MIN, comm);

    int local_win_id1 = local_found_flag ? (id+1) : 0;
    int win_id1 = 0;
    MPI_Allreduce(&local_win_id1, &win_id1, 1, MPI_INT, MPI_MAX, comm);
    int winner = (win_id1>0) ? (win_id1-1) : -1;

    double t1 = MPI_Wtime();
    double elapsed = t1 - t0;

    if(id==0){
        if(global_found==ULLONG_MAX){
            printf("np=%d; key=NOT_FOUND; winner=%d; t_total=%.6f; git=%s\n",
                N, winner, elapsed, GIT_COMMIT);
        } else {
            // decodifica una copia para mostrar texto
            unsigned char out[64]; memset(out,0,sizeof(out));
            int L = (ciphlen < (int)sizeof(out)) ? ciphlen : (int)sizeof(out);
            memcpy(out, cipher, L);
            des_decrypt(global_found, out, L);
            printf("np=%d; key=%llu; winner=%d; t_total=%.6f; git=%s; plain=\"%.*s\"\n",
                N, (unsigned long long)global_found, winner, elapsed, GIT_COMMIT, L, out);
        }
        fflush(stdout);
    }

    if(in_path && cipher && cipher!=cipher_embedded) free(cipher);
    MPI_Finalize();
    return 0;
}
