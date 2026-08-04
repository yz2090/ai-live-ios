#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

// ============================================================
// 违规弹窗检测 Tweak（Dopamine 越狱）v0.0.2
// 功能：Hook UIAlertController，检测到违规/人脸识别等弹窗
//       → POST 到服务器 /api/violation_report → Bark 推送
// 配置：/var/mobile/Library/Preferences/com.ailive.violationalert.plist
// 日志：/var/mobile/violationalert.log（用「文件」App 即可查看）
// ============================================================

static NSString *kPrefsPath = @"/var/mobile/Library/Preferences/com.ailive.violationalert.plist";
static NSString *kLogPath = @"/var/mobile/violationalert.log";
static BOOL gTestMode = NO;
static BOOL gTestAlertShown = NO;

// 写日志（追加）
static void LogToFile(NSString *msg) {
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:kLogPath contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    }
    if (fh) {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
            [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterMediumStyle],
            msg];
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    NSLog(@"[ViolationAlert] %@", msg);
}

@interface ViolationAlertHelper : NSObject
+ (instancetype)shared;
- (void)checkAlert:(UIAlertController *)alert;
- (void)showTestAlert;
- (UIViewController *)topViewController;
@end

@implementation ViolationAlertHelper

+ (instancetype)shared {
    static ViolationAlertHelper *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[ViolationAlertHelper alloc] init];
    });
    return inst;
}

// 读取配置
- (NSDictionary *)loadConfig {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    if (!cfg) cfg = @{};
    return cfg;
}

// 关键词匹配（命中任意一个即报警）
- (BOOL)matchKeyword:(NSString *)text {
    NSArray *defaultKeywords = @[
        @"人脸识别", @"人脸验证", @"身份验证", @"实名认证",
        @"违规", @"违规内容", @"涉嫌违规", @"违反",
        @"警告", @"提醒", @"封禁", @"禁播", @"限流",
        @"直播中断", @"直播异常", @"直播已结束",
        @"安全验证", @"验证码", @"异常登录", @"账号异常",
        @"未成年人", @"青少年模式", @"低俗", @"涉黄", @"涉政",
        @"停止直播", @"暂时无法", @"操作频繁"
    ];
    NSDictionary *cfg = [self loadConfig];
    NSArray *keywords = cfg[@"keywords"];
    if (![keywords isKindOfClass:[NSArray class]] || keywords.count == 0) {
        keywords = defaultKeywords;
    }
    for (NSString *kw in keywords) {
        if ([kw isKindOfClass:[NSString class]] && [text containsString:kw]) return YES;
    }
    return NO;
}

// 上报到服务器
- (void)reportToServer:(NSString *)text app:(NSString *)app {
    NSDictionary *cfg = [self loadConfig];
    NSString *deviceId = cfg[@"device_id"] ?: @"";
    NSString *server = cfg[@"server"] ?: @"http://59.110.152.66:18766";
    if (!deviceId.length) {
        LogToFile(@"⚠️ 未配置 device_id，跳过上报（请检查 plist）");
        return;
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
        LogToFile([NSString stringWithFormat:@"⚠️ JSON序列化失败: %@", err]);
        return;
    }
    req.HTTPBody = jsonData;
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) {
            LogToFile([NSString stringWithFormat:@"❌ 上报失败: %@", error.localizedDescription]);
        } else {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)resp;
            LogToFile([NSString stringWithFormat:@"✅ 上报成功 HTTP %ld: %@", (long)httpResp.statusCode, text]);
        }
    }];
    [task resume];
}

// 检测弹窗（入口）
- (void)checkAlert:(UIAlertController *)alert {
    NSString *title = alert.title ?: @"";
    NSString *message = alert.message ?: @"";
    NSString *full = [NSString stringWithFormat:@"%@ %@", title, message];
    full = [full stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!full.length) return;

    if (gTestMode) {
        LogToFile([NSString stringWithFormat:@"[测试模式] 捕获弹窗: %@", full]);
        NSString *appName = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        [self reportToServer:full app:appName];
        return;
    }

    if ([self matchKeyword:full]) {
        LogToFile([NSString stringWithFormat:@"🚨 检测到违规弹窗: %@", full]);
        NSString *appName = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        [self reportToServer:full app:appName];
    }
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
    UIViewController *top = keyWindow.rootViewController;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    return top;
}

// 测试模式：自动弹一个模拟违规弹窗（验证全链路）
- (void)showTestAlert {
    if (gTestAlertShown) return;
    gTestAlertShown = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (!top) {
            LogToFile(@"❌ 测试弹窗失败：找不到顶层控制器");
            return;
        }
        UIAlertController *testAlert = [UIAlertController alertControllerWithTitle:@"测试弹窗"
                                                                          message:@"【ViolationAlert测试】人脸识别验证，请完成验证后继续直播。这是一条模拟违规弹窗，用于验证检测链路。"
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [testAlert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [top presentViewController:testAlert animated:YES completion:nil];
        LogToFile(@"✅ 已弹出测试弹窗");
    });
}

@end

// ============ Hook 点 ============

%hook UIAlertController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [[ViolationAlertHelper shared] checkAlert:self];
}

%end

%ctor {
    LogToFile(@"===== ViolationAlert v0.0.2 已加载 =====");
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kPrefsPath];
    gTestMode = [cfg[@"test_mode"] boolValue];
    NSString *deviceId = cfg[@"device_id"] ?: @"";
    LogToFile([NSString stringWithFormat:@"配置: test_mode=%d device_id=%@",
        gTestMode, deviceId.length ? deviceId : @"(未设置!)"]);

    if (gTestMode) {
        // 监听 App 激活后再弹（更可靠），多次尝试
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[ViolationAlertHelper shared] showTestAlert];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gTestAlertShown) [[ViolationAlertHelper shared] showTestAlert];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gTestAlertShown) [[ViolationAlertHelper shared] showTestAlert];
        });
    }
}
