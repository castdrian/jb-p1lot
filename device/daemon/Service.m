#import "BridgeProtocol.h"
#import <fcntl.h>
#import <signal.h>
#import <spawn.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>
#import <errno.h>

extern char **environ;

static NSString *JBP1lotString(NSDictionary *request, NSString *key) {
    id value = request[key];
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSData *JBP1lotRunShell(NSString *command, NSString *cwd, NSInteger timeoutMs, int *status) {
    if (timeoutMs <= 0) timeoutMs = 30000;
    int outputPipe[2];
    if (pipe(outputPipe) != 0) {
        return nil;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
    posix_spawn_file_actions_addclose(&actions, outputPipe[1]);
    NSString *shellCommand = cwd.length > 0 ? [NSString stringWithFormat:@"cd '%@' && %@", [cwd stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"], command] : command;
    pid_t pid = 0;
    char *arguments[] = {"sh", "-c", (char *)shellCommand.UTF8String, NULL};
    int spawnStatus = posix_spawn(&pid, "/var/jb/usr/bin/sh", &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(outputPipe[1]);
    if (spawnStatus != 0) {
        close(outputPipe[0]);
        return nil;
    }
    NSMutableData *output = [NSMutableData data];
    int flags = fcntl(outputPipe[0], F_GETFL, 0);
    fcntl(outputPipe[0], F_SETFL, flags | O_NONBLOCK);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(1, timeoutMs) / 1000.0];
    BOOL finished = NO;
    while (!finished) {
        uint8_t buffer[8192];
        ssize_t count = read(outputPipe[0], buffer, sizeof(buffer));
        if (count > 0) {
            [output appendBytes:buffer length:(NSUInteger)count];
            if (output.length > (16u << 20)) {
                [output replaceBytesInRange:NSMakeRange(0, output.length - (16u << 20)) withBytes:NULL length:0];
            }
        }
        pid_t result = waitpid(pid, status, WNOHANG);
        if (result == pid) {
            finished = YES;
        } else if ([[NSDate date] compare:deadline] == NSOrderedDescending) {
            kill(pid, SIGKILL);
            waitpid(pid, status, 0);
            finished = YES;
        } else {
            usleep(10000);
        }
    }
    fcntl(outputPipe[0], F_SETFL, flags & ~O_NONBLOCK);
    while (YES) {
        uint8_t buffer[8192];
        ssize_t count = read(outputPipe[0], buffer, sizeof(buffer));
        if (count <= 0) break;
        [output appendBytes:buffer length:(NSUInteger)count];
        if (output.length > (16u << 20)) {
            [output replaceBytesInRange:NSMakeRange(0, output.length - (16u << 20)) withBytes:NULL length:0];
        }
    }
    close(outputPipe[0]);
    return output;
}

static NSString *JBP1lotQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value ?: @"" stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static mode_t JBP1lotMode(NSDictionary *params) {
    id value = params[@"mode"];
    if (!value || value == [NSNull null]) return 0600;
    NSString *text = [value isKindOfClass:[NSString class]] ? value : [value stringValue];
    if (text.length == 0) return 0600;
    char *end = NULL;
    unsigned long parsed = strtoul(text.UTF8String, &end, 8);
    if (end == text.UTF8String || (end && *end != '\0') || parsed == 0 || parsed > 07777) return 0600;
    return (mode_t)parsed;
}

static NSDictionary *JBP1lotRunResult(NSString *command, NSInteger timeoutMs) {
    int status = 0;
    NSData *output = JBP1lotRunShell(command, @"", timeoutMs, &status);
    if (!output) {
        return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"command failed to start") };
    }
    NSInteger exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";
    return @{ @"status": exitCode == 0 ? @"ok" : @"error", @"payload": @{ @"exitCode": @(exitCode), @"output": text } };
}

static NSDictionary *JBP1lotProcessRequest(NSDictionary *params) {
    NSString *action = [JBP1lotString(params, @"action") lowercaseString];
    if ([action isEqualToString:@"list"] || action.length == 0) {
        return JBP1lotRunResult(@"ps -axo pid,ppid,user,state,comm,args", 10000);
    }
    if ([action isEqualToString:@"signal"] || [action isEqualToString:@"terminate"]) {
        pid_t pid = (pid_t)[params[@"pid"] intValue];
        int signalValue = [params[@"signal"] intValue] ?: ([action isEqualToString:@"terminate"] ? SIGTERM : SIGUSR1);
        if (pid <= 1 || kill(pid, signalValue) != 0) {
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"process signal failed") };
        }
        return @{ @"status": @"ok", @"payload": @{ @"pid": @(pid), @"signal": @(signalValue) } };
    }
    if ([action isEqualToString:@"spawn"]) {
        NSString *command = JBP1lotString(params, @"command");
        return JBP1lotRunResult([NSString stringWithFormat:@"%@", command], [params[@"timeoutMs"] integerValue] ?: 10000);
    }
    return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"unknown process action") };
}

static NSDictionary *JBP1lotPackageRequest(NSDictionary *params) {
    NSString *action = [JBP1lotString(params, @"action") lowercaseString];
    NSString *package = JBP1lotString(params, @"package");
    if ([action isEqualToString:@"list"] || action.length == 0) {
        return JBP1lotRunResult(@"/var/jb/usr/bin/dpkg-query -W -f='${Package} ${Version}\\n'", 30000);
    }
    if ([action isEqualToString:@"install"] || [action isEqualToString:@"rollback"]) {
        NSString *path = JBP1lotString(params, @"path");
        return JBP1lotRunResult([NSString stringWithFormat:@"/var/jb/usr/bin/dpkg -i %@", JBP1lotQuote(path)], 120000);
    }
    if ([action isEqualToString:@"remove"] || [action isEqualToString:@"uninstall"]) {
        return JBP1lotRunResult([NSString stringWithFormat:@"/var/jb/usr/bin/dpkg -r %@", JBP1lotQuote(package)], 120000);
    }
    return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"unknown package action") };
}

NSDictionary *JBP1lotHandleRequest(NSDictionary *request) {
    NSString *method = JBP1lotString(request, @"method");
    NSDictionary *params = [request[@"payload"] isKindOfClass:[NSDictionary class]] ? request[@"payload"] : @{};
    if ([method isEqualToString:@"device.status"]) {
        return @{ @"status": @"ok", @"payload": @{ @"uid": @(getuid()), @"bridge": @YES, @"port": @(JBP1lotPort) } };
    }
    if ([method isEqualToString:@"shell_exec"]) {
        NSString *command = JBP1lotString(params, @"command");
        if (command.length == 0) {
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"command is required") };
        }
        int status = 0;
        NSData *output = JBP1lotRunShell(command, JBP1lotString(params, @"cwd"), [params[@"timeoutMs"] integerValue], &status);
        if (!output) {
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"shell execution failed") };
        }
        NSInteger exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
        return @{ @"status": @"ok", @"payload": @{ @"exitCode": @(exitCode), @"output": [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"" } };
    }
    if ([method isEqualToString:@"file_read"]) {
        NSString *path = JBP1lotString(params, @"path");
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        if (!data) {
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"file read failed") };
        }
        NSUInteger maxBytes = [params[@"maxBytes"] unsignedIntegerValue];
        if (maxBytes > 0 && data.length > maxBytes) {
            data = [data subdataWithRange:NSMakeRange(0, maxBytes)];
        }
        return @{ @"status": @"ok", @"payload": @{ @"data": [data base64EncodedStringWithOptions:0], @"bytes": @(data.length) } };
    }
    if ([method isEqualToString:@"file_write"]) {
        NSString *path = JBP1lotString(params, @"path");
        NSString *value = JBP1lotString(params, @"data");
        NSString *encoding = [JBP1lotString(params, @"encoding") lowercaseString];
        NSData *data = [encoding isEqualToString:@"base64"] ? [[NSData alloc] initWithBase64EncodedString:value options:0] : [value dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) data = [NSData data];
        NSString *temporary = [path stringByAppendingFormat:@".jb-p1lot-%@", NSUUID.UUID.UUIDString];
        if (![data writeToFile:temporary options:NSDataWritingFileProtectionNone error:nil] || rename(temporary.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
            unlink(temporary.fileSystemRepresentation);
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"file write failed") };
        }
        chmod(path.fileSystemRepresentation, JBP1lotMode(params));
        return @{ @"status": @"ok", @"payload": @{ @"path": path, @"bytes": @(data.length) } };
    }
    if ([method isEqualToString:@"file_list"]) {
        NSString *path = JBP1lotString(params, @"path");
        NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
        if (!entries) {
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"directory listing failed") };
        }
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:entries.count];
        for (NSString *entry in entries) {
            NSString *fullPath = [path stringByAppendingPathComponent:entry];
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil];
            NSString *fileType = attributes[NSFileType];
            NSNumber *fileSize = attributes[NSFileSize] ?: @0;
            [items addObject:@{ @"name": entry, @"path": fullPath, @"directory": @([fileType isEqualToString:NSFileTypeDirectory]), @"size": fileSize }];
        }
        return @{ @"status": @"ok", @"payload": @{ @"path": path, @"entries": items } };
    }
    if ([method isEqualToString:@"file_search"]) {
        NSString *root = JBP1lotString(params, @"root");
        NSString *pattern = JBP1lotString(params, @"pattern");
        NSInteger limit = [params[@"maxResults"] integerValue] ?: 100;
        NSString *command = [NSString stringWithFormat:@"find %@ -iname %@ -print | head -n %ld", JBP1lotQuote(root), JBP1lotQuote(pattern), (long)MIN(MAX(limit, 1), 10000)];
        return JBP1lotRunResult(command, 30000);
    }
    if ([method isEqualToString:@"file_transfer"]) {
        NSString *source = JBP1lotString(params, @"source");
        NSString *destination = JBP1lotString(params, @"destination");
        if (![[NSFileManager defaultManager] copyItemAtPath:source toPath:destination error:nil]) {
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"file transfer failed") };
        }
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:destination error:nil];
        return @{ @"status": @"ok", @"payload": @{ @"source": source, @"destination": destination, @"bytes": attributes[NSFileSize] ?: @0 } };
    }
    if ([method isEqualToString:@"process_manage"]) {
        return JBP1lotProcessRequest(params);
    }
    if ([method isEqualToString:@"package_manage"]) {
        return JBP1lotPackageRequest(params);
    }
    if ([method isEqualToString:@"app_manage"]) {
        NSString *action = [JBP1lotString(params, @"action") lowercaseString];
        if ([action isEqualToString:@"list"] || action.length == 0) {
            return JBP1lotRunResult(@"find /Applications /var/jb/Applications -maxdepth 2 -name '*.app' -type d -print 2>/dev/null", 30000);
        }
        if ([action isEqualToString:@"install"]) {
            return JBP1lotRunResult([NSString stringWithFormat:@"/var/jb/usr/bin/uicache -p %@", JBP1lotQuote(JBP1lotString(params, @"path"))], 120000);
        }
        if ([action isEqualToString:@"uninstall"]) {
            NSString *bundleID = JBP1lotString(params, @"bundleId");
            NSString *path = JBP1lotString(params, @"path");
            if (path.length == 0 && bundleID.length > 0) {
                path = [NSString stringWithFormat:@"/var/jb/Applications/%@.app", bundleID];
            }
            return JBP1lotRunResult([NSString stringWithFormat:@"/var/jb/usr/bin/uicache -u %@", JBP1lotQuote(path)], 120000);
        }
        if ([action isEqualToString:@"launch"]) {
            return JBP1lotRunResult([NSString stringWithFormat:@"/var/jb/usr/bin/uiopen --bundleid %@", JBP1lotQuote(JBP1lotString(params, @"bundleId"))], 30000);
        }
        return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"unknown app action") };
    }
    if ([method isEqualToString:@"log_query"]) {
        NSString *predicate = JBP1lotString(params, @"predicate");
        NSString *process = JBP1lotString(params, @"process");
        NSString *logPath = [[NSFileManager defaultManager] isExecutableFileAtPath:@"/var/jb/usr/bin/log"] ? @"/var/jb/usr/bin/log" : @"/usr/bin/log";
        if (![[NSFileManager defaultManager] isExecutableFileAtPath:logPath])
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"unified log tool is unavailable on this device") };
        NSString *command = [NSString stringWithFormat:@"%@ show --style compact --last 10m", logPath];
        if (predicate.length > 0) command = [command stringByAppendingFormat:@" --predicate %@", JBP1lotQuote(predicate)];
        if (process.length > 0) command = [command stringByAppendingFormat:@" --process %@", JBP1lotQuote(process)];
        NSInteger limit = [params[@"limit"] integerValue] ?: 2000;
        command = [command stringByAppendingFormat:@" | tail -n %ld", (long)MIN(MAX(limit, 1), 20000)];
        return JBP1lotRunResult(command, 60000);
    }
    if ([method isEqualToString:@"crash_manage"]) {
        NSString *action = [JBP1lotString(params, @"action") lowercaseString];
        NSString *path = JBP1lotString(params, @"path");
        if ([action isEqualToString:@"clear"]) {
            return JBP1lotRunResult([NSString stringWithFormat:@"rm -f %@", JBP1lotQuote(path)], 30000);
        }
        if (path.length > 0) {
            NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
            if (data) return @{ @"status": @"ok", @"payload": @{ @"data": [data base64EncodedStringWithOptions:0], @"path": path, @"mimeType": @"text/plain" } };
        }
        return JBP1lotRunResult(@"find /var/mobile/Library/Logs/CrashReporter -type f -maxdepth 1 -print 2>/dev/null", 30000);
    }
    if ([method isEqualToString:@"diagnostics_collect"]) {
        NSString *path = [NSString stringWithFormat:@"/var/mobile/Media/jb-p1lot/sysdiagnose-%@.tar.gz", NSUUID.UUID.UUIDString];
        NSDictionary *result = JBP1lotRunResult([NSString stringWithFormat:@"/usr/bin/sysdiagnose -f %@", JBP1lotQuote(path)], [params[@"durationMs"] integerValue] ?: 180000);
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        if (data) return @{ @"status": @"ok", @"payload": @{ @"artifact": path, @"data": [data base64EncodedStringWithOptions:0], @"mimeType": @"application/gzip" } };
        return result;
    }
    if ([method isEqualToString:@"metrics_stream"]) {
        return JBP1lotRunResult(@"/var/jb/usr/bin/ltop -l 1 -s 0 -n 0; /usr/bin/vm_stat; /sbin/ifconfig", [params[@"durationMs"] integerValue] ?: 30000);
    }
    if ([method isEqualToString:@"network_capture"]) {
        NSString *path = [NSString stringWithFormat:@"/var/mobile/Media/jb-p1lot/capture-%@.pcap", NSUUID.UUID.UUIDString];
        NSString *interface = JBP1lotString(params, @"interface");
        NSString *filter = JBP1lotString(params, @"filter");
        NSInteger snaplen = [params[@"snaplen"] integerValue] ?: 256;
        NSInteger duration = [params[@"durationMs"] integerValue] ?: 10000;
        NSString *command = [NSString stringWithFormat:@"mkdir -p /var/mobile/Media/jb-p1lot; /var/jb/usr/bin/tcpdump -i %@ -s %ld -w %@ %@ -G %ld -W 1", JBP1lotQuote(interface.length ? interface : @"any"), (long)MIN(MAX(snaplen, 64), 65535), JBP1lotQuote(path), filter.length ? JBP1lotQuote(filter) : @"", (long)MAX(duration / 1000, 1)];
        NSDictionary *run = JBP1lotRunResult(command, duration + 15000);
        NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        if (data) return @{ @"status": @"ok", @"payload": @{ @"path": path, @"data": [data base64EncodedStringWithOptions:0], @"mimeType": @"application/vnd.tcpdump.pcap" } };
        return run;
    }
    if ([method isEqualToString:@"port_forward"]) {
        NSString *session = [NSString stringWithFormat:@"forward-%@", NSUUID.UUID.UUIDString];
        return @{ @"status": @"ok", @"payload": @{ @"sessionId": session, @"localPort": params[@"localPort"] ?: @0, @"remotePort": params[@"remotePort"] ?: @0 } };
    }
    if ([method isEqualToString:@"debug_session"] || [method isEqualToString:@"frida_session"]) {
        NSString *session = [NSString stringWithFormat:@"%@-%@", [method hasPrefix:@"debug"] ? @"lldb" : @"frida", NSUUID.UUID.UUIDString];
        return @{ @"status": @"ok", @"payload": @{ @"sessionId": session, @"backend": [method hasPrefix:@"debug"] ? @"debugserver" : @"frida" } };
    }
    if ([method isEqualToString:@"tweak_deploy"] || [method isEqualToString:@"tweak_cycle"]) {
        NSString *path = JBP1lotString(params, @"path");
        NSDictionary *install = JBP1lotRunResult([NSString stringWithFormat:@"/var/jb/usr/bin/dpkg -i %@", JBP1lotQuote(path)], 120000);
        NSString *reload = [JBP1lotString(params, @"reload") lowercaseString];
        if ([reload isEqualToString:@"sbreload"] || [reload isEqualToString:@"springboard"]) {
            int reloadStatus = 0;
            JBP1lotRunShell(@"/var/jb/usr/bin/sbreload", @"", 30000, &reloadStatus);
        }
        return install;
    }
    if ([method isEqualToString:@"device_action"]) {
        NSString *action = [JBP1lotString(params, @"action") lowercaseString];
        NSString *normalizedAction = [action stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
        if ([@[@"screen_off", @"display_off", @"dark_on", @"screen_on", @"display_on", @"dark_off"] containsObject:normalizedAction]) {
            NSMutableDictionary *agentRequest = [request mutableCopy];
            NSMutableDictionary *agentParams = [params mutableCopy];
            agentRequest[@"method"] = @"ui_action";
            agentParams[@"action"] = normalizedAction;
            agentRequest[@"payload"] = agentParams;
            NSDictionary *response = nil;
            if (JBP1lotForwardToAgent(agentRequest, &response))
                return response;
        }
        if ([action isEqualToString:@"reboot"] || [action isEqualToString:@"userspace_reboot"] || [action isEqualToString:@"respring"] || [action isEqualToString:@"sbreload"]) {
            char *arguments[] = {"launchctl", "reboot", "userspace", NULL};
            pid_t pid = 0;
            int result = posix_spawn(&pid, "/var/jb/usr/bin/launchctl", NULL, NULL, arguments, environ);
            if (result != 0) {
                return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", @"userspace reboot failed") };
            }
            return @{ @"status": @"ok", @"payload": @{ @"action": @"userspace_reboot", @"pid": @(pid) } };
        }
        if ([action isEqualToString:@"full_reboot"] || [action isEqualToString:@"hardware_reboot"] || [action isEqualToString:@"reboot_full"]) {
            return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"invalid_frame", @"hardware reboot is unavailable; use userspace_reboot") };
        }
    }
    if ([method hasPrefix:@"screen."] || [method hasPrefix:@"ui_"] || [method hasPrefix:@"ui."]) {
        NSDictionary *response = nil;
        if (JBP1lotForwardToAgent(request, &response)) {
            return response;
        }
    }
    return @{ @"status": @"error", @"error": JBP1lotErrorPayload(@"backend_error", [NSString stringWithFormat:@"unsupported method %@", method]) };
}

BOOL JBP1lotForwardToAgent(NSDictionary *request, NSDictionary **response) {
    int socketFD = socket(AF_UNIX, SOCK_STREAM, 0);
    if (socketFD < 0) {
        return NO;
    }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, JBP1lotAgentSocketPath.fileSystemRepresentation, sizeof(address.sun_path));
    if (connect(socketFD, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(socketFD);
        return NO;
    }
    NSData *frame = JBP1lotFrameForDictionary(request);
    if (!frame) {
        close(socketFD);
        return NO;
    }
    size_t written = 0;
    while (written < frame.length) {
        ssize_t count = write(socketFD, frame.bytes + written, frame.length - written);
        if (count <= 0) {
            close(socketFD);
            return NO;
        }
        written += (size_t)count;
    }
    uint32_t length = 0;
    size_t readLength = 0;
    while (readLength < sizeof(length)) {
        ssize_t count = read(socketFD, ((uint8_t *)&length) + readLength, sizeof(length) - readLength);
        if (count <= 0) {
            close(socketFD);
            return NO;
        }
        readLength += (size_t)count;
    }
    if (readLength != sizeof(length)) {
        close(socketFD);
        return NO;
    }
    length = CFSwapInt32BigToHost(length);
    if (length == 0 || length > (16u << 20)) {
        close(socketFD);
        return NO;
    }
    NSMutableData *body = [NSMutableData dataWithLength:length];
    size_t bodyRead = 0;
    while (bodyRead < length) {
        ssize_t count = read(socketFD, (uint8_t *)body.mutableBytes + bodyRead, length - bodyRead);
        if (count <= 0) {
            close(socketFD);
            return NO;
        }
        bodyRead += (size_t)count;
    }
    close(socketFD);
    uint32_t prefix = CFSwapInt32HostToBig(length);
    NSMutableData *full = [NSMutableData dataWithBytes:&prefix length:sizeof(prefix)];
    [full appendData:body];
    NSDictionary *parsed = JBP1lotDictionaryFromFrame(full);
    if (!parsed) {
        return NO;
    }
    if (response) {
        *response = parsed;
    }
    return YES;
}

static void JBP1lotReceive(nw_connection_t connection, NSMutableData *buffer) {
    nw_connection_receive(connection, 4, 16u << 20, ^(dispatch_data_t content, nw_content_context_t context, bool is_complete, nw_error_t error) {
        if (error) {
            nw_connection_cancel(connection);
            return;
        }
        if (content) {
            dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *bytes, size_t size) {
                [buffer appendBytes:bytes length:size];
                return true;
            });
        }
        while (buffer.length >= sizeof(uint32_t)) {
            uint32_t length = 0;
            [buffer getBytes:&length length:sizeof(length)];
            length = CFSwapInt32BigToHost(length);
            if (length == 0 || length > (16u << 20)) {
                nw_connection_cancel(connection);
                return;
            }
            if (buffer.length < sizeof(uint32_t) + length) {
                break;
            }
            NSData *frame = [buffer subdataWithRange:NSMakeRange(0, sizeof(uint32_t) + length)];
            [buffer replaceBytesInRange:NSMakeRange(0, sizeof(uint32_t) + length) withBytes:NULL length:0];
            NSDictionary *request = JBP1lotDictionaryFromFrame(frame);
            if (!request) {
                nw_connection_cancel(connection);
                return;
            }
            NSDictionary *handled = JBP1lotHandleRequest(request);
            NSMutableDictionary *reply = [handled mutableCopy];
            reply[@"version"] = @1;
            reply[@"kind"] = [handled[@"status"] isEqualToString:@"error"] ? @"error" : @"response";
            reply[@"id"] = request[@"id"] ?: @0;
            if ([reply[@"kind"] isEqualToString:@"error"] && !reply[@"payload"] && reply[@"error"]) {
                reply[@"payload"] = reply[@"error"];
            }
            NSData *replyFrame = JBP1lotFrameForDictionary(reply);
            if (replyFrame) {
                NSData *retainedReply = replyFrame;
                dispatch_data_t data = dispatch_data_create(retainedReply.bytes, retainedReply.length, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    (void)retainedReply;
                });
                nw_connection_send(connection, data, NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT, true, ^(nw_error_t sendError) {
                    if (sendError) {
                        nw_connection_cancel(connection);
                    }
                });
            }
        }
        if (is_complete) {
            nw_connection_cancel(connection);
        } else {
            JBP1lotReceive(connection, buffer);
        }
    });
}

void JBP1lotStartService(void) {
    nw_parameters_t parameters = JBP1lotCreateTLSParameters();
    nw_listener_t listener = nw_listener_create_with_port("5912", parameters);
    nw_listener_set_queue(listener, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    nw_listener_set_advertise_descriptor(listener, nw_advertise_descriptor_create_bonjour_service("jb-p1lot", "_jb-p1lot._tcp", "local."));
    nw_listener_set_new_connection_handler(listener, ^(nw_connection_t connection) {
        nw_connection_set_queue(connection, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t error) {
            if (state == nw_connection_state_ready) {
                JBP1lotReceive(connection, [NSMutableData data]);
            }
            if (state == nw_connection_state_failed || state == nw_connection_state_cancelled) {
                nw_connection_cancel(connection);
            }
        });
        nw_connection_start(connection);
    });
    nw_listener_set_state_changed_handler(listener, ^(nw_listener_state_t state, nw_error_t error) {
        if (state == nw_listener_state_failed) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                JBP1lotStartService();
            });
        }
    });
    nw_listener_start(listener);
}
