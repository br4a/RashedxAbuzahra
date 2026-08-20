#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>

// ==================================================
// State
// ==================================================
static volatile BOOL replayShouldStop = NO;
static NSInteger replayIndex = 0;
static NSInteger burstCount  = 0;
static NSInteger skipCount   = 0;
static NSTimer  *replayTimer = nil;
static NSInteger selectedSlot = 1;
static NSMutableArray *gOverlays = nil;

static const NSInteger kTimes = 2000;
static const NSInteger kSpeed = 1;
static const NSInteger kBurst = 440;
static const NSInteger kSkip  = 50;

static void stopReplay(void);
static void doReplay(void);

// ==================================================
// Colors / font helpers
// ==================================================
static UIColor *cBG()     { return [UIColor colorWithRed:0.03 green:0.01 blue:0.07 alpha:0.97]; }
static UIColor *cBorder() { return [UIColor colorWithRed:0.53 green:0.25 blue:1.00 alpha:1]; }
static UIColor *cDim()    { return [UIColor colorWithRed:0.45 green:0.35 blue:0.65 alpha:1]; }
static UIColor *cText()   { return [UIColor colorWithRed:0.82 green:0.74 blue:1.00 alpha:1]; }
static UIColor *cGreen()  { return [UIColor colorWithRed:0.05 green:0.78 blue:0.45 alpha:1]; }
static UIFont  *mono(CGFloat s, BOOL bold) {
    return bold ? [UIFont monospacedSystemFontOfSize:s weight:UIFontWeightBold]
                : [UIFont monospacedSystemFontOfSize:s weight:UIFontWeightRegular];
}
static void glow(CALayer *l, UIColor *c, CGFloat r) {
    l.shadowColor = c.CGColor; l.shadowOffset = CGSizeMake(0,0);
    l.shadowRadius = r; l.shadowOpacity = 0.75;
}

// ==================================================
// Key window helper
// ==================================================
static UIWindow *getKeyWindow() {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:[UIWindowScene class]])
            for (UIWindow *w in ((UIWindowScene *)sc).windows)
                if (w.isKeyWindow) return w;
    return UIApplication.sharedApplication.windows.firstObject;
}

// ==================================================
// Find all LTMikeElement views sorted by screen position
// ==================================================
static NSArray *findMikeElements() {
    NSMutableArray *allWins = [NSMutableArray new];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:[UIWindowScene class]])
            [allWins addObjectsFromArray:((UIWindowScene *)sc).windows];
    for (UIWindow *w in UIApplication.sharedApplication.windows)
        if (![allWins containsObject:w]) [allWins addObject:w];

    Class mikeClass = NSClassFromString(@"YallaLite.LTMikeElement")
                   ?: NSClassFromString(@"LTMikeElement")
                   ?: NSClassFromString(@"YallaLite_LTMikeElement");
    NSMutableArray *result = [NSMutableArray new];
    NSMutableArray *queue  = [NSMutableArray arrayWithArray:allWins];
    while (queue.count > 0) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (mikeClass && [v isKindOfClass:mikeClass])
            [result addObject:v];
        [queue addObjectsFromArray:v.subviews];
    }
    UIWindow *ref = getKeyWindow();
    [result sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        UIView *base = ref ?: a.window;
        CGRect fa = [a convertRect:a.bounds toView:base];
        CGRect fb = [b convertRect:b.bounds toView:base];
        if (fabs(fa.origin.y - fb.origin.y) > 20)
            return fa.origin.y < fb.origin.y ? NSOrderedAscending : NSOrderedDescending;
        return fa.origin.x < fb.origin.x ? NSOrderedAscending : NSOrderedDescending;
    }];
    return result;
}

// ==================================================
// Force isAvailable = true on LTMikeElement
// ==================================================
__attribute__((unused)) static void forceAvailable(id elem) {
    if (!elem) return;
    Ivar ivar = NULL;
    Class c = object_getClass(elem);
    while (c && !ivar) {
        ivar = class_getInstanceVariable(c, "isAvailable");
        c = class_getSuperclass(c);
    }
    if (!ivar) return;
    ptrdiff_t offset = ivar_getOffset(ivar);
    uint8_t *ptr = (uint8_t *)(__bridge void *)elem + offset;
    *ptr = 1;
}

// ==================================================
// Room-leave check (slow — every 1s, not every 1ms)
// ==================================================
static void scheduleRoomCheck() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (replayShouldStop) return;
        if (findMikeElements().count == 0) { stopReplay(); return; }
        scheduleRoomCheck();
    });
}

static void freezeMike(void) {
    NSArray *elems = findMikeElements();
    NSInteger idx = selectedSlot - 1;
    if (idx < 0 || idx >= (NSInteger)elems.count) return;
    UIView *elem = elems[idx];
    UIGraphicsBeginImageContextWithOptions(elem.bounds.size, NO, 0);
    [elem drawViewHierarchyInRect:elem.bounds afterScreenUpdates:NO];
    UIImage *snap = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    UIImageView *ov = [[UIImageView alloc] initWithFrame:elem.bounds];
    ov.image = snap;
    ov.userInteractionEnabled = NO;
    [elem addSubview:ov];
    if (!gOverlays) gOverlays = [NSMutableArray new];
    [gOverlays addObject:ov];
}

static void unfreezeMike(void) {
    for (UIView *v in gOverlays) [v removeFromSuperview];
    [gOverlays removeAllObjects];
}

static void stopReplay() {
    replayShouldStop = YES;
    if (replayTimer) { [replayTimer invalidate]; replayTimer = nil; }
    dispatch_async(dispatch_get_main_queue(), ^{ unfreezeMike(); });
}

// ==================================================
// Darwin cross-process sync (كل النسخ تبدأ/توقف مع بعض)
// ==================================================
#define kSWTStart CFSTR("com.swt.replay.start")
#define kSWTStop  CFSTR("com.swt.replay.stop")

static void _cbStart(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{ doReplay(); });
}
static void _cbStop(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef i) {
    dispatch_async(dispatch_get_main_queue(), ^{ stopReplay(); });
}
static void registerDarwinObs() {
    CFNotificationCenterRef d = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(d, NULL, _cbStart, kSWTStart, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(d, NULL, _cbStop,  kSWTStop,  NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void doReplay() {
    stopReplay();
    replayIndex = 0; burstCount = 0; skipCount = 0; replayShouldStop = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Cache elements + SEL once — لا تعيد traverse كل 1ms
        NSArray *elems = findMikeElements();
        if (!elems.count) return;
        freezeMike();
        scheduleRoomCheck();
        SEL rippleSel = NSSelectorFromString(@"lt_rippleButtonAction:");
        replayTimer = [NSTimer scheduledTimerWithTimeInterval:(kSpeed / 1000.0)
            repeats:YES block:^(NSTimer *t) {
                if (replayShouldStop || replayIndex >= kTimes) { stopReplay(); return; }
                if (skipCount > 0) { skipCount--; return; }
                NSInteger idx = selectedSlot - 1;
                if (idx >= 0 && idx < (NSInteger)elems.count) {
                    id elem = elems[idx];
                    if ([elem respondsToSelector:rippleSel])
                        ((void(*)(id,SEL,id))objc_msgSend)(elem, rippleSel, nil);
                }
                replayIndex++; burstCount++;
                if (burstCount >= kBurst) { burstCount = 0; skipCount = kSkip; }
            }];
    });
}

// ==================================================
// Panel
// ==================================================
@interface SWTPanel : UIView
+ (instancetype)shared;
@end

@interface SWTPanel ()
@property (nonatomic, strong) NSMutableArray<UIButton *> *slotBtns;
@property (nonatomic, strong) UIButton *startBtn;
@property (nonatomic, strong) UIButton *stopBtn;
@property (nonatomic, strong) UILabel  *countLbl;
@end

@implementation SWTPanel

+ (instancetype)shared {
    static SWTPanel *p; static dispatch_once_t t;
    dispatch_once(&t, ^{ p = [[SWTPanel alloc] initPanel]; });
    return p;
}

- (UIView *)sep:(CGFloat)x y:(CGFloat)y w:(CGFloat)w {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(x, y, w, 1)];
    v.backgroundColor = [UIColor colorWithRed:0.53 green:0.25 blue:1.00 alpha:0.30];
    return v;
}

- (UIButton *)makeBtn:(CGRect)f title:(NSString *)t bg:(UIColor *)bg {
    UIButton *b = [[UIButton alloc] initWithFrame:f];
    b.backgroundColor    = bg;
    b.titleLabel.font    = mono(12, YES);
    b.layer.cornerRadius = 6;
    b.layer.borderWidth  = 1;
    b.layer.borderColor  = cBorder().CGColor;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    glow(b.layer, cBorder(), 4);
    return b;
}

- (instancetype)initPanel {
    CGFloat PW = 296, PH = 380;
    self = [super initWithFrame:CGRectMake(0, 0, PW, PH)];
    self.backgroundColor = cBG();
    self.layer.cornerRadius = 10;
    self.layer.borderWidth  = 1.2;
    self.layer.borderColor  = cBorder().CGColor;
    glow(self.layer, cBorder(), 14);

    CGFloat x = 12, y = 12, w = PW - 24;

    // Title
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 20)];
    title.text = @"#SWT"; title.font = mono(15, YES);
    title.textColor = UIColor.whiteColor; title.textAlignment = NSTextAlignmentCenter;
    [self addSubview:title]; y += 22;

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 13)];
    sub.text = @"By Rashed & Abu Zahra"; sub.font = mono(9, NO);
    sub.textColor = cDim(); sub.textAlignment = NSTextAlignmentCenter;
    [self addSubview:sub]; y += 18;

    [self addSubview:[self sep:x y:y w:w]]; y += 10;

    // Mic slot label
    UILabel *slotLbl = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 12)];
    slotLbl.text = @"MIC SEAT"; slotLbl.font = mono(9, NO); slotLbl.textColor = cDim();
    slotLbl.textAlignment = NSTextAlignmentCenter;
    [self addSubview:slotLbl]; y += 15;

    // 10 slot buttons — 2 rows of 5
    self.slotBtns = [NSMutableArray new];
    NSInteger cols = 5;
    CGFloat gap = 5;
    CGFloat sbW = (w - gap*(cols-1)) / cols;
    CGFloat sbH = 40;
    UIColor *offBG = [UIColor colorWithRed:0.12 green:0.05 blue:0.25 alpha:1];
    UIColor *onBG  = [UIColor colorWithRed:0.03 green:0.22 blue:0.12 alpha:1];

    for (int i = 0; i < 10; i++) {
        int row = i / 5, col = i % 5;
        CGFloat bx = x + col * (sbW + gap);
        CGFloat by = y + row * (sbH + gap);
        UIButton *sb = [self makeBtn:CGRectMake(bx, by, sbW, sbH)
                               title:[NSString stringWithFormat:@"%d", i+1]
                                  bg:(i == 0 ? onBG : offBG)];
        sb.tag = i + 1;
        if (i == 0) { sb.layer.borderColor = cGreen().CGColor; glow(sb.layer, cGreen(), 5); }
        [sb addTarget:self action:@selector(slotTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:sb];
        [self.slotBtns addObject:sb];
    }
    y += 2*(sbH + gap) - gap + 10;

    [self addSubview:[self sep:x y:y w:w]]; y += 10;

    CGFloat half = (w - 8) / 2;

    // START — swipe right to start, left to cancel
    UIColor *startBG = [UIColor colorWithRed:0.28 green:0.10 blue:0.60 alpha:1];
    self.startBtn = [self makeBtn:CGRectMake(x, y, half, 56) title:@"→ START" bg:startBG];
    self.startBtn.titleLabel.font = mono(14, YES);
    UIPanGestureRecognizer *startPan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(startPan:)];
    [self.startBtn addGestureRecognizer:startPan];
    [self addSubview:self.startBtn];

    // STOP — beside START
    UIColor *stopBG = [UIColor colorWithRed:0.40 green:0.04 blue:0.10 alpha:1];
    self.stopBtn = [self makeBtn:CGRectMake(x+half+8, y, half, 56) title:@"[ STOP ]" bg:stopBG];
    self.stopBtn.titleLabel.font = mono(14, YES);
    [self.stopBtn addTarget:self action:@selector(tappedStop) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.stopBtn];

    // Found counter
    y += 56 + 8;
    self.countLbl = [[UILabel alloc] initWithFrame:CGRectMake(x, y, w, 12)];
    self.countLbl.text = @"elements: ?";
    self.countLbl.font = mono(9, NO);
    self.countLbl.textColor = cDim();
    self.countLbl.textAlignment = NSTextAlignmentCenter;
    [self addSubview:self.countLbl];

    // DUMP buttons
    y += 4;
    UIColor *dumpBG = [UIColor colorWithRed:0.08 green:0.08 blue:0.20 alpha:1];
    UIButton *dumpBtn = [self makeBtn:CGRectMake(x, y, w, 26) title:@"[ DUMP METHODS → CLIPBOARD ]" bg:dumpBG];
    dumpBtn.titleLabel.font = mono(9, YES);
    [dumpBtn addTarget:self action:@selector(tappedDump) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:dumpBtn]; y += 30;

    UIColor *ivarBG = [UIColor colorWithRed:0.08 green:0.15 blue:0.08 alpha:1];
    UIButton *ivarBtn = [self makeBtn:CGRectMake(x, y, w, 26) title:@"[ DUMP IVARS (LTMikeElement) ]" bg:ivarBG];
    ivarBtn.titleLabel.font = mono(9, YES);
    ivarBtn.layer.borderColor = cGreen().CGColor;
    [ivarBtn addTarget:self action:@selector(tappedDumpIvars) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:ivarBtn]; y += 30;

    UIColor *qBG = [UIColor colorWithRed:0.20 green:0.04 blue:0.35 alpha:1];
    UIButton *qBtn = [self makeBtn:CGRectMake(x, y, w, 26) title:@"[ قلتش ]" bg:qBG];
    qBtn.titleLabel.font = mono(12, YES);
    qBtn.layer.borderColor = [UIColor colorWithRed:0.7 green:0.2 blue:1.0 alpha:1].CGColor;
    [qBtn addTarget:self action:@selector(tappedQultash) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:qBtn];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];
    return self;
}

- (void)slotTapped:(UIButton *)sender {
    selectedSlot = sender.tag;
    UIColor *onBG  = [UIColor colorWithRed:0.03 green:0.22 blue:0.12 alpha:1];
    UIColor *offBG = [UIColor colorWithRed:0.12 green:0.05 blue:0.25 alpha:1];
    for (UIButton *b in self.slotBtns) {
        BOOL sel = (b.tag == selectedSlot);
        b.backgroundColor   = sel ? onBG : offBG;
        b.layer.borderColor = sel ? cGreen().CGColor : cBorder().CGColor;
        if (sel) glow(b.layer, cGreen(), 6);
        else     glow(b.layer, cBorder(), 4);
    }
}

- (void)startPan:(UIPanGestureRecognizer *)g {
    UIColor *activeBG = [UIColor colorWithRed:0.55 green:0.15 blue:1.00 alpha:1];
    UIColor *normalBG = [UIColor colorWithRed:0.28 green:0.10 blue:0.60 alpha:1];
    CGPoint trans = [g translationInView:self.startBtn];

    if (g.state == UIGestureRecognizerStateBegan) {
        self.startBtn.backgroundColor = activeBG;
        glow(self.startBtn.layer, cGreen(), 10);
    } else if (g.state == UIGestureRecognizerStateChanged) {
        // Shift text while dragging right
        CGFloat pct = MIN(MAX(trans.x / self.startBtn.bounds.size.width, 0), 1);
        CGFloat r = 0.28 + 0.27*pct, gb = 0.10 + 0.05*pct;
        self.startBtn.backgroundColor = [UIColor colorWithRed:r green:gb blue:1.0 alpha:1];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        self.startBtn.backgroundColor = normalBG;
        glow(self.startBtn.layer, cBorder(), 4);
        if (trans.x > 0) {
            NSArray *elems = findMikeElements();
            self.countLbl.text = [NSString stringWithFormat:@"elements: %d", (int)elems.count];
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kSWTStart, NULL, NULL, YES);
        }
    } else {
        self.startBtn.backgroundColor = normalBG;
        glow(self.startBtn.layer, cBorder(), 4);
    }
}
- (void)tappedStop {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), kSWTStop, NULL, NULL, YES);
}

- (void)tappedQultash {
    Class faceCls = NSClassFromString(@"YallaLite.LTLiveMikeFace")
                 ?: NSClassFromString(@"LTLiveMikeFace");
    if (!faceCls) { self.countLbl.text = @"LTLiveMikeFace not found"; return; }

    NSMutableArray *faces = [NSMutableArray array];
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        NSMutableArray *q = [NSMutableArray arrayWithObject:w];
        while (q.count) {
            UIView *v = q.firstObject; [q removeObjectAtIndex:0];
            if ([v isKindOfClass:faceCls]) [faces addObject:v];
            [q addObjectsFromArray:v.subviews];
        }
    }
    if (!faces.count) { self.countLbl.text = @"ما في روم مفتوح"; return; }

    NSArray *facesToCall = [faces copy];

    // UIWindow منفصلة فوق كل شيء
    UIWindowScene *wscene = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:[UIWindowScene class]]) { wscene = (UIWindowScene *)sc; break; }
    UIWindow *cwin = wscene ? [[UIWindow alloc] initWithWindowScene:wscene]
                            : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor clearColor];
    cwin.rootViewController = vc;
    cwin.windowLevel = UIWindowLevelAlert + 200;
    cwin.backgroundColor = [UIColor clearColor];
    cwin.hidden = NO;

    CGFloat cW = 220, cH = 100;
    CGRect sc = cwin.bounds;
    UIView *box = [[UIView alloc] initWithFrame:CGRectMake((sc.size.width-cW)/2, (sc.size.height-cH)/2, cW, cH)];
    box.backgroundColor    = [UIColor colorWithRed:0.05 green:0.02 blue:0.12 alpha:0.97];
    box.layer.cornerRadius = 12;
    box.layer.borderWidth  = 1;
    box.layer.borderColor  = [UIColor colorWithRed:0.55 green:0.15 blue:1.0 alpha:1].CGColor;

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 12, cW, 30)];
    lbl.text = @"تأكيد قلتش؟"; lbl.textAlignment = NSTextAlignmentCenter;
    lbl.textColor = UIColor.whiteColor; lbl.font = mono(13, YES);
    [box addSubview:lbl];

    CGFloat bW = (cW-30)/2;
    UIButton *cancel = [[UIButton alloc] initWithFrame:CGRectMake(10, 52, bW, 34)];
    cancel.backgroundColor    = [UIColor colorWithRed:0.35 green:0.04 blue:0.08 alpha:1];
    cancel.layer.cornerRadius = 8;
    [cancel setTitle:@"إلغاء" forState:UIControlStateNormal];
    cancel.titleLabel.font = mono(12, YES);
    objc_setAssociatedObject(cancel, "cwin", cwin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [cancel addTarget:self action:@selector(dismissConfirm:) forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:cancel];

    UIButton *ok = [[UIButton alloc] initWithFrame:CGRectMake(20+bW, 52, bW, 34)];
    ok.backgroundColor    = [UIColor colorWithRed:0.20 green:0.04 blue:0.45 alpha:1];
    ok.layer.cornerRadius = 8;
    [ok setTitle:@"موافق" forState:UIControlStateNormal];
    ok.titleLabel.font = mono(12, YES);
    objc_setAssociatedObject(ok, "cwin",  cwin,        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(ok, "faces", facesToCall, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ok addTarget:self action:@selector(confirmQultash:) forControlEvents:UIControlEventTouchUpInside];
    [box addSubview:ok];

    [cwin addSubview:box];
}

- (void)dismissConfirm:(UIButton *)btn {
    UIWindow *cwin = objc_getAssociatedObject(btn, "cwin");
    cwin.hidden = YES;
}

- (void)confirmQultash:(UIButton *)btn {
    UIWindow *cwin = objc_getAssociatedObject(btn, "cwin");
    cwin.hidden = YES;
    NSArray *facesToCall = objc_getAssociatedObject(btn, "faces");
    // .cxx_destruct XOR 0x5B
    const uint8_t _e[] = {0x75,0x38,0x23,0x23,0x04,0x3F,0x3E,0x28,0x2F,0x29,0x2E,0x38,0x2F};
    char _d[14]; for(int i=0;i<13;i++) _d[i]=(char)(_e[i]^0x5B); _d[13]=0;
    SEL sel = sel_registerName(_d);
    for (id face in facesToCall)
        if ([face respondsToSelector:sel])
            ((void(*)(id,SEL))objc_msgSend)(face, sel);
    self.countLbl.text = @"قلتش ✓";
}

- (void)tappedDump {
    Class cls = NSClassFromString(@"YallaLite.LTMikeElement")
             ?: NSClassFromString(@"LTMikeElement")
             ?: NSClassFromString(@"YallaLite_LTMikeElement");
    if (!cls) { self.countLbl.text = @"class not found"; return; }
    NSMutableString *out = [NSMutableString new];
    Class c = cls;
    while (c && c != [NSObject class]) {
        [out appendFormat:@"=== %@ ===\n", NSStringFromClass(c)];
        unsigned int count = 0;
        Method *methods = class_copyMethodList(c, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            const char *typeEnc = method_getTypeEncoding(methods[i]);
            [out appendFormat:@"- %@ [%s]\n", name, typeEnc ? typeEnc : "?"];
        }
        free(methods);
        c = class_getSuperclass(c);
    }
    [UIPasteboard generalPasteboard].string = out;
    self.countLbl.text = [NSString stringWithFormat:@"copied %lu methods", (unsigned long)[out componentsSeparatedByString:@"\n- "].count];
}

- (void)tappedDumpIvars {
    NSArray *elems = findMikeElements();
    NSInteger idx = selectedSlot - 1;
    if (idx < 0 || idx >= (NSInteger)elems.count) {
        self.countLbl.text = @"اختر مايك أولاً";
        return;
    }
    id liveInstance = elems[idx];
    Class dumpCls = [liveInstance class];

    NSMutableString *out = [NSMutableString new];
    [out appendFormat:@"=== %@ (slot %ld) ===\n", NSStringFromClass(dumpCls), (long)selectedSlot];

    uint8_t *base = (uint8_t *)(__bridge void *)liveInstance;

    Class c = dumpCls;
    while (c && c != [NSObject class]) {
        unsigned int ivarCount = 0;
        Ivar *ivars = class_copyIvarList(c, &ivarCount);
        if (ivarCount > 0) [out appendFormat:@"-- %@ --\n", NSStringFromClass(c)];
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *name    = ivar_getName(ivars[i]);
            const char *typeEnc = ivar_getTypeEncoding(ivars[i]);
            ptrdiff_t   offset  = ivar_getOffset(ivars[i]);
            NSString *valStr = @"?";
            if (typeEnc && typeEnc[0] == '@') {
                @try {
                    id val = object_getIvar(liveInstance, ivars[i]);
                    valStr = val ? NSStringFromClass([val class]) : @"nil";
                } @catch (...) { valStr = @"err"; }
            } else {
                @try {
                    uint64_t raw = 0;
                    memcpy(&raw, base + offset, sizeof(raw));
                    valStr = [NSString stringWithFormat:@"0x%016llX  b0=%hhu",
                              (unsigned long long)raw, base[offset]];
                } @catch (...) { valStr = @"(err)"; }
            }
            [out appendFormat:@"%s [+%td] (%s) = %@\n",
             name ? name : "?", offset, typeEnc ? typeEnc : "?", valStr];
        }
        free(ivars);
        c = class_getSuperclass(c);
    }

    [UIPasteboard generalPasteboard].string = out;
    self.countLbl.text = @"ivars copied!";
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [pan setTranslation:CGPointZero inView:self.superview];
}

@end

// ==================================================
// Floating #SWT button
// ==================================================
static UIButton *swtBtn = nil;

@interface SWTHandler : NSObject
+ (instancetype)shared;
- (void)tapped;
- (void)drag:(UIPanGestureRecognizer *)pan;
@end
@implementation SWTHandler
+ (instancetype)shared {
    static SWTHandler *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [SWTHandler new]; });
    return s;
}
- (void)tapped {
    SWTPanel *p = [SWTPanel shared];
    UIWindow *w = getKeyWindow(); if (!w) return;
    if (!p.superview) { p.center = CGPointMake(w.bounds.size.width/2, w.bounds.size.height/2); [w addSubview:p]; }
    p.hidden = !p.hidden;
    [w bringSubviewToFront:p];
}
- (void)drag:(UIPanGestureRecognizer *)pan {
    UIView *v = pan.view; CGPoint t = [pan translationInView:v.superview];
    v.center = CGPointMake(v.center.x+t.x, v.center.y+t.y);
    [pan setTranslation:CGPointZero inView:v.superview];
}
@end

static void createButton(UIWindow *win) {
    CGFloat W = win.bounds.size.width;
    swtBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    swtBtn.frame = CGRectMake(W - 68, 130, 56, 24);
    swtBtn.backgroundColor   = [UIColor colorWithRed:0.03 green:0.01 blue:0.07 alpha:0.96];
    swtBtn.layer.cornerRadius = 4;
    swtBtn.layer.borderWidth  = 1;
    swtBtn.layer.borderColor  = cBorder().CGColor;
    glow(swtBtn.layer, cBorder(), 7);
    [swtBtn setTitle:@"#SWT" forState:UIControlStateNormal];
    [swtBtn setTitleColor:cText() forState:UIControlStateNormal];
    swtBtn.titleLabel.font = mono(11, YES);
    [swtBtn addTarget:[SWTHandler shared] action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:[SWTHandler shared] action:@selector(drag:)];
    [swtBtn addGestureRecognizer:pan];
    [win addSubview:swtBtn];
}

static void ensureButton() {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = getKeyWindow(); if (!win) return;
        if (!swtBtn || swtBtn.superview != win) {
            [swtBtn removeFromSuperview];
            createButton(win);
        }
        [win bringSubviewToFront:swtBtn];
        SWTPanel *p = [SWTPanel shared];
        if (p.superview) [win bringSubviewToFront:p];
    });
}

// Hook performSelector:withObject:afterDelay: — يخلي الـ delay صفر لـ LTMikeElement
static IMP gOrigPerfSel = NULL;
static void _myPerfSel(id self, SEL _cmd, SEL selector, id obj, NSTimeInterval delay) {
    Class mikeClass = NSClassFromString(@"YallaLite.LTMikeElement")
                   ?: NSClassFromString(@"LTMikeElement")
                   ?: NSClassFromString(@"YallaLite_LTMikeElement");
    if (mikeClass && [self isKindOfClass:mikeClass]) delay = 0;
    ((void(*)(id,SEL,SEL,id,NSTimeInterval))gOrigPerfSel)(self, _cmd, selector, obj, delay);
}

static void swizzleMikeElement(void) {
    Class cls = NSClassFromString(@"YallaLite.LTMikeElement")
             ?: NSClassFromString(@"LTMikeElement")
             ?: NSClassFromString(@"YallaLite_LTMikeElement");
    if (!cls) return;

    // Hook lt_rippleButtonAction: — تعطيل animations + تسريع CALayer
    SEL sel = NSSelectorFromString(@"lt_rippleButtonAction:");
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        IMP orig = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(UIView *_self, id arg) {
            [UIView setAnimationsEnabled:NO];
            ((void(*)(id,SEL,id))orig)(_self, sel, arg);
            [UIView setAnimationsEnabled:YES];
        }));
    }

    // Hook performSelector:withObject:afterDelay: على NSObject — يصفّر الـ delay
    SEL pSel = @selector(performSelector:withObject:afterDelay:);
    Method pm = class_getInstanceMethod([NSObject class], pSel);
    if (pm && !gOrigPerfSel) {
        gOrigPerfSel = method_getImplementation(pm);
        method_setImplementation(pm, (IMP)_myPerfSel);
    }
}

// ==================================================
// Audio session patch — كل النسخ تتشارك بدل ما تتطارد
// ==================================================
static void patchAudioSession() {
    Class cls = [AVAudioSession class];

    // setCategory:withOptions:error:
    SEL s1 = @selector(setCategory:withOptions:error:);
    Method m1 = class_getInstanceMethod(cls, s1);
    if (m1) {
        IMP orig1 = method_getImplementation(m1);
        method_setImplementation(m1, imp_implementationWithBlock(
            ^BOOL(AVAudioSession *_s, AVAudioSessionCategory cat,
                  AVAudioSessionCategoryOptions opts, NSError **e) {
                opts |= AVAudioSessionCategoryOptionMixWithOthers;
                return ((BOOL(*)(id,SEL,AVAudioSessionCategory,AVAudioSessionCategoryOptions,NSError**))orig1)
                       (_s, s1, cat, opts, e);
            }));
    }

    // setCategory:mode:options:error: (iOS 10+)
    SEL s2 = @selector(setCategory:mode:options:error:);
    Method m2 = class_getInstanceMethod(cls, s2);
    if (m2) {
        IMP orig2 = method_getImplementation(m2);
        method_setImplementation(m2, imp_implementationWithBlock(
            ^BOOL(AVAudioSession *_s, AVAudioSessionCategory cat,
                  AVAudioSessionMode mode, AVAudioSessionCategoryOptions opts, NSError **e) {
                opts |= AVAudioSessionCategoryOptionMixWithOthers;
                return ((BOOL(*)(id,SEL,AVAudioSessionCategory,AVAudioSessionMode,AVAudioSessionCategoryOptions,NSError**))orig2)
                       (_s, s2, cat, mode, opts, e);
            }));
    }
}

// ==================================================
// Silent audio — تخلي iOS ما يطرد النسخة من الخلفية
// ==================================================
static AVAudioEngine      *_bgEngine = nil;
static AVAudioPlayerNode  *_bgPlayer = nil;

static void startSilentAudio() {
    if (_bgEngine) return;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback
       withOptions:AVAudioSessionCategoryOptionMixWithOthers
             error:nil];
    [s setActive:YES error:nil];

    _bgEngine = [AVAudioEngine new];
    _bgPlayer = [AVAudioPlayerNode new];
    [_bgEngine attachNode:_bgPlayer];
    AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:8000 channels:1];
    [_bgEngine connect:_bgPlayer to:_bgEngine.mainMixerNode format:fmt];
    [_bgEngine startAndReturnError:nil];

    AVAudioFrameCount frames = 800;
    AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:frames];
    buf.frameLength = frames;
    memset(buf.floatChannelData[0], 0, frames * sizeof(float));
    [_bgPlayer scheduleBuffer:buf atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
    [_bgPlayer play];
}

static void restartSilentAudio() {
    [_bgEngine stop];
    _bgEngine = nil; _bgPlayer = nil;
    startSilentAudio();
}

static void startKeepAlive() {
    static NSTimer *t = nil; if (t) return;
    t = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *_) { ensureButton(); }];
}

// ==================================================
// Constructor
// ==================================================
__attribute__((constructor)) static void _ctor() {
    registerDarwinObs();
    patchAudioSession();
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    startSilentAudio();
                    ensureButton();
                    startKeepAlive();
                    swizzleMikeElement();
                });
        }];
    // لو iOS قاطع الـ session (نسخة ثانية أخذتها) نعيد التشغيل
    [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioSessionInterruptionNotification object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            NSNumber *type = n.userInfo[AVAudioSessionInterruptionTypeKey];
            if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded)
                restartSilentAudio();
        }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{ ensureButton(); });
        }];
}
