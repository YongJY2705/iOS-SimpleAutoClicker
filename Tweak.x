#import <UIKit/UIKit.h>
#include <dlfcn.h>
#import <objc/runtime.h>
#import "ZSFakeTouch/ZSFakeTouchDome/ZSFakeTouch/ZSFakeTouch.h"

// --- Mô hình dữ liệu cho 10 điểm bấm ---
@interface TapPointModel : NSObject
@property (nonatomic, assign) BOOL isEnabled;
@property (nonatomic, assign) CGFloat x;
@property (nonatomic, assign) CGFloat y;
@property (nonatomic, assign) CGFloat interval;       // khoảng cách giữa các lần bấm của điểm này (giây)
@property (nonatomic, assign) CGFloat duration;       // thời gian điểm này hoạt động; hết thì sang điểm tiếp theo (giây)
@property (nonatomic, strong) UIView *indicatorView;  // chấm đỏ hiển thị trên màn hình

- (NSDictionary *)toDictionary;
- (void)updateWithDictionary:(NSDictionary *)dict;
@end

@implementation TapPointModel
- (instancetype)init {
    self = [super init];
    if (self) {
        _interval = 0.3;
        _duration = 0.3;
    }
    return self;
}

- (NSDictionary *)toDictionary {
    return @{
        @"isEnabled": @(self.isEnabled),
        @"x": @(self.x),
        @"y": @(self.y),
        @"interval": @(self.interval),
        @"duration": @(self.duration)
    };
}

- (void)updateWithDictionary:(NSDictionary *)dict {
    if (!dict) return;
    self.isEnabled = [dict[@"isEnabled"] boolValue];
    self.x = [dict[@"x"] floatValue];
    self.y = [dict[@"y"] floatValue];
    if (dict[@"interval"]) {
        self.interval = [dict[@"interval"] floatValue];
    }
    if (dict[@"duration"]) {
        self.duration = [dict[@"duration"] floatValue];
    } else if (dict[@"delay"]) { // tương thích bản cũ
        self.duration = [dict[@"delay"] floatValue];
    }
}
@end

@interface FloatingOverlayWindow : UIWindow
@end

@implementation FloatingOverlayWindow
// Vùng trống thì cho chạm xuyên xuống app bên dưới
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self) {
        return nil;
    }
    return hitView;
}

- (BOOL)_canAffectStatusBarAppearance {
    return NO;
}
@end

@interface AutoClickerManager : NSObject
@property (nonatomic, strong) FloatingOverlayWindow *overlayWindow;
@property (nonatomic, strong) UIView *controlBar;       // thanh điều khiển nổi
@property (nonatomic, strong) UIView *settingsPanel;    // bảng cài đặt
@property (nonatomic, strong) UIButton *toggleBtn;      // nút chạy / dừng
@property (nonatomic, strong) UILabel *intervalLbl;
@property (nonatomic, strong) NSMutableArray<UISlider *> *xSliders;
@property (nonatomic, strong) NSMutableArray<UISlider *> *ySliders;
@property (nonatomic, strong) NSMutableArray<UILabel *> *intervalLabels;
@property (nonatomic, strong) NSMutableArray<UILabel *> *durationLabels;
@property (nonatomic, strong) NSMutableArray<TapPointModel *> *points;
@property (nonatomic, assign) CGFloat clickInterval;    // nghỉ giữa các vòng (giây)
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, assign) NSUInteger runToken;      // dùng để huỷ chuỗi đang chờ khi dừng
+ (instancetype)sharedInstance;
- (void)setupUI;
@end

@implementation AutoClickerManager

+ (instancetype)sharedInstance {
    static AutoClickerManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AutoClickerManager alloc] init];
    });
    return instance;
}

- (NSString *)settingsKeyForCurrentApp {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID) bundleID = @"unknown_app";
    return [NSString stringWithFormat:@"AutoClicker_Settings_%@", bundleID];
}

// Lưu cài đặt
- (void)saveSettings {
    NSMutableArray *pointsArray = [NSMutableArray array];
    for (TapPointModel *model in self.points) {
        [pointsArray addObject:[model toDictionary]];
    }

    NSDictionary *settings = @{
        @"clickInterval": @(self.clickInterval),
        @"points": pointsArray
    };

    [[NSUserDefaults standardUserDefaults] setObject:settings forKey:[self settingsKeyForCurrentApp]];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Đọc cài đặt
- (void)loadSettings {
    NSDictionary *settings = [[NSUserDefaults standardUserDefaults] dictionaryForKey:[self settingsKeyForCurrentApp]];

    if (settings) {
        if (settings[@"clickInterval"]) {
            self.clickInterval = [settings[@"clickInterval"] floatValue];
        }

        NSArray *pointsArray = settings[@"points"];
        if (pointsArray && pointsArray.count == 10) {
            for (int i = 0; i < 10; i++) {
                [self.points[i] updateWithDictionary:pointsArray[i]];
            }
        }
    } else {
        self.clickInterval = 0.1;
        CGSize screenSize = [UIScreen mainScreen].bounds.size;
        for (int i = 0; i < 10; i++) {
            self.points[i].isEnabled = NO;
            self.points[i].x = screenSize.width / 2;
            self.points[i].y = screenSize.height / 2;
            self.points[i].interval = 0.3;
            self.points[i].duration = 0.3;
        }
    }
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _clickInterval = 0.1;
        _points = [NSMutableArray array];
        for (int i = 0; i < 10; i++) {
            [_points addObject:[[TapPointModel alloc] init]];
        }
        [self loadSettings];
    }
    return self;
}

- (void)setupUI {
    if (self.overlayWindow) return;
    self.xSliders = [NSMutableArray arrayWithCapacity:10];
    self.ySliders = [NSMutableArray arrayWithCapacity:10];
    self.intervalLabels = [NSMutableArray arrayWithCapacity:10];
    self.durationLabels = [NSMutableArray arrayWithCapacity:10];

    CGSize screenSize = [UIScreen mainScreen].bounds.size;

    // 1. Cửa sổ nổi cho chạm xuyên qua
    self.overlayWindow = [[FloatingOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 2;
    self.overlayWindow.hidden = NO;
    self.overlayWindow.backgroundColor = [UIColor clearColor];

    // 2. Chấm đỏ chỉ vị trí các điểm (ẩn khi điểm chưa bật)
    for (int i = 0; i < 10; i++) {
        TapPointModel *model = self.points[i];
        UIView *indicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 20, 20)];
        indicator.backgroundColor = [[UIColor redColor] colorWithAlphaComponent:0.6];
        indicator.layer.cornerRadius = 10;
        indicator.center = CGPointMake(model.x, model.y);
        indicator.hidden = !model.isEnabled;
        indicator.userInteractionEnabled = NO;

        UILabel *numLbl = [[UILabel alloc] initWithFrame:indicator.bounds];
        numLbl.text = [NSString stringWithFormat:@"%d", i+1];
        numLbl.textColor = [UIColor whiteColor];
        numLbl.textAlignment = NSTextAlignmentCenter;
        numLbl.font = [UIFont boldSystemFontOfSize:12];
        [indicator addSubview:numLbl];

        [self.overlayWindow addSubview:indicator];
        model.indicatorView = indicator;
    }

    CGFloat panelMaxWidth = MIN(screenSize.width - 40, 350);
    CGFloat panelMaxHeight = MIN(screenSize.height - 80, 650);

    // 3. Bảng cài đặt (mặc định ẩn)
    self.settingsPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelMaxWidth, panelMaxHeight)];
    self.settingsPanel.center = self.overlayWindow.center;
    self.settingsPanel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.5];
    self.settingsPanel.layer.cornerRadius = 15;
    self.settingsPanel.hidden = YES;
    self.settingsPanel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                          UIViewAutoresizingFlexibleRightMargin |
                                          UIViewAutoresizingFlexibleTopMargin |
                                          UIViewAutoresizingFlexibleBottomMargin;
    [self.overlayWindow addSubview:self.settingsPanel];

    UIScrollView *scrollView = [[UIScrollView alloc] initWithFrame:self.settingsPanel.bounds];
    scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.settingsPanel addSubview:scrollView];

    CGFloat currentY = 20;

    // Nghỉ giữa các vòng (chỉnh bằng các nút -10 -1 -0.1 +0.1 +1 +10)
    self.intervalLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, scrollView.frame.size.width - 40, 30)];
    self.intervalLbl.text = [NSString stringWithFormat:@"Nghỉ giữa các vòng: %.2f s", self.clickInterval];
    self.intervalLbl.textColor = [UIColor whiteColor];
    self.intervalLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [scrollView addSubview:self.intervalLbl];

    [scrollView addSubview:[self makeStepRowWithBaseTag:900
                                                  frame:CGRectMake(20, currentY + 30, scrollView.frame.size.width - 40, 30)]];

    currentY += 80;

    // Cài đặt cho 10 điểm
    for (int i = 0; i < 10; i++) {
        UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, 100, 30)];
        titleLbl.text = [NSString stringWithFormat:@"Điểm %d", i+1];
        titleLbl.textColor = [UIColor whiteColor];
        titleLbl.font = [UIFont boldSystemFontOfSize:16];
        [scrollView addSubview:titleLbl];

        UISwitch *enableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(120, currentY, 50, 30)];
        enableSwitch.tag = i;
        enableSwitch.on = self.points[i].isEnabled;
        [enableSwitch addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [scrollView addSubview:enableSwitch];

        currentY += 40;

        // Nhãn X
        UILabel *xLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, 30, 30)];
        xLbl.text = @"X";
        xLbl.textColor = [UIColor whiteColor];
        xLbl.font = [UIFont boldSystemFontOfSize:16];
        [scrollView addSubview:xLbl];

        // Thanh X
        UISlider *xSlider = [[UISlider alloc] initWithFrame:CGRectMake(20 + 30, currentY, scrollView.frame.size.width - 40 - 30, 30)];
        xSlider.minimumValue = 0;
        xSlider.maximumValue = screenSize.width;
        xSlider.value = self.points[i].x;
        xSlider.tag = 100 + i;
        xSlider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [xSlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [scrollView addSubview:xSlider];
        [self.xSliders addObject:xSlider];

        currentY += 40;

        // Nhãn Y
        UILabel *yLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, 30, 30)];
        yLbl.text = @"Y";
        yLbl.textColor = [UIColor whiteColor];
        yLbl.font = [UIFont boldSystemFontOfSize:16];
        [scrollView addSubview:yLbl];

        // Thanh Y
        UISlider *ySlider = [[UISlider alloc] initWithFrame:CGRectMake(20 + 30, currentY, scrollView.frame.size.width - 40 - 30, 30)];
        ySlider.minimumValue = 0;
        ySlider.maximumValue = screenSize.height;
        ySlider.value = self.points[i].y;
        ySlider.tag = 200 + i;
        ySlider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [ySlider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [scrollView addSubview:ySlider];
        [self.ySliders addObject:ySlider];

        currentY += 40;

        // Khoảng cách giữa các lần bấm của chính điểm này
        UILabel *intervalPtLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, scrollView.frame.size.width - 40, 24)];
        intervalPtLbl.text = [NSString stringWithFormat:@"Bấm lặp mỗi: %.2f s", self.points[i].interval];
        intervalPtLbl.textColor = [UIColor whiteColor];
        intervalPtLbl.font = [UIFont systemFontOfSize:14];
        intervalPtLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [scrollView addSubview:intervalPtLbl];
        [self.intervalLabels addObject:intervalPtLbl];

        currentY += 26;

        [scrollView addSubview:[self makeStepRowWithBaseTag:(2000 + i * 10)
                                                      frame:CGRectMake(20, currentY, scrollView.frame.size.width - 40, 30)]];

        currentY += 40;

        // Thời gian điểm này hoạt động (hết thời gian mới sang điểm tiếp theo)
        UILabel *durationLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, currentY, scrollView.frame.size.width - 40, 24)];
        durationLbl.text = [NSString stringWithFormat:@"Chạy trong: %.2f s", self.points[i].duration];
        durationLbl.textColor = [UIColor whiteColor];
        durationLbl.font = [UIFont systemFontOfSize:14];
        durationLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [scrollView addSubview:durationLbl];
        [self.durationLabels addObject:durationLbl];

        currentY += 26;

        [scrollView addSubview:[self makeStepRowWithBaseTag:(1000 + i * 10)
                                                      frame:CGRectMake(20, currentY, scrollView.frame.size.width - 40, 30)]];

        currentY += 40;

        UIView *line = [[UIView alloc] initWithFrame:CGRectMake(10, currentY, scrollView.frame.size.width - 20, 1)];
        line.backgroundColor = [UIColor darkGrayColor];
        line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [scrollView addSubview:line];

        currentY += 20;
    }
    scrollView.contentSize = CGSizeMake(scrollView.frame.size.width, currentY);

    // 4. Thanh điều khiển nổi (nút cài đặt và nút chạy/dừng)
    self.controlBar = [[UIView alloc] initWithFrame:CGRectMake(20, screenSize.height/2, 40, 70)];
    self.controlBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.4];
    self.controlBar.layer.cornerRadius = 20;
    [self.overlayWindow addSubview:self.controlBar];

    // Cử chỉ kéo
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.controlBar addGestureRecognizer:pan];

    // Nút cài đặt
    UIButton *settingsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    settingsBtn.frame = CGRectMake(0, 5, 40, 30);
    [settingsBtn setTitle:@"⚙️" forState:UIControlStateNormal];
    [settingsBtn addTarget:self action:@selector(toggleSettings) forControlEvents:UIControlEventTouchUpInside];
    [self.controlBar addSubview:settingsBtn];

    // Nút chạy / dừng
    self.toggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleBtn.frame = CGRectMake(0, 35, 40, 30);
    [self.toggleBtn setTitle:@"▶️" forState:UIControlStateNormal];
    [self.toggleBtn addTarget:self action:@selector(toggleAutoClick) forControlEvents:UIControlEventTouchUpInside];
    [self.controlBar addSubview:self.toggleBtn];

    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDeviceRotation)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
}

#pragma mark - Tương tác

- (void)handleDeviceRotation {
    if (!self.overlayWindow) return;

    CGSize targetSize = [UIScreen mainScreen].bounds.size;

    self.overlayWindow.frame = CGRectMake(0, 0, targetSize.width, targetSize.height);
    self.settingsPanel.center = self.overlayWindow.center;

    for (int i = 0; i < 10; i++) {
        UISlider *xSlider = self.xSliders[i];
        UISlider *ySlider = self.ySliders[i];

        if (xSlider) xSlider.maximumValue = targetSize.width;
        if (ySlider) ySlider.maximumValue = targetSize.height;

        self.points[i].x = MIN(self.points[i].x, targetSize.width);
        self.points[i].y = MIN(self.points[i].y, targetSize.height);

        if (xSlider) xSlider.value = self.points[i].x;
        if (ySlider) ySlider.value = self.points[i].y;

        self.points[i].indicatorView.center = CGPointMake(self.points[i].x, self.points[i].y);
    }

    [self clampControlBarToScreen];
}

- (void)clampControlBarToScreen {
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat halfWidth = self.controlBar.bounds.size.width / 2.0;
    CGFloat halfHeight = self.controlBar.bounds.size.height / 2.0;
    CGFloat margin = 5.0;

    CGPoint currentCenter = self.controlBar.center;
    currentCenter.x = MAX(halfWidth + margin, MIN(currentCenter.x, screenSize.width - halfWidth - margin));
    currentCenter.y = MAX(halfHeight + 30.0, MIN(currentCenter.y, screenSize.height - halfHeight - 20.0));

    [UIView animateWithDuration:0.3 animations:^{
        self.controlBar.center = currentCenter;
    }];
}

- (void)handlePan:(UIPanGestureRecognizer *)recognizer {
    UIView *panView = recognizer.view;
    CGPoint translation = [recognizer translationInView:self.overlayWindow];

    CGPoint newCenter = CGPointMake(panView.center.x + translation.x,
                                    panView.center.y + translation.y);

    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat halfWidth = panView.bounds.size.width / 2.0;
    CGFloat halfHeight = panView.bounds.size.height / 2.0;

    CGFloat margin = 5.0;

    CGFloat minX = halfWidth + margin;
    CGFloat maxX = screenSize.width - halfWidth - margin;
    CGFloat minY = halfHeight + 30.0;
    CGFloat maxY = screenSize.height - halfHeight - 20.0;

    newCenter.x = MAX(minX, MIN(newCenter.x, maxX));
    newCenter.y = MAX(minY, MIN(newCenter.y, maxY));

    panView.center = newCenter;
    [recognizer setTranslation:CGPointZero inView:self.overlayWindow];
    [self clampControlBarToScreen];
}

- (void)toggleSettings {
    self.settingsPanel.hidden = !self.settingsPanel.hidden;
}

// Tạo một hàng 6 nút: -10, -1, -0.1, +0.1, +1, +10
- (UIStackView *)makeStepRowWithBaseTag:(NSInteger)baseTag frame:(CGRect)frame {
    NSArray<NSString *> *titles = @[@"-10", @"-1", @"-0.1", @"+0.1", @"+1", @"+10"];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (NSInteger k = 0; k < 6; k++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:titles[k] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        b.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];
        b.layer.cornerRadius = 6;
        b.tag = baseTag + k;
        [b addTarget:self action:@selector(stepTapped:) forControlEvents:UIControlEventTouchUpInside];
        [buttons addObject:b];
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 4;
    stack.frame = frame;
    stack.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    return stack;
}

// Bấm nút cộng/trừ thời gian
- (void)stepTapped:(UIButton *)sender {
    static const double steps[6] = {-10.0, -1.0, -0.1, 0.1, 1.0, 10.0};
    NSInteger tag = sender.tag;

    if (tag >= 2000) { // Khoảng cách giữa các lần bấm của từng điểm
        NSInteger code = tag - 2000;
        NSInteger index = code / 10;
        NSInteger k = code % 10;
        if (index < 0 || index >= 10 || k >= 6) return;

        double v = self.points[index].interval + steps[k];
        v = MAX(0.1, MIN(3600.0, round(v * 100.0) / 100.0));
        self.points[index].interval = v;
        self.intervalLabels[index].text = [NSString stringWithFormat:@"Bấm lặp mỗi: %.2f s", v];
    } else if (tag >= 1000) { // Thời gian hoạt động của từng điểm
        NSInteger code = tag - 1000;
        NSInteger index = code / 10;
        NSInteger k = code % 10;
        if (index < 0 || index >= 10 || k >= 6) return;

        double v = self.points[index].duration + steps[k];
        v = MAX(0.0, MIN(3600.0, round(v * 100.0) / 100.0));
        self.points[index].duration = v;
        self.durationLabels[index].text = [NSString stringWithFormat:@"Chạy trong: %.2f s", v];
    } else if (tag >= 900) { // Nghỉ giữa các vòng
        NSInteger k = tag - 900;
        if (k >= 6) return;

        double v = self.clickInterval + steps[k];
        v = MAX(0.05, MIN(3600.0, round(v * 100.0) / 100.0));
        self.clickInterval = v;
        self.intervalLbl.text = [NSString stringWithFormat:@"Nghỉ giữa các vòng: %.2f s", v];
    }

    [self saveSettings];
}

- (void)switchChanged:(UISwitch *)sender {
    NSInteger index = sender.tag;
    self.points[index].isEnabled = sender.isOn;
    self.points[index].indicatorView.hidden = !sender.isOn;

    [self saveSettings];
}

- (void)sliderChanged:(UISlider *)sender {
    NSInteger tag = sender.tag;
    NSInteger index = 0;

    if (tag >= 200) { // Trục Y
        index = tag - 200;
        self.points[index].y = sender.value;
    } else if (tag >= 100) { // Trục X
        index = tag - 100;
        self.points[index].x = sender.value;
    }
    self.points[index].indicatorView.center = CGPointMake(self.points[index].x, self.points[index].y);

    [self saveSettings];
}

#pragma mark - Logic bấm

- (void)toggleAutoClick {
    if (self.isRunning) {
        [self stopClicking];
        [self.toggleBtn setTitle:@"▶️" forState:UIControlStateNormal];
    } else {
        [self startClicking];
        [self.toggleBtn setTitle:@"⏹" forState:UIControlStateNormal];
    }
}

- (void)startClicking {
    if (self.isRunning) return;
    self.isRunning = YES;
    self.runToken++;
    [self runStepWithToken:self.runToken index:0];
}

- (void)stopClicking {
    if (!self.isRunning) return;
    self.isRunning = NO;
    self.runToken++; // huỷ mọi bước đang chờ
}

// Chạy lần lượt từng điểm. Mỗi điểm bấm lặp (cách nhau "Bấm lặp mỗi") trong suốt "Chạy trong",
// hết thời gian đó mới sang điểm tiếp theo. Hết điểm cuối thì nghỉ "giữa các vòng" rồi quay lại điểm đầu.
- (void)runStepWithToken:(NSUInteger)token index:(NSUInteger)index {
    if (!self.isRunning || token != self.runToken) return;

    __weak typeof(self) weakSelf = self;

    // Tìm điểm đang bật tiếp theo
    NSUInteger i = index;
    while (i < self.points.count && !self.points[i].isEnabled) {
        i++;
    }

    // Hết vòng: nghỉ rồi bắt đầu lại
    if (i >= self.points.count) {
        double rest = MAX(self.clickInterval, 0.05);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(rest * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf runStepWithToken:token index:0];
        });
        return;
    }

    [self clickPointAtIndex:i clickNumber:0 start:[NSProcessInfo processInfo].systemUptime token:token];
}

// Bấm lần thứ k của một điểm. Mốc thời gian tính từ lúc điểm bắt đầu nên không bị lệch dần.
- (void)clickPointAtIndex:(NSUInteger)i clickNumber:(NSUInteger)k start:(NSTimeInterval)start token:(NSUInteger)token {
    if (!self.isRunning || token != self.runToken) return;

    TapPointModel *model = self.points[i];
    CGPoint point = CGPointMake(model.x, model.y);
    double interval = MAX(model.interval, 0.1);
    double duration = model.duration;

    __weak typeof(self) weakSelf = self;

    [ZSFakeTouch beginTouchWithPoint:point];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // Luôn nhả touch, kể cả khi vừa bấm dừng, để không bị kẹt
        [ZSFakeTouch endTouchWithPoint:point];

        NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
        double nextOffset = (double)(k + 1) * interval;
        BOOL clickAgain = nextOffset < duration;

        // Còn trong thời gian chạy -> chờ tới lần bấm kế; hết thời gian -> chờ tới hết "Chạy trong"
        double delay = clickAgain ? (start + nextOffset - now) : (start + duration - now);
        if (delay < 0) delay = 0;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (clickAgain) {
                [weakSelf clickPointAtIndex:i clickNumber:k + 1 start:start token:token];
            } else {
                [weakSelf runStepWithToken:token index:i + 1];
            }
        });
    });
}

@end

typedef void (*MSHookMessageEx_t)(Class _class, SEL message, IMP hook, IMP *old);
static MSHookMessageEx_t MSHookMessageEx_p = NULL;

typedef void (*UIWindow_makeKeyAndVisible_t)(id self, SEL _cmd);
static UIWindow_makeKeyAndVisible_t UIWindow_makeKeyAndVisible_p = NULL;

static void makeKeyAndVisible(id self, SEL _cmd) {
    UIWindow_makeKeyAndVisible_p(self, _cmd);

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Đợi 1 giây cho giao diện chính của app hiện xong
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[AutoClickerManager sharedInstance] setupUI];
        });
    });
}

__attribute__((constructor))
static void tweakConstructor() {
    MSHookMessageEx_p = (MSHookMessageEx_t)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (MSHookMessageEx_p) {
        MSHookMessageEx_p(UIWindow.class, @selector(makeKeyAndVisible), (IMP)makeKeyAndVisible, (IMP *)&UIWindow_makeKeyAndVisible_p);
        return;
    }

    // Không có ElleKit/Substrate: hook trực tiếp bằng Objective-C runtime
    Method m = class_getInstanceMethod(UIWindow.class, @selector(makeKeyAndVisible));
    if (m) {
        UIWindow_makeKeyAndVisible_p = (UIWindow_makeKeyAndVisible_t)method_getImplementation(m);
        method_setImplementation(m, (IMP)makeKeyAndVisible);
    }
}
