// mkcipher.c — genera encrypted_output.bin con DES/ECB sin padding explícito (PKCS#7 interno)
// Usa la misma conversión 56→64 bits (paridad impar por byte) que su brute-force.
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <openssl/des.h>

static inline void key56_to_block(uint64_t key56, DES_cblock *out){
    uint64_t k = 0;
    for(int i=0;i<8;i++){
        key56 <<= 1;                            // deja LSB para paridad
        k |= (key56 & (0xFEull << (i*8)));      // 7 bits útiles por byte
    }
    memcpy(out, &k, 8);
    DES_set_odd_parity(out);
}

static void des_encrypt_ecb(uint64_t key56, unsigned char *buf, int len){
    DES_cblock cb; DES_key_schedule ks;
    key56_to_block(key56, &cb);
    DES_set_key_unchecked(&cb, &ks);
    for(int i=0; i<len; i+=8){
        DES_ecb_encrypt((const_DES_cblock*)(buf+i), (DES_cblock*)(buf+i), &ks, DES_ENCRYPT);
    }
}

// PKCS#7 padding a múltiplo de 8
static int pad_pkcs7(unsigned char **pbuf, int len){
    int pad = 8 - (len % 8);
    int outlen = len + pad;
    unsigned char *out = (unsigned char*)malloc(outlen);
    if(!out) return -1;
    memcpy(out, *pbuf, len);
    for(int i=0;i<pad;i++) out[len+i] = (unsigned char)pad;
    *pbuf = out;
    return outlen;
}

int main(int argc, char **argv){
    if(argc < 4){
        fprintf(stderr, "Uso: %s -k <key_dec> -i <doc.txt> -o <encrypted_output.bin>\n", argv[0]);
        return 1;
    }
    uint64_t key56 = 0; const char *in = NULL; const char *out = NULL;
    for(int i=1;i<argc;i++){
        if(!strcmp(argv[i],"-k") && i+1<argc) key56 = strtoull(argv[++i],NULL,0);
        else if(!strcmp(argv[i],"-i") && i+1<argc) in = argv[++i];
        else if(!strcmp(argv[i],"-o") && i+1<argc) out = argv[++i];
    }
    if(!in || !out){ fprintf(stderr,"Faltan -i/-o\n"); return 1; }

    // lee doc.txt completo
    FILE *fi = fopen(in,"rb"); if(!fi){ perror("in"); return 1; }
    fseek(fi,0,SEEK_END); long L = ftell(fi); fseek(fi,0,SEEK_SET);
    unsigned char *buf = (unsigned char*)malloc(L?L:1);
    if(!buf){ fclose(fi); return 1; }
    if(L>0 && fread(buf,1,L,fi)!=(size_t)L){ perror("fread"); fclose(fi); free(buf); return 1; }
    fclose(fi);

    // padding PKCS#7
    int enc_len = pad_pkcs7(&buf, (int)L);
    if(enc_len < 0){ fprintf(stderr,"sin memoria\n"); free(buf); return 1; }

    // cifra
    des_encrypt_ecb(key56, buf, enc_len);

    // escribe binario
    FILE *fo = fopen(out,"wb"); if(!fo){ perror("out"); free(buf); return 1; }
    fwrite(buf,1,enc_len,fo);
    fclose(fo);
    free(buf);

    fprintf(stderr, "OK: %s generado con key_dec=%llu, bytes=%d\n",
            out, (unsigned long long)key56, enc_len);
    return 0;
}
