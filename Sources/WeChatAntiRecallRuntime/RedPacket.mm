#import <Foundation/Foundation.h>
#include <atomic>
#include <cstring>
#include <ctime>
#include <deque>
#include <dlfcn.h>
#include <functional>
#include <memory>
#include <optional>
#include <os/log.h>
#include "RedPacketInternal.h"
#include "RedPacketPolicy.hpp"
#include "WeChatAntiRecallRuntime.h"

@interface ARPacketXML : NSObject <NSXMLParserDelegate>
@property(retain) NSMutableArray<NSString *> *path;
@property(retain) NSMutableDictionary<NSString *, NSString *> *values;
@property(copy) NSString *active;
@property(retain) NSMutableString *text;
@property BOOL invalid;
@end

@implementation ARPacketXML
- (instancetype)init {
    if ((self = [super init])) {
        self.path = [NSMutableArray array];
        self.values = [NSMutableDictionary dictionary];
    }
    return self;
}
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)qualified attributes:(NSDictionary *)attributes {
    if (self.active || self.path.count >= 32) { self.invalid = YES; [parser abortParsing]; return; }
    [self.path addObject:name];
    NSString *path = [self.path componentsJoinedByString:@"/"];
    if ([path hasPrefix:@"msg/"]) path = [path substringFromIndex:4];
    NSString *key = nil;
    if ([path isEqualToString:@"appmsg/type"]) key = @"type";
    if ([path isEqualToString:@"appmsg/wcpayinfo/nativeurl"]) key = @"url";
    if ([path isEqualToString:@"appmsg/fromusername"] || [path isEqualToString:@"fromusername"]) key = @"sender";
    if (key) {
        if (self.values[key]) { self.invalid = YES; [parser abortParsing]; return; }
        self.active = key;
        self.text = [NSMutableString string];
    }
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)text {
    if (!self.active) return;
    if (self.text.length + text.length > 8192) { self.invalid = YES; [parser abortParsing]; return; }
    [self.text appendString:text];
}
- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)data {
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) { self.invalid = YES; [parser abortParsing]; return; }
    [self parser:parser foundCharacters:text];
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified {
    if (self.active) {
        self.values[self.active] = [self.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        self.active = nil;
        self.text = nil;
    }
    [self.path removeLastObject];
}
@end

namespace red_packet {
struct Packet { std::string id, sender; };

std::optional<Packet> parse(const std::string &raw) {
    if (raw.empty() || raw.size() > 65536 || raw.find('\0') != std::string::npos ||
        raw.find("<!DOCTYPE") != std::string::npos || raw.find("<!ENTITY") != std::string::npos) return {};
    @autoreleasepool {
        std::string xml = raw, prefix;
        // Group messages carry the actual sender before the XML document.
        auto split = xml.find(":\n");
        if (split != std::string::npos && split < 256 && xml.find('<') > split) {
            prefix = xml.substr(0, split);
            xml.erase(0, split + 2);
        }
        NSData *data = [NSData dataWithBytes:xml.data() length:xml.size()];
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
        ARPacketXML *collector = [[ARPacketXML alloc] init];
        parser.delegate = collector;
        parser.shouldResolveExternalEntities = NO;
        if (![parser parse] || collector.invalid || ![collector.values[@"type"] isEqualToString:@"2001"]) return {};
        NSURLComponents *url = [NSURLComponents componentsWithString:collector.values[@"url"] ?: @""];
        if (![url.scheme isEqualToString:@"wxpay"] || ![url.host isEqualToString:@"c2cbizmessagehandler"] ||
            ![url.path isEqualToString:@"/hongbao/receivehongbao"] || url.user || url.password || url.port || url.fragment) return {};
        NSMutableDictionary *query = [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in url.queryItems) {
            if (query[item.name] || !item.value) return {};
            query[item.name] = item.value;
        }
        NSString *sendID = query[@"sendid"], *channel = query[@"channelid"];
        NSCharacterSet *digits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
        if (!sendID.length || sendID.length > 256 || !channel.length || channel.length > 8 ||
            [sendID rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound ||
            [channel rangeOfCharacterFromSet:digits.invertedSet].location != NSNotFound ||
            ![query[@"msgtype"] isEqualToString:@"1"]) return {};
        std::string sender = [collector.values[@"sender"] UTF8String] ?: "";
        if (!prefix.empty()) {
            if (!sender.empty() && sender != prefix) return {};
            sender = prefix;
        }
        return Packet{sendID.UTF8String, sender};
    }
}

bool canOpen(int retcode, bool sender, int received, int status, int type, bool hasTiming) {
    // PayRedEnvelopeCoverViewModel, build 269624, sub_126FAE4.
    return retcode == 0 && !sender && received == 0 && (status == 2 || status == 3) &&
        (type == 0 || type == 1 || type == 3) && hasTiming;
}

struct Settings { bool enabled = false; int delay = 500; };
Settings settings() {
    @autoreleasepool {
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        if (!bundle.length) return {};
        NSArray *paths = @[
            [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Preferences/%@.plist", bundle]],
            [NSHomeDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"Library/Containers/%@/Data/Library/Preferences/%@.plist", bundle, bundle]]
        ];
        for (NSString *path in paths) {
            id value = [NSDictionary dictionaryWithContentsOfFile:path][@"WeChatAntiRecall_RedPacket"];
            if (!value) continue;
            if (![value isKindOfClass:NSDictionary.class]) return {};
            id enabled = value[@"enabled"], delay = value[@"delayMilliseconds"];
            if (![enabled isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)enabled) != CFBooleanGetTypeID() ||
                ![delay isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)delay) == CFBooleanGetTypeID() ||
                [delay doubleValue] != [delay intValue] || [delay intValue] < 0 || [delay intValue] > 5000) return {};
            return Settings{[enabled boolValue] != NO, [delay intValue]};
        }
        return {};
    }
}

bool readable(const void *p, size_t size) {
    return p && wechat_antirecall_is_address_range_readable(reinterpret_cast<uintptr_t>(p), size);
}
std::optional<std::string> readString(const void *p, size_t limit = 65536) {
    if (!readable(p, 24)) return {};
    const auto *bytes = static_cast<const uint8_t *>(p);
    size_t size = bytes[23];
    const char *data = reinterpret_cast<const char *>(bytes);
    if (size & 128) {
        std::memcpy(&data, bytes, sizeof(data));
        std::memcpy(&size, bytes + 8, sizeof(size));
    } else if (size > 22) return {};
    if (size > limit || (size && !readable(data, size))) return {};
    return size ? std::string(data, size) : std::string();
}
template <class T> T field(const void *p, size_t offset) {
    T value;
    std::memcpy(&value, static_cast<const uint8_t *>(p) + offset, sizeof(T));
    return value;
}

#if defined(__arm64__)
extern "C" void wechat_antirecall_native_sret5(void *, void *, const void *, const void *, const void *, const void *, const void *);
void sret(uintptr_t fn, void *out, const void *a = nullptr, const void *b = nullptr,
          const void *c = nullptr, const void *d = nullptr, const void *e = nullptr) {
    wechat_antirecall_native_sret5(reinterpret_cast<void *>(fn), out, a, b, c, d, e);
}

// These layouts are verified at the caller, factory, subscriber and destructor.
// Do not cast the 632-byte receive Message directly to the 848-byte display model.
struct NativeTask {
    std::function<void(void *)> callable;
    std::weak_ptr<void> weak;
    uintptr_t extra = 0;
};
struct Subscription {
    uint64_t id = 0;
    std::shared_ptr<void> receiver, auxiliary;
};
struct SourceLocation { const char *function; const char *file; int line; uintptr_t pc; };
static_assert(sizeof(std::string) == 24 && sizeof(std::function<void()>) == 32);
static_assert(sizeof(NativeTask) == 56 && offsetof(NativeTask, weak) == 32);
static_assert(sizeof(Subscription) == 40 && offsetof(Subscription, receiver) == 8 && offsetof(Subscription, auxiliary) == 24);
static_assert(sizeof(SourceLocation) == 32);

struct Api {
    uintptr_t slide;
    uintptr_t at(uintptr_t ea) const { return slide + ea; }
    bool valid() const {
        struct Check { uintptr_t ea; uint32_t words[3]; };
        const Check checks[] = {
            {0x494e760,{0xd101c3ff,0xa9035ff8,0xa90457f6}},
            {0x38bc54,{0xa9be4ff4,0xa9017bfd,0x910043fd}},
            {0x4316f84,{0xb002e2e8,0xf9404500,0xd65f03c0}},
            {0x421e59c,{0xd107c3ff,0xa91a67fa,0xa91b5ff8}},
            {0x40dd2cc,{0xf9401c00,0x17ff82cc,0xf9401c00}},
            {0x40dd2d4,{0xf9401c00,0x17ff83c9,0xf9401c00}},
            {0x4ddea0,{0xd10303ff,0xa9085ff8,0xa90957f6}},
            {0x40d65c8,{0xd10503ff,0xa90f67fa,0xa9105ff8}},
            {0x40d5dd8,{0xa9bc6ffc,0xa90157f6,0xa9024ff4}}
        };
        for (const auto &check : checks) {
            auto p = reinterpret_cast<void *>(at(check.ea));
            if (!readable(p, sizeof(check.words)) || std::memcmp(p, check.words, sizeof(check.words))) return false;
        }
        return true;
    }
    void *context() const { return reinterpret_cast<void *(*)()>(at(0x4316f84))(); }
    uintptr_t method(void *object, size_t offset) const {
        if (!readable(object, sizeof(uintptr_t))) return 0;
        const auto table = field<uintptr_t>(object, 0);
        if (!readable(reinterpret_cast<void *>(table + offset), sizeof(uintptr_t))) return 0;
        const auto fn = field<uintptr_t>(reinterpret_cast<void *>(table), offset);
        return fn >= slide + 0x19000 && fn < slide + 0x6d8f06c ? fn : 0;
    }
    std::string account() const {
        void *ctx = context();
        auto fn = method(ctx, 40);
        if (!fn) return {};
        const void *name = reinterpret_cast<const void *(*)(void *)>(fn)(ctx);
        return readString(name, 256).value_or("");
    }
    std::shared_ptr<void> service() const {
        void *ctx = context();
        auto fn = method(ctx, 104);
        if (!fn) return {};
        std::shared_ptr<void> accountContext, center, result;
        sret(fn, &accountContext, ctx);
        fn = method(accountContext.get(), 48);
        if (!fn) return {};
        sret(fn, &center, accountContext.get());
        if (!center) return {};
        uintptr_t descriptor = at(0x97640d0);
        sret(at(0x421e59c), &result, center.get(), &descriptor);
        return result;
    }
    void *response(const std::shared_ptr<void> &value, bool opening) const {
        using Cast = void *(*)(const void *, const void *, const void *, ptrdiff_t);
        static auto cast = reinterpret_cast<Cast>(dlsym(RTLD_DEFAULT, "__dynamic_cast"));
        if (!cast || !readable(value.get(), sizeof(uintptr_t))) return nullptr;
        return cast(value.get(), reinterpret_cast<void *>(at(0x9768eb8)),
                    reinterpret_cast<void *>(at(opening ? 0x99b8db8 : 0x99b8d38)), 0);
    }
};

struct DisplayModel {
    alignas(8) uint8_t bytes[848] = {};
    uintptr_t destroy = 0;
    bool initialized = false;
    ~DisplayModel() { if (initialized) reinterpret_cast<void (*)(void *)>(destroy)(bytes); }
};
struct Attempt {
    Packet packet;
    uint64_t created;
    std::string from, to, account;
    std::shared_ptr<DisplayModel> model;
    std::shared_ptr<void> service;
    Subscription subscription;
    AttemptState state;
};

std::atomic<Api *> activeApi{nullptr};
std::atomic<bool> enabled{false};
std::atomic<uint64_t> activated{0};
std::atomic<size_t> scheduled{0};

// All coordinator state and native service calls stay on the main queue. The
// original service schedules its own network work on WeChat's task queue.
class Engine {
    std::deque<std::shared_ptr<Attempt>> pending;
    std::shared_ptr<Attempt> current;
    Ledger ledger;
    dispatch_source_t timer = nullptr;
public:
    static Engine &shared() { static Engine value; return value; }
    void start() {
        refresh();
        if (timer) return;
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
        dispatch_source_set_event_handler(timer, ^{ Engine::shared().refresh(); });
        dispatch_resume(timer);
    }
    void refresh() {
        const bool next = settings().enabled;
        if (next && !enabled.load()) activated.store(static_cast<uint64_t>(std::time(nullptr)));
        enabled.store(next);
        if (!next) {
            pending.clear();
            if (current) finish(current, "disabled");
        }
    }
    void enqueue(const std::shared_ptr<Attempt> &a) {
        refresh();
        Api *api = activeApi.load();
        const auto now = static_cast<uint64_t>(std::time(nullptr));
        if (!api || !enabled.load() || !fresh(a->created, activated.load(), now) || pending.size() >= maximumPending) return;
        a->account = api->account();
        if (a->account.empty() || a->from.empty() || a->to != a->account ||
            a->from == a->account || a->packet.sender == a->account) return;
        if (!ledger.reserve(a->packet.id, now)) return;
        pending.push_back(a);
        pump();
    }
    bool eligible(const std::shared_ptr<Attempt> &a) {
        Api *api = activeApi.load();
        return api && current == a && settings().enabled && enabled.load() &&
            fresh(a->created, activated.load(), static_cast<uint64_t>(std::time(nullptr))) &&
            api->account() == a->account;
    }
    void pump() {
        if (current || !enabled.load() || pending.empty()) return;
        current = pending.front(); pending.pop_front();
        auto a = current;
        const int delay = settings().delay;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(delay) * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            auto &engine = Engine::shared();
            try {
                if (!engine.eligible(a)) { engine.finish(a, "skipped"); return; }
                if (!a->state.beginReceive()) return;
                a->service = activeApi.load()->service();
                if (!a->service) { engine.finish(a, "service-unavailable"); return; }
                engine.request(a, false, "");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    Engine::shared().finish(a, "timeout");
                });
            } catch (...) { engine.finish(a, "native-error"); }
        });
    }
    void request(const std::shared_ptr<Attempt> &a, bool opening, const std::string &timing) {
        Api *api = activeApi.load();
        NativeTask task;
        sret(api->at(opening ? 0x40dd2d4 : 0x40dd2cc), &task, a->service.get(), a->model->bytes, opening ? &timing : nullptr);
        std::function<void(const std::shared_ptr<void> &)> success = [a, opening](const std::shared_ptr<void> &response) {
            // Retain the reply across the dispatch; the original callback owns it only during this call.
            auto held = response;
            dispatch_async(dispatch_get_main_queue(), ^{ Engine::shared().reply(a, held, opening); });
        };
        std::function<void()> error, complete;
        const SourceLocation location{"WeChatAntiRecallRedPacket", "RedPacket.mm", 1, 0};
        Subscription subscription;
        sret(api->at(0x4ddea0), &subscription, &task, &success, &error, &complete, &location);
        a->subscription = std::move(subscription);
    }
    void reply(const std::shared_ptr<Attempt> &a, const std::shared_ptr<void> &value, bool opening) {
        if (a->state.stage != (opening ? Stage::opening : Stage::receiving)) return;
        try {
            if (!eligible(a)) { finish(a, "skipped"); return; }
            Api *api = activeApi.load();
            void *result = api->response(value, opening);
            if (!readable(result, opening ? 184 : 328)) { finish(a, "unexpected-response"); return; }
            const int code = field<int>(result, 8);
            auto sendID = readString(static_cast<uint8_t *>(result) + 40, 256);
            if (!sendID || *sendID != a->packet.id) { finish(a, "mismatched-response"); return; }
            if (opening) {
                finish(a, code == 0 && field<int>(result, 120) == 2 ? "received" : "not-received");
                return;
            }
            auto timing = readString(static_cast<uint8_t *>(result) + 304, 4096);
            if (!canOpen(code, field<uint8_t>(result, 88) != 0, field<int>(result, 120),
                         field<int>(result, 124), field<int>(result, 152), timing && !timing->empty())) {
                finish(a, "unavailable"); return;
            }
            if (!a->state.beginOpen()) return;
            request(a, true, *timing);
        } catch (...) { finish(a, "native-error"); }
    }
    void finish(std::shared_ptr<Attempt> a, const char *status) {
        if (!a || !a->state.finish()) return;
        a->subscription = {};
        // Do not log account names, message contents, native URLs or timing credentials.
        os_log_info(OS_LOG_DEFAULT, "[WeChatAntiRecall] red-packet: %{public}s", status);
        if (current == a) {
            current.reset();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Engine::shared().pump(); });
        }
    }
};
#endif
}

void wechat_antirecall_red_packet_initialize(uintptr_t slide, const char *build) {
#if defined(__arm64__)
    if (!build || std::strcmp(build, "269624") || red_packet::activeApi.load()) return;
    auto api = std::make_unique<red_packet::Api>(); api->slide = slide;
    if (!api->valid()) {
        os_log_error(OS_LOG_DEFAULT, "[WeChatAntiRecall] red-packet: binary profile mismatch");
        return;
    }
    red_packet::activeApi.store(api.release());
    dispatch_async(dispatch_get_main_queue(), ^{ red_packet::Engine::shared().start(); });
#endif
}

void wechat_antirecall_red_packet_observe(void *message, int mode) {
#if defined(__arm64__)
    using namespace red_packet;
    Api *api = activeApi.load();
    if (!api || !enabled.load() || mode != 1 || !readable(message, 632) ||
        field<uintptr_t>(message, 0) != api->at(0x99eb1a0) || field<uint32_t>(message, 12) != 49) return;
    const auto created = field<uint32_t>(message, 276);
    if (!fresh(created, activated.load(), static_cast<uint64_t>(std::time(nullptr)))) return;
    bool reserved = false;
    try {
        auto raw = readString(static_cast<uint8_t *>(message) + 304);
        auto from = readString(static_cast<uint8_t *>(message) + 24, 256);
        auto to = readString(static_cast<uint8_t *>(message) + 48, 256);
        if (!raw || !from || !to) return;
        auto packet = parse(*raw);
        if (!packet) return;
        if (scheduled.fetch_add(1) >= maximumPending) { scheduled.fetch_sub(1); return; }
        reserved = true;
        auto a = std::make_shared<Attempt>();
        a->packet = std::move(*packet); a->created = created; a->from = *from; a->to = *to;
        a->model = std::make_shared<DisplayModel>();
        a->model->destroy = api->at(0x38bc54);
        sret(api->at(0x494e760), a->model->bytes, message);
        a->model->initialized = true;
        dispatch_async(dispatch_get_main_queue(), ^{
            scheduled.fetch_sub(1);
            try { Engine::shared().enqueue(a); }
            catch (...) { os_log_error(OS_LOG_DEFAULT, "[WeChatAntiRecall] red-packet: enqueue failed"); }
        });
    } catch (...) {
        if (reserved) scheduled.fetch_sub(1);
        os_log_error(OS_LOG_DEFAULT, "[WeChatAntiRecall] red-packet: message conversion failed");
    }
#endif
}

#if defined(__arm64__)
namespace {
red_packet::NativeTask fakePacketFactory(const std::shared_ptr<int> *owner, int *calls,
                                        const int *a, const int *b, const int *c) {
    red_packet::NativeTask task;
    auto held = *owner;
    const int sum = *a + *b + *c;
    task.callable = [held, calls, sum](void *) { *calls += *held + sum; };
    task.weak = held;
    task.extra = 0x12345678;
    return task;
}
red_packet::Subscription fakePacketSubscribe(red_packet::NativeTask *task,
        std::function<void(const std::shared_ptr<void> &)> *success,
        std::function<void()> *error, std::function<void()> *complete,
        const red_packet::SourceLocation *location) {
    red_packet::Subscription result;
    result.id = location->line;
    result.receiver = task->weak.lock();
    if (location->pc != 0x55 || std::strcmp(location->function, "offline") || std::strcmp(location->file, "fixture")) {
        (*error)();
        return result;
    }
    task->callable(nullptr);
    (*success)(result.receiver);
    (*complete)();
    return result;
}
}
#endif

extern "C" {
const char *wechat_antirecall_red_packet_runtime_version(void) {
    return "WeChatAntiRecallRedPacket:269624:1";
}
int wechat_antirecall_red_packet_parse(const char *xml) {
    return xml && red_packet::parse(xml).has_value();
}
int wechat_antirecall_red_packet_can_open(int code, int sender, int received, int status, int type, const char *timing) {
    return red_packet::canOpen(code, sender != 0, received, status, type, timing && *timing);
}
int wechat_antirecall_red_packet_fresh(uint64_t created, uint64_t activated, uint64_t now) {
    return red_packet::fresh(created, activated, now);
}
int wechat_antirecall_red_packet_policy_selftest(void) {
    using namespace red_packet;
    Ledger ledger;
    if (!ledger.reserve("one", 100) || ledger.reserve("one", 101) || ledger.reserve("one", 220)) return 0;
    for (size_t n = 1; n < maximumSeen; ++n) if (!ledger.reserve(std::to_string(n), 100)) return 0;
    if (ledger.reserve("overflow", 101) || !ledger.reserve("one", 221)) return 0;
    AttemptState state;
    if (state.beginOpen() || !state.beginReceive() || state.beginReceive() || !state.beginOpen() || state.beginOpen()) return 0;
    if (!state.finish() || state.finish() || state.beginOpen()) return 0;
    AttemptState timedOut;
    if (!timedOut.beginReceive() || !timedOut.finish() || timedOut.beginOpen()) return 0;
    return 1;
}
int wechat_antirecall_red_packet_native_abi_selftest(void) {
#if defined(__arm64__)
    using namespace red_packet;
    auto owner = std::make_shared<int>(7);
    std::weak_ptr<int> weak = owner;
    int calls = 0, successCalls = 0, errors = 0, completions = 0;
    int a = 11, b = 13, c = 17;
    {
        NativeTask task;
        sret(reinterpret_cast<uintptr_t>(&fakePacketFactory), &task, &owner, &calls, &a, &b, &c);
        if (task.extra != 0x12345678 || task.weak.expired()) return 0;
        owner.reset();
        std::function<void(const std::shared_ptr<void> &)> success = [&](const std::shared_ptr<void> &value) {
            if (value && *static_cast<int *>(value.get()) == 7) ++successCalls;
        };
        std::function<void()> error = [&] { ++errors; }, complete = [&] { ++completions; };
        SourceLocation location{"offline", "fixture", 42, 0x55};
        Subscription sub;
        sret(reinterpret_cast<uintptr_t>(&fakePacketSubscribe), &sub, &task, &success, &error, &complete, &location);
        if (sub.id != 42 || !sub.receiver || calls != 48 || successCalls != 1 || completions != 1 || errors) return 0;
    }
    return weak.expired() ? 1 : 0;
#else
    return 0;
#endif
}
}
