// A small JSON reader, enough for the replay server's responses. Header only.
#pragma once
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace mini {

struct Json {
  enum Type { Null, Bool, Num, Str, Arr, Obj } type = Null;
  bool b = false;
  double n = 0;
  std::string s;
  std::vector<Json> a;
  std::map<std::string, Json> o;

  const Json& at(const std::string& k) const {
    static const Json none;
    auto it = o.find(k);
    return it == o.end() ? none : it->second;
  }
  const Json& at(size_t i) const {
    static const Json none;
    return i < a.size() ? a[i] : none;
  }
  std::string str(const std::string& d = "") const { return type == Str ? s : d; }
  long long num(long long d = 0) const { return type == Num ? (long long)n : d; }
  bool isNull() const { return type == Null; }
};

class Parser {
 public:
  explicit Parser(const std::string& t) : t_(t) {}
  bool parse(Json& out) {
    skip();
    if (!value(out, 0)) return false;
    skip();
    return i_ == t_.size();
  }

 private:
  const std::string& t_;
  size_t i_ = 0;
  void skip() {
    while (i_ < t_.size() && std::isspace((unsigned char)t_[i_])) i_++;
  }
  bool lit(const char* w) {
    size_t n = std::char_traits<char>::length(w);
    if (t_.compare(i_, n, w) == 0) {
      i_ += n;
      return true;
    }
    return false;
  }
  static void utf8(std::string& o, unsigned cp) {
    if (cp < 0x80) o += (char)cp;
    else if (cp < 0x800) { o += (char)(0xC0 | (cp >> 6)); o += (char)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) { o += (char)(0xE0 | (cp >> 12)); o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F)); }
    else { o += (char)(0xF0 | (cp >> 18)); o += (char)(0x80 | ((cp >> 12) & 0x3F)); o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F)); }
  }
  bool string(std::string& o) {
    if (t_[i_] != '"') return false;
    i_++;
    while (i_ < t_.size()) {
      char c = t_[i_++];
      if (c == '"') return true;
      if (c != '\\') { o += c; continue; }
      if (i_ >= t_.size()) return false;
      char e = t_[i_++];
      switch (e) {
        case 'n': o += '\n'; break;
        case 't': o += '\t'; break;
        case 'r': o += '\r'; break;
        case 'b': o += '\b'; break;
        case 'f': o += '\f'; break;
        case 'u': {
          if (i_ + 4 > t_.size()) return false;
          unsigned cp = (unsigned)std::strtoul(t_.substr(i_, 4).c_str(), nullptr, 16);
          i_ += 4;
          if (cp >= 0xD800 && cp < 0xDC00 && t_.compare(i_, 2, "\\u") == 0) {
            unsigned lo = (unsigned)std::strtoul(t_.substr(i_ + 2, 4).c_str(), nullptr, 16);
            i_ += 6;
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
          }
          utf8(o, cp);
          break;
        }
        default: o += e;
      }
    }
    return false;
  }
  bool value(Json& j, int depth) {
    if (depth > 64 || i_ >= t_.size()) return false;
    char c = t_[i_];
    if (c == '{') {
      i_++;
      j.type = Json::Obj;
      skip();
      if (i_ < t_.size() && t_[i_] == '}') { i_++; return true; }
      while (true) {
        skip();
        std::string k;
        if (i_ >= t_.size() || !string(k)) return false;
        skip();
        if (i_ >= t_.size() || t_[i_++] != ':') return false;
        skip();
        if (!value(j.o[k], depth + 1)) return false;
        skip();
        if (i_ >= t_.size()) return false;
        if (t_[i_] == ',') { i_++; continue; }
        if (t_[i_] == '}') { i_++; return true; }
        return false;
      }
    }
    if (c == '[') {
      i_++;
      j.type = Json::Arr;
      skip();
      if (i_ < t_.size() && t_[i_] == ']') { i_++; return true; }
      while (true) {
        skip();
        j.a.emplace_back();
        if (!value(j.a.back(), depth + 1)) return false;
        skip();
        if (i_ >= t_.size()) return false;
        if (t_[i_] == ',') { i_++; continue; }
        if (t_[i_] == ']') { i_++; return true; }
        return false;
      }
    }
    if (c == '"') { j.type = Json::Str; return string(j.s); }
    if (lit("true")) { j.type = Json::Bool; j.b = true; return true; }
    if (lit("false")) { j.type = Json::Bool; j.b = false; return true; }
    if (lit("null")) { j.type = Json::Null; return true; }
    char* end = nullptr;
    j.n = std::strtod(t_.c_str() + i_, &end);
    if (end == t_.c_str() + i_) return false;
    i_ = (size_t)(end - t_.c_str());
    j.type = Json::Num;
    return true;
  }
};

inline bool parse(const std::string& text, Json& out) { return Parser(text).parse(out); }

// Compact JSON text for a value. Whole numbers print without a decimal point, so ids and counts round-trip as the game wrote them.
inline std::string quote(const std::string& s) {
  std::string o = "\"";
  for (unsigned char c : s) {
    switch (c) {
      case '"': o += "\\\""; break;
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break;
      case '\r': o += "\\r"; break;
      case '\t': o += "\\t"; break;
      default:
        if (c < 0x20) { char b[8]; std::snprintf(b, sizeof b, "\\u%04x", c); o += b; }
        else o += (char)c;   // UTF-8 passes through untouched
    }
  }
  return o + "\"";
}

inline void dump(const Json& j, std::string& out) {
  switch (j.type) {
    case Json::Null: out += "null"; break;
    case Json::Bool: out += j.b ? "true" : "false"; break;
    case Json::Num: {
      char b[40];
      if (j.n == (double)(long long)j.n && j.n > -9e15 && j.n < 9e15) std::snprintf(b, sizeof b, "%lld", (long long)j.n);
      else std::snprintf(b, sizeof b, "%.17g", j.n);
      out += b;
      break;
    }
    case Json::Str: out += quote(j.s); break;
    case Json::Arr:
      out += '[';
      for (size_t i = 0; i < j.a.size(); i++) { if (i) out += ','; dump(j.a[i], out); }
      out += ']';
      break;
    case Json::Obj: {
      out += '{';
      bool first = true;
      for (const auto& kv : j.o) { if (!first) out += ','; first = false; out += quote(kv.first); out += ':'; dump(kv.second, out); }
      out += '}';
      break;
    }
  }
}

inline std::string dump(const Json& j) { std::string o; dump(j, o); return o; }

}  // namespace mini
