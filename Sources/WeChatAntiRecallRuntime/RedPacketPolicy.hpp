#pragma once
#include <cstdint>
#include <string>
#include <unordered_map>

namespace red_packet {
constexpr std::size_t maximumPending = 32;
constexpr std::size_t maximumSeen = 1024;
constexpr uint64_t maximumAge = 60;

inline bool fresh(uint64_t created, uint64_t activated, uint64_t now) {
    return created != 0 && created >= activated && created <= now && now - created <= maximumAge;
}

// Keep entries longer than the acceptance window. When full, refuse new work;
// evicting a fresh ID would permit duplicate transactions during a message flood.
class Ledger {
public:
    bool reserve(const std::string &id, uint64_t now) {
        for (auto it = seen.begin(); it != seen.end();) {
            if (it->second < now && now - it->second > maximumAge * 2) it = seen.erase(it);
            else ++it;
        }
        if (id.empty() || seen.size() >= maximumSeen) return false;
        return seen.emplace(id, now).second;
    }
private:
    std::unordered_map<std::string, uint64_t> seen;
};

enum class Stage { queued, receiving, opening, finished };
class AttemptState {
public:
    Stage stage = Stage::queued;
    bool beginReceive() {
        if (stage != Stage::queued) return false;
        stage = Stage::receiving;
        return true;
    }
    bool beginOpen() {
        if (stage != Stage::receiving) return false;
        stage = Stage::opening;
        return true;
    }
    bool finish() {
        if (stage == Stage::finished) return false;
        stage = Stage::finished;
        return true;
    }
};
}
