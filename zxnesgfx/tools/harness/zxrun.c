// Minimal 48K Spectrum-like harness for timing measurements.
// - 64K flat RAM (no ROM needed: program installs its own IM2)
// - 50 Hz interrupt every 69888 T (INT held 32 T)
// - approximate ULA memory contention for 0x4000-0x7FFF accesses
// - OUT ($FF),a  -> logs marker (a, T) to stdout
// - dumps the screen (6912 bytes) at chosen frames
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "z80.h"
static uint8_t mem[65536];
static z80 cpu;
static unsigned long contended=0, contend_t=0;
static int contention=1;
static const int pat[8]={6,5,4,3,2,1,0,0};
static void contend(uint16_t a){
  if(!contention || a<0x4000 || a>=0x8000) return;
  unsigned long t=cpu.cyc%69888;
  if(t<14335 || t>=14335+192*224) return;
  unsigned long lt=(t-14335)%224; if(lt>=128) return;
  int d=pat[lt&7]; cpu.cyc+=d; contended++; contend_t+=d;
}
static uint8_t rb(void*u,uint16_t a){ contend(a); return mem[a]; }
static void wb(void*u,uint16_t a,uint8_t v){ contend(a); if(a>=0x4000) mem[a]=v; }
static uint8_t keys[8]={0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff};
static uint8_t pin(z80*z,uint8_t p){ if(p==0xfe){ uint8_t hi=z->b? z->b : z->a; uint8_t r=0xff; for(int i=0;i<8;i++) if(!(hi&(1<<i))) r&=keys[i]; return r|0xe0;} return 0xff; }
static int border=7; static FILE* outf=0; static int stop=0; static long space_from=-1, space_to=-1; static long curframe=0;
static unsigned long long prof[65536]; static int profiling=0;
static void pout(z80*z,uint8_t p,uint8_t v){
  if(p==0xff){ printf("M %d %lu\n",v,z->cyc); if(v==0xEE) stop=1; }
  else if(p==0xfd){ if(outf) fputc(v,outf); }
  else if((p&1)==0){ border=v&7; }
}
static void usage(void){ fprintf(stderr,
 "zxrun -load file@addr [-load ...] -entry addr -frames n [-dump prefix f1,f2,..]\n"
 "      [-out stream.bin] [-prof] [-nc] [-space from to]\n"
 "  OUT ($FF),a: marker (stdout), $EE stops.  OUT ($FD),a: byte to -out file.\n"); }
int main(int argc,char**argv){
  long frames=0; unsigned entry=0; const char*pref="scr"; long dumps[256]; int nd=0;
  for(int i=1;i<argc;i++){
    if(!strcmp(argv[i],"-load")){ char*f=argv[++i]; char*at=strchr(f,'@'); *at=0; unsigned org=strtoul(at+1,0,16);
      FILE*fp=fopen(f,"rb"); if(!fp){perror(f);return 1;} size_t n=fread(mem+org,1,65536-org,fp); fclose(fp); fprintf(stderr,"loaded %s: %zu bytes at %04x\n",f,n,org); }
    else if(!strcmp(argv[i],"-entry")) entry=strtoul(argv[++i],0,16);
    else if(!strcmp(argv[i],"-frames")) frames=atol(argv[++i]);
    else if(!strcmp(argv[i],"-dump")){ pref=argv[++i]; char*t=strtok(argv[++i],","); while(t){dumps[nd++]=atol(t); t=strtok(0,",");} }
    else if(!strcmp(argv[i],"-out")) outf=fopen(argv[++i],"wb");
    else if(!strcmp(argv[i],"-prof")) profiling=1;
    else if(!strcmp(argv[i],"-nc")) contention=0;
    else if(!strcmp(argv[i],"-space")){ space_from=atol(argv[++i]); space_to=atol(argv[++i]); }
    else { usage(); return 1; }
  }
  if(!frames){ usage(); return 1; }
  z80_init(&cpu); cpu.read_byte=rb; cpu.write_byte=wb; cpu.port_in=pin; cpu.port_out=pout;
  cpu.pc=entry; cpu.sp=0x8000;
  for(long fr=0; fr<frames && !stop; fr++){ curframe=fr; keys[7]=(fr>=space_from && fr<space_to)? 0xfe : 0xff;
    unsigned long start=(unsigned long)fr*69888;
    z80_gen_int(&cpu,0xff);
    while(cpu.cyc<start+69888 && !stop){ uint16_t pc0=cpu.pc; unsigned long c0=cpu.cyc; z80_step(&cpu); if(profiling) prof[pc0]+=cpu.cyc-c0; if(cpu.cyc>start+32) cpu.int_pending=0; }
    for(int i=0;i<nd;i++) if(dumps[i]==fr){ char fn[512]; sprintf(fn,"%s_%05ld.scr",pref,fr); FILE*o=fopen(fn,"wb"); fwrite(mem+0x4000,1,6912,o); fclose(o);}
  }
  if(profiling){ FILE*o=fopen("prof.bin","wb"); fwrite(prof,8,65536,o); fclose(o);}
  if(outf) fclose(outf);
  printf("C contended_accesses %lu contention_T %lu total_T %lu\n",contended,contend_t,cpu.cyc);
  return 0;
}
