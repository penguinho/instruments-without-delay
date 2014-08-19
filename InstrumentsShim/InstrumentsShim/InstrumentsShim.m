//
// Copyright 2013 Facebook
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//


#import <objc/runtime.h>
#import <objc/message.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <spawn.h>
#import <sys/types.h>
#import <sys/sysctl.h>

#import "../../Common/dyld-interposing.h"

static NSDictionary *LaunchTaskAndCaptureOutput(NSTask *task) {
  NSPipe *stdoutPipe = [NSPipe pipe];
  NSFileHandle *stdoutHandle = [stdoutPipe fileHandleForReading];

  NSPipe *stderrPipe = [NSPipe pipe];
  NSFileHandle *stderrHandle = [stderrPipe fileHandleForReading];

  __block NSString *standardOutput = nil;
  __block NSString *standardError = nil;

  void (^completionBlock)(NSNotification *) = ^(NSNotification *notification){
    NSData *data = notification.userInfo[NSFileHandleNotificationDataItem];
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];

    if (notification.object == stdoutHandle) {
      standardOutput = str;
    } else if (notification.object == stderrHandle) {
      standardError = str;
    }

    CFRunLoopStop(CFRunLoopGetCurrent());
  };

  id stdoutObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSFileHandleReadToEndOfFileCompletionNotification
                                                                        object:stdoutHandle
                                                                         queue:nil
                                                                    usingBlock:completionBlock];
  id stderrObserver = [[NSNotificationCenter defaultCenter] addObserverForName:NSFileHandleReadToEndOfFileCompletionNotification
                                                                        object:stderrHandle
                                                                         queue:nil
                                                                    usingBlock:completionBlock];
  [stdoutHandle readToEndOfFileInBackgroundAndNotify];
  [stderrHandle readToEndOfFileInBackgroundAndNotify];
  [task setStandardOutput:stdoutPipe];
  [task setStandardError:stderrPipe];

  [task launch];
  [task waitUntilExit];

  while (standardOutput == nil || standardError == nil) {
    CFRunLoopRun();
  }

  [[NSNotificationCenter defaultCenter] removeObserver:stdoutObserver];
  [[NSNotificationCenter defaultCenter] removeObserver:stderrObserver];

  return @{@"stdout" : standardOutput, @"stderr" : standardError};
}

static void SwizzleSelectorForFunction(Class cls, SEL sel, IMP newImp)
{
  Method originalMethod = class_getInstanceMethod(cls, sel);
  const char *typeEncoding = method_getTypeEncoding(originalMethod);

  NSString *newSelectorName = [NSString stringWithFormat:@"__%s_%s", class_getName(cls), sel_getName(sel)];
  SEL newSelector = sel_registerName([newSelectorName UTF8String]);
  class_addMethod(cls, newSelector, newImp, typeEncoding);

  Method newMethod = class_getInstanceMethod(cls, newSelector);
  method_exchangeImplementations(originalMethod, newMethod);
}

static id UIAHost_performTaskWithpath(id self, SEL cmd, id path, id arguments, id timeout)
{
  NSLog(@"UIAutomationService: %@", NSClassFromString(@"UIAutomationService"));
  NSLog(@"Stack: %@", [NSThread callStackSymbols]);
  NSLog(@"Current time: %lf", [[NSDate date] timeIntervalSince1970]);
  return @{@"kUIAServiceTaskExitCodeKey": @(0),
           @"kUIAServiceTaskStandardOutputKey": [@"Hello!11" stringByAppendingString:@" "],
           @"kUIAServiceTaskStandardErrorKey": @"",
           };

  NSTask *task = [[[NSTask alloc] init] autorelease];
  [task setLaunchPath:path];
  [task setArguments:arguments];

  NSMutableDictionary *environment = [[[NSMutableDictionary alloc] initWithDictionary:[[NSProcessInfo processInfo] environment]] autorelease];
  NSString *envpath = [[NSString stringWithContentsOfFile:@"/etc/paths"
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL]
                       stringByReplacingOccurrencesOfString:@"\n"
                       withString:@":"];
  [environment setObject:envpath
                  forKey:@"PATH"];
  [environment removeObjectForKey:@"DYLD_ROOT_PATH"];
  [task setEnvironment:environment];

  NSDictionary *output = LaunchTaskAndCaptureOutput(task);

  id result = @{@"kUIAServiceTaskExitCodeKey": @([task terminationStatus]),
                @"kUIAServiceTaskStandardOutputKey": output[@"stdout"],
                @"kUIAServiceTaskStandardErrorKey": output[@"stderr"],
                };
  return result;
}

static BOOL UIAInstrument__startAgentForAppWithPID(id self, SEL cmd, id app, id pid) {
  NSLog(@"App: %@ pid: %@", app, pid);
  return NO;
}

static void *_dlopen(const char *path, int mode)
{
  void *result = dlopen(path, mode);

  if (path && strstr(path, "AutomationInstrument")) {
    if (NSClassFromString(@"UIAInstrument")) {
      SwizzleSelectorForFunction(NSClassFromString(@"UIAInstrument"),
                                 @selector(performTaskOnHost:withArguments:timeout:),
                                 (IMP)UIAHost_performTaskWithpath);
    }
  }

  return result;
}

DYLD_INTERPOSE(_dlopen, dlopen);

static int _posix_spawn(pid_t *pid,
                        const char *path,
                        const posix_spawn_file_actions_t *file_actions,
                        const posix_spawnattr_t *attrp,
                        char *const argv[],
                        char *const envp[])
{
  fprintf(stderr, "%s\n", path);
  return posix_spawn(pid, path, file_actions, attrp, argv, envp);
}

DYLD_INTERPOSE(_posix_spawn, posix_spawn);

static int _sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
  return sysctl(name, namelen, oldp, oldlenp, newp, newlen);
}

DYLD_INTERPOSE(_sysctl, sysctl);

__attribute__((constructor)) static void EntryPoint()
{
  unsetenv("DYLD_INSERT_LIBRARIES");
}