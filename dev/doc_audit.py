"""
=============================================================================
  FILE        : Farm_Vendor/dev/doc_audit.py
  PACKAGE     : Farm Vendor  (MacroQuest Lua / EverQuest)
  VERSION     : 1.4.0
  CHANGES     : 1.4.0  The header is looked for in the first 90 lines (was
                       60): CHANGES grows with every release, and the
                       init.lua and ui.lua headers passed 60 lines.
                1.3.0  First version for Farm Vendor, adapted from the
                       SkillMaster audit (same seven checks).
                       'end,' and '},' count as structure lines.

  CREDITS     : Adapted from the SkillMaster dev/doc_audit.py by the same
                author. Original to this author; no outside code.

  WHAT  : Checks that every Lua file in the package meets the documentation
          standard described in ARCHITECTURE.md, and prints anything that
          does not.

  WHY   : The project rule is that all code is fully documented. Reading
          about four thousand lines by eye after every edit is not
          realistic, so this script does the checking. Run it after any
          change and fix whatever it reports before calling the change
          finished.

  WHERE : Lives in Farm_Vendor/dev/. Not used by the game; MacroQuest
          ignores Python files. Run it from a normal command prompt.

  HOW   : For each .lua file in the package folder it checks, in order:
            1. Header block has FILE, PACKAGE, VERSION, CHANGES, CREDITS,
               WHAT, WHY, WHERE, HOW and WHEN.
            2. Footer block has END OF FILE.
            3. VERSION matches the newest entry in CHANGELOG.md, and the
               file's CHANGES list has an entry for that version.
            4. Every function has a doc block with WHAT, WHY, WHERE, HOW and
               WHEN above it (or an inline comment directly above it).
            5. Every line of code has a comment at the end of the line or
               within the three lines above it.
            6. Every "SECTION : name" block (the former modules inside core
               and engine) has WHAT, WHY, WHERE, HOW and WHEN within its doc
               block and a matching "END OF SECTION : name" footer.
            7. Every header has a CREDITS line (part of check 1).
          Exit code is 0 when everything passes, 1 when anything fails.

  WHEN  : After every edit to any .lua file, before packaging a new zip.

  USAGE : python dev/doc_audit.py          (run from the Farm_Vendor folder)
=============================================================================
"""

import glob    # finds the .lua files
import os      # builds paths relative to this script
import re      # pattern matching for headers, versions and functions
import sys     # exit code

# The package folder is the parent of dev/. Using the script's own location
# means the audit works no matter which folder you run it from.
PACKAGE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Labels every file header must contain.
HEADER_TAGS = ['FILE', 'PACKAGE', 'VERSION', 'CHANGES', 'CREDITS', 'WHAT', 'WHY', 'WHERE', 'HOW', 'WHEN']

# Labels every function doc block must contain.
FUNC_TAGS = ['WHAT', 'WHY', 'WHERE', 'HOW', 'WHEN']

# Lines that are pure structure and need no comment of their own.
# 'end,' and '},' close table entries and are as trivial as 'end'.
TRIVIAL = {'end', 'end,', 'else', '}', '},', '{', '})', 'end)', 'return', 'break'}


def latest_changelog_version():
    """
    WHAT  : Returns the newest version number listed in CHANGELOG.md.
    WHY   : Every file's VERSION line must match it.
    WHERE : Called once by main.
    HOW   : Finds the first "## x.y.z" heading; the changelog lists newest
            first.
    WHEN  : At the start of the audit.
    """
    path = os.path.join(PACKAGE_DIR, 'CHANGELOG.md')
    with open(path, encoding='utf-8') as fh:
        match = re.search(r'^## (\d+\.\d+\.\d+)', fh.read(), re.M)  # first heading
    return match.group(1) if match else None                         # None if missing


def comment_map(lines):
    """
    WHAT  : Returns a list of booleans, True where a line is a comment.
    WHY   : Lines inside --[[ ... ]] blocks look like code to a simple check,
            so block comments must be tracked properly.
    WHERE : Called by audit_file.
    HOW   : Walks the lines, entering block mode on --[[ and leaving it on ]].
            Lines starting with -- are comments too.
    WHEN  : Once per file.
    """
    is_comment = [False] * len(lines)  # default: code
    in_block = False                    # inside a --[[ block?
    for i, line in enumerate(lines):
        stripped = line.strip()
        if in_block:
            is_comment[i] = True                     # still inside the block
            if ']]' in stripped:
                in_block = False                     # block ends on this line
            continue
        if stripped.startswith('--[['):
            is_comment[i] = True                     # block starts here
            if ']]' not in stripped[4:]:
                in_block = True                      # and continues below
        elif stripped.startswith('--'):
            is_comment[i] = True                     # single line comment
    return is_comment


def audit_file(path, version):
    """
    WHAT  : Runs all five checks on one Lua file. Returns a list of problems.
    WHY   : One function per file keeps the report grouped by file.
    WHERE : Called by main for each .lua file.
    HOW   : See the HOW list in the file header.
    WHEN  : Once per file.
    """
    problems = []
    with open(path, encoding='utf-8') as fh:
        text = fh.read()
    lines = text.split('\n')
    header = '\n'.join(lines[:90])     # header is always in the first 90 lines
    footer = '\n'.join(lines[-80:])    # footer is always in the last 80 lines

    # Check 1: header labels.
    for tag in HEADER_TAGS:
        if tag not in header:
            problems.append('header missing ' + tag)

    # Check 2: footer.
    if 'END OF FILE' not in footer:
        problems.append('footer missing END OF FILE')

    # Check 3: version matches the changelog and has a CHANGES entry.
    match = re.search(r'VERSION\s*:\s*(\d+\.\d+\.\d+)', header)
    if not match or match.group(1) != version:
        problems.append('VERSION is %s, changelog says %s' % (match and match.group(1), version))
    changes = re.search(r'CHANGES\s*:(.*?)\n\s*\n', text, re.S)
    if not changes or version not in changes.group(1):
        problems.append('CHANGES has no entry for ' + str(version))

    # Check 6: section doc blocks in the consolidated files.
    for m in re.finditer(r'^\s*SECTION\s*:\s*(\w+)', text, re.M):      # each section
        name = m.group(1)                                             # section name
        block = text[m.start():text.find(']]--', m.start())]          # its doc block
        for tag in FUNC_TAGS:
            if tag not in block:
                problems.append('section %s doc missing %s' % (name, tag))
        if not re.search(r'END OF SECTION\s*:\s*%s\b' % name, text):  # footer present?
            problems.append('section %s has no END OF SECTION footer' % name)

    is_comment = comment_map(lines)
    func_re = re.compile(r'\s*(local\s+)?function\s+([\w\.:]+)')

    for i, line in enumerate(lines):
        stripped = line.strip()

        # Check 4: function doc blocks.
        m = func_re.match(line)
        if m and not is_comment[i]:
            above = '\n'.join(lines[max(0, i - 40):i])               # 40 lines above
            has_block = all(tag in above for tag in FUNC_TAGS)        # full doc block
            has_inline = i > 0 and lines[i - 1].strip().startswith('--')
            if not (has_block or has_inline):
                problems.append('line %d: function %s has no doc block' % (i + 1, m.group(2)))

        # Check 5: every code line explained.
        if not stripped or is_comment[i] or stripped in TRIVIAL:
            continue                                                  # nothing to explain
        if '--' in line:
            continue                                                  # end of line comment
        explained = False
        for j in range(i - 1, max(-1, i - 4), -1):                    # up to 3 lines above
            if is_comment[j] or '--' in lines[j]:
                explained = True
                break
        if not explained:
            problems.append('line %d: no comment: %s' % (i + 1, stripped[:60]))
    return problems


def main():
    """
    WHAT  : Audits every .lua file and prints a report.
    WHY   : Entry point when the script is run.
    WHERE : Bottom of this file.
    HOW   : Reads the changelog version, audits each file, prints PASS or the
            problem list, and exits 0 or 1.
    WHEN  : When run from the command line.
    """
    version = latest_changelog_version()
    print('Changelog version:', version)
    failed = False
    for path in sorted(glob.glob(os.path.join(PACKAGE_DIR, '*.lua'))):
        problems = audit_file(path, version)
        name = os.path.basename(path)
        if problems:
            failed = True
            print('FAIL', name)
            for p in problems:
                print('   ', p)
        else:
            print('PASS', name)
    sys.exit(1 if failed else 0)   # non zero tells a calling script it failed


if __name__ == '__main__':
    main()   # only runs when executed directly, not when imported

# =============================================================================
#   END OF FILE : Farm_Vendor/dev/doc_audit.py
#
#   HOW TO EDIT SAFELY
#     - To require a new header label, add it to HEADER_TAGS.
#     - The "within 3 lines above" rule is the range(i - 1, ..., -1) loop in
#       audit_file. Changing it changes the standard; update ARCHITECTURE.md
#       to match.
# =============================================================================
