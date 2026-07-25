// compile 
// gcc -shared -fPIC -o nosleep.so nosleep.c
// LD_PRELOAD=$(pwd)/nosleep.so ./app1

// for Docker
// ENV LD_PRELOAD=/app/nosleep.so
#include <time.h>
#include <sys/select.h>

// This covers the high-precision sleep Python uses
int nanosleep(const struct timespec *req, struct timespec *rem) {
    return 0;
}

// This covers the older style of sleeping
int select(int nfds, fd_set *readfds, fd_set *writefds,
           fd_set *exceptfds, struct timeval *timeout) {
    return 0;
}

// This covers the basic C sleep
unsigned int sleep(unsigned int seconds) {
    return 0;
}
