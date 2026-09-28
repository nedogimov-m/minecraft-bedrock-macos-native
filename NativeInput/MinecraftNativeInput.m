#import <Foundation/Foundation.h>
#import <GameController/GCKeyCodes.h>
#import <GameController/GCKeyboard.h>
#import <GameController/GCKeyboardInput.h>
#import <GameController/GCMouse.h>
#import <GameController/GCMouseInput.h>
#import <GameController/GCControllerButtonInput.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>
#include <unistd.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdatomic.h>

static int (*associateMouseCursor)(bool);
static int (*hideCursor)(uint32_t);
static int (*showCursor)(uint32_t);
static uint32_t (*mainDisplayID)(void);
static CGRect (*displayBounds)(uint32_t);
static int (*warpCursor)(CGPoint);

static BOOL loadCursorFunctions(void) {
    if (associateMouseCursor && hideCursor && showCursor && mainDisplayID && displayBounds && warpCursor) return YES;
    void *handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL);
    if (!handle) return NO;
    associateMouseCursor = dlsym(handle, "CGAssociateMouseAndMouseCursorPosition");
    hideCursor = dlsym(handle, "CGDisplayHideCursor");
    showCursor = dlsym(handle, "CGDisplayShowCursor");
    mainDisplayID = dlsym(handle, "CGMainDisplayID");
    displayBounds = dlsym(handle, "CGDisplayBounds");
    warpCursor = dlsym(handle, "CGWarpMouseCursorPosition");
    return associateMouseCursor && hideCursor && showCursor && mainDisplayID && displayBounds && warpCursor;
}

// Loaded by PlayTools' UserPluginLoader in the Minecraft app only.
// The game sees connected devices before its input handler is ready, so it
// needs one more connection notification after startup. Native GameController
// events are then passed through only while the Minecraft window has focus.

static void (*setKeyboardHandlerOriginal)(id, SEL, GCKeyboardValueChangedHandler);
static void (*setMouseMoveHandlerOriginal)(id, SEL, GCMouseMoved);
static void (*setButtonPressedHandlerOriginal)(id, SEL, GCControllerButtonValueChangedHandler);
static void (*setButtonValueHandlerOriginal)(id, SEL, GCControllerButtonValueChangedHandler);
static void (*pointerLockUpdateOriginal)(id, SEL);
static void (*terminateApplicationOriginal)(id, SEL, id);
static void releaseManualPointerCapture(void);
static struct sigaction previousAbortAction;
static atomic_bool shuttingDown = ATOMIC_VAR_INIT(false);
static BOOL abortGuardInstalled = NO;

static void abortGuard(int signalNumber, siginfo_t *info, void *context) {
    if (atomic_load_explicit(&shuttingDown, memory_order_relaxed)) _exit(128 + signalNumber);
    if (previousAbortAction.sa_flags & SA_SIGINFO) {
        previousAbortAction.sa_sigaction(signalNumber, info, context);
    } else if (previousAbortAction.sa_handler == SIG_DFL) {
        sigaction(signalNumber, &previousAbortAction, NULL);
        raise(signalNumber);
    } else if (previousAbortAction.sa_handler != SIG_IGN) {
        previousAbortAction.sa_handler(signalNumber);
    }
}

static void installAbortGuard(void) {
    if (abortGuardInstalled) return;
    struct sigaction action = {0};
    action.sa_sigaction = abortGuard;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_SIGINFO;
    if (sigaction(SIGABRT, &action, &previousAbortAction) == 0) {
        abortGuardInstalled = YES;
        NSLog(@"MinecraftNativeInput: protected shutdown from recursive SIGABRT");
    }
}

static void terminateApplication(id receiver, SEL selector, id sender) {
    atomic_store_explicit(&shuttingDown, true, memory_order_relaxed);
    installAbortGuard();
    releaseManualPointerCapture();
    NSLog(@"MinecraftNativeInput: termination requested");
    terminateApplicationOriginal(receiver, selector, sender);
}

static NSLock *stateLock;
static NSMutableDictionary<NSNumber *, NSDictionary *> *heldKeys;
static NSMutableDictionary<NSValue *, NSDictionary *> *heldMouseButtons;
static BOOL lastFocusState = NO;
static id keyRepeatMonitor;
static BOOL hasFocusedWindow(void);
static pid_t frontmostApplicationPID(void);
static BOOL gameRequestsPointerLock(void);
static void releaseHeldInputs(void);
static BOOL manualPointerCapture = NO;
static BOOL pointerInsideWindow(id keyWindow);
static BOOL captureCheckPending = NO;


static void releaseManualPointerCapture(void) {
    if (!manualPointerCapture) return;
    associateMouseCursor(true);
    showCursor(mainDisplayID());
    manualPointerCapture = NO;
    NSLog(@"MinecraftNativeInput: released manual pointer capture");
}

static void capturePointerForGameplay(void) {
    if (manualPointerCapture) return;
    if (!loadCursorFunctions()) return;
    Class appClass = NSClassFromString(@"NSApplication");
    id app = ((id (*)(id, SEL))objc_msgSend)(appClass, sel_registerName("sharedApplication"));
    id window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("keyWindow"));
    if (!window || !pointerInsideWindow(window)) return;
    CGRect frame = ((CGRect (*)(id, SEL))objc_msgSend)(window, sel_registerName("frame"));
    CGRect display = displayBounds(mainDisplayID());
    CGPoint center = CGPointMake(frame.origin.x + frame.size.width / 2,
                                 display.size.height - (frame.origin.y + frame.size.height / 2));
    if (warpCursor(center) != 0) return;
    if (associateMouseCursor(false) != 0) return;
    hideCursor(mainDisplayID());
    manualPointerCapture = YES;
    NSLog(@"MinecraftNativeInput: manually captured cursor at (%.1f, %.1f)", center.x, center.y);
}

static id gameViewController(void) {
    Class appClass = NSClassFromString(@"UIApplication");
    if (!appClass) return nil;
    id app = ((id (*)(id, SEL))objc_msgSend)(appClass, sel_registerName("sharedApplication"));
    NSArray *windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
    for (id window in windows) {
        if (!((BOOL (*)(id, SEL))objc_msgSend)(window, sel_registerName("isKeyWindow"))) continue;
        return ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("rootViewController"));
    }
    return nil;
}

static BOOL pointerActuallyLocked(void) {
    Class appClass = NSClassFromString(@"UIApplication");
    if (!appClass) return NO;
    id app = ((id (*)(id, SEL))objc_msgSend)(appClass, sel_registerName("sharedApplication"));
    NSArray *windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
    for (id window in windows) {
        if (!((BOOL (*)(id, SEL))objc_msgSend)(window, sel_registerName("isKeyWindow"))) continue;
        id scene = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("windowScene"));
        if (!scene) return NO;
        id state = ((id (*)(id, SEL))objc_msgSend)(scene, sel_registerName("pointerLockState"));
        return state && ((BOOL (*)(id, SEL))objc_msgSend)(state, sel_registerName("isLocked"));
    }
    return NO;
}

static void checkPointerLockAfterGameUpdate(void) {
    if (frontmostApplicationPID() != getpid()) {
        releaseManualPointerCapture();
        return;
    }
    if (!gameRequestsPointerLock() || pointerActuallyLocked()) {
        releaseManualPointerCapture();
        return;
    }
    if (hasFocusedWindow()) capturePointerForGameplay();
}

static void pointerLockUpdate(id receiver, SEL selector) {
    pointerLockUpdateOriginal(receiver, selector);
    if (captureCheckPending || frontmostApplicationPID() != getpid()) return;
    captureCheckPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        captureCheckPending = NO;
        checkPointerLockAfterGameUpdate();
    });
}
static GCKeyboardValueChangedHandler gameKeyboardHandler;

static CGPoint pointerLocationInWindow(id keyWindow) {
    return ((CGPoint (*)(id, SEL))objc_msgSend)(keyWindow, sel_registerName("mouseLocationOutsideOfEventStream"));
}

static CGRect contentBoundsOfWindow(id keyWindow) {
    id contentView = ((id (*)(id, SEL))objc_msgSend)(keyWindow, sel_registerName("contentView"));
    if (!contentView) return CGRectZero;
    return ((CGRect (*)(id, SEL))objc_msgSend)(contentView, sel_registerName("bounds"));
}

static BOOL pointerInsideWindow(id keyWindow) {
    CGRect bounds = contentBoundsOfWindow(keyWindow);
    if (CGRectIsEmpty(bounds)) return NO;
    return CGRectContainsPoint(bounds, pointerLocationInWindow(keyWindow));
}

static BOOL gameRequestsPointerLock(void) {
    id controller = gameViewController();
    return controller && [controller respondsToSelector:sel_registerName("prefersPointerLocked")]
        && ((BOOL (*)(id, SEL))objc_msgSend)(controller, sel_registerName("prefersPointerLocked"));
}

static void pauseWorldOnLeave(void) {
    if (frontmostApplicationPID() != getpid() || hasFocusedWindow() || !gameRequestsPointerLock()) return;
    GCKeyboard *keyboard = GCKeyboard.coalescedKeyboard;
    GCKeyboardInput *input = keyboard.keyboardInput;
    GCDeviceButtonInput *escapeKey = [input buttonForKeyCode:GCKeyCodeEscape];
    GCKeyboardValueChangedHandler handler;
    [stateLock lock];
    handler = gameKeyboardHandler;
    [stateLock unlock];
    if (!input || !escapeKey || !handler) return;
    handler(input, escapeKey, GCKeyCodeEscape, YES);
    handler(input, escapeKey, GCKeyCodeEscape, NO);
    NSLog(@"MinecraftNativeInput: requested pause when pointer left gameplay window");
}

static void suppressDuplicateMacKeyEvents(void) {
    Class eventClass = NSClassFromString(@"NSEvent");
    if (!eventClass) return;
    SEL monitorSelector = sel_registerName("addLocalMonitorForEventsMatchingMask:handler:");
    if (![eventClass respondsToSelector:monitorSelector]) return;
    keyRepeatMonitor = ((id (*)(id, SEL, unsigned long long, id))objc_msgSend)(eventClass, monitorSelector, 1ULL << 10, ^id(id event) {
        // GameController already delivers the physical key. AppKit has no
        // gameplay responder for the duplicate keyDown and plays a system beep.
        unsigned long long modifiers = ((unsigned long long (*)(id, SEL))objc_msgSend)(event, sel_registerName("modifierFlags"));
        if (modifiers & (1ULL << 20)) return event; // preserve Command shortcuts
        // In menus and text fields Minecraft releases pointer lock. Preserve
        // regular AppKit key events there so chat and search remain usable.
        if (!gameRequestsPointerLock() && hasFocusedWindow()) return event;
        if (frontmostApplicationPID() == getpid() && GCKeyboard.coalescedKeyboard.keyboardInput.keyChangedHandler) {
            return nil;
        }
        return event;
    });
    NSLog(@"MinecraftNativeInput: repeated AppKit key suppression installed=%d", keyRepeatMonitor != nil);
}

static pid_t frontmostApplicationPID(void) {
    Class workspaceClass = NSClassFromString(@"NSWorkspace");
    if (!workspaceClass) return -1;
    id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, sel_registerName("sharedWorkspace"));
    id application = ((id (*)(id, SEL))objc_msgSend)(workspace, sel_registerName("frontmostApplication"));
    if (!application) return -1;
    return ((pid_t (*)(id, SEL))objc_msgSend)(application, sel_registerName("processIdentifier"));
}

static BOOL hasFocusedWindow(void) {
    Class appClass = NSClassFromString(@"NSApplication");
    if (!appClass) return NO;
    id app = ((id (*)(id, SEL))objc_msgSend)(appClass, sel_registerName("sharedApplication"));
    if (!app) return NO;
    BOOL active = ((BOOL (*)(id, SEL))objc_msgSend)(app, sel_registerName("isActive"));
    id keyWindow = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("keyWindow"));
    return active && keyWindow != nil && frontmostApplicationPID() == getpid() && pointerInsideWindow(keyWindow);
}

static void logFocusChange(BOOL focused) {
    [stateLock lock];
    BOOL changed = focused != lastFocusState;
    BOOL wasFocused = lastFocusState;
    lastFocusState = focused;
    [stateLock unlock];
    if (wasFocused && !focused) dispatch_async(dispatch_get_main_queue(), ^{
        releaseHeldInputs();
        pauseWorldOnLeave();
    });
}

static BOOL isMouseButton(id button) {
    for (GCMouse *mouse in GCMouse.mice) {
        GCMouseInput *input = mouse.mouseInput;
        if (button == input.leftButton || button == input.rightButton || button == input.middleButton) return YES;
        for (GCControllerButtonInput *extra in input.auxiliaryButtons) {
            if (button == extra) return YES;
        }
    }
    return NO;
}

static void releaseHeldInputs(void) {
    NSArray<NSDictionary *> *keys;
    NSArray<NSDictionary *> *buttons;
    [stateLock lock];
    keys = heldKeys.allValues;
    buttons = heldMouseButtons.allValues;
    [heldKeys removeAllObjects];
    [heldMouseButtons removeAllObjects];
    [stateLock unlock];

    for (NSDictionary *record in keys) {
        GCKeyboardValueChangedHandler handler = record[@"handler"];
        handler(record[@"input"], record[@"key"], (GCKeyCode)[record[@"code"] integerValue], NO);
    }
    for (NSDictionary *record in buttons) {
        GCControllerButtonValueChangedHandler handler = record[@"handler"];
        handler(record[@"button"], 0.0f, NO);
    }
    if (keys.count || buttons.count) NSLog(@"MinecraftNativeInput: released %lu keys and %lu mouse buttons on focus loss", (unsigned long)keys.count, (unsigned long)buttons.count);
    logFocusChange(NO);
}

static void keyboardSetter(id receiver, SEL selector, GCKeyboardValueChangedHandler handler) {
    if (!handler) {
        releaseHeldInputs();
        [stateLock lock];
        gameKeyboardHandler = nil;
        [stateLock unlock];
        setKeyboardHandlerOriginal(receiver, selector, nil);
        return;
    }
    GCKeyboardValueChangedHandler gameHandler = [handler copy];
    [stateLock lock];
    gameKeyboardHandler = gameHandler;
    [stateLock unlock];
    setKeyboardHandlerOriginal(receiver, selector, ^(GCKeyboardInput *input, GCDeviceButtonInput *key, GCKeyCode code, BOOL pressed) {
        BOOL focused = hasFocusedWindow();
        logFocusChange(focused);
        NSNumber *identity = @(code);
        if (pressed) {
            if (!focused) {
                    return;
            }
            [stateLock lock];
            heldKeys[identity] = @{@"handler": gameHandler, @"input": input, @"key": key, @"code": identity};
            [stateLock unlock];
            gameHandler(input, key, code, YES);
        } else {
            [stateLock lock];
            NSDictionary *record = heldKeys[identity];
            [heldKeys removeObjectForKey:identity];
            [stateLock unlock];
            if (record) gameHandler(input, key, code, NO);
        }
    });
}

static void mouseMoveSetter(id receiver, SEL selector, GCMouseMoved handler) {
    if (!handler) {
        setMouseMoveHandlerOriginal(receiver, selector, nil);
        return;
    }
    GCMouseMoved gameHandler = [handler copy];
    setMouseMoveHandlerOriginal(receiver, selector, ^(GCMouseInput *input, float dx, float dy) {
        BOOL focused = hasFocusedWindow();
        logFocusChange(focused);
        if (focused) {
            gameHandler(input, dx, dy);
        } else {
        }
    });
}

static GCControllerButtonValueChangedHandler focusedButtonHandler(GCControllerButtonValueChangedHandler gameHandler) {
    GCControllerButtonValueChangedHandler original = [gameHandler copy];
    return ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        BOOL focused = hasFocusedWindow();
        logFocusChange(focused);
        NSValue *identity = [NSValue valueWithNonretainedObject:button];
        if (pressed) {
            if (!focused) return;
            [stateLock lock];
            heldMouseButtons[identity] = @{@"handler": original, @"button": button};
            [stateLock unlock];
            original(button, value, YES);
        } else {
            [stateLock lock];
            NSDictionary *record = heldMouseButtons[identity];
            [heldMouseButtons removeObjectForKey:identity];
            [stateLock unlock];
            if (record) original(button, value, NO);
        }
    };
}

static void buttonPressedSetter(id receiver, SEL selector, GCControllerButtonValueChangedHandler handler) {
    setButtonPressedHandlerOriginal(receiver, selector, handler && isMouseButton(receiver) ? focusedButtonHandler(handler) : handler);
}

static void buttonValueSetter(id receiver, SEL selector, GCControllerButtonValueChangedHandler handler) {
    setButtonValueHandlerOriginal(receiver, selector, handler && isMouseButton(receiver) ? focusedButtonHandler(handler) : handler);
}

static void installSwizzle(Class cls, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *original = method_setImplementation(method, replacement);
}

static void announceConnectedDevices(void) {
    GCKeyboard *keyboard = GCKeyboard.coalescedKeyboard;
    GCMouse *mouse = GCMouse.current ?: GCMouse.mice.firstObject;
    if (keyboard) [NSNotificationCenter.defaultCenter postNotificationName:GCKeyboardDidConnectNotification object:keyboard];
    if (mouse) {
        [NSNotificationCenter.defaultCenter postNotificationName:GCMouseDidConnectNotification object:mouse];
        [NSNotificationCenter.defaultCenter postNotificationName:GCMouseDidBecomeCurrentNotification object:mouse];
    }
}

__attribute__((constructor)) static void startNativeInput(void) {
    stateLock = [NSLock new];
    heldKeys = [NSMutableDictionary new];
    heldMouseButtons = [NSMutableDictionary new];
    installSwizzle(GCKeyboardInput.class, @selector(setKeyChangedHandler:), (IMP)keyboardSetter, (IMP *)&setKeyboardHandlerOriginal);
    installSwizzle(GCMouseInput.class, @selector(setMouseMovedHandler:), (IMP)mouseMoveSetter, (IMP *)&setMouseMoveHandlerOriginal);
    installSwizzle(GCControllerButtonInput.class, @selector(setPressedChangedHandler:), (IMP)buttonPressedSetter, (IMP *)&setButtonPressedHandlerOriginal);
    installSwizzle(GCControllerButtonInput.class, @selector(setValueChangedHandler:), (IMP)buttonValueSetter, (IMP *)&setButtonValueHandlerOriginal);
    Class viewControllerClass = NSClassFromString(@"UIViewController");
    if (viewControllerClass) {
        installSwizzle(viewControllerClass, sel_registerName("setNeedsUpdateOfPrefersPointerLocked"), (IMP)pointerLockUpdate, (IMP *)&pointerLockUpdateOriginal);
    }
    Class macApplicationClass = NSClassFromString(@"NSApplication");
    if (macApplicationClass) {
        id macApplication = ((id (*)(id, SEL))objc_msgSend)(macApplicationClass, sel_registerName("sharedApplication"));
        installSwizzle([macApplication class], sel_registerName("terminate:"), (IMP)terminateApplication, (IMP *)&terminateApplicationOriginal);
    }

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:@"NSApplicationWillTerminateNotification" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
        atomic_store_explicit(&shuttingDown, true, memory_order_relaxed);
        installAbortGuard();
    }];
    for (NSString *name in @[@"NSApplicationDidResignActiveNotification", @"NSWindowDidResignKeyNotification", @"UIApplicationWillResignActiveNotification"]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
            releaseHeldInputs();
            releaseManualPointerCapture();
        }];
    }
    NSLog(@"MinecraftNativeInput: loaded");
    suppressDuplicateMacKeyEvents();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        announceConnectedDevices();
        NSLog(@"MinecraftNativeInput: announced connected keyboard and mouse");
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 11 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        GCKeyboard *keyboard = GCKeyboard.coalescedKeyboard;
        GCMouse *mouse = GCMouse.current ?: GCMouse.mice.firstObject;
        if (!keyboard.keyboardInput.keyChangedHandler || !mouse.mouseInput.mouseMovedHandler) {
            announceConnectedDevices();
            NSLog(@"MinecraftNativeInput: retried connected keyboard and mouse");
        }
    });

}
