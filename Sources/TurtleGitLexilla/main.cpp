// SPDX-License-Identifier: GPL-2.0-or-later
// Read-only Scintilla IDocument adapter for the pinned upstream Lexilla lexers.
#include <algorithm>
#include <fstream>
#include <iostream>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
#include "ILexer.h"
#include "Scintilla.h"
#include "SciLexer.h"
#include "LexerModule.h"

extern const Lexilla::LexerModule lmCPP, lmPython, lmPascal, lmHTML;

class Document final : public Scintilla::IDocument {
    std::string text;
    std::vector<Sci_Position> starts{0};
    std::vector<int> levels, states;
    Sci_Position position = 0;
    int tabs;
public:
    std::vector<char> styles;
    int error = 0;
    Document(std::string value, int tabWidth) : text(std::move(value)), tabs(tabWidth), styles(text.size(), 0) {
        for (Sci_Position i = 0; i < Length(); ++i) if (text[i] == '\n') starts.push_back(i + 1);
        levels.resize(starts.size(), SC_FOLDLEVELBASE); states.resize(starts.size(), 0);
    }
    int SCI_METHOD Version() const override { return Scintilla::dvRelease4; }
    void SCI_METHOD SetErrorStatus(int value) override { error = value; }
    Sci_Position SCI_METHOD Length() const override { return static_cast<Sci_Position>(text.size()); }
    void SCI_METHOD GetCharRange(char *buffer, Sci_Position start, Sci_Position count) const override {
        if (start < 0 || count < 0 || start > Length() || count > Length() - start) throw std::out_of_range("character range");
        std::copy_n(text.data() + start, count, buffer);
    }
    char SCI_METHOD StyleAt(Sci_Position offset) const override { return offset >= 0 && offset < Length() ? styles[offset] : 0; }
    Sci_Position SCI_METHOD LineFromPosition(Sci_Position offset) const override {
        return static_cast<Sci_Position>(std::upper_bound(starts.begin(), starts.end(), offset) - starts.begin()) - 1;
    }
    Sci_Position SCI_METHOD LineStart(Sci_Position line) const override {
        return line < 0 ? 0 : static_cast<size_t>(line) < starts.size() ? starts[line] : Length();
    }
    int SCI_METHOD GetLevel(Sci_Position line) const override { return line >= 0 && static_cast<size_t>(line) < levels.size() ? levels[line] : SC_FOLDLEVELBASE; }
    int SCI_METHOD SetLevel(Sci_Position line, int value) override {
        const int previous = GetLevel(line);
        if (line >= 0 && static_cast<size_t>(line) < levels.size()) levels[line] = value;
        return previous;
    }
    int SCI_METHOD GetLineState(Sci_Position line) const override { return line >= 0 && static_cast<size_t>(line) < states.size() ? states[line] : 0; }
    int SCI_METHOD SetLineState(Sci_Position line, int value) override {
        const int previous = GetLineState(line);
        if (line >= 0 && static_cast<size_t>(line) < states.size()) states[line] = value;
        return previous;
    }
    void SCI_METHOD StartStyling(Sci_Position start) override { position = start; }
    bool SCI_METHOD SetStyleFor(Sci_Position count, char style) override {
        if (position < 0 || count < 0 || position > Length() || count > Length() - position) return false;
        std::fill_n(styles.begin() + position, count, style); position += count; return true;
    }
    bool SCI_METHOD SetStyles(Sci_Position count, const char *values) override {
        if (position < 0 || count < 0 || position > Length() || count > Length() - position) return false;
        std::copy_n(values, count, styles.begin() + position); position += count; return true;
    }
    void SCI_METHOD DecorationSetCurrentIndicator(int) override {}
    void SCI_METHOD DecorationFillRange(Sci_Position, int, Sci_Position) override {}
    void SCI_METHOD ChangeLexerState(Sci_Position, Sci_Position) override {}
    int SCI_METHOD CodePage() const override { return 65001; }
    bool SCI_METHOD IsDBCSLeadByte(char) const override { return false; }
    const char * SCI_METHOD BufferPointer() override { return text.data(); }
    int SCI_METHOD GetLineIndentation(Sci_Position line) override {
        int count = 0;
        for (Sci_Position i = LineStart(line); i < Length(); ++i) {
            if (text[i] == ' ') ++count;
            else if (text[i] == '\t') count += tabs - count % tabs;
            else break;
        }
        return count;
    }
    Sci_Position SCI_METHOD LineEnd(Sci_Position line) const override {
        Sci_Position end = LineStart(line + 1);
        if (end > LineStart(line) && text[end - 1] == '\n') --end;
        if (end > LineStart(line) && text[end - 1] == '\r') --end;
        return end;
    }
    Sci_Position SCI_METHOD GetRelativePosition(Sci_Position start, Sci_Position offset) const override {
        while (offset > 0 && start < Length()) {
            ++start; while (start < Length() && (static_cast<unsigned char>(text[start]) & 0xC0) == 0x80) ++start;
            --offset;
        }
        while (offset < 0 && start > 0) {
            --start; while (start > 0 && (static_cast<unsigned char>(text[start]) & 0xC0) == 0x80) --start;
            ++offset;
        }
        return offset == 0 ? start : -1;
    }
    int SCI_METHOD GetCharacterAndWidth(Sci_Position start, Sci_Position *width) const override {
        if (start < 0 || start >= Length()) { if (width) *width = 1; return 0; }
        const unsigned char first = text[start];
        const int count = first < 0x80 ? 1 : first < 0xE0 ? 2 : first < 0xF0 ? 3 : 4;
        unsigned value = count == 1 ? first : first & ((1u << (7 - count)) - 1);
        for (int i = 1; i < count && start + i < Length(); ++i) value = (value << 6) | (static_cast<unsigned char>(text[start + i]) & 0x3F);
        if (width) *width = std::min<Sci_Position>(count, Length() - start);
        return static_cast<int>(value);
    }
};

static std::string read(const char *path, size_t maximum) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("input is unavailable");
    std::string value;
    char buffer[8192];
    while (stream.read(buffer, sizeof buffer) || stream.gcount()) {
        value.append(buffer, static_cast<size_t>(stream.gcount()));
        if (value.size() > maximum) throw std::runtime_error("input exceeds limit");
    }
    return value;
}

int main(int argc, char **argv) {
    try {
        if (argc == 2 && std::string(argv[1]) == "--version") { std::cout << "TurtleGit Lexilla ef08a1a00ce151ccdddf7da700fbe1a4934a9c71\n"; return 0; }
        if (argc < 4 || (argc - 4) % 2) throw std::runtime_error("expected lexer, tabs, text and word-list pairs");
        const std::string name = argv[1];
        const Lexilla::LexerModule *module = name == "cpp" ? &lmCPP : name == "python" ? &lmPython : name == "pascal" ? &lmPascal : name == "hypertext" ? &lmHTML : nullptr;
        if (!module) throw std::runtime_error("unsupported lexer");
        const int tabs = std::stoi(argv[2]); if (tabs < 1 || tabs > 1000) throw std::runtime_error("invalid tab width");
        const auto release = [](Scintilla::ILexer5 *lexer) { if (lexer) lexer->Release(); };
        std::unique_ptr<Scintilla::ILexer5, decltype(release)> lexer(module->Create(), release);
        if (!lexer) throw std::runtime_error("lexer creation failed");
        for (int i = 4; i < argc; i += 2) {
            const int index = std::stoi(argv[i]); if (index < 0 || index > 8) throw std::runtime_error("invalid word-list index");
            const auto words = read(argv[i + 1], 1024 * 1024); lexer->WordListSet(index, words.c_str());
        }
        lexer->PropertySet("lexer.cpp.track.preprocessor", "0");
        Document document(read(argv[3], 16 * 1024 * 1024), tabs);
        lexer->Lex(0, document.Length(), 0, &document);
        if (document.error) throw std::runtime_error("lexer failed");
        std::cout << "lexilla\t1\nname\t" << name << '\n';
        size_t emitted = 0;
        for (size_t start = 0; start < document.styles.size();) {
            size_t end = start + 1;
            while (end < document.styles.size() && document.styles[end] == document.styles[start]) ++end;
            if (++emitted > 250000) throw std::runtime_error("too many style ranges");
            std::cout << "range\t" << start << '\t' << end - start << '\t' << static_cast<unsigned>(static_cast<unsigned char>(document.styles[start])) << '\n';
            start = end;
        }
        return 0;
    } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
