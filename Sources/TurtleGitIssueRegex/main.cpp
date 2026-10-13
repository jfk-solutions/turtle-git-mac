// Issue matching adapted from TortoiseGit ProjectProperties.cpp and
// Utils/MiscUI/SciEdit.cpp::MarkEnteredBugID and CommitDlg.cpp::ScanFile.
// Copyright (C) 2003-2021, 2023-2025 - TortoiseGit
// SciEdit: Copyright (C) 2009-2026 - TortoiseGit
// Copyright (C) 2003-2008, 2012-2020, 2025 - TortoiseSVN
// Log match ranges adapt TortoiseGit FilterHelper.cpp::GetMatchRanges.
// FilterHelper: Copyright (C) 2018-2023 TortoiseGit; 2010-2017 TortoiseSVN.
// TurtleGit for Mac adaptations: UTF-16 transport and process protocol.
// SPDX-License-Identifier: GPL-2.0-or-later
// See LICENSE and docs/ISSUE-TRACKER-PARITY.md.
#include <fstream>
#include <iostream>
#include <iterator>
#include <regex>
#include <stdexcept>
#include <string>

// wchar_t is 32-bit on macOS. Keep one Windows UTF-16 unit per wchar_t so
// ECMAScript escapes, captures and offsets retain Windows string semantics.
static std::wstring read_units(const char* path, bool nullTerminated = true) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("Could not open regex input.");
    std::string bytes((std::istreambuf_iterator<char>(input)), {});
    if (bytes.size() % 2 || bytes.size() > 16 * 1024 * 1024)
        throw std::runtime_error("Invalid or oversized UTF-16 input.");
    std::wstring value;
    value.reserve(bytes.size() / 2);
    for (size_t index = 0; index < bytes.size(); index += 2)
    {
        const auto unit = static_cast<unsigned char>(bytes[index]) |
                          (static_cast<unsigned char>(bytes[index + 1]) << 8);
        // Upstream constructs regexes and searched std::wstring values from
        // CString's null-terminated LPCWSTR conversion.
        if (unit == 0 && nullTerminated) break;
        value.push_back(unit);
    }
    return value;
}
static std::string utf8(const std::wstring& units) {
    std::string result;
    for (size_t index = 0; index < units.size(); ++index) {
        unsigned value = units[index];
        if (value >= 0xD800 && value <= 0xDBFF && index + 1 < units.size() && units[index + 1] >= 0xDC00 && units[index + 1] <= 0xDFFF)
            value = 0x10000 + ((value - 0xD800) << 10) + (units[++index] - 0xDC00);
        else if (value >= 0xD800 && value <= 0xDFFF) value = 0xFFFD;
        if (value < 0x80) result.push_back(value);
        else if (value < 0x800) {
            result.push_back(0xC0 | (value >> 6)); result.push_back(0x80 | (value & 0x3F));
        } else if (value < 0x10000) {
            result.push_back(0xE0 | (value >> 12)); result.push_back(0x80 | ((value >> 6) & 0x3F)); result.push_back(0x80 | (value & 0x3F));
        } else {
            result.push_back(0xF0 | (value >> 18)); result.push_back(0x80 | ((value >> 12) & 0x3F));
            result.push_back(0x80 | ((value >> 6) & 0x3F)); result.push_back(0x80 | (value & 0x3F));
        }
    }
    return result;
}
static void style(const char* kind, size_t start, size_t length) {
    if (length) std::cout << kind << '\t' << start << '\t' << length << '\n';
}
static void styles(const std::wstring& checkUnits, const std::wstring& extractUnits, const std::wstring& textUnits) {
    std::cout << "styles\tutf8\n";
    const auto check = utf8(checkUnits), extract = utf8(extractUnits), text = utf8(textUnits);
    if (check.empty()) return;
    const std::regex first(check), second(extract);
    const std::sregex_iterator end;
    for (std::sregex_iterator match(text.cbegin(), text.cend(), first); match != end; ++match) {
        const auto start = match->position(0);
        if (extract.empty()) {
            if (match->size() >= 2) {
                const auto& group = (*match)[1];
                const auto offset = group.first - text.cbegin();
                if (offset >= start) style("context", start, offset - start);
                style("identifier", offset, group.second - group.first);
            }
        } else {
            const std::string section = (*match)[0];
            size_t position = 0;
            for (std::sregex_iterator id(section.cbegin(), section.cend(), second); id != end; ++id) {
                const auto offset = id->position(0);
                if (offset > 0) style("context", start + position, offset - position);
                style("identifier", start + offset, id->length(0));
                position = offset + id->length(0);
            }
            if (position && position < section.size()) style("context", start + position, section.size() - position);
        }
    }
}
int main(int argc, char** argv) {
    const bool batchIssues = argc == 5 && std::string(argv[4]) == "--batch-issue-ids";
    const bool svnRevisions = argc == 5 && std::string(argv[4]) == "--svn-revisions";
    const bool mergeReplace = argc == 5 && std::string(argv[4]) == "--merge-replace";
    const bool styling = argc == 5 && std::string(argv[4]) == "--styles-utf8";
    const bool code = argc == 5 && std::string(argv[4]) == "--code-captures";
    const bool issueIDs = argc == 5 && std::string(argv[4]) == "--issue-ids";
    const bool logRanges = argc == 5 && (std::string(argv[4]) == "--log-ranges-case" || std::string(argv[4]) == "--log-ranges-insensitive");
    const bool logFilter = argc == 5 && (std::string(argv[4]) == "--log-case" || std::string(argv[4]) == "--log-insensitive");
    if (argc != 4 && !styling && !code && !logFilter && !logRanges && !issueIDs && !mergeReplace && !svnRevisions && !batchIssues) { std::cerr << "Expected check pattern, extraction pattern and message files.\n"; return 2; }
    try {
        const auto check = read_units(argv[1]), extract = read_units(argv[2]), text = read_units(argv[3], !code && !logFilter && !logRanges && !mergeReplace && !svnRevisions && !batchIssues);
        if (batchIssues) {
            std::cout << "issues\t1\n";
            std::wregex first, second;
            try { first = std::wregex(check); if (!extract.empty()) second = std::wregex(extract); }
            catch (const std::regex_error&) { return 0; } // Source FindBugID ignores invalid syntax.
            size_t offset = 0, row = 0;
            while (offset < text.size()) {
                if (text.size() - offset < 2) throw std::runtime_error("Invalid issue record header.");
                const size_t length = static_cast<size_t>(text[offset]) | (static_cast<size_t>(text[offset + 1]) << 16); offset += 2;
                if (length > text.size() - offset) throw std::runtime_error("Invalid issue record length.");
                auto value = text.substr(offset, length); offset += length;
                const auto nul = value.find(L'\0'); if (nul != std::wstring::npos) value.resize(nul);
                const std::wsregex_iterator end;
                for (std::wsregex_iterator match(value.cbegin(), value.cend(), first); match != end; ++match) {
                    if (extract.empty()) {
                        if (match->size() >= 2) { const auto& group = (*match)[1]; std::cout << row << '\t' << (group.first - value.cbegin()) << '\t' << (group.second - group.first) << '\n'; }
                    } else {
                        const std::wstring section = (*match)[0];
                        for (std::wsregex_iterator id(section.cbegin(), section.cend(), second); id != end; ++id)
                            std::cout << row << '\t' << (match->position(0) + id->position(0)) << '\t' << id->length(0) << '\n';
                    }
                }
                ++row;
            }
            return 0;
        }
        if (svnRevisions) {
            // Pinned CGitLogListBase::FindSVNRev, including default ECMAScript
            // whole-message anchors. Do not silently broaden to multiline.
            const std::wregex normal(L"^\\s*git-svn-id:\\s+(.*)\\@(\\d+)\\s([a-f\\d\\-]+)$");
            const std::wregex compact(L"^\\s*git-svn-id:\\s(\\d+)\\@([a-f\\d\\-]+)$");
            size_t offset = 0;
            std::cout << "svn\t1\n";
            while (offset < text.size()) {
                if (text.size() - offset < 2) throw std::runtime_error("Invalid SVN record header.");
                const size_t length = static_cast<size_t>(text[offset]) | (static_cast<size_t>(text[offset + 1]) << 16); offset += 2;
                if (length > text.size() - offset) throw std::runtime_error("Invalid SVN record length.");
                auto value = text.substr(offset, length); offset += length;
                const auto nul = value.find(L'\0'); if (nul != std::wstring::npos) value.resize(nul);
                std::wsmatch match; std::wstring revision;
                if (std::regex_search(value, match, normal) && match.size() == 4) revision = match[2];
                else if (std::regex_search(value, match, compact) && match.size() == 3) revision = match[1];
                for (auto digit : revision) std::cout.put(static_cast<char>(digit));
                std::cout.put('\n');
            }
            return 0;
        }
        if (mergeReplace) {
            // CFileTextLines::LineRegex: one default ECMAScript wregex, applied
            // independently to each line; Windows UTF-16 units and $ captures.
            const std::wregex pattern(check);
            size_t offset = 0, emitted = 0;
            auto unit = [](unsigned value) { std::cout.put(value & 255); std::cout.put((value >> 8) & 255); };
            while (offset < text.size()) {
                if (text.size() - offset < 2) throw std::runtime_error("Invalid merge record header.");
                const size_t length = static_cast<size_t>(text[offset]) | (static_cast<size_t>(text[offset + 1]) << 16);
                offset += 2;
                if (length > text.size() - offset) throw std::runtime_error("Invalid merge record length.");
                auto value = text.substr(offset, length); offset += length;
                // CString to LPCWSTR, as upstream LineRegex, stops at NUL.
                const auto nul = value.find(L'\0'); if (nul != std::wstring::npos) value.resize(nul);
                auto replaced = std::regex_replace(value, pattern, extract);
                const auto resultNul = replaced.find(L'\0'); if (resultNul != std::wstring::npos) replaced.resize(resultNul);
                if (replaced.size() > 8 * 1024 * 1024 || emitted + replaced.size() > 8 * 1024 * 1024)
                    throw std::runtime_error("Filtered comparison is too large.");
                emitted += replaced.size(); unit(replaced.size()); unit(replaced.size() >> 16);
                for (auto ch : replaced) unit(ch);
            }
            return 0;
        }
        if (logFilter || logRanges) {
            // FilterHelper validates one ECMAScript expression; invalid syntax
            // leaves the filter inactive, rather than using substring fallback.
            std::wregex pattern;
            if (check.empty()) { std::cout << (logRanges ? "ranges\tinactive\n" : "log\tinactive\n"); return 0; }
            try {
                auto flags = std::regex_constants::ECMAScript;
                if ((std::string(argv[4]) == "--log-insensitive" || std::string(argv[4]) == "--log-ranges-insensitive")) flags |= std::regex_constants::icase;
                pattern.assign(check, flags);
            } catch (const std::regex_error&) { std::cout << (logRanges ? "ranges\tinactive\n" : "log\tinactive\n"); return 0; }
            std::cout << (logRanges ? "ranges\tactive\n" : "log\tactive\n");
            size_t offset = 0, record = 0;
            while (offset < text.size()) {
                if (text.size() - offset < 2) throw std::runtime_error("Invalid log record header.");
                const size_t length = static_cast<size_t>(text[offset]) | (static_cast<size_t>(text[offset + 1]) << 16);
                offset += 2;
                if (length > text.size() - offset) throw std::runtime_error("Invalid log record length.");
                if (logRanges) {
                    const auto begin = text.cbegin() + offset, end = begin + length;
                    for (std::wsregex_iterator match(begin, end, pattern), finish; match != finish; ++match)
                        std::cout << record << '\t' << match->position(0) << '\t' << match->length(0) << '\n';
                    offset += length; ++record; continue;
                }
                bool matched = false;
                if (length) {
                    try { matched = std::regex_search(text.begin() + offset, text.begin() + offset + length, pattern, std::regex_constants::match_any); }
                    catch (const std::exception&) { matched = false; }
                }
                std::cout << (matched ? "1\n" : "0\n"); offset += length;
            }
            return 0;
        }
        if (code) {
            const std::wregex pattern(check, std::regex_constants::icase | std::regex_constants::ECMAScript);
            std::cout << "captures\tutf16\n";
            const std::wsregex_iterator end;
            for (std::wsregex_iterator match(text.cbegin(), text.cend(), pattern); match != end; ++match) {
                for (size_t i = 1; i < match->size(); ++i) {
                    const auto& group = (*match)[i];
                    if (group.first == group.second) continue;
                    // ScanFile inserts the captured wstring via c_str(), so a
                    // captured NUL truncates its candidate, even though the
                    // searched decoded file is an explicit string_view.
                    auto finish = group.first;
                    while (finish != group.second && *finish != 0) ++finish;
                    std::cout << (group.first - text.cbegin()) << '\t' << (finish - group.first) << '\n';
                }
            }
            return 0;
        }
        if (styling) { styles(check, extract, text); return 0; }
        if (check.empty()) { std::cout << "matched\t0\n"; return 0; }
        std::wregex first, second;
        try { first.assign(check); second.assign(extract); }
        catch (const std::regex_error&) {
            if (!issueIDs) throw;
            std::cout << "matched\t0\n"; return 0;
        }
        std::cout << "matched\t" << (std::regex_search(text, first) ? 1 : 0) << '\n';
        const std::wsregex_iterator end;
        for (std::wsregex_iterator match(text.cbegin(), text.cend(), first); match != end; ++match) {
            if (extract.empty()) {
                if (match->size() >= 2) {
                    const auto& group = (*match)[1];
                    std::cout << (group.first - text.cbegin()) << '\t' << (group.second - group.first) << '\n';
                }
            } else {
                const std::wstring section = (*match)[0];
                const auto start = match->position(0);
                for (std::wsregex_iterator id(section.cbegin(), section.cend(), second); id != end; ++id)
                    std::cout << (start + id->position(0)) << '\t' << id->length(0) << '\n';
            }
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
