#import "Sessions.h"
#import "BridgeProtocol.h"
#import <fcntl.h>
#import <netinet/in.h>
#import <signal.h>
#import <spawn.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/wait.h>

extern char **environ;

static NSString * const JBP1lotSessionLogDirectory = @"/var/mobile/Library/Logs/jb-p1lot-sessions";
static NSMutableDictionary<NSString *, NSMutableDictionary *> *JBP1lotSessions;
static dispatch_queue_t JBP1lotSessionQueue;

static NSArray<NSString *> *JBP1lotFridaServerPaths(void) {
    return @[@"/var/jb/usr/sbin/frida-server", @"/var/jb/usr/bin/frida-server", @"/var/jb/usr/libexec/frida-server"];
}

static NSString * const JBP1lotProvisionedDebugserver = @"/var/jb/usr/libexec/jb-p1lot/debugserver";
static NSString * const JBP1lotDebugserverEntitlements = @"/var/jb/usr/share/jb-p1lot/debugserver-entitlements.plist";
static NSString * const JBP1lotSystemDebugserver = @"/usr/libexec/debugserver";

static BOOL JBP1lotRun(NSString *executable, NSArray<NSString *> *arguments) {
    NSMutableArray *all = [NSMutableArray arrayWithObject:executable];
    [all addObjectsFromArray:arguments];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger index = 0; index < all.count; index++) argv[index] = (char *)[all[index] UTF8String];
    pid_t pid = 0;
    int status = -1;
    BOOL spawned = posix_spawn(&pid, executable.fileSystemRepresentation, NULL, NULL, argv, environ) == 0;
    free(argv);
    return spawned && waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static NSString *JBP1lotProvisionDebugserver(NSString **failure) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSDictionary *system = [manager attributesOfItemAtPath:JBP1lotSystemDebugserver error:nil];
    NSDictionary *provisioned = [manager attributesOfItemAtPath:JBP1lotProvisionedDebugserver error:nil];
    if (provisioned && (!system || [provisioned[NSFileModificationDate] compare:system[NSFileModificationDate]] != NSOrderedAscending)) return JBP1lotProvisionedDebugserver;
    if (!system) {
        *failure = @"debugserver is unavailable; mount the developer disk image";
        return nil;
    }
    [manager createDirectoryAtPath:JBP1lotProvisionedDebugserver.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *staging = [JBP1lotProvisionedDebugserver stringByAppendingString:@".new"];
    [manager removeItemAtPath:staging error:nil];
    if (![manager copyItemAtPath:JBP1lotSystemDebugserver toPath:staging error:nil] || !JBP1lotRun(@"/var/jb/usr/bin/ldid", @[[@"-S" stringByAppendingString:JBP1lotDebugserverEntitlements], staging])) {
        [manager removeItemAtPath:staging error:nil];
        *failure = @"debugserver could not be re-signed with ldid";
        return nil;
    }
    chmod(staging.fileSystemRepresentation, 0755);
    rename(staging.fileSystemRepresentation, JBP1lotProvisionedDebugserver.fileSystemRepresentation);
    return JBP1lotProvisionedDebugserver;
}

static NSString *JBP1lotFirstExecutable(NSArray<NSString *> *paths) {
    for (NSString *path in paths)
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) return path;
    return nil;
}

static uint16_t JBP1lotFreeLoopbackPort(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 0;
    struct sockaddr_in address = { .sin_len = sizeof(address), .sin_family = AF_INET, .sin_port = 0, .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    socklen_t length = sizeof(address);
    uint16_t port = 0;
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) == 0 && getsockname(fd, (struct sockaddr *)&address, &length) == 0) port = ntohs(address.sin_port);
    close(fd);
    return port;
}

static NSDictionary *JBP1lotSessionInfo(NSDictionary *session) {
    NSMutableDictionary *info = [session mutableCopy];
    [info removeObjectsForKeys:@[@"source", @"inputDescriptor"]];
    return info;
}

static NSString *JBP1lotSessionLogTail(NSString *path, NSUInteger maxBytes) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return @"";
    unsigned long long size = [handle seekToEndOfFile];
    [handle seekToFileOffset:size > maxBytes ? size - maxBytes : 0];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static void JBP1lotWatchExit(NSString *identifier, pid_t pid) {
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT, JBP1lotSessionQueue);
    dispatch_source_set_event_handler(source, ^{
        int status = 0;
        waitpid(pid, &status, WNOHANG);
        NSMutableDictionary *session = JBP1lotSessions[identifier];
        if (session[@"inputDescriptor"]) close([session[@"inputDescriptor"] intValue]);
        [session removeObjectForKey:@"inputDescriptor"];
        session[@"state"] = @"stopped";
        session[@"exitStatus"] = @(WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        session[@"stoppedAt"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000));
        dispatch_source_cancel(source);
    });
    JBP1lotSessions[identifier][@"source"] = source;
    dispatch_resume(source);
}

static NSDictionary *JBP1lotSpawnSession(NSString *kind, NSString *executable, NSArray<NSString *> *arguments, uint16_t port, NSDictionary *details) {
    [[NSFileManager defaultManager] createDirectoryAtPath:JBP1lotSessionLogDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *identifier = [NSString stringWithFormat:@"%@-%@", kind, [NSUUID.UUID.UUIDString substringToIndex:8].lowercaseString];
    NSString *logPath = [JBP1lotSessionLogDirectory stringByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"log"]];
    int input[2];
    if (pipe(input) != 0) return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"session input pipe failed") };
    fcntl(input[1], F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    posix_spawn_file_actions_addclose(&actions, input[1]);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    NSMutableArray *all = [NSMutableArray arrayWithObject:executable];
    [all addObjectsFromArray:arguments];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger index = 0; index < all.count; index++) argv[index] = (char *)[all[index] UTF8String];
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    sigset_t defaults, empty;
    sigfillset(&defaults);
    sigemptyset(&empty);
    posix_spawnattr_setsigdefault(&attributes, &defaults);
    posix_spawnattr_setsigmask(&attributes, &empty);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP);
    posix_spawnattr_setpgroup(&attributes, 0);
    pid_t pid = 0;
    int result = posix_spawn(&pid, executable.fileSystemRepresentation, &actions, &attributes, argv, environ);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    free(argv);
    close(input[0]);
    if (result != 0) close(input[1]);
    if (result != 0) return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", [NSString stringWithFormat:@"%@ failed to start: %s", executable.lastPathComponent, strerror(result)]) };
    NSMutableDictionary *session = [@{
        @"sessionId": identifier,
        @"kind": kind,
        @"pid": @(pid),
        @"remotePort": @(port),
        @"executable": executable,
        @"arguments": arguments,
        @"logPath": logPath,
        @"state": @"running",
        @"inputDescriptor": @(input[1]),
        @"startedAt": @((long long)(NSDate.date.timeIntervalSince1970 * 1000)),
    } mutableCopy];
    [session addEntriesFromDictionary:details];
    JBP1lotSessions[identifier] = session;
    JBP1lotWatchExit(identifier, pid);
    usleep(400000);
    int status = 0;
    BOOL exited = waitpid(pid, &status, WNOHANG) == pid;
    NSMutableDictionary *payload = [JBP1lotSessionInfo(session) mutableCopy];
    payload[@"output"] = JBP1lotSessionLogTail(logPath, 4096);
    if (!exited) return @{ @"status": @"ok", @"payload": payload };
    session[@"state"] = @"stopped";
    return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", [NSString stringWithFormat:@"%@ exited immediately: %@", executable.lastPathComponent, payload[@"output"]]) };
}

static NSDictionary *JBP1lotStartDebugserver(NSDictionary *params) {
    NSString *failure = nil;
    NSString *debugserver = JBP1lotProvisionDebugserver(&failure);
    if (!debugserver) return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"not_found", failure) };
    uint16_t port = (uint16_t)[params[@"remotePort"] intValue] ?: JBP1lotFreeLoopbackPort();
    NSMutableArray *arguments = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"127.0.0.1:%u", port]];
    NSString *process = [params[@"process"] isKindOfClass:[NSString class]] ? params[@"process"] : @"";
    NSString *waitFor = [params[@"waitFor"] isKindOfClass:[NSString class]] ? params[@"waitFor"] : @"";
    NSString *path = [params[@"path"] isKindOfClass:[NSString class]] ? params[@"path"] : @"";
    if ([params[@"pid"] intValue] > 0) [arguments addObject:[NSString stringWithFormat:@"--attach=%d", [params[@"pid"] intValue]]];
    else if (process.length) [arguments addObject:[NSString stringWithFormat:@"--attach=%@", process]];
    else if (waitFor.length) [arguments addObject:[NSString stringWithFormat:@"--waitfor=%@", waitFor]];
    else if (path.length) [arguments addObjectsFromArray:@[@"-x", @"backboard", path]];
    for (id argument in [params[@"extraArguments"] isKindOfClass:[NSArray class]] ? params[@"extraArguments"] : @[])
        if ([argument isKindOfClass:[NSString class]]) [arguments addObject:argument];
    return JBP1lotSpawnSession(@"lldb", debugserver, arguments, port, @{ @"backend": @"debugserver", @"connect": [NSString stringWithFormat:@"process connect connect://127.0.0.1:%u", port] });
}

static NSDictionary *JBP1lotStartFridaServer(NSDictionary *params) {
    NSString *server = JBP1lotFirstExecutable(JBP1lotFridaServerPaths());
    if (!server) return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"not_found", @"frida-server is not installed; add the re.frida.server package from https://build.frida.re") };
    for (NSDictionary *session in JBP1lotSessions.allValues)
        if ([session[@"kind"] isEqualToString:@"frida"] && [session[@"state"] isEqualToString:@"running"]) return @{ @"status": @"ok", @"payload": JBP1lotSessionInfo(session) };
    uint16_t port = (uint16_t)[params[@"remotePort"] intValue] ?: 27042;
    return JBP1lotSpawnSession(@"frida", server, @[@"-l", [NSString stringWithFormat:@"127.0.0.1:%u", port]], port, @{ @"backend": @"frida-server", @"connect": [NSString stringWithFormat:@"frida -H 127.0.0.1:%u", port] });
}

NSDictionary *JBP1lotManagedSessionRequest(NSString *kind, NSDictionary *params) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        JBP1lotSessions = [NSMutableDictionary dictionary];
        JBP1lotSessionQueue = dispatch_queue_create("dev.adrian.jb-p1lot.sessions", DISPATCH_QUEUE_SERIAL);
    });
    NSString *action = [params[@"action"] isKindOfClass:[NSString class]] ? [params[@"action"] lowercaseString] : @"start";
    NSString *identifier = [params[@"sessionId"] isKindOfClass:[NSString class]] ? params[@"sessionId"] : @"";
    __block NSDictionary *response = nil;
    dispatch_sync(JBP1lotSessionQueue, ^{
        NSMutableDictionary *session = identifier.length ? JBP1lotSessions[identifier] : nil;
        if (action.length == 0 || [action isEqualToString:@"start"]) {
            response = [kind isEqualToString:@"frida"] ? JBP1lotStartFridaServer(params) : JBP1lotStartDebugserver(params);
        } else if ([action isEqualToString:@"list"]) {
            NSMutableArray *sessions = [NSMutableArray array];
            for (NSDictionary *candidate in JBP1lotSessions.allValues)
                if ([candidate[@"kind"] isEqualToString:kind]) [sessions addObject:JBP1lotSessionInfo(candidate)];
            response = @{ @"status": @"ok", @"payload": @{ @"sessions": sessions } };
        } else if (!session) {
            response = @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"not_found", @"unknown sessionId") };
        } else if ([action isEqualToString:@"stop"]) {
            pid_t pid = [session[@"pid"] intValue];
            if ([session[@"state"] isEqualToString:@"running"]) {
                kill(pid, SIGTERM);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), JBP1lotSessionQueue, ^{
                    if ([session[@"state"] isEqualToString:@"stopping"]) kill(pid, SIGKILL);
                });
                session[@"state"] = @"stopping";
            }
            response = @{ @"status": @"ok", @"payload": JBP1lotSessionInfo(session) };
        } else if ([action isEqualToString:@"status"] || [action isEqualToString:@"read"]) {
            NSMutableDictionary *payload = [JBP1lotSessionInfo(session) mutableCopy];
            payload[@"output"] = JBP1lotSessionLogTail(session[@"logPath"], MIN(MAX([params[@"maxBytes"] unsignedIntegerValue] ?: 16384, 256), 1u << 20));
            response = @{ @"status": @"ok", @"payload": payload };
        } else {
            response = @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"action must be start, list, status, read, or stop") };
        }
    });
    return response;
}
