#include "json.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace gluk::json {
namespace {

class Parser {
public:
    explicit Parser(const std::string& text) : text_(text) {}

    bool Run(Value& out) {
        SkipWhitespace();
        if (!ParseValue(out, 0)) return false;
        SkipWhitespace();
        // Trailing garbage is a protocol error, not something to tolerate.
        return pos_ >= text_.size();
    }

private:
    const std::string& text_;
    size_t pos_ = 0;

    bool Eof() const { return pos_ >= text_.size(); }
    char Peek() const { return pos_ < text_.size() ? text_[pos_] : '\0'; }

    void SkipWhitespace() {
        while (pos_ < text_.size()) {
            const char c = text_[pos_];
            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                ++pos_;
            } else {
                break;
            }
        }
    }

    bool Literal(const char* word, size_t length) {
        if (text_.compare(pos_, length, word) != 0) return false;
        pos_ += length;
        return true;
    }

    bool ParseValue(Value& out, int depth) {
        if (depth > kMaxDepth) return false;
        SkipWhitespace();
        if (Eof()) return false;

        switch (Peek()) {
            case '{': return ParseObject(out, depth);
            case '[': return ParseArray(out, depth);
            case '"': {
                std::string s;
                if (!ParseString(s)) return false;
                out = Value(std::move(s));
                return true;
            }
            case 't':
                if (!Literal("true", 4)) return false;
                out = Value(true);
                return true;
            case 'f':
                if (!Literal("false", 5)) return false;
                out = Value(false);
                return true;
            case 'n':
                if (!Literal("null", 4)) return false;
                out = Value();
                return true;
            default:
                return ParseNumber(out);
        }
    }

    bool ParseObject(Value& out, int depth) {
        ++pos_; // consume '{'
        Object object;
        SkipWhitespace();
        if (Peek() == '}') {
            ++pos_;
            out = Value(std::move(object));
            return true;
        }

        while (true) {
            SkipWhitespace();
            if (Peek() != '"') return false;

            std::string key;
            if (!ParseString(key)) return false;

            SkipWhitespace();
            if (Peek() != ':') return false;
            ++pos_;

            Value value;
            if (!ParseValue(value, depth + 1)) return false;
            if (object.size() >= kMaxMembers) return false;
            object.emplace(std::move(key), std::move(value));

            SkipWhitespace();
            if (Peek() == ',') {
                ++pos_;
                continue;
            }
            if (Peek() == '}') {
                ++pos_;
                out = Value(std::move(object));
                return true;
            }
            return false;
        }
    }

    bool ParseArray(Value& out, int depth) {
        ++pos_; // consume '['
        Array array;
        SkipWhitespace();
        if (Peek() == ']') {
            ++pos_;
            out = Value(std::move(array));
            return true;
        }

        while (true) {
            Value value;
            if (!ParseValue(value, depth + 1)) return false;
            if (array.size() >= kMaxMembers) return false;
            array.push_back(std::move(value));

            SkipWhitespace();
            if (Peek() == ',') {
                ++pos_;
                continue;
            }
            if (Peek() == ']') {
                ++pos_;
                out = Value(std::move(array));
                return true;
            }
            return false;
        }
    }

    // Appends a code point as UTF-8.
    static void AppendUtf8(std::string& out, unsigned int cp) {
        if (cp <= 0x7F) {
            out.push_back(static_cast<char>(cp));
        } else if (cp <= 0x7FF) {
            out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else if (cp <= 0xFFFF) {
            out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        } else {
            out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
            out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
        }
    }

    bool ParseHex4(unsigned int& value) {
        if (pos_ + 4 > text_.size()) return false;
        value = 0;
        for (int i = 0; i < 4; ++i) {
            const char c = text_[pos_++];
            value <<= 4;
            if (c >= '0' && c <= '9') {
                value |= static_cast<unsigned int>(c - '0');
            } else if (c >= 'a' && c <= 'f') {
                value |= static_cast<unsigned int>(c - 'a' + 10);
            } else if (c >= 'A' && c <= 'F') {
                value |= static_cast<unsigned int>(c - 'A' + 10);
            } else {
                return false;
            }
        }
        return true;
    }

    bool ParseString(std::string& out) {
        if (Peek() != '"') return false;
        ++pos_;
        out.clear();

        while (pos_ < text_.size()) {
            const char c = text_[pos_++];
            if (c == '"') return true;

            if (c != '\\') {
                // Raw control characters are illegal in JSON strings.
                if (static_cast<unsigned char>(c) < 0x20) return false;
                out.push_back(c);
                continue;
            }

            if (pos_ >= text_.size()) return false;
            const char esc = text_[pos_++];
            switch (esc) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u': {
                    unsigned int cp = 0;
                    if (!ParseHex4(cp)) return false;
                    // Combine surrogate pairs so paths with non-BMP characters
                    // survive the round trip.
                    if (cp >= 0xD800 && cp <= 0xDBFF && pos_ + 1 < text_.size() &&
                        text_[pos_] == '\\' && text_[pos_ + 1] == 'u') {
                        pos_ += 2;
                        unsigned int low = 0;
                        if (!ParseHex4(low)) return false;
                        if (low >= 0xDC00 && low <= 0xDFFF) {
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                        } else {
                            AppendUtf8(out, cp);
                            cp = low;
                        }
                    }
                    AppendUtf8(out, cp);
                    break;
                }
                default:
                    return false;
            }
        }
        return false;
    }

    bool ParseNumber(Value& out) {
        const size_t start = pos_;
        if (Peek() == '-' || Peek() == '+') ++pos_;

        bool digits = false;
        while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
            ++pos_;
            digits = true;
        }
        if (pos_ < text_.size() && text_[pos_] == '.') {
            ++pos_;
            while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
                ++pos_;
                digits = true;
            }
        }
        if (!digits) return false;

        if (pos_ < text_.size() && (text_[pos_] == 'e' || text_[pos_] == 'E')) {
            ++pos_;
            if (pos_ < text_.size() && (text_[pos_] == '-' || text_[pos_] == '+')) ++pos_;
            bool expDigits = false;
            while (pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9') {
                ++pos_;
                expDigits = true;
            }
            if (!expDigits) return false;
        }

        out = Value(std::strtod(text_.substr(start, pos_ - start).c_str(), nullptr));
        return true;
    }
};

} // namespace

std::string Escape(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    for (const char c : in) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x",
                                  static_cast<unsigned char>(c));
                    out += buf;
                } else {
                    out.push_back(c);
                }
        }
    }
    return out;
}

std::string Write(const Value& value) {
    switch (value.type()) {
        case Type::Null:
            return "null";
        case Type::Bool:
            return value.asBool() ? "true" : "false";
        case Type::Number: {
            const double n = value.asNumber();
            char buf[40];
            // Byte counters and timestamps should not come out as 1.2e+09.
            if (std::isfinite(n) && n == std::floor(n) &&
                std::fabs(n) < 9.2e18) {
                std::snprintf(buf, sizeof(buf), "%lld",
                              static_cast<long long>(n));
            } else if (!std::isfinite(n)) {
                return "null";
            } else {
                std::snprintf(buf, sizeof(buf), "%.10g", n);
            }
            return buf;
        }
        case Type::String:
            return "\"" + Escape(value.asString()) + "\"";
        case Type::Array: {
            const Array* a = value.asArray();
            if (!a) return "[]";
            std::string out = "[";
            for (size_t i = 0; i < a->size(); ++i) {
                if (i) out += ",";
                out += Write((*a)[i]);
            }
            out += "]";
            return out;
        }
        case Type::Object: {
            const Object* o = value.asObject();
            if (!o) return "{}";
            std::string out = "{";
            bool first = true;
            for (const auto& [key, member] : *o) {
                if (!first) out += ",";
                first = false;
                out += "\"" + Escape(key) + "\":" + Write(member);
            }
            out += "}";
            return out;
        }
    }
    return "null";
}

bool Parse(const std::string& text, Value& out) {
    Parser parser(text);
    return parser.Run(out);
}

} // namespace gluk::json
