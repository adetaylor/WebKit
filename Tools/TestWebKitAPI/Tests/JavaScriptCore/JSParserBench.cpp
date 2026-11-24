/*
 * Copyright (C) 2026 Apple Inc. All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

#include "config.h"

#include "Helpers/Test.h"
#include <JavaScriptCore/APICast.h>
#include <JavaScriptCore/Completion.h>
#include <JavaScriptCore/InitializeThreading.h>
#include <JavaScriptCore/JSCJSValueInlines.h>
#include <JavaScriptCore/JSContextRef.h>
#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/JSLock.h>
#include <JavaScriptCore/JSObjectRef.h>
#include <JavaScriptCore/JSRetainPtr.h>
#include <JavaScriptCore/JSStringRef.h>
#include <JavaScriptCore/JSValueRef.h>
#include <JavaScriptCore/OpaqueJSString.h>
#include <JavaScriptCore/ParserError.h>
#include <JavaScriptCore/SourceCode.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <string>
#include <vector>
#include <wtf/FileSystem.h>
#include <wtf/MonotonicTime.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

// Throughput of JavaScriptCore's lexer and parser, one TEST per kind of source text. The check tests call
// JSCheckScriptSyntax (the top level is built by the AST builder, function bodies by the syntax checker), as the
// "SyntaxOnly" variants do with the same text wrapped in a function that is never called: their parse is the syntax
// checker's. The Modules test calls JSC::checkModuleSyntax. CallEveryFunction calls JSEvaluateScript on a script of
// many functions that it then calls, which makes the lazy reparse of each body, the source provider cache and the
// bytecode generator run. By default each TEST makes one pass over its input and checks a checksum of the verdicts and
// error messages (and, for CallEveryFunction, the results). With WEBKIT_RUN_BENCHMARKS=1 in the environment it then
// repeats the pass a fixed number of times (a constant of each shape) and prints "<Name>: <ms> ms <MB/s> MB/s checksum=<hex>", with the same
// checksum. Nothing asserts on time. MinifiedBundle and LargeScript read files of the tree.
//
// The generators between the BEGIN GENERATORS and END GENERATORS lines use only the standard library, so that they
// can be run alone to look at their output.

namespace TestWebKitAPI {

namespace {

// BEGIN GENERATORS
class Generator {
public:
    explicit Generator(uint32_t seed)
        : m_state(seed)
    {
    }

    unsigned below(unsigned n)
    {
        m_state = m_state * 1664525u + 1013904223u;
        return (m_state >> 8) % n;
    }

private:
    uint32_t m_state;
};

static constexpr size_t targetBytes = 1 << 20;

// Source text under construction. UTF-8; a text with any non-ASCII character reaches the parser as 16-bit.
using Text = std::string;

static const char* const identifierStarts = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$";
static const char* const identifierParts = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$0123456789";

// Never a reserved word: it starts with "q" and has a digit.
static Text identifier(Generator& generator, unsigned minLength, unsigned maxLength)
{
    Text result = "q";
    unsigned length = minLength + generator.below(maxLength - minLength + 1);
    result += identifierStarts[generator.below(54)];
    for (unsigned i = 0; i < length; ++i)
        result += identifierParts[generator.below(64)];
    result += static_cast<char>('0' + generator.below(10));
    return result;
}

static Text numberText(unsigned n) { return std::to_string(n); }

// A source is built by repeating chunks until it holds about targetBytes. A chunk may use "var", function and class
// declarations with names made unique by the counter, so that repeating it at the top level is valid.
template<typename Chunk>
static Text repeatChunks(uint32_t seed, Chunk chunk)
{
    Generator generator(seed);
    Text text;
    unsigned counter = 0;
    while (text.size() < targetBytes)
        chunk(generator, text, counter++);
    return text;
}

static Text identifiersText()
{
    static const char* const keywordProperties[] = { "class", "function", "if", "default", "new", "typeof", "in", "of", "let", "static", "await", "yield" };
    return repeatChunks(1, [](Generator& g, Text& t, unsigned) {
        t += "var " + identifier(g, 1, 12) + " = " + identifier(g, 1, 40) + " + " + identifier(g, 3, 20) + "." + keywordProperties[g.below(12)] + " * " + identifier(g, 30, 36) + ";\n";
        t += identifier(g, 0, 6) + "(" + identifier(g, 1, 8) + ", " + identifier(g, 8, 31) + ")." + identifier(g, 2, 10) + " = typeof " + identifier(g, 1, 5) + " === 'undefined' ? " + identifier(g, 6, 12) + " : " + identifier(g, 30, 34) + ";\n";
        t += "var \\u0061bc" + numberText(g.below(100)) + " = " + identifier(g, 1, 2) + "; var a = b, c = d, e = f, g = h;\n";
    });
}

static Text numbersText()
{
    static const char* const numbers[] = { "0", "1", "42", "255", "1234567", "0x1F", "0xdeadbeef", "0b101101", "0o755", "3.14159", "1e10", ".5", "0.1e-5",
        "123456789012345", "1234567890123456", "9007199254740991", "9007199254740993", "123456789012345678901", "0xFFFFFFFFFFFFF", "0x20000000000001",
        "1_000_000", "0xFF_FF", "10n", "0x7fffffffffffffffn", "123456789012345678901234567890n", "1.5e+300", "2.2250738585072014e-308", "4.9e-324", "0.000001", "100.0" };
    return repeatChunks(2, [](Generator& g, Text& t, unsigned) {
        // Arrays of small integers followed by commas: the lexer's fast scan of simple array elements.
        t += "var a = [";
        for (unsigned i = 0; i < 24; ++i)
            t += numberText(g.below(100000)) + ",";
        t += "];\n";
        t += "var n = [";
        for (unsigned i = 0; i < 16; ++i)
            t += std::string(numbers[g.below(30)]) + ", ";
        t += "];\n";
        t += "var m = " + std::string(numbers[g.below(30)]) + " + " + std::string(numbers[g.below(30)]) + " * " + numberText(g.below(1000)) + ";\n";
    });
}

static Text stringsText()
{
    static const char* const strings[] = { "\"plain text of some length\"", "'single quoted'", "\"escapes \\n \\t \\\\ \\\" \\' \\0\"", "'\\x41\\x42\\u0043\\u{44}\\u{1F600}'",
        "\"line \\\ncontinuation\"", "\"\"", "''", "\"a string with a rather long run of ordinary characters, which the lexer scans without special cases\"",
        "'\\u00e9\\u00e8\\u00ea'", "\"use strict\"", "'it\\'s'", "\"say \\\"hi\\\"\"" };
    return repeatChunks(3, [](Generator& g, Text& t, unsigned) {
        t += "var s = [";
        for (unsigned i = 0; i < 12; ++i)
            t += std::string(strings[g.below(12)]) + ", ";
        t += "];\n";
        t += "var o = { 'key" + numberText(g.below(1000)) + "': " + strings[g.below(12)] + ", \"other\": " + strings[g.below(12)] + " };\n";
    });
}

static Text templatesText()
{
    static const char* const templates[] = { "`plain`", "`a${x}b`", "`${x}${y}${z}`", "`nested ${`inner ${x + `deep ${y}`}`} end`", "`escapes \\n \\u0041 \\${ \\``",
        "`multi\nline\n${x}\ntext`", "tag`a${x}b`", "String.raw`\\unicode and \\xerror ${x}`", "`${{ a: 1 }.a}`", "`${(function () { return `x${1}`; })()}`" };
    return repeatChunks(4, [](Generator& g, Text& t, unsigned) {
        t += "var t = [";
        for (unsigned i = 0; i < 8; ++i)
            t += std::string(templates[g.below(10)]) + ", ";
        t += "];\n";
    });
}

static Text regExpLiteralsText()
{
    static const char* const regexps[] = { "/ab+c/gi", "/[a-z0-9_]+@[a-z]+\\.com/", "/(?<year>\\d{4})-(?<month>\\d{2})/u", "/^\\s*(?:\\/\\/.*)?$/m", "/[/]\\//", "/(?<=a)b(?!c)/", "/\\p{L}+/u",
        "/(a|b|c)*?d{2,5}/y", "/[\\]\\[]/", "/\\u{1F600}/v", "/./s" };
    return repeatChunks(5, [](Generator& g, Text& t, unsigned) {
        t += "var r = [";
        for (unsigned i = 0; i < 8; ++i)
            t += std::string(regexps[g.below(11)]) + ", ";
        t += "];\n";
        // Division, which the parser must not take for a regular expression.
        t += "var d = a / b / c, e = (a) / 2 / (b), f = a[0] / 3 /g;\n";
        t += "if (x) /re/.test(y);\n";
    });
}

static Text commentsText()
{
    return repeatChunks(6, [](Generator& g, Text& t, unsigned n) {
        t += "// a line comment with some ordinary text in it, number " + numberText(n) + "\n";
        t += "/* a block comment\n * over several lines\n * " + identifier(g, 5, 20) + " */\n";
        t += "/**\n * @param {number} a\n * @return {number}\n */\n";
        t += "var " + identifier(g, 1, 5) + " = 1; // trailing\n";
        t += "var " + identifier(g, 1, 5) + " = /* inline */ 2 /* another */ + 3;\n";
        if (!(n % 16))
            t += "//# sourceMappingURL=data" + numberText(n) + ".map\n";
        if (!(n % 16))
            t += "/*\n*/ --> html close comment\n<!-- html open comment\n";
    });
}

static Text unicode16Text()
{
    static const char* const wideIdentifiers[] = { "\xE5\xA4\x89\xE6\x95\xB0", "\xCE\xB1\xCE\xB2\xCE\xB3", "\xD0\xBF\xD0\xB5\xD1\x80\xD0\xB5\xD0\xBC\xD0\xB5\xD0\xBD\xD0\xBD\xD0\xB0\xD1\x8F", "caf\xC3\xA9", "\xF0\xA0\x80\x80x" };
    static const char* const wideStrings[] = { "\"\xE6\x97\xA5\xE6\x9C\xAC\xE8\xAA\x9E\xE3\x81\xAE\xE6\x96\x87\xE5\xAD\x97\xE5\x88\x97\"", "'\xF0\x9F\x98\x80\xF0\x9F\x98\x81'", "\"\xCE\xB5\xCE\xBB\xCE\xB7\xCE\xBD\xCE\xB9\xCE\xBA\xCE\xAC\"", "`\xD1\x82\xD0\xB5\xD0\xBA\xD1\x81\xD1\x82 ${x}`" };
    return repeatChunks(7, [](Generator& g, Text& t, unsigned n) {
        t += "var " + std::string(wideIdentifiers[g.below(4)]) + numberText(n) + " = " + wideStrings[g.below(4)] + " + " + identifier(g, 4, 16) + ";\n";
        t += "var " + identifier(g, 4, 16) + " = [" + wideStrings[g.below(4)] + ", " + wideStrings[g.below(4)] + ", " + numberText(g.below(1000)) + "];\n";
        t += "// \xE3\x82\xB3\xE3\x83\xA1\xE3\x83\xB3\xE3\x83\x88 comment with wide characters \xF0\x9F\x8E\x89\n";
        t += "function " + identifier(g, 3, 12) + "(" + identifier(g, 2, 6) + ", " + wideIdentifiers[g.below(4)] + "x) { return " + identifier(g, 2, 6) + " + 1; }\n";
    });
}

static Text deepNestingText()
{
    constexpr unsigned depth = 200;
    auto nest = [](Text& t, const char* open, const char* innermost, const char* close) {
        for (unsigned i = 0; i < depth; ++i)
            t += open;
        t += innermost;
        for (unsigned i = 0; i < depth; ++i)
            t += close;
        t += ";\n";
    };
    return repeatChunks(8, [&](Generator&, Text& t, unsigned) {
        nest(t, "(", "1", ")");
        nest(t, "[", "1", "]");
        nest(t, "x = { a: ", "1", " }");
        nest(t, "{ ", "", " }");
        nest(t, "x = function () { return ", "1", " }");
        nest(t, "- ", "1", "");
        nest(t, "a ? b : ", "c", "");
        nest(t, "if (a) ", "b", "");
    });
}

static Text arrowBacktrackingText()
{
    return repeatChunks(9, [](Generator& g, Text& t, unsigned) {
        // Parenthesized text that may or may not turn out to be arrow parameters: the parser saves its position and,
        // when it was wrong, rescans.
        unsigned depth = 6 + g.below(6);
        for (unsigned form = 0; form < 3; ++form) {
            t += "var f = ";
            for (unsigned i = 0; i < depth; ++i)
                t += "(a" + numberText(i) + " = ";
            t += "1";
            for (unsigned i = 0; i < depth; ++i)
                t += !form ? ")" : (i + 1 == depth && form == 2 ? ") => 0" : ")");
            t += ";\n";
        }
        t += "var g = (a, b, c) => (d, e) => (f, { g, h = (i, j) => i }, [k, l]) => g + h(k, l);\n";
        t += "var h = async (a, b) => await (a, b), i = (a, b) + (c, d);\n";
    });
}

static Text classesText()
{
    return repeatChunks(10, [](Generator& g, Text& t, unsigned n) {
        std::string name = "Class" + numberText(n);
        t += "class " + name + (n % 3 ? "" : " extends Base") + " {\n";
        t += "  static count = " + numberText(g.below(100)) + ";\n  #secret = " + numberText(g.below(100)) + ";\n  field" + numberText(g.below(100)) + " = 'x';\n";
        t += "  constructor(a, b = 2, ...rest) { " + std::string(n % 3 ? "" : "super(a); ") + "this.a = a; this.#secret += b; }\n";
        t += "  get value() { return this.#secret; }\n  set value(v) { this.#secret = v; }\n";
        t += "  static create(a) { return new " + name + "(a); }\n  #priv() { return #secret in this; }\n";
        t += "  async *generate() { yield* [1, 2, 3]; }\n  [Symbol.iterator]() { return this.generate(); }\n  static { " + name + ".ready = true; }\n";
        t += "}\n";
    });
}

static Text modulesText()
{
    return repeatChunks(11, [](Generator& g, Text& t, unsigned n) {
        std::string suffix = numberText(n);
        t += "import def" + suffix + ", { a" + suffix + " as b" + suffix + ", c" + suffix + " } from './module" + numberText(g.below(100)) + ".js';\n";
        t += "import * as ns" + suffix + " from \"./other" + numberText(g.below(100)) + ".js\";\n";
        t += "export const value" + suffix + " = def" + suffix + " + b" + suffix + " + ns" + suffix + ".x;\n";
        t += "export function fn" + suffix + "(a) { return a + value" + suffix + "; }\n";
        t += "export { c" + suffix + " as d" + suffix + " };\n";
        if (!(n % 8))
            t += "export * from './re" + suffix + ".js';\nexport * as star" + suffix + " from './star.js';\n";
        if (!n)
            t += "export default class { }\n";
        if (n % 8 == 1)
            t += "const dyn" + suffix + " = await import('./dyn.js');\n";
    });
}

// Many small scripts, most of them with one syntax error, and a few valid ones.
static std::vector<Text> syntaxErrorTexts()
{
    static const char* const bases[] = { "var a = 1 + 2 * (3 - 4);", "function f(a, b) { return a + b; }", "if (a) { b(); } else { c(); }", "for (let i = 0; i < 10; ++i) x[i] = i;",
        "class A extends B { constructor() { super(); } }", "var o = { a: 1, b: [1, 2, 3], c: function () { } };", "let s = `a${b}c`;", "try { a(); } catch (e) { b(e); } finally { c(); }",
        "switch (a) { case 1: b(); break; default: c(); }", "var r = /a+b/g.test(s);", "const f = (a, b) => a + b;", "async function g() { await h(); }", "label: while (a) { break label; }",
        "x = y ? z : w;", "var t = typeof a === 'string';" };
    std::vector<Text> texts;
    Generator generator(12);
    size_t total = 0;
    while (total < targetBytes / 8) {
        Text text = bases[generator.below(15)];
        switch (generator.below(4)) {
        case 0: // Cut short.
            text.resize(1 + generator.below(text.size()));
            break;
        case 1: // One character removed.
            text.erase(generator.below(text.size()), 1);
            break;
        case 2: // One character replaced.
            text[generator.below(text.size())] = "){}[]=;,.'\"`/*#@\\0a"[generator.below(19)];
            break;
        case 3: // A second statement after a bad one.
            text += " var 1x = 2; " + std::string(bases[generator.below(15)]);
            break;
        }
        total += text.size();
        texts.push_back(WTF::move(text));
    }
    return texts;
}

// A script of many functions and a call of each, for JSEvaluateScript.
static Text callEveryFunctionText()
{
    unsigned count = 0;
    Text functions = repeatChunks(13, [&](Generator& g, Text& t, unsigned n) {
        std::string name = "fn" + numberText(n);
        t += "function " + name + "(a, b) {\n  var s = a * " + numberText(g.below(10) + 1) + ";\n  for (var i = 0; i < 3; ++i) { if (i % 2) s += b; else s -= i; }\n";
        t += "  function inner(x) { return x + a + " + numberText(g.below(100)) + "; }\n  var o = { k: [a, b, s], m() { return inner(s); } };\n";
        t += "  return o.m() + o.k.length + (s > 0 ? 1 : 2);\n}\n";
        count = n + 1;
    });
    Text calls = "var total = 0;\n";
    for (unsigned i = 0; i < count; ++i)
        calls += "total += fn" + numberText(i) + "(" + numberText(i % 7) + ", " + numberText(i % 5) + ");\n";
    return functions + calls + "total;\n";
}
// END GENERATORS

struct Checksum {
    uint64_t value { 1469598103934665603ull };

    void addByte(uint8_t byte)
    {
        value ^= byte;
        value *= 1099511628211ull;
    }

    void add(uint64_t word)
    {
        for (unsigned i = 0; i < 8; ++i)
            addByte((word >> (8 * i)) & 0xff);
    }

    void add(const String& string)
    {
        if (string.isNull()) {
            add(~0ull);
            return;
        }
        add(string.length());
        for (unsigned i = 0; i < string.length(); ++i) {
            char16_t character = string[i];
            addByte(character & 0xff);
            addByte(character >> 8);
        }
    }
};

static bool runsBenchmarks()
{
    auto* value = getenv("WEBKIT_RUN_BENCHMARKS");
    return value && *value && StringView::fromLatin1(value) != "0"_s;
}

static JSRetainPtr<JSStringRef> scriptString(const String& string)
{
    if (string.is8Bit())
        return adopt(&OpaqueJSString::create(string.span8()).leakRef());
    return adopt(&OpaqueJSString::create(string.span16()).leakRef());
}

static String treeFile(std::initializer_list<StringView> components)
{
    String path = String::fromUTF8(__FILE__);
    for (unsigned i = 0; i < 5; ++i)
        path = FileSystem::parentPath(path);
    for (auto component : components)
        path = FileSystem::pathByAppendingComponent(path, component);
    auto contents = FileSystem::readEntireFile(path);
    EXPECT_TRUE(contents.has_value()) << "cannot read " << path;
    if (!contents)
        return emptyString();
    return String::fromUTF8(contents->span());
}

static String codeLoadFile(ASCIILiteral name)
{
    return treeFile({ "PerformanceTests"_s, "JetStream2"_s, "code-load"_s, StringView(name) });
}

static String fromText(const Text& text)
{
    return String::fromUTF8(std::span<const char> { text.data(), text.size() });
}

// The same text as the body of a function that is never called, so that every function body in it is parsed by the
// syntax checker rather than the AST builder.
static String wrapInFunction(const Text& text)
{
    return fromText("function wrapper() {\n" + text + "\n}\n");
}

enum class Entry : uint8_t { CheckScript, CheckModule, EvaluateScript };

struct Input {
    Entry entry { Entry::CheckScript };
    Vector<String> scripts;
    size_t bytes { 0 };
    // Every script is expected to be valid (all but SyntaxErrors).
    bool expectsValid { true };
};

static Input makeInput(Entry entry, Vector<String>&& scripts, bool expectsValid = true)
{
    Input input;
    input.entry = entry;
    input.expectsValid = expectsValid;
    for (auto& script : scripts)
        input.bytes += script.length() * (script.is8Bit() ? 1 : 2);
    input.scripts = WTF::move(scripts);
    return input;
}

static Input singleInput(Entry entry, String&& script)
{
    Vector<String> scripts;
    scripts.append(WTF::move(script));
    return makeInput(entry, WTF::move(scripts));
}

static Input fullParseInput(const Text& text) { return singleInput(Entry::CheckScript, fromText(text)); }
static Input syntaxOnlyInput(const Text& text) { return singleInput(Entry::CheckScript, wrapInFunction(text)); }

class Benchmark {
public:
    explicit Benchmark(Input&& input)
        : m_input(WTF::move(input))
        , m_context(JSGlobalContextCreate(nullptr))
    {
    }

    ~Benchmark()
    {
        JSGlobalContextRelease(m_context);
    }

    const Input& input() const { return m_input; }

    String describe(JSValueRef value)
    {
        if (!value)
            return { };
        auto* globalObject = toJS(m_context);
        JSC::JSLockHolder locker(globalObject->vm());
        return toJS(globalObject, value).toWTFString(globalObject);
    }

    // One pass over the input. With a checksum, every verdict, message and result is digested.
    void runOnce(Checksum* checksum)
    {
        for (auto& script : m_input.scripts) {
            switch (m_input.entry) {
            case Entry::CheckScript:
                checkScript(script, checksum);
                break;
            case Entry::CheckModule:
                checkModule(script, checksum);
                break;
            case Entry::EvaluateScript:
                evaluateScript(script, checksum);
                break;
            }
        }
        ++m_pass;
    }

private:
    void checkScript(const String& script, Checksum* checksum)
    {
        // JSC::checkSyntax, which JSCheckScriptSyntax calls, but not the API's wrapper: for an invalid script that makes a
        // JSC::Exception and reports it to the remote inspector, which costs milliseconds (symbolicating the native
        // stack), a hundred times the parse. The verdict, message and line are the same.
        auto* globalObject = toJS(m_context);
        JSC::JSLockHolder locker(globalObject->vm());
        auto source = JSC::makeSource(script, JSC::SourceOrigin { URL { } }, JSC::SourceTaintedOrigin::Untainted, String(), WTF::TextPosition());
        JSC::JSValue syntaxException;
        bool valid = JSC::checkSyntax(globalObject, source, &syntaxException);
        JSValueRef exception = valid ? nullptr : toRef(globalObject, syntaxException);
        if (!checksum)
            return;
        checksum->add(valid);
        if (!valid && m_input.expectsValid)
            ADD_FAILURE() << "unexpected syntax error: " << describe(exception) << " in " << script.left(80);
        if (exception) {
            checksum->add(describe(exception));
            checksum->add(exceptionLine(exception));
        }
    }

    uint64_t exceptionLine(JSValueRef exception)
    {
        JSObjectRef object = JSValueToObject(m_context, exception, nullptr);
        if (!object)
            return 0;
        auto lineName = adopt(JSStringCreateWithUTF8CString("line"));
        JSValueRef line = JSObjectGetProperty(m_context, object, lineName.get(), nullptr);
        double number = line ? JSValueToNumber(m_context, line, nullptr) : 0;
        return number >= 0 && number < 1e9 ? static_cast<uint64_t>(number) : 0;
    }

    void checkModule(const String& script, Checksum* checksum)
    {
        JSC::JSLockHolder locker(toJS(m_context)->vm());
        auto source = JSC::makeSource(script, JSC::SourceOrigin { URL { } }, JSC::SourceTaintedOrigin::Untainted, String(), WTF::TextPosition(), JSC::SourceProviderSourceType::Module);
        JSC::ParserError error;
        bool valid = JSC::checkModuleSyntax(toJS(m_context), source, error);
        if (!checksum)
            return;
        checksum->add(valid);
        if (!valid && m_input.expectsValid)
            ADD_FAILURE() << "unexpected syntax error: " << error.message() << " in " << script.left(80);
        checksum->add(static_cast<uint64_t>(error.type()));
        checksum->add(static_cast<uint64_t>(error.syntaxErrorType()));
        checksum->add(static_cast<uint64_t>(error.line()));
        checksum->add(error.message());
    }

    // Each pass evaluates the script with a comment in front that no earlier pass had, so that the code cache of the
    // virtual machine does not answer instead of the parser.
    void evaluateScript(const String& script, Checksum* checksum)
    {
        String text = makeString("// pass "_s, m_pass, "\n"_s, script);
        auto string = scriptString(text);
        JSValueRef exception = nullptr;
        JSValueRef result = JSEvaluateScript(m_context, string.get(), nullptr, nullptr, 1, &exception);
        if (!checksum)
            return;
        EXPECT_FALSE(exception) << describe(exception);
        checksum->add(!exception);
        checksum->add(describe(exception ? exception : result));
    }

    Input m_input;
    JSGlobalContextRef m_context;
    unsigned m_pass { 0 };
};

// Checksums of one pass, from the reference implementation, and beside each the number of passes the timed run makes:
// fixed, so that every build does the same work, and chosen so that the C++ parser takes about 1.25 s.
static constexpr uint64_t checksumIdentifiersFullParse = 0x29034675a49f07c2ull;
static constexpr unsigned passesIdentifiersFullParse = 163;
static constexpr uint64_t checksumIdentifiersSyntaxOnly = 0x29034675a49f07c2ull;
static constexpr unsigned passesIdentifiersSyntaxOnly = 165;
static constexpr uint64_t checksumNumbersFullParse = 0x29034675a49f07c2ull;
static constexpr unsigned passesNumbersFullParse = 334;
static constexpr uint64_t checksumNumbersSyntaxOnly = 0x29034675a49f07c2ull;
static constexpr unsigned passesNumbersSyntaxOnly = 402;
static constexpr uint64_t checksumStringsFullParse = 0x29034675a49f07c2ull;
static constexpr unsigned passesStringsFullParse = 417;
static constexpr uint64_t checksumStringsSyntaxOnly = 0x29034675a49f07c2ull;
static constexpr unsigned passesStringsSyntaxOnly = 524;
static constexpr uint64_t checksumTemplatesFullParse = 0x29034675a49f07c2ull;
static constexpr unsigned passesTemplatesFullParse = 171;
static constexpr uint64_t checksumTemplatesSyntaxOnly = 0x29034675a49f07c2ull;
static constexpr unsigned passesTemplatesSyntaxOnly = 209;
static constexpr uint64_t checksumRegExpLiteralsFullParse = 0x29034675a49f07c2ull;
static constexpr unsigned passesRegExpLiteralsFullParse = 120;
static constexpr uint64_t checksumRegExpLiteralsSyntaxOnly = 0x29034675a49f07c2ull;
static constexpr unsigned passesRegExpLiteralsSyntaxOnly = 142;
static constexpr uint64_t checksumCommentsFullParse = 0x29034675a49f07c2ull;
static constexpr unsigned passesCommentsFullParse = 522;
static constexpr uint64_t checksumCommentsSyntaxOnly = 0x29034675a49f07c2ull;
static constexpr unsigned passesCommentsSyntaxOnly = 582;
static constexpr uint64_t checksumUnicode16FullParse = 0x29034675a49f07c2ull;
static constexpr unsigned passesUnicode16FullParse = 185;
static constexpr uint64_t checksumUnicode16SyntaxOnly = 0x29034675a49f07c2ull;
static constexpr unsigned passesUnicode16SyntaxOnly = 198;
static constexpr uint64_t checksumMinifiedBundle = 0x29034675a49f07c2ull;
static constexpr unsigned passesMinifiedBundle = 107;
static constexpr uint64_t checksumLargeScript = 0x29034675a49f07c2ull;
static constexpr unsigned passesLargeScript = 85;
static constexpr uint64_t checksumDeepNestingFullParse = 0x29034675a49f07c2ull;
static constexpr unsigned passesDeepNestingFullParse = 96;
static constexpr uint64_t checksumDeepNestingSyntaxOnly = 0x29034675a49f07c2ull;
static constexpr unsigned passesDeepNestingSyntaxOnly = 116;
static constexpr uint64_t checksumArrowBacktrackingFullParse = 0x29034675a49f07c2ull;
static constexpr unsigned passesArrowBacktrackingFullParse = 40;
static constexpr uint64_t checksumArrowBacktrackingSyntaxOnly = 0x29034675a49f07c2ull;
static constexpr unsigned passesArrowBacktrackingSyntaxOnly = 46;
static constexpr uint64_t checksumClassesFullParse = 0x29034675a49f07c2ull;
static constexpr unsigned passesClassesFullParse = 147;
static constexpr uint64_t checksumClassesSyntaxOnly = 0x29034675a49f07c2ull;
static constexpr unsigned passesClassesSyntaxOnly = 173;
static constexpr uint64_t checksumModules = 0x866dace74a6c4cb2ull;
static constexpr unsigned passesModules = 115;
static constexpr uint64_t checksumSyntaxErrors = 0x6caad56368bc5a01ull;
static constexpr unsigned passesSyntaxErrors = 310;
static constexpr uint64_t checksumCallEveryFunction = 0xc9528fc7d40e14c1ull;
static constexpr unsigned passesCallEveryFunction = 21;

static void runBenchmark(ASCIILiteral name, Input&& input, uint64_t expectedChecksum, unsigned passes)
{
    JSC::initialize();
    Benchmark benchmark(WTF::move(input));

    Checksum checksum;
    benchmark.runOnce(&checksum);
    EXPECT_EQ(checksum.value, expectedChecksum) << name << " checksum=" << std::hex << std::setfill('0') << std::setw(16) << checksum.value;

    if (!runsBenchmarks())
        return;

    // A fixed number of passes, not a fixed time: arms that take different times do the same work.
    auto start = MonotonicTime::now();
    for (unsigned pass = 0; pass < passes; ++pass)
        benchmark.runOnce(nullptr);
    double seconds = (MonotonicTime::now() - start).seconds();

    double bytes = static_cast<double>(benchmark.input().bytes) * passes;
    SAFE_PRINTF("%s: %.1f ms %.1f MB/s checksum=%016llx\n", name, seconds * 1000, bytes / seconds / 1e6, static_cast<unsigned long long>(checksum.value));
    fflush(stdout);
}

} // namespace

// Every test is one shape, so that each runs in a process of its own.
TEST(JSParserBench, StartUp) { }

TEST(JSParserBench, IdentifiersFullParse) { runBenchmark("IdentifiersFullParse"_s, fullParseInput(identifiersText()), checksumIdentifiersFullParse, passesIdentifiersFullParse); }
TEST(JSParserBench, IdentifiersSyntaxOnly) { runBenchmark("IdentifiersSyntaxOnly"_s, syntaxOnlyInput(identifiersText()), checksumIdentifiersSyntaxOnly, passesIdentifiersSyntaxOnly); }
TEST(JSParserBench, NumbersFullParse) { runBenchmark("NumbersFullParse"_s, fullParseInput(numbersText()), checksumNumbersFullParse, passesNumbersFullParse); }
TEST(JSParserBench, NumbersSyntaxOnly) { runBenchmark("NumbersSyntaxOnly"_s, syntaxOnlyInput(numbersText()), checksumNumbersSyntaxOnly, passesNumbersSyntaxOnly); }
TEST(JSParserBench, StringsFullParse) { runBenchmark("StringsFullParse"_s, fullParseInput(stringsText()), checksumStringsFullParse, passesStringsFullParse); }
TEST(JSParserBench, StringsSyntaxOnly) { runBenchmark("StringsSyntaxOnly"_s, syntaxOnlyInput(stringsText()), checksumStringsSyntaxOnly, passesStringsSyntaxOnly); }
TEST(JSParserBench, TemplatesFullParse) { runBenchmark("TemplatesFullParse"_s, fullParseInput(templatesText()), checksumTemplatesFullParse, passesTemplatesFullParse); }
TEST(JSParserBench, TemplatesSyntaxOnly) { runBenchmark("TemplatesSyntaxOnly"_s, syntaxOnlyInput(templatesText()), checksumTemplatesSyntaxOnly, passesTemplatesSyntaxOnly); }
TEST(JSParserBench, RegExpLiteralsFullParse) { runBenchmark("RegExpLiteralsFullParse"_s, fullParseInput(regExpLiteralsText()), checksumRegExpLiteralsFullParse, passesRegExpLiteralsFullParse); }
TEST(JSParserBench, RegExpLiteralsSyntaxOnly) { runBenchmark("RegExpLiteralsSyntaxOnly"_s, syntaxOnlyInput(regExpLiteralsText()), checksumRegExpLiteralsSyntaxOnly, passesRegExpLiteralsSyntaxOnly); }
TEST(JSParserBench, CommentsFullParse) { runBenchmark("CommentsFullParse"_s, fullParseInput(commentsText()), checksumCommentsFullParse, passesCommentsFullParse); }
TEST(JSParserBench, CommentsSyntaxOnly) { runBenchmark("CommentsSyntaxOnly"_s, syntaxOnlyInput(commentsText()), checksumCommentsSyntaxOnly, passesCommentsSyntaxOnly); }
TEST(JSParserBench, Unicode16FullParse) { runBenchmark("Unicode16FullParse"_s, fullParseInput(unicode16Text()), checksumUnicode16FullParse, passesUnicode16FullParse); }
TEST(JSParserBench, Unicode16SyntaxOnly) { runBenchmark("Unicode16SyntaxOnly"_s, syntaxOnlyInput(unicode16Text()), checksumUnicode16SyntaxOnly, passesUnicode16SyntaxOnly); }
TEST(JSParserBench, DeepNestingFullParse) { runBenchmark("DeepNestingFullParse"_s, fullParseInput(deepNestingText()), checksumDeepNestingFullParse, passesDeepNestingFullParse); }
TEST(JSParserBench, DeepNestingSyntaxOnly) { runBenchmark("DeepNestingSyntaxOnly"_s, syntaxOnlyInput(deepNestingText()), checksumDeepNestingSyntaxOnly, passesDeepNestingSyntaxOnly); }
TEST(JSParserBench, ArrowBacktrackingFullParse) { runBenchmark("ArrowBacktrackingFullParse"_s, fullParseInput(arrowBacktrackingText()), checksumArrowBacktrackingFullParse, passesArrowBacktrackingFullParse); }
TEST(JSParserBench, ArrowBacktrackingSyntaxOnly) { runBenchmark("ArrowBacktrackingSyntaxOnly"_s, syntaxOnlyInput(arrowBacktrackingText()), checksumArrowBacktrackingSyntaxOnly, passesArrowBacktrackingSyntaxOnly); }
TEST(JSParserBench, ClassesFullParse) { runBenchmark("ClassesFullParse"_s, fullParseInput(classesText()), checksumClassesFullParse, passesClassesFullParse); }
TEST(JSParserBench, ClassesSyntaxOnly) { runBenchmark("ClassesSyntaxOnly"_s, syntaxOnlyInput(classesText()), checksumClassesSyntaxOnly, passesClassesSyntaxOnly); }

// Real files of the tree: JetStream 2's Web Inspector payload, minified and not. Their top level is mostly function
// bodies, so one test each.
TEST(JSParserBench, MinifiedBundle) { runBenchmark("MinifiedBundle"_s, singleInput(Entry::CheckScript, codeLoadFile("inspector-payload-minified.js"_s)), checksumMinifiedBundle, passesMinifiedBundle); }
TEST(JSParserBench, LargeScript) { runBenchmark("LargeScript"_s, singleInput(Entry::CheckScript, codeLoadFile("inspector-payload.js"_s)), checksumLargeScript, passesLargeScript); }

TEST(JSParserBench, Modules) { runBenchmark("Modules"_s, singleInput(Entry::CheckModule, fromText(modulesText())), checksumModules, passesModules); }

TEST(JSParserBench, SyntaxErrors)
{
    Vector<String> scripts;
    for (auto& text : syntaxErrorTexts())
        scripts.append(fromText(text));
    runBenchmark("SyntaxErrors"_s, makeInput(Entry::CheckScript, WTF::move(scripts), false), checksumSyntaxErrors, passesSyntaxErrors);
}

TEST(JSParserBench, CallEveryFunction) { runBenchmark("CallEveryFunction"_s, singleInput(Entry::EvaluateScript, fromText(callEveryFunctionText())), checksumCallEveryFunction, passesCallEveryFunction); }

} // namespace TestWebKitAPI
