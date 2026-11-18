// ReSONANCE Run13: local-disc-only BIOS experiment. No proprietary firmware or games.
#include "netfs.h"
#include "updater.h"
#include <cerrno>
const char *ps4_app_dir() { return "/app0"; }
std::string ps4_app_version() { return "01.42"; }
long ps4_http_get(const std::string&, std::string&, std::string& error) {
    error="HTTP disabled in local-disc-only BIOS trial"; return 0;
}
namespace updater {
Release checkLatest() { Release r; r.ok=false; r.error="Network features disabled"; return r; }
int compareVersions(const std::string& a, const std::string& b) { return a.compare(b); }
std::string install(const Release&,const std::function<bool(uint64_t,uint64_t)>&,bool *needsInstaller) {
    if(needsInstaller) *needsInstaller=false;
    return "Update disabled in offline BIOS test";
}
void startDownloadedUpdate(int,char*[]) {}
}
namespace netfs {
std::string Share::folder() const {return "/net/"+label;}
std::string Share::describe() const {return type+" "+host+":"+path;}
std::vector<Share> shares() {return {};}
void addShare(Share) {}
void removeShare(const std::string&) {}
std::string makeLabel(const std::string& host,const std::string& path) {return host+"_"+path;}
std::string test(const Share&,int& entries) {entries=0;return "Network shares disabled in offline BIOS test";}
void mountAll() {}
}
extern "C" int ps4_netfs_is_path(const char*) {return 0;}
extern "C" int ps4_netfs_open(const char*,int) {errno=ENOENT;return -1;}
extern "C" int ps4_netfs_close(int) {return 0;}
