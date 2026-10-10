// TurtleGit for Mac. Layout configuration adapted from TortoiseGit
// CRevisionGraphWnd (copyright TortoiseSVN/TortoiseGit contributors).
// SPDX-License-Identifier: GPL-2.0-or-later
#include <ogdf/basic/GraphAttributes.h>
#include <ogdf/layered/SugiyamaLayout.h>
#include <ogdf/layered/OptimalRanking.h>
#include <ogdf/layered/MedianHeuristic.h>
#include <ogdf/layered/FastHierarchyLayout.h>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <queue>
#include <stdexcept>
#include <vector>

int main(int argc, char **argv) {
    try {
        if (argc != 2) throw std::runtime_error("Expected one graph input file.");
        std::ifstream input(argv[1]);
        std::string magic;
        size_t count = 0, edgeCount = 0;
        if (!(input >> magic >> count >> edgeCount) || magic != "TGGRAPH1"
            || count > 1000000 || edgeCount > 10000000)
            throw std::runtime_error("Invalid graph header.");
        ogdf::Graph graph;
        ogdf::GraphAttributes attributes(graph, ogdf::GraphAttributes::nodeGraphics | ogdf::GraphAttributes::edgeGraphics);
        std::vector<ogdf::node> nodes;
        for (size_t i = 0; i < count; ++i) {
            double width, height;
            if (!(input >> width >> height) || !std::isfinite(width) || !std::isfinite(height)
                || width <= 0 || height <= 0 || width > 1000000 || height > 1000000)
                throw std::runtime_error("Invalid node dimensions.");
            auto node = graph.newNode();
            nodes.push_back(node);
            attributes.width(node) = width; attributes.height(node) = height;
        }
        std::vector<ogdf::edge> edges;
        std::vector<std::vector<size_t>> children(count);
        std::vector<size_t> indegrees(count, 0);
        for (size_t i = 0; i < edgeCount; ++i) {
            size_t from, to;
            if (!(input >> from >> to) || from >= count || to >= count || from == to)
                throw std::runtime_error("Invalid graph edge.");
            edges.push_back(graph.newEdge(nodes[from], nodes[to]));
            children[from].push_back(to); ++indegrees[to];
        }
        std::string extra;
        if (input >> extra) throw std::runtime_error("Unexpected graph input.");
        std::queue<size_t> ready;
        for (size_t i = 0; i < count; ++i) if (indegrees[i] == 0) ready.push(i);
        size_t visited = 0;
        while (!ready.empty()) {
            auto i = ready.front(); ready.pop(); ++visited;
            for (auto next : children[i]) if (--indegrees[next] == 0) ready.push(next);
        }
        if (visited != count) throw std::runtime_error("Revision graph contains a cycle.");
        if (count) {
            ogdf::SugiyamaLayout layout;
            layout.setRanking(new ogdf::OptimalRanking());
            layout.setCrossMin(new ogdf::MedianHeuristic());
            auto hierarchy = new ogdf::FastHierarchyLayout();
            hierarchy->layerDistance(30.0); hierarchy->nodeDistance(25.0);
            layout.setLayout(hierarchy);
            layout.call(attributes);
        }
        std::cout << std::setprecision(17) << "TGGRAPH1 " << count << ' ' << edgeCount << '\n';
        for (auto node : nodes)
            std::cout << attributes.x(node) << ' ' << attributes.y(node) << '\n';
        for (auto edge : edges) {
            const auto &bends = attributes.bends(edge);
            std::cout << bends.size();
            for (const auto &point : bends) std::cout << ' ' << point.m_x << ' ' << point.m_y;
            std::cout << '\n';
        }
        return std::cout ? 0 : 2;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n'; return 1;
    } catch (...) {
        std::cerr << "Graph layout failed.\n"; return 1;
    }
}
