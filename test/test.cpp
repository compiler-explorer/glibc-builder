#include <cstdlib>
#include <cmath>
#include <cstdio>
#include <gnu/libc-version.h>
#include <iostream>
#include <locale>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

int main() {
    std::vector<std::string> words{"hello", "from", "libstdc++"};
    std::string joined;
    for (const auto &w : words)
        joined += w + " ";

    int thread_result = 0;
    std::thread t([&] { thread_result = 42; });
    t.join();

    bool caught = false;
    try {
        throw std::runtime_error("boom");
    } catch (const std::exception &) {
        caught = true;
    }

    std::cout << joined << "thread=" << thread_result << " exception=" << caught
              << " sqrt=" << std::sqrt(2.0) << " headers=" << __GLIBC__ << "." << __GLIBC_MINOR__ << "\n";
    bool ok = thread_result == 42 && caught;
    std::cout << "version=" << (ok ? gnu_get_libc_version() : "checks-failed") << std::endl;
    return ok ? 0 : 1;
}
