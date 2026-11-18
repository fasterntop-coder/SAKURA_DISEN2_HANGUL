#!/usr/bin/env python3
"""ReSONANCE Run13 local-disc-only test variant; features intentionally reduced."""
from pathlib import Path
import sys
fly=Path(sys.argv[1]); res=Path(sys.argv[2]); here=Path(__file__).parent
def patch(p,edits):
    s=p.read_text()
    for a,b in edits:
        if s.count(a)!=1: raise SystemExit(f"REFUSE DRIFT {p}: {a[:60]!r} ({s.count(a)})")
        s=s.replace(a,b,1)
    p.write_text(s)
    print('PATCHED',p)
patch(fly/'shell/ps4/CMakeLists.txt',[
 ('netfs.cpp\n\tupdater.cpp','offline.cpp\n\t# network modules omitted in offline BIOS trial'),
 ('target_link_libraries(${PROJECT_NAME} PRIVATE\n\t${PS4_SYSROOT}/lib/libnfs.a ${PS4_SYSROOT}/lib/libsmb2.a\n\t${PS4_SYSROOT}/lib/libcurl.a ${PS4_SYSROOT}/lib/libssl.a ${PS4_SYSROOT}/lib/libcrypto.a)','')
])
patch(res/'toolchain/ps4-love-style.cmake',[
 ('    ${CMAKE_CURRENT_LIST_DIR}/../port/ps4_netfs.cpp)','    # network filesystem disabled for local-disc trial\n    )'),
 ('foreach (fn read _read readv _readv pread lseek fstat stat getdents)\n    list(APPEND PS4_NETFS_WRAPS --wrap=${fn})\nendforeach ()','# remote file IO wrappers omitted for this trial')
])
p=fly/'core/oslib/http_client.cpp';s=p.read_text()
a='#include <curl/curl.h>'
if s.count(a)!=1: raise SystemExit('refuse drift: curl include')
s=s.replace(a,'''#ifdef __ORBIS__
namespace http {
void init() {}
void term() {}
int get(const std::string&, std::vector<u8>&, const Headers*, Headers*) {return 503;}
int post(const std::string&, const char*, const char*, std::vector<u8>&) {return 503;}
int post(const std::string&, const std::vector<PostField>&) {return 503;}
}
#else
#include <curl/curl.h>''',1)
marker='\n#endif\t// !_WIN32'
if s.count(marker)!=1: raise SystemExit('refuse drift: curl section closure')
s=s.replace(marker,'\n#endif // __ORBIS__ local disc trial'+marker,1)
p.write_text(s)
(fly/'shell/ps4/offline.cpp').write_bytes((here/'offline.cpp').read_bytes())
print('OFFLINE_BIOS_PATCH_COMPLETE (no online updater/achievements/network share)')
