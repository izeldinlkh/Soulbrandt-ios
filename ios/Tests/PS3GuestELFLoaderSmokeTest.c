#include "../SoulbrandtIOS/PS3GuestMemory.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern uint8_t *vm_base;

static void put16(uint8_t *p, uint16_t v)
{
    p[0]=(uint8_t)(v>>8); p[1]=(uint8_t)v;
}
static void put32(uint8_t *p, uint32_t v)
{
    p[0]=(uint8_t)(v>>24); p[1]=(uint8_t)(v>>16);
    p[2]=(uint8_t)(v>>8); p[3]=(uint8_t)v;
}
static void put64(uint8_t *p, uint64_t v)
{
    put32(p,(uint32_t)(v>>32)); put32(p+4,(uint32_t)v);
}

static void make_elf(uint8_t *f, size_t n)
{
    memset(f,0,n);
    f[0]=0x7f; f[1]='E'; f[2]='L'; f[3]='F';
    f[4]=2; f[5]=2; f[6]=1;
    put16(f+16,2); put16(f+18,21);
    put32(f+20,1);
    put64(f+24,0x60000100);
    put64(f+32,64);
    put16(f+52,64); put16(f+54,56); put16(f+56,2);

    uint8_t *load=f+64;
    put32(load,1); put32(load+4,5);
    put64(load+8,176); put64(load+16,0x60000100);
    put64(load+32,4); put64(load+40,8); put64(load+48,16);

    uint8_t *tls=f+120;
    put32(tls,7);
    put64(tls+16,0x60000100);
    put64(tls+32,4); put64(tls+40,8);

    f[176]=0x12; f[177]=0x34; f[178]=0x56; f[179]=0x78;
}

int main(void)
{
    uint8_t file[192];
    soulbrandt_guest_elf_info info;
    make_elf(file,sizeof(file));

    if (soulbrandt_guest_load_elf(file,sizeof(file),&info) != -1) {
        fprintf(stderr,"loader must reject calls before VM initialization\n");
        return 1;
    }
    if (soulbrandt_guest_memory_init() != 0) return 2;
    if (soulbrandt_guest_load_elf(file,sizeof(file),&info) != 0) {
        fprintf(stderr,"valid PPC64 ELF rejected\n");
        return 3;
    }
    if (info.entry_opd != 0x60000100 || info.tls_vaddr != 0x60000100 ||
        info.tls_filesz != 4 || info.tls_memsz != 8 ||
        info.load_segment_count != 1 || info.load_min_vaddr != 0x60000100ULL ||
        info.load_max_vaddr != 0x60000108ULL || info.load_range_count != 1 ||
        info.load_ranges[0].begin != 0x60000100ULL ||
        info.load_ranges[0].end != 0x60000108ULL) return 4;
    const uint8_t expected[8]={0x12,0x34,0x56,0x78,0,0,0,0};
    if (memcmp(vm_base+0x60000100,expected,sizeof(expected)) != 0) return 5;

    /* A malformed later range must be rejected before any segment is copied. */
    vm_base[0x60000200]=0xA5;
    put64(file+64+8,0xFFFFFFFFFFFFFFF0ULL);
    put64(file+64+16,0x60000200);
    if (soulbrandt_guest_load_elf(file,sizeof(file),&info) != -7) return 6;
    if (vm_base[0x60000200] != 0xA5) return 7;

    make_elf(file,sizeof(file));
    file[5]=1; /* little-endian is not a PS3 ELF */
    if (soulbrandt_guest_load_elf(file,sizeof(file),&info) != -2) return 8;

    /* Entry points must resolve into a mapped PT_LOAD range. */
    make_elf(file,sizeof(file));
    put64(file+24,0x61000000);
    if (soulbrandt_guest_load_elf(file,sizeof(file),&info) != -9) return 9;

    /* PT_TLS file bytes must be present in the ELF file. */
    make_elf(file,sizeof(file));
    put64(file+120+8,0xFFFFFFFFFFFFFFF0ULL);
    if (soulbrandt_guest_load_elf(file,sizeof(file),&info) != -6) return 10;

    /* TLS metadata must refer to memory represented by a PT_LOAD segment. */
    make_elf(file,sizeof(file));
    put64(file+120+16,0x61000000);
    if (soulbrandt_guest_load_elf(file,sizeof(file),&info) != -10) return 11;

    soulbrandt_guest_memory_shutdown();
    puts("PS3 guest ELF loader smoke test passed");
    return 0;
}
