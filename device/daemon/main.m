#import "BridgeProtocol.h"
#import "Display.h"
#import "Health.h"
#import <signal.h>
#import <sys/stat.h>

static dispatch_source_t JBP1lotTerminationSource;

static void JBP1lotHandleTermination(void) {
    signal(SIGTERM, SIG_IGN);
    JBP1lotTerminationSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(JBP1lotTerminationSource, ^{
        JBP1lotHealthReleasePower();
        exit(0);
    });
    dispatch_resume(JBP1lotTerminationSource);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        umask(0077);
        if (argc > 1 && strcmp(argv[1], "--release-power") == 0) {
            JBP1lotHealthReleasePower();
            return 0;
        }
        JBP1lotHandleTermination();
        JBP1lotStartService();
        JBP1lotHealthStart();
        JBP1lotDisplayStart();
        dispatch_main();
    }
    return 0;
}
