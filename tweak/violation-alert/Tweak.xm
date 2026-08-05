#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================
// 违规弹窗检测 Tweak（Dopamine 越狱）v0.0.7
// ============================================================
// 背景：抖音直播违规弹窗是【自定义UI】（白卡片+红色警示三角+遮罩），
//       不是 iOS 原生 UIAlertController，老版本 Hook 不到！
// 升级：三路检测，检测到弹窗就上报（无论内容）：
//   1. Hook presentViewController —— 主力，捕获所有 present 弹窗 VC
//   2. Hook UIAlertController viewDidAppear —— 原生弹窗双保险
//   3. 定时轮询 alert 级独立窗口 —— 兜底 window 型弹窗
// 策略：检测到弹窗立即推送，30 秒同类去重，白名单关键词忽略
// v0.0.7 新增【侦察模式】(plist scout_mode=true)：
//   - 定时 dump 抖音直播页面视图层级（找评论列表/订单提示类名）
//   - 检测页面内 WKWebView（罗盘大屏是否 H5）
//   - 上报 /api/scout_report（不推 Bark，供逆向分析）
// 配置（可选）：/var/mobile/Library/Preferences/com.ailive.violationalert.plist
//   { device_id, server, test_mode, ignore_keywords, scout_mode }
// 默认 device_id=99c79a server=http://59.110.152.66:18766
// 默认【实战模式】（无 plist 不弹测试窗）；test_mode=true 可手动开测试
// ============================================================

static NSString *kPrefsPath = @"/var/mobile/Library/Preferences/com.ailive.violationalert.plist";
static NSString *kDefaultDeviceId = @"99c79a";   // 默认测试机设备ID（99c79a = 真机3）
static NSString *kDefaultServer = @"http://59.110.152.66:18766";
static BOOL gTestMode = NO;
static BOOL gScoutMode = NO;
static BOOL gTestAlertShown = NO;
static UIViewController *gTestDialog = nil;      // 强引用测试弹窗，供按钮 dismiss
static NSMutableDictionary *gLastReport = nil;   // 去重表 key -> NSDate

@interface ViolationAlertHelper : NSObject
+ (instancetype)shared;
- (void)checkAlert:(UIAlertController *)alert;
- (void)checkPresentedVC:(UIViewController *)vc;
- (void)startPolling;
- (void)showTestAlert;
- (UIViewController *)topViewController;
- (void)reportScout:(NSString *)kind payload:(NSDictionary *)payload;
- (void)dumpHierarchy;
- (void)findWebViews;
- (void)enumerateClasses;
- (void)enumerateMethods;
- (void)probeMessage:(id)message source:(NSString *)source;
- (void)handleLiveMessage:(id)message;
@end

@implementation ViolationAlertHelper

+ (instancetype)shared {
    static ViolationAlertHelper *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[ViolationAlertHelper alloc] init];
        gLastReport = [NSMutableDictionary dictionary];
    });
    return inst;
}

// 读取配置（无 plist 返回空字典）
- (NSDictionary *)loadConfig {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (!cfg) cfg = @{};
    return cfg;
}

// 30 秒同类去重
- (BOOL)shouldReport:(NSString *)key {
    if (!key.length) return YES;
    NSDate *last = gLastReport[key];
    NSTimeInterval since = last ? -[last timeIntervalSinceNow] : 9999;
    if (since < 30) return NO;
    gLastReport[key] = [NSDate date];
    if (gLastReport.count > 200) [gLastReport removeAllObjects];
    return YES;
}

// 上报到服务器
- (void)reportToServer:(NSString *)text app:(NSString *)app {
    NSDictionary *cfg = [self loadConfig];
    NSString *deviceId = cfg[@"device_id"];
    if (![deviceId isKindOfClass:[NSString class]] || !deviceId.length) {
        deviceId = kDefaultDeviceId;
    }
    NSString *server = cfg[@"server"];
    if (![server isKindOfClass:[NSString class]] || !server.length) {
        server = kDefaultServer;
    }
    NSString *urlStr = [NSString stringWithFormat:@"%@/api/violation_report", server];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{
        @"device_id": deviceId,
        @"text": text,
        @"app": app ?: @"douyin"
    };
    NSError *err = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (err) {
        NSLog(@"[ViolationAlert] ⚠️ JSON序列化失败: %@", err);
        return;
    }
    req.HTTPBody = jsonData;
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) {
            NSLog(@"[ViolationAlert] ❌ 上报失败: %@", error.localizedDescription);
        } else {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)resp;
            NSLog(@"[ViolationAlert] ✅ 上报成功 HTTP %ld: %@", (long)httpResp.statusCode, text);
        }
    }];
    [task resume];
}

// 白名单：命中关键词的弹窗不推（默认内置常见无害弹窗，plist ignore_keywords 可覆盖）
- (BOOL)isIgnored:(NSString *)text {
    NSArray *defaultIgnore = @[
        @"关注成功", @"已关注", @"点赞成功", @"收藏成功",
        @"已加入粉丝团", @"成为粉丝"
    ];
    NSDictionary *cfg = [self loadConfig];
    NSArray *ign = cfg[@"ignore_keywords"];
    if (![ign isKindOfClass:[NSArray class]] || ign.count == 0) {
        ign = defaultIgnore;
    }
    for (NSString *kw in ign) {
        if ([kw isKindOfClass:[NSString class]] && kw.length && [text containsString:kw]) return YES;
    }
    return NO;
}

// 统一上报入口：拼文本 + 白名单 + 去重 + 上报
- (void)reportDialogWithClass:(NSString *)cls text:(NSString *)text source:(NSString *)source {
    NSMutableString *full = [NSMutableString string];
    if (cls.length) [full appendFormat:@"[%@]", cls];
    if (text.length) {
        if (full.length) [full appendString:@" "];
        [full appendString:text];
    }
    if (!full.length) {
        [full appendFormat:@"[%@] 检测到弹窗", cls.length ? cls : @"unknown"];
    }
    // 白名单过滤
    if ([self isIgnored:full]) {
        NSLog(@"[ViolationAlert] ⏸ 白名单忽略: %@", full);
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@", cls ?: @"", text ?: @""];
    if (![self shouldReport:key]) {
        NSLog(@"[ViolationAlert] ⏸ 去重跳过: %@", full);
        return;
    }
    NSLog(@"[ViolationAlert] 🚨 [%@] 弹窗: %@", source, full);
    [self reportToServer:full app:[[NSBundle mainBundle] bundleIdentifier]];
}

// 遍历视图层级提取文字（UILabel/UITextView）
- (void)collectTextFromView:(UIView *)view into:(NSMutableArray *)outArray depth:(int)depth {
    if (!view || depth > 8) return;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)view;
        if (l.text.length) [outArray addObject:l.text];
    } else if ([view isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)view;
        if (tv.text.length) [outArray addObject:tv.text];
    }
    for (UIView *sub in view.subviews) {
        [self collectTextFromView:sub into:outArray depth:depth + 1];
    }
}

// 弹窗形态判定：是不是"弹窗"而不是普通全屏页面
- (BOOL)looksLikeDialog:(UIViewController *)vc {
    if (!vc || !vc.view) return NO;
    NSString *cls = NSStringFromClass(vc.class);
    if (!cls.length) return NO;
    // 原生弹窗直接算
    if ([cls containsString:@"UIAlertController"]) return YES;
    // 排除系统容器/正常页面
    NSArray *ignore = @[
        @"UINavigationController", @"UITabBarController", @"UISplitViewController",
        @"AVPlayerViewController", @"WKWebView", @"UIInputWindowController",
        @"UIActivityViewController", @"UIDocumentPicker", @"UIKeyboard",
        @"UIPopoverController", @"UIPageViewController"
    ];
    for (NSString *p in ignore) {
        if ([cls containsString:p]) return NO;
    }
    CGSize screen = [UIScreen mainScreen].bounds.size;
    UIView *v = vc.view;
    CGRect f = v.frame;
    if (CGRectIsEmpty(f) || CGRectIsNull(f)) f = v.bounds;
    CGFloat area = f.size.width * f.size.height;
    CGFloat screenArea = screen.width * screen.height;
    // 1) 面积明显小于屏幕 → 居中卡片弹窗
    if (screenArea > 0 && area / screenArea < 0.75) return YES;
    // 2) over 类型 presentation → 弹窗
    UIModalPresentationStyle ms = vc.modalPresentationStyle;
    if (ms == UIModalPresentationOverFullScreen || ms == UIModalPresentationOverCurrentContext) return YES;
    // 3) 全屏但带半透明遮罩 + 小卡片 → 弹窗
    if (f.size.width >= screen.width * 0.98 && f.size.height >= screen.height * 0.98) {
        BOOL hasMask = NO;
        for (UIView *sub in v.subviews) {
            if (sub.alpha < 0.95 &&
                sub.frame.size.width >= screen.width * 0.9 &&
                sub.frame.size.height >= screen.height * 0.9) {
                hasMask = YES;
                break;
            }
        }
        if (hasMask) {
            for (UIView *sub2 in v.subviews) {
                if (sub2.frame.size.width < screen.width * 0.8 &&
                    sub2.frame.size.height < screen.height * 0.8 &&
                    sub2.frame.size.width > 50 && sub2.frame.size.height > 50) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

// 原生弹窗检测（UIAlertController）
- (void)checkAlert:(UIAlertController *)alert {
    NSString *title = alert.title ?: @"";
    NSString *message = alert.message ?: @"";
    NSString *full = [NSString stringWithFormat:@"%@ %@", title, message];
    full = [full stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!full.length) return;
    NSString *cls = NSStringFromClass(alert.class);
    [self reportDialogWithClass:cls text:full source:@"alert"];
}

// present 出来的 VC 检测（主力）
- (void)checkPresentedVC:(UIViewController *)vc {
    // 延迟等布局完成再判定（present 动画中 frame 不准）
    __weak UIViewController *wvc = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIViewController *svc = wvc;
        if (!svc) return;
        if ([self looksLikeDialog:svc]) {
            NSMutableArray *texts = [NSMutableArray array];
            [self collectTextFromView:svc.view into:texts depth:0];
            NSString *text = [texts componentsJoinedByString:@" "];
            NSString *cls = NSStringFromClass(svc.class);
            [self reportDialogWithClass:cls text:text source:@"present"];
        } else {
            NSLog(@"[ViolationAlert] 非弹窗忽略: %@", NSStringFromClass(svc.class));
        }
    });
}

// 侦察数据上报（不推 Bark，只发服务器日志供逆向分析）
- (void)reportScout:(NSString *)kind payload:(NSDictionary *)payload {
    NSDictionary *cfg = [self loadConfig];
    NSString *deviceId = cfg[@"device_id"];
    if (![deviceId isKindOfClass:[NSString class]] || !deviceId.length) {
        deviceId = kDefaultDeviceId;
    }
    NSString *server = cfg[@"server"];
    if (![server isKindOfClass:[NSString class]] || !server.length) {
        server = kDefaultServer;
    }
    NSString *urlStr = [NSString stringWithFormat:@"%@/api/scout_report", server];
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{
        @"device_id": deviceId,
        @"kind": kind ?: @"",
        @"payload": payload ?: @{}
    };
    NSError *err = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&err];
    if (err) {
        NSLog(@"[ViolationAlert] ⚠️ 侦察JSON失败: %@", err);
        return;
    }
    req.HTTPBody = jsonData;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) {
            NSLog(@"[ViolationAlert] ❌ 侦察上报失败: %@", error.localizedDescription);
        } else {
            NSLog(@"[ViolationAlert] ✅ 侦察上报成功: %@", kind);
        }
    }];
    [task resume];
}

// 递归生成视图层级描述（类名 + frame + 是否含文字）
- (NSString *)describeView:(UIView *)view depth:(int)depth maxDepth:(int)maxDepth {
    if (!view || depth > maxDepth) return @"";
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < depth; i++) [s appendString:@"  "];
    NSString *cls = NSStringFromClass(view.class);
    CGRect f = view.frame;
    [s appendFormat:@"%@ %@ (%.0f,%.0f %.0fx%.0f)", cls, view.hidden ? @"HIDDEN" : @"", f.origin.x, f.origin.y, f.size.width, f.size.height];
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)view).text;
        if (t.length) [s appendFormat:@" text=\"%@\"", t.length > 40 ? [t substringToIndex:40] : t];
    } else if ([view isKindOfClass:[UIButton class]]) {
        NSString *t = ((UIButton *)view).titleLabel.text;
        if (t.length) [s appendFormat:@" btn=\"%@\"", t.length > 30 ? [t substringToIndex:30] : t];
    } else if ([view isKindOfClass:[UITextField class]]) {
        NSString *t = ((UITextField *)view).placeholder;
        if (t.length) [s appendFormat:@" ph=\"%@\"", t];
    }
    [s appendString:@"\n"];
    for (UIView *sub in view.subviews) {
        [s appendString:[self describeView:sub depth:depth + 1 maxDepth:maxDepth]];
    }
    return s;
}

// 侦察：dump 当前窗口视图层级（找评论列表/订单提示的类名）
- (void)dumpHierarchy {
    NSMutableArray *windows = [NSMutableArray array];
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *w in ws.windows) {
            if (!w.hidden && w.rootViewController) [windows addObject:w];
        }
    }
    if (!windows.count) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.hidden && w.rootViewController) [windows addObject:w];
        }
    }
    NSMutableArray *hierarchies = [NSMutableArray array];
    for (UIWindow *w in windows) {
        NSString *desc = [self describeView:w depth:0 maxDepth:15];
        if (desc.length > 12000) desc = [desc substringToIndex:12000];
        [hierarchies addObject:desc];
    }
    [self reportScout:@"hierarchy" payload:@{
        @"windows": @(hierarchies.count),
        @"dump": [hierarchies componentsJoinedByString:@"\n---\n"]
    }];
}

// 侦察：检测页面内是否有 WKWebView / UIWebView（罗盘大屏是否 H5）
- (void)findWebViews {
    NSMutableArray *found = [NSMutableArray array];
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        [self scanWebViewsInView:w.rootViewController.view found:found depth:0];
    }
    [self reportScout:@"webview" payload:@{
        @"count": @(found.count),
        @"list": found
    }];
}

- (void)scanWebViewsInView:(UIView *)view found:(NSMutableArray *)found depth:(int)depth {
    if (!view || depth > 10) return;
    NSString *cls = NSStringFromClass(view.class);
    if ([cls containsString:@"WKWebView"] || [cls containsString:@"UIWebView"] || [cls containsString:@"WebView"]) {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        info[@"class"] = cls;
        info[@"frame"] = NSStringFromCGRect(view.frame);
        // 尝试拿 URL
        if ([view respondsToSelector:@selector(URL)]) {
            id url = [view performSelector:@selector(URL)];
            if ([url isKindOfClass:[NSURL class]]) info[@"url"] = [(NSURL *)url absoluteString];
        }
        [found addObject:info];
    }
    for (UIView *sub in view.subviews) {
        [self scanWebViewsInView:sub found:found depth:depth + 1];
    }
}

// 动态逆向：枚举运行时所有类，过滤直播/评论/订单相关关键词上报
- (void)enumerateClasses {
    int total = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * total);
    objc_getClassList(classes, total);
    
    NSArray *keywords = @[@"IESLive", @"HTSLive", @"LiveRoom", @"LiveMessage", @"Comment", @"Danmaku", @"Gift", @"Order", @"Chat", @"MessageModel", @"AwemeLive", @"LiveCell", @"LiveFeed"];
    NSMutableArray *matches = [NSMutableArray array];
    
    for (int i = 0; i < total; i++) {
        Class c = classes[i];
        const char *name = class_getName(c);
        if (!name) continue;
        NSString *cn = [NSString stringWithUTF8String:name];
        for (NSString *kw in keywords) {
            if ([cn containsString:kw]) {
                [matches addObject:cn];
                break;
            }
        }
    }
    free(classes);
    
    NSLog(@"[ViolationAlert] 🔍 运行时类枚举: 共%d个类, 匹配%d个", total, (int)matches.count);
    [self reportScout:@"classes" payload:@{
        @"total": @(total),
        @"matched": @(matches.count),
        @"list": [matches sortedArrayUsingSelector:@selector(compare:)]
    }];
}

// 动态逆向：枚举核心直播消息类的方法签名（instance + class methods）
- (void)enumerateMethods {
    NSArray *coreClasses = @[
        @"HTSLiveMessageHandler",
        @"HTSLiveMessageDispatcherAdapterImpl",
        @"HTSGroupedLiveMessageHandler",
        @"IESLiveChatChannelMessageDispatcher",
        @"IESLiveIMMessageDispatcher",
        @"IESLLLiveMessageCenter",
        @"HTSLiveRoomChannelChatMessage",
        @"HTSLiveRoomChannelChatRoot",
        @"HTSLiveRoomChannelGiftMessage",
        @"HTSLiveRoomChannelGiftRoot",
        @"HTSLiveRoomChannelStateMessage",
        @"HTSLiveRoomChannelSystemMessage",
        @"HTSLiveRoomChannelAccessMessage",
        @"HTSLiveRoomMessageRoot",
        @"HTSLiveUnifiedMessageRoot",
        @"HTSLiveGiftMessageRoot",
        @"HTSLiveGiftCommentMessageRoot",
        @"HTSLiveWebcastChatLikeMessageRoot",
        @"IESLiveMessageFilterProcesser",
        @"IESLiveMessageListBaseQueue",
        @"IESLiveMessageListCommonCell"
    ];
    NSMutableArray *result = [NSMutableArray array];
    
    for (NSString *clsName in coreClasses) {
        Class cls = NSClassFromString(clsName);
        if (!cls) {
            [result addObject:[NSString stringWithFormat:@"%@: <不存在>", clsName]];
            continue;
        }
        NSMutableString *methods = [NSMutableString string];
        
        // 实例方法
        unsigned int mc = 0;
        Method *mList = class_copyMethodList(cls, &mc);
        for (unsigned int i = 0; i < mc; i++) {
            SEL sel = method_getName(mList[i]);
            NSString *sig = [NSString stringWithUTF8String:sel_getName(sel)];
            [methods appendFormat:@"  -%@\n", sig];
        }
        free(mList);
        
        // 类方法
        unsigned int cc = 0;
        Method *cList = class_copyMethodList(object_getClass(cls), &cc);
        for (unsigned int i = 0; i < cc; i++) {
            SEL sel = method_getName(cList[i]);
            NSString *sig = [NSString stringWithUTF8String:sel_getName(sel)];
            [methods appendFormat:@"  +%@\n", sig];
        }
        free(cList);
        
        NSString *entry = [NSString stringWithFormat:@"=== %@ (%u methods) ===\n%@", clsName, mc + cc, methods];
        [result addObject:entry];
    }
    
    NSLog(@"[ViolationAlert] 🔍 方法枚举完成");
    [self reportScout:@"methods" payload:@{
        @"list": result
    }];
}

// v0.2.0 消息探针：拦截直播消息，dump 类名+字段结构上报（不推Bark）
- (void)probeMessage:(id)message source:(NSString *)source {
    if (!message) return;
    // 频率限制：每类消息最多 1 次/3秒，防刷爆
    static NSMutableDictionary *lastProbe = nil;
    if (!lastProbe) lastProbe = [NSMutableDictionary dictionary];
    NSString *cls = NSStringFromClass([message class]);
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSNumber *last = lastProbe[cls];
    if (last && (now - last.doubleValue) < 3.0) return;
    lastProbe[cls] = @(now);
    
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"source"] = source ?: @"";
    info[@"class"] = cls;
    info[@"methods"] = [self methodNamesForClass:[message class]];
    
    // 尝试提取关键文本字段（评论内容/用户名等）
    NSMutableString *textInfo = [NSMutableString string];
    NSArray *textSelectors = @[@"text", @"content", @"message", @"userName", @"nickname", @"displayText", @"description", @"tipText", @"localTipText", @"common", @"user", @"chatMessage", @"gift", @"order"];
    for (NSString *selName in textSelectors) {
        SEL sel = NSSelectorFromString(selName);
        if ([message respondsToSelector:sel]) {
            @try {
                id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
                id val = fn(message, sel);
                if (val) {
                    if ([val isKindOfClass:[NSString class]]) {
                        [textInfo appendFormat:@"%@=%@\n", selName, val];
                    } else if ([val isKindOfClass:[NSArray class]]) {
                        [textInfo appendFormat:@"%@=<array %lu>\n", selName, (unsigned long)[(NSArray *)val count]];
                    } else if ([val isKindOfClass:[NSDictionary class]]) {
                        [textInfo appendFormat:@"%@=<dict %lu>\n", selName, (unsigned long)[(NSDictionary *)val count]];
                    } else if ([val isKindOfClass:[NSNumber class]]) {
                        [textInfo appendFormat:@"%@=%@\n", selName, val];
                    } else {
                        [textInfo appendFormat:@"%@=<%@>\n", selName, NSStringFromClass([val class])];
                    }
                }
            } @catch (NSException *e) {}
        }
    }
    info[@"texts"] = textInfo;
    
    // 上报（限制单条大小）
    NSString *dumpStr = [NSString stringWithFormat:@"[%@] %@\n---\n%@", source ?: @"", cls, textInfo];
    if (dumpStr.length > 3000) dumpStr = [dumpStr substringToIndex:3000];
    [self reportScout:@"probe" payload:info];
    NSLog(@"[ViolationAlert] 📡 消息探针: %@", dumpStr);
}

// v0.3.0 正式采集：识别消息类型并上报服务器（服务器决定是否播报）
- (void)handleLiveMessage:(id)message {
    if (!message) return;
    NSString *cls = NSStringFromClass([message class]);
    
    // 1. 评论消息：HTSLiveChatMessage → content 字段
    if ([cls isEqualToString:@"HTSLiveChatMessage"]) {
        NSString *content = nil;
        @try {
            if ([message respondsToSelector:@selector(content)]) {
                content = ((NSString *(*)(id, SEL))objc_msgSend)(message, @selector(content));
            }
        } @catch (NSException *e) {}
        if (content.length) {
            [self reportSay:content type:@"danmaku"];
            NSLog(@"[ViolationAlert] 💬 评论: %@", content);
        }
        return;
    }
    
    // 2. 电商消息（下单）：HTSLiveLiveEcomGeneralMessage → data 二进制 base64 上报
    if ([cls isEqualToString:@"HTSLiveLiveEcomGeneralMessage"]) {
        NSString *contentType = nil;
        NSData *data = nil;
        @try {
            if ([message respondsToSelector:@selector(contentType)]) {
                contentType = ((NSString *(*)(id, SEL))objc_msgSend)(message, @selector(contentType));
            }
            if ([message respondsToSelector:@selector(data)]) {
                data = ((NSData *(*)(id, SEL))objc_msgSend)(message, @selector(data));
            }
        } @catch (NSException *e) {}
        if (data.length) {
            NSString *b64 = [data base64EncodedStringWithOptions:0];
            [self reportEcom:contentType ?: @"" dataB64:b64];
            NSLog(@"[ViolationAlert] 🛒 电商消息: %@ (%lu bytes)", contentType ?: @"", (unsigned long)data.length);
        }
        return;
    }
    
    // 3. 进房消息：不处理（用户要求）
    if ([cls isEqualToString:@"HTSLiveMemberMessage"]) {
        return;
    }
    
    // 其他消息：暂不处理（后续扩展：RoomStats→在线人数等）
}

// 上报评论到 /api/say
- (void)reportSay:(NSString *)text type:(NSString *)type {
    NSDictionary *cfg = [self loadConfig];
    NSString *deviceId = cfg[@"device_id"];
    if (![deviceId isKindOfClass:[NSString class]] || !deviceId.length) deviceId = kDefaultDeviceId;
    NSString *server = cfg[@"server"];
    if (![server isKindOfClass:[NSString class]] || !server.length) server = kDefaultServer;
    
    NSString *urlStr = [NSString stringWithFormat:@"%@/api/say", server];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{
        @"phone_id": deviceId,
        @"text": text,
        @"type": type ?: @"danmaku"
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonData) return;
    req.HTTPBody = jsonData;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) NSLog(@"[ViolationAlert] ❌ 上报失败: %@", error.localizedDescription);
        else NSLog(@"[ViolationAlert] ✅ 上报成功: %@", text);
    }];
    [task resume];
}

// 上报电商消息（data base64 交给服务器解码）
- (void)reportEcom:(NSString *)contentType dataB64:(NSString *)dataB64 {
    NSDictionary *cfg = [self loadConfig];
    NSString *deviceId = cfg[@"device_id"];
    if (![deviceId isKindOfClass:[NSString class]] || !deviceId.length) deviceId = kDefaultDeviceId;
    NSString *server = cfg[@"server"];
    if (![server isKindOfClass:[NSString class]] || !server.length) server = kDefaultServer;
    
    NSString *urlStr = [NSString stringWithFormat:@"%@/api/say", server];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{
        @"phone_id": deviceId,
        @"type": @"ecom_raw",
        @"content_type": contentType,
        @"data_b64": dataB64
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonData) return;
    req.HTTPBody = jsonData;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) NSLog(@"[ViolationAlert] ❌ 电商上报失败: %@", error.localizedDescription);
        else NSLog(@"[ViolationAlert] ✅ 电商上报成功: %@", contentType);
    }];
    [task resume];
}

// 辅助：列出类的方法名（实例方法，去重）
- (NSArray *)methodNamesForClass:(Class)cls {
    NSMutableArray *names = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    Class cur = cls;
    while (cur && cur != [NSObject class]) {
        unsigned int mc = 0;
        Method *mList = class_copyMethodList(cur, &mc);
        for (unsigned int i = 0; i < mc; i++) {
            SEL sel = method_getName(mList[i]);
            NSString *sig = [NSString stringWithUTF8String:sel_getName(sel)];
            if (![seen containsObject:sig]) {
                [seen addObject:sig];
                [names addObject:sig];
            }
        }
        free(mList);
        cur = class_getSuperclass(cur);
    }
    return names;
}

// 兜底轮询：alert 级独立窗口
- (void)startPolling {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.hidden) continue;
            if (w.windowLevel < UIWindowLevelAlert) continue;  // 只查弹窗级窗口
            UIView *rootView = w.rootViewController.view;
            if (!rootView) continue;
            NSMutableArray *texts = [NSMutableArray array];
            [self collectTextFromView:rootView into:texts depth:0];
            NSString *text = [texts componentsJoinedByString:@" "];
            [self reportDialogWithClass:NSStringFromClass(w.rootViewController.class)
                                   text:text
                                 source:@"window"];
        }
        [self startPolling];
    });
}

// 找当前顶层控制器（多场景兼容）
- (UIViewController *)topViewController {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
            if (keyWindow) break;
        }
    }
    if (!keyWindow) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.rootViewController) { keyWindow = w; break; }
        }
    }
    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

// 关闭测试弹窗
- (void)dismissTestDialog:(id)sender {
    if (gTestDialog) {
        [gTestDialog dismissViewControllerAnimated:YES completion:^{
            gTestDialog = nil;
        }];
    }
}

// 测试模式：弹【抖音风格】自定义弹窗（验证 present hook 链路）
- (void)showTestAlert {
    if (gTestAlertShown) return;
    gTestAlertShown = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (!top) {
            NSLog(@"[ViolationAlert] ❌ 测试弹窗失败：找不到顶层控制器");
            gTestAlertShown = NO; // 允许重试
            return;
        }
        UIViewController *dialog = [[UIViewController alloc] init];
        dialog.modalPresentationStyle = UIModalPresentationOverFullScreen;
        dialog.view.backgroundColor = [UIColor clearColor];
        gTestDialog = dialog;

        // 半透明遮罩
        UIView *mask = [[UIView alloc] initWithFrame:dialog.view.bounds];
        mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        mask.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [dialog.view addSubview:mask];

        // 白色圆角卡片
        CGFloat cw = 280, ch = 230;
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake((dialog.view.bounds.size.width - cw) / 2,
                                                                (dialog.view.bounds.size.height - ch) / 2,
                                                                cw, ch)];
        card.backgroundColor = [UIColor whiteColor];
        card.layer.cornerRadius = 16;
        card.clipsToBounds = YES;
        [dialog.view addSubview:card];

        // 红色警示三角（模拟抖音样式）
        UILabel *icon = [[UILabel alloc] initWithFrame:CGRectMake(0, 18, cw, 32)];
        icon.text = @"⚠️";
        icon.font = [UIFont systemFontOfSize:28];
        icon.textAlignment = NSTextAlignmentCenter;
        [card addSubview:icon];

        // 标题
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 56, cw - 32, 24)];
        title.text = @"测试弹窗";
        title.font = [UIFont boldSystemFontOfSize:17];
        title.textAlignment = NSTextAlignmentCenter;
        [card addSubview:title];

        // 正文
        UILabel *msg = [[UILabel alloc] initWithFrame:CGRectMake(16, 88, cw - 32, 92)];
        msg.text = @"【ViolationAlert测试】人脸识别验证，请完成验证后继续直播。这是一条模拟违规弹窗，用于验证检测链路。";
        msg.font = [UIFont systemFontOfSize:14];
        msg.textColor = [UIColor darkGrayColor];
        msg.numberOfLines = 0;
        msg.textAlignment = NSTextAlignmentCenter;
        [card addSubview:msg];

        // 分隔线
        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, ch - 51, cw, 0.5)];
        line.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1];
        [card addSubview:line];

        // 按钮
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(0, ch - 50, cw, 50);
        [btn setTitle:@"知道了" forState:UIControlStateNormal];
        [btn.titleLabel setFont:[UIFont systemFontOfSize:16]];
        [btn addTarget:self action:@selector(dismissTestDialog:) forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:btn];

        [top presentViewController:dialog animated:YES completion:nil];
        NSLog(@"[ViolationAlert] ✅ 已弹出测试弹窗（抖音风格自定义样式）");
    });
}

@end

// ============ Hook 点 ============

// 主力：所有 present 出来的 VC
%hook UIViewController

- (void)presentViewController:(UIViewController *)viewControllerToPresent animated:(BOOL)flag completion:(void (^)(void))completion {
    %orig;
    if (viewControllerToPresent) {
        [[ViolationAlertHelper shared] checkPresentedVC:viewControllerToPresent];
    }
}

%end

// 原生弹窗双保险
%hook UIAlertController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[ViolationAlertHelper shared] checkAlert:self];
}

%end

// v0.2.0 消息探针：拦截直播 IM 消息分发（评论/礼物/下单/系统消息全走这里）
%hook IESLiveIMMessageDispatcher

- (void)dispatchMessage:(id)message {
    %orig;
    // v0.3.0 正式采集：识别消息类型上报服务器
    [[ViolationAlertHelper shared] handleLiveMessage:message];
}

- (void)didRecieveMessages:(id)messages {
    %orig;
    // 批量消息，逐个采集
    if ([messages isKindOfClass:[NSArray class]]) {
        for (id m in (NSArray *)messages) {
            [[ViolationAlertHelper shared] handleLiveMessage:m];
        }
    } else {
        [[ViolationAlertHelper shared] handleLiveMessage:messages];
    }
}

%end

%ctor {
    NSLog(@"[ViolationAlert] ===== v0.3.0 已加载 (bundle: %@) =====", [[NSBundle mainBundle] bundleIdentifier]);
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    // v0.0.6：默认实战模式。没有 plist 或没 test_mode 字段 → test_mode=NO（不弹测试窗）
    if (!cfg || ![cfg objectForKey:@"test_mode"]) {
        gTestMode = NO;
        NSLog(@"[ViolationAlert] 🔧 无配置或未设置test_mode → 默认实战模式");
    } else {
        gTestMode = [cfg[@"test_mode"] boolValue];
    }

    NSString *deviceId = cfg[@"device_id"];
    if (![deviceId isKindOfClass:[NSString class]] || !deviceId.length) {
        deviceId = kDefaultDeviceId;
    }
    // v0.0.7 侦察模式（plist scout_mode=true 开启）
    // v0.0.8：无 plist 或未设置 scout_mode → 默认开启侦察（方便零配置直接采集）
    if (!cfg || ![cfg objectForKey:@"scout_mode"]) {
        gScoutMode = YES;
        NSLog(@"[ViolationAlert] 🔧 无配置或未设置scout_mode → 默认开启侦察模式");
    } else {
        gScoutMode = [cfg[@"scout_mode"] boolValue];
    }
    NSLog(@"[ViolationAlert] 配置: test_mode=%d scout_mode=%d device_id=%@", gTestMode, gScoutMode, deviceId);

    // 启动兜底轮询
    [[ViolationAlertHelper shared] startPolling];

    if (gScoutMode) {
        // 侦察：等页面就绪后 dump 层级 + 找 WebView + 枚举类名（v0.1.0）
        for (int i = 0; i < 12; i++) {
            double delay = 8.0 + i * 25.0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[ViolationAlertHelper shared] dumpHierarchy];
                [[ViolationAlertHelper shared] findWebViews];
                if (i == 1) {
                    // 第二次采样时枚举一次运行时类名（类全集，较重）
                    [[ViolationAlertHelper shared] enumerateClasses];
                    // v0.1.1：同批次枚举核心消息类方法签名
                    [[ViolationAlertHelper shared] enumerateMethods];
                }
            });
        }
    }

    if (gTestMode) {
        // 多次尝试弹测试窗（抖音界面就绪需要时间）
        for (int i = 0; i < 5; i++) {
            double delay = 3.0 + i * 5.0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[ViolationAlertHelper shared] showTestAlert];
            });
        }
    }
}
