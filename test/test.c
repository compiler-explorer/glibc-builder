#define _GNU_SOURCE
#include <errno.h>
#include <gnu/libc-version.h>
#include <iconv.h>
#include <langinfo.h>
#include <linux/version.h>
#include <locale.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef USE_ZLIB
#include <zlib.h>
#endif

/* Which libc.so.6 is mapped: proves the prefix's libc is used even when its version matches
   the host's. Static binaries have none. */
static void print_libc_path(void) {
    FILE *maps = fopen("/proc/self/maps", "r");
    char line[4096];
    const char *found = "static";
    static char path[4096];
    while (maps && fgets(line, sizeof(line), maps)) {
        char *p = strchr(line, '/');
        if (p && strstr(p, "/libc.so.6")) {
            p[strcspn(p, "\n")] = 0;
            strcpy(path, p);
            found = path;
            break;
        }
    }
    if (maps)
        fclose(maps);
    printf("libc=%s\n", found);
}

/* Every locale named in $TEST_LOCALES (space separated) must load. */
static int check_locales(void) {
    const char *list = getenv("TEST_LOCALES");
    if (!list)
        return 1;
    char *copy = strdup(list);
    int ok = 1, count = 0;
    for (char *name = strtok(copy, " "); name; name = strtok(NULL, " ")) {
        if (!setlocale(LC_ALL, name)) {
            printf("locale %s=FAILED\n", name);
            ok = 0;
        }
        count++;
    }
    setlocale(LC_ALL, "C");
    printf("locales=%d %s\n", count, ok ? "ok" : "FAILED");
    free(copy);
    return ok;
}

static int check_iconv(void) {
    iconv_t cd = iconv_open("UTF-16LE", "UTF-8");
    if (cd == (iconv_t)-1) {
        perror("iconv_open UTF-8 -> UTF-16LE");
        return 0;
    }
    char in[] = "h\xc3\xa9llo";
    char out[32];
    char *inp = in, *outp = out;
    size_t inleft = strlen(in), outleft = sizeof(out);
    size_t r = iconv(cd, &inp, &inleft, &outp, &outleft);
    iconv_close(cd);
    if (r == (size_t)-1 || sizeof(out) - outleft != 10) {
        perror("iconv");
        return 0;
    }

    iconv_t back = iconv_open("UTF-8", "UTF-16LE");
    if (back == (iconv_t)-1) {
        perror("iconv_open UTF-16LE -> UTF-8");
        return 0;
    }
    char round[32];
    char *rin = out, *rout = round;
    size_t rinleft = 10, routleft = sizeof(round);
    r = iconv(back, &rin, &rinleft, &rout, &routleft);
    iconv_close(back);
    return r != (size_t)-1 && sizeof(round) - routleft == strlen(in) && memcmp(round, in, strlen(in)) == 0;
}

int main(void) {
    int ok = 1;
    printf("headers=%d.%d kernel-headers=%d.%d\n", __GLIBC__, __GLIBC_MINOR__, LINUX_VERSION_CODE >> 16,
           (LINUX_VERSION_CODE >> 8) & 0xff);

    print_libc_path();
    ok &= check_locales();

    int iconv_ok = check_iconv();
    printf("iconv=%s\n", iconv_ok ? "ok" : "FAILED");
    ok &= iconv_ok;

    /* $NO_C_UTF8: this glibc ships no C.UTF-8 (< 2.36); check another UTF-8 locale instead */
    const char *utf8_locale = getenv("NO_C_UTF8") && *getenv("NO_C_UTF8") ? "en_US.UTF-8" : "C.UTF-8";
    const char *loc = setlocale(LC_ALL, utf8_locale);
    int loc_ok = loc && strcmp(nl_langinfo(CODESET), "UTF-8") == 0;
    printf("locale=%s codeset=%s\n", loc ? loc : "(null)", nl_langinfo(CODESET));
    ok &= loc_ok;

    setenv("TZ", "Europe/Amsterdam", 1);
    tzset();
    time_t t = 1750000000; /* June 2025: CEST */
    struct tm tm;
    localtime_r(&t, &tm);
    printf("tz=%s\n", tm.tm_zone);
    ok &= strcmp(tm.tm_zone, "CEST") == 0;

#ifdef USE_ZLIB
    printf("zlib=%s\n", zlibVersion());
#endif

    printf("version=%s\n", ok ? gnu_get_libc_version() : "checks-failed");
    return ok ? 0 : 1;
}
