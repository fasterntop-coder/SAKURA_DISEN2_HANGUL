#!/usr/bin/env python3
"""ReSONANCE Run13 PS4-only genuine Dreamcast ROM fallback. No firmware included."""
import pathlib, sys
root=pathlib.Path(sys.argv[1]).resolve()
def patch(rel, edits):
    p=root/rel
    s=p.read_text()
    for needle, replace in edits:
        n=s.count(needle)
        if n!=1:
            raise SystemExit(f"FATAL source drift {rel}: {n} occurrences of {needle[:80]!r}")
        s=s.replace(needle, replace, 1)
    p.write_text(s)
    print("PATCHED", p)
patch("core/emulator.cpp",[(
    '\t\t\t\t\tif (gdr::initDrive(settings.content.path))\n\t\t\t\t\t{\n\t\t\t\t\t\tloadGameSpecificSettings();',
    '''\t\t\t\t\tif (gdr::initDrive(settings.content.path))
\t\t\t\t\t{
\t\t\t\t\t\tloadGameSpecificSettings();
#ifdef __ORBIS__
                        if (settings.content.gameId == "HDR-0082" && config::loadBool("resonance", "PreferRealBiosST2", true)) {
                            NOTICE_LOG(BOOT, "[ST2-BIOS] genuine Dreamcast boot ROM requested");
                            config::UseReios.override(false);
                        }
#endif'''
)])
patch("core/hw/flashrom/nvmem.cpp",[
    ('#include "oslib/resources.h"', '''#include "oslib/resources.h"
#ifdef __ORBIS__
#include <sys/stat.h>
#include <cerrno>
#include <cstdio>
#endif'''),
    ('\t\trc = sys_nvmem->Load(getRomPrefix(), "%nvmem.bin", "nvram");', '''#ifdef __ORBIS__
        rc = sys_nvmem->Load(getRomPrefix(), "%nvmem.bin;%flash.bin", "nvram");
#else
\t\trc = sys_nvmem->Load(getRomPrefix(), "%nvmem.bin", "nvram");
#endif'''),
    ('\tif (sys_rom->Load(getRomPrefix(), "%boot.bin;%bios.bin", "bootrom"))', '''    bool loaded = sys_rom->Load(getRomPrefix(), "%boot.bin;%bios.bin", "bootrom");
#ifdef __ORBIS__
    if (!loaded) {
        const char *const paths[] = {
            "/data/Resonance/data/dc_boot.bin", "/data/Resonance/data/dc_bios.bin",
            "/data/Resonance/bios/dc_boot.bin", "/data/Resonance/bios/dc_bios.bin",
            "/data/Resonance/dc_boot.bin"
        };
        for (const char *path : paths) {
            struct stat info {};
            if (stat(path, &info) != 0) {
                INFO_LOG(FLASHROM, "[PS4-BIOS] stat failed '%s' errno=%d", path, errno);
                continue;
            }
            if (info.st_size != 2097152) {
                WARN_LOG(FLASHROM, "[PS4-BIOS] bad size '%s': %lld", path, static_cast<long long>(info.st_size));
                continue;
            }
            FILE *file = std::fopen(path, "rb");
            if (!file) {
                WARN_LOG(FLASHROM, "[PS4-BIOS] open failed '%s' errno=%d", path, errno);
                continue;
            }
            std::unique_ptr<u8[]> image(new u8[2097152]);
            const size_t count = std::fread(image.get(), 1, 2097152, file);
            const int error = std::ferror(file);
            std::fclose(file);
            if (count != 2097152 || error) {
                WARN_LOG(FLASHROM, "[PS4-BIOS] read failed '%s': %zu bytes, error=%d", path, count, error);
                continue;
            }
            sys_rom->Load(image.get(), 2097152);
            loaded = true;
            NOTICE_LOG(FLASHROM, "[PS4-BIOS] genuine ROM loaded from %s", path);
            break;
        }
    }
#endif
    if (loaded)'''),
    ('\t\tbios_loaded = true;\n\t\treturn true;', '''        bios_loaded = true;
#ifdef __ORBIS__
        NOTICE_LOG(FLASHROM, "[PS4-BIOS] genuine ROM ACTIVE");
#endif
\t\treturn true;''')
])
print("Run13 PS4 BIOS patch complete")