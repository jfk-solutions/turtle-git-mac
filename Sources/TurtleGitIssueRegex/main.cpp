// Issue matching adapted from TortoiseGit ProjectProperties.cpp.
// Copyright (C) 2003-2021, 2023-2025 - TortoiseGit
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
static std::wstring read_units(const char* path) {
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
        if (unit == 0) break;
        value.push_back(unit);
    }
    return value;
}
int main(int argc, char** argv) {
    if (argc != 4) { std::cerr << "Expected check pattern, extraction pattern and message files.\n"; return 2; }
    try {
        const auto check = read_units(argv[1]), extract = read_units(argv[2]), text = read_units(argv[3]);
        if (check.empty()) { std::cout << "matched\t0\n"; return 0; }
        const std::wregex first(check), second(extract);
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
