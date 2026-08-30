// Minimal JSON reader/writer for the tunnel IPC protocol.
//
// The service speaks newline-delimited JSON over a named pipe. Pulling in a
// full JSON library for four message types would add a dependency to a
// privileged process, so this is a small, bounded, allocation-conscious
// implementation. It rejects deeply nested or oversized documents rather than
// trying to be generic.

#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace gluk::json {

constexpr int kMaxDepth = 64;
constexpr size_t kMaxMembers = 4096;

class Value;
using Object = std::map<std::string, Value>;
using Array = std::vector<Value>;

enum class Type { Null, Bool, Number, String, Object, Array };

class Value {
public:
    Value() : type_(Type::Null) {}
    Value(bool b) : type_(Type::Bool), bool_(b) {}
    Value(double n) : type_(Type::Number), num_(n) {}
    Value(int64_t n) : type_(Type::Number), num_(static_cast<double>(n)) {}
    Value(uint64_t n) : type_(Type::Number), num_(static_cast<double>(n)) {}
    Value(int n) : type_(Type::Number), num_(static_cast<double>(n)) {}
    Value(const char* s) : type_(Type::String), str_(s ? s : "") {}
    Value(std::string s) : type_(Type::String), str_(std::move(s)) {}
    Value(Object o) : type_(Type::Object), obj_(std::make_shared<Object>(std::move(o))) {}
    Value(Array a) : type_(Type::Array), arr_(std::make_shared<Array>(std::move(a))) {}

    Type type() const { return type_; }
    bool isNull() const { return type_ == Type::Null; }
    bool isObject() const { return type_ == Type::Object; }
    bool isArray() const { return type_ == Type::Array; }
    bool isString() const { return type_ == Type::String; }
    bool isNumber() const { return type_ == Type::Number; }
    bool isBool() const { return type_ == Type::Bool; }

    bool asBool(bool fallback = false) const {
        if (type_ == Type::Bool) return bool_;
        if (type_ == Type::Number) return num_ != 0.0;
        return fallback;
    }

    double asNumber(double fallback = 0.0) const {
        return type_ == Type::Number ? num_ : fallback;
    }

    int64_t asInt(int64_t fallback = 0) const {
        return type_ == Type::Number ? static_cast<int64_t>(num_) : fallback;
    }

    const std::string& asString() const {
        static const std::string kEmpty;
        return type_ == Type::String ? str_ : kEmpty;
    }

    const Object* asObject() const {
        return type_ == Type::Object && obj_ ? obj_.get() : nullptr;
    }

    const Array* asArray() const {
        return type_ == Type::Array && arr_ ? arr_.get() : nullptr;
    }

    // Convenience lookup that never throws.
    const Value& operator[](const std::string& key) const {
        static const Value kNull;
        const Object* o = asObject();
        if (!o) return kNull;
        auto it = o->find(key);
        return it == o->end() ? kNull : it->second;
    }

    std::vector<std::string> stringList() const {
        std::vector<std::string> out;
        const Array* a = asArray();
        if (!a) return out;
        out.reserve(a->size());
        for (const Value& v : *a) {
            if (v.isString()) out.push_back(v.asString());
        }
        return out;
    }

private:
    Type type_;
    bool bool_ = false;
    double num_ = 0.0;
    std::string str_;
    std::shared_ptr<Object> obj_;
    std::shared_ptr<Array> arr_;
};

// Escapes a string for embedding in JSON output.
std::string Escape(const std::string& in);

// Serialises a value. Numbers are written as integers when they are integral,
// which keeps byte counters readable in the logs.
std::string Write(const Value& value);

// Parses UTF-8 JSON. Returns false on malformed input; never throws.
bool Parse(const std::string& text, Value& out);

// ---------------------------------------------------------------------------
// Response helpers
// ---------------------------------------------------------------------------

inline std::string Failure(const std::string& code, const std::string& message) {
    return "{\"ok\":false,\"error\":{\"code\":\"" + Escape(code) +
           "\",\"message\":\"" + Escape(message) + "\"}}";
}

} // namespace gluk::json
