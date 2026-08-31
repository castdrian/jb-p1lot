#import "BridgeProtocol.h"
#import <sys/stat.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        umask(0077);
        JBP1lotStartService();
        dispatch_main();
    }
    return 0;
}
