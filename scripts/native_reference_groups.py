"""Plan reference QA groups from the existing driver's cases and default policy.

The driver remains authoritative for fixture generation, assertions, arguments,
permissions, environment, subprocess ownership and parent/worker handoffs.
"""
import ast
from pathlib import Path
import re

DECLARATION = re.compile(r'(?m)^(?:@\w+(?:\([^\n]*\))?\s+)*(?:(?:final|public|internal)\s+)*(?:struct|class|enum|protocol|typealias|func)\s+(\w+)')
TOKEN = re.compile(r'\b\w+\b')


def inventory(root: Path):
    driver = root / 'scripts/test-native-reference-batch.py'
    tree = ast.parse(driver.read_text())
    cases = ast.literal_eval(next(node.value for node in tree.body if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == 'CASES' for target in node.targets)))
    default = next(node.iter.values[1] for node in ast.walk(tree) if isinstance(node, ast.For)
        and isinstance(node.target, ast.Name) and node.target.id == 'case' and isinstance(node.iter, ast.BoolOp)
        and isinstance(node.iter.values[1], ast.ListComp))
    # Evaluate only the repository's existing literal/default expressions, not
    # the driver module (which would compile and execute native applications).
    selected = eval(compile(ast.Expression(default), str(driver), 'eval'), {'CASES': cases})
    path_expression = next(node.value for node in ast.walk(tree) if isinstance(node, ast.Assign)
        and any(isinstance(target, ast.Name) and target.id == 'fixture' for target in node.targets)
        and isinstance(node.value, ast.BinOp))
    paths = {case: eval(compile(ast.Expression(path_expression), str(driver), 'eval'), {'root': root, 'case': case}) for case in cases}
    texts = {case: path.read_text() for case, path in paths.items()}
    owners = {}
    for case, source in texts.items():
        for name in DECLARATION.findall(source):
            owners.setdefault(name, set()).add(case)
    dependencies = {case: {next(iter(owners[name])) for name in set(TOKEN.findall(source))
                          if name in owners and len(owners[name]) == 1} - {case}
                    for case, source in texts.items()}
    pairs = next(ast.literal_eval(node.iter) for node in tree.body if isinstance(node, ast.For)
                 and isinstance(node.target, ast.Tuple) and [item.id for item in node.target.elts] == ['parent', 'worker'])
    for parent, worker in pairs:
        dependencies[parent].add(worker)
    return cases, selected, paths, dependencies


def plan(cases, selected, dependencies, size, check_all=False):
    if size < 1:
        raise ValueError('Group size must be positive')

    def group(primary, run):
        compiled = set(primary)
        while True:
            expanded = compiled | {dependency for case in compiled for dependency in dependencies[case]}
            if compiled == expanded:
                break
            compiled = expanded
        return {'run': run, 'compile': primary,
                'include': [case for case in cases if case in compiled and case not in primary]}

    groups = [group(selected[offset:offset + size], selected[offset:offset + size])
              for offset in range(0, len(selected), size)]
    if check_all:
        compiled = {case for row in groups for case in row['compile'] + row['include']}
        omitted = [case for case in cases if case not in compiled]
        # The former monolith also typechecked captures/helpers that its default
        # runtime excludes. Preserve that check without launching those cases.
        groups = [group(omitted[offset:offset + size], []) for offset in range(0, len(omitted), size)] + groups
    return groups
