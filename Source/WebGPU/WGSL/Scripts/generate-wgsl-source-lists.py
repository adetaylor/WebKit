#!/usr/bin/env python3
#
# Copyright (C) 2026 Apple Inc. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
# THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
# THE POSSIBILITY OF SUCH DAMAGE.

"""Writes the source lists of the WGSL Swift module and of its tests into both build systems.

The module is every *.swift file under Source/WebGPU/WGSL/ except those under wgslc/ and wgslfuzz/,
plus TypeDeclarations.swift, which generator/main.rb writes from TypeDeclarations.rb. That one list
becomes the WGSL_SOURCES block of Source/WebGPU/WGSL/CMakeLists.txt and the Sources phase of the
WGSL target of Source/WebGPU/WebGPU.xcodeproj (the TypeDeclarations.swift that the target's
"Generate TypeDeclarations.swift" script phase writes with the generator's --swift mode, WGSLStub.c, and
every .swift file). The tests are every *.swift file directly in Tools/TestWebKitAPI/Tests/WGSL/; they
become the TestWGSL_SWIFT_SOURCES block of Tools/TestWebKitAPI/PlatformCocoa.cmake and, with the
goldens/*.golden files TestWGSL copies, the membership exceptions of the TestWGSL target in
Tools/TestWebKitAPI/TestWebKitAPI.xcodeproj.

Usage: generate-wgsl-source-lists.py [--check] [--wgsl-dir DIR]
  --check         change nothing; exit 1 if either build system disagrees with the files on disk.
  --wgsl-dir DIR  take the sources from DIR instead of the Source/WebGPU/WGSL holding this script, and the
                  tests from the Tools/TestWebKitAPI/Tests/WGSL of the checkout holding DIR.
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys

SCRIPT_WGSL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CMAKE_LISTS = os.path.join(SCRIPT_WGSL_DIR, 'CMakeLists.txt')
PROJECT = os.path.join(os.path.dirname(SCRIPT_WGSL_DIR), 'WebGPU.xcodeproj', 'project.pbxproj')
TESTS_RELATIVE_DIR = os.path.join('Tools', 'TestWebKitAPI', 'Tests', 'WGSL')
TESTS_CMAKE = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(SCRIPT_WGSL_DIR))), 'Tools', 'TestWebKitAPI', 'PlatformCocoa.cmake')
TESTS_PROJECT = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(SCRIPT_WGSL_DIR))), 'Tools', 'TestWebKitAPI', 'TestWebKitAPI.xcodeproj', 'project.pbxproj')
WGSL_DIR = SCRIPT_WGSL_DIR

EXCLUDED_DIRECTORIES = ('wgslc', 'wgslfuzz')
CMAKE_LIST = 'WGSL_SOURCES'
CMAKE_BEGIN = '# BEGIN %s\n' % CMAKE_LIST
CMAKE_END = '# END %s\n' % CMAKE_LIST
TESTS_CMAKE_LIST = 'TestWGSL_SWIFT_SOURCES'
TESTS_CMAKE_BEGIN = '        # BEGIN %s\n' % TESTS_CMAKE_LIST
TESTS_CMAKE_END = '        # END %s\n' % TESTS_CMAKE_LIST
TESTS_CMAKE_PREFIX = '${TESTWEBKITAPI_DIR}/Tests/WGSL/'
XCODE_TARGET = 'WGSL'
WGSL_GROUP = '1CEBD7F62716B33100A5254D'
# The TypeDeclarations.swift that the GENERATOR_PHASE script phase writes, in the project's "Derived Sources" group
# ($(BUILT_PRODUCTS_DIR)/DerivedSources/WebGPU). A script phase, not a build rule: installapi runs no build rules.
GENERATED_REFERENCE = 'E50EBFB88E033E70BAE7E364'
GENERATED_SOURCE = 'DerivedSources/WebGPU/TypeDeclarations.swift'
GENERATOR_PHASE = 'Generate TypeDeclarations.swift'
# Without Swift every other source is excluded; Xcode then still produces the libwgsl.a the other targets link.
STUB = 'WGSLStub.c'
GENERATOR_MODE = '--swift'
# TestWebKitAPI.xcodeproj's Tests folder is a synchronized group: TestWGSL builds the files the first exception
# set lists, and its "Copy WGSL Goldens" phase copies those of the second.
TESTS_PROJECT_SOURCES = ('07C913DF2F820CCA003A09D8', 'WGSL/')
TESTS_PROJECT_GOLDENS = ('E50591ADD7103C24A0B643EF', 'WGSL/goldens/')


def module_sources():
    sources = []
    for directory, subdirectories, files in os.walk(WGSL_DIR):
        relative_directory = os.path.relpath(directory, WGSL_DIR)
        if relative_directory == '.':
            subdirectories[:] = [name for name in subdirectories if name not in EXCLUDED_DIRECTORIES]
            relative_directory = ''
        for name in files:
            if name.endswith('.swift'):
                sources.append(os.path.join(relative_directory, name))
    return sorted(sources)


def test_sources(tests_dir):
    return sorted(name for name in os.listdir(tests_dir) if name.endswith('.swift') and os.path.isfile(os.path.join(tests_dir, name)))


def golden_files(tests_dir):
    goldens_dir = os.path.join(tests_dir, 'goldens')
    return sorted(name for name in os.listdir(goldens_dir) if name.endswith('.golden'))


def plist_string(value):
    # As Xcode writes them: quoted unless every character may appear in an unquoted string.
    if re.match(r'^[A-Za-z0-9_$/:.-]+$', value):
        return value
    return '"%s"' % value.replace('\\', '\\\\').replace('"', '\\"')


def new_id(name):
    # Derived from the path, so that reruns, and the conversion of the WGSL target, agree on the IDs.
    return 'E5' + hashlib.sha1(('WGSL-Swift:' + name).encode()).hexdigest()[:22].upper()


# --- CMake ---------------------------------------------------------------------------------------------

def cmake_block(sources):
    # check-webkit-style's list order: grouped by directory, top level first, one empty line between groups.
    lines = ['set(%s\n' % CMAKE_LIST]
    directory = None
    for source in sorted(sources, key=lambda source: (os.path.dirname(source), source)):
        if directory is not None and os.path.dirname(source) != directory:
            lines.append('\n')
        directory = os.path.dirname(source)
        lines.append('    %s\n' % source)
    lines.append(')\n')
    return ''.join(lines)


def tests_cmake_block(sources):
    lines = ['        list(APPEND TestWGSL_SOURCES\n']
    lines += ['            %s%s\n' % (TESTS_CMAKE_PREFIX, source) for source in sorted(sources)]
    lines.append('        )\n')
    return ''.join(lines)


def block_span(text, begin_marker, end_marker, path):
    begin = text.find(begin_marker)
    end = text.find(end_marker)
    if begin < 0 or end < begin:
        sys.exit('generate-wgsl-source-lists.py: no "%s" ... "%s" block in %s' % (begin_marker.strip(), end_marker.strip(), path))
    return begin + len(begin_marker), end


def cmake_block_span(text):
    return block_span(text, CMAKE_BEGIN, CMAKE_END, CMAKE_LISTS)


def tests_cmake_block_span(text):
    return block_span(text, TESTS_CMAKE_BEGIN, TESTS_CMAKE_END, TESTS_CMAKE)


def cmake_listed(text):
    begin, end = cmake_block_span(text)
    return re.findall(r'^    (\S+\.swift)$', text[begin:end], re.M)


def tests_cmake_listed(text):
    begin, end = tests_cmake_block_span(text)
    return re.findall(r'^            ' + re.escape(TESTS_CMAKE_PREFIX) + r'(\S+\.swift)$', text[begin:end], re.M)


# --- Xcode ---------------------------------------------------------------------------------------------

def exception_name(value):
    # As Xcode writes membership exceptions: quoted unless every character may appear unquoted.
    if re.match(r'^[A-Za-z0-9_$/:.]+$', value):
        return value
    return '"%s"' % value


def exception_sort_key(name):
    # Xcode orders membership exceptions as the Finder does: case-insensitively, numbers by value.
    return [(0, int(part), '') if part.isdigit() else (1, 0, part.lower()) for part in re.split(r'(\d+)', name)]


def exceptions_block(prefix, names):
    return ''.join('\t\t\t\t%s,\n' % exception_name(prefix + name) for name in sorted(names, key=exception_sort_key))


def exceptions_span(text, object_id):
    match = re.search(r'^\t\t' + object_id + r' /\*[^\n]*\*/ = \{\n(?:\t\t\t[^\n]*\n)*?\t\t\tmembershipExceptions = \(\n', text, re.M)
    if not match:
        sys.exit('generate-wgsl-source-lists.py: no membership exception set %s in %s' % (object_id, TESTS_PROJECT))
    return match.end(), text.index('\t\t\t);', match.end())


def exceptions_listed(text, object_id, prefix):
    begin, end = exceptions_span(text, object_id)
    return [name.strip('"')[len(prefix):] for name in re.findall(r'^\t\t\t\t("?[^\n]*?"?),$', text[begin:end], re.M)]


class Project:
    def __init__(self, text):
        self.text = text

    def span(self, object_id):
        match = re.search(r'^\t\t' + object_id + r' (/\*.*?\*/ )?= \{', self.text, re.M)
        if not match:
            return None
        if self.text[match.end():].startswith('isa'):
            end = self.text.index('};\n', match.end()) + 3
        else:
            end = self.text.index('\n\t\t};\n', match.end()) + 6
        return match.start(), end

    def body(self, object_id):
        start, end = self.span(object_id)
        return self.text[start:end]

    def has(self, object_id):
        return self.span(object_id) is not None

    def delete(self, object_id):
        start, end = self.span(object_id)
        self.text = self.text[:start] + self.text[end:]

    def members(self, object_id, key):
        match = re.search(r'\t\t\t' + key + r' = \(\n(.*?)\t\t\t\);', self.body(object_id), re.S)
        return re.findall(r'^\t+([0-9A-F]{24})', match.group(1), re.M) if match else []

    def set_members(self, object_id, key, entries):
        start, end = self.span(object_id)
        body = self.text[start:end]
        match = re.search(r'(\t\t\t' + key + r' = \(\n)(.*?)(\t\t\t\);)', body, re.S)
        listing = ''.join('\t\t\t\t%s /* %s */,\n' % entry for entry in entries)
        body = body[:match.end(1)] + listing + body[match.start(3):]
        self.text = self.text[:start] + body + self.text[end:]

    def append_member(self, object_id, key, entry):
        self.set_members(object_id, key, [(member, self.comment(member)) for member in self.members(object_id, key)] + [entry])

    def remove_member(self, object_id, key, member):
        self.set_members(object_id, key, [(other, self.comment(other)) for other in self.members(object_id, key) if other != member])

    def comment(self, object_id):
        match = re.search(r'^\t\t' + object_id + r' /\* (.*?) \*/ = \{', self.text, re.M)
        return match.group(1)

    def add(self, section, entry):
        """Inserts the object before the first one of the section with a greater ID, as Xcode orders them."""
        begin = self.text.index('/* Begin %s section */\n' % section)
        end = self.text.index('/* End %s section */' % section)
        index = end
        for match in re.finditer(r'^\t\t([0-9A-F]{24}) ', self.text[begin:end], re.M):
            if match.group(1) > entry[2:26]:
                index = begin + match.start()
                break
        self.text = self.text[:index] + entry + self.text[index:]

    def value(self, object_id, key):
        match = re.search(r'\b' + key + r' = ("(?:[^"\\]|\\.)*"|[^;]*);', self.body(object_id))
        return match.group(1).strip('"') if match else None

    def is_group(self, object_id):
        return 'isa = PBXGroup;' in self.body(object_id)

    def target(self, name):
        for match in re.finditer(r'^\t\t([0-9A-F]{24}) /\* %s \*/ = \{\n\t\t\tisa = PBXNativeTarget;' % re.escape(name), self.text, re.M):
            return match.group(1)
        sys.exit('generate-wgsl-source-lists.py: no target %s in %s' % (name, PROJECT))

    def sources_phase(self, target):
        for phase in self.members(target, 'buildPhases'):
            if 'isa = PBXSourcesBuildPhase;' in self.body(phase):
                return phase
        sys.exit('generate-wgsl-source-lists.py: target %s has no Sources phase' % XCODE_TARGET)

    def generator_phase(self, target):
        for phase in self.members(target, 'buildPhases'):
            if 'isa = PBXShellScriptBuildPhase;' in self.body(phase) and self.value(phase, 'name') == GENERATOR_PHASE:
                return phase
        sys.exit('generate-wgsl-source-lists.py: target %s has no "%s" script phase' % (XCODE_TARGET, GENERATOR_PHASE))

    def file_references(self, group, prefix=''):
        """Maps the path of every file reference under the group (relative to it) to its ID; subgroups by path."""
        files, groups = {}, {}
        for child in self.members(group, 'children'):
            path = self.value(child, 'path')
            name = self.value(child, 'name')
            if self.is_group(child):
                directory = os.path.join(prefix, path) if path else prefix
                if path and directory not in groups:
                    groups[directory] = child
                child_files, child_groups = self.file_references(child, directory)
                files.update(child_files)
                groups.update(child_groups)
            elif path:
                files[os.path.join(prefix, path)] = child
            elif name:
                files[os.path.join(prefix, name)] = child
        return files, groups


def xcode_listed(project, target):
    files, _ = project.file_references(WGSL_GROUP)
    paths = {reference: path for path, reference in files.items()}
    paths[GENERATED_REFERENCE] = GENERATED_SOURCE
    listed = []
    for build_file in project.members(project.sources_phase(target), 'files'):
        reference = re.search(r'fileRef = ([0-9A-F]{24})', project.body(build_file)).group(1)
        listed.append(paths.get(reference, '<file reference %s outside the WGSL group>' % reference))
    script = project.value(project.generator_phase(target), 'shellScript')
    return sorted(listed), (' %s ' % GENERATOR_MODE) in script


def group_for(project, groups, directory):
    if directory in groups:
        return groups[directory]
    parent = group_for(project, groups, os.path.dirname(directory)) if os.path.dirname(directory) else WGSL_GROUP
    name = os.path.basename(directory)
    group = new_id('group:' + directory)
    project.add('PBXGroup', '\t\t%s /* %s */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t);\n\t\t\tpath = %s;\n\t\t\tsourceTree = "<group>";\n\t\t};\n' % (group, name, plist_string(name)))
    project.append_member(parent, 'children', (group, name))
    groups[directory] = group
    return group


def update_project(project, sources):
    target = project.target(XCODE_TARGET)
    phase = project.sources_phase(target)
    files, groups = project.file_references(WGSL_GROUP)

    # File references of .swift files that no longer exist on disk.
    for path, reference in sorted(files.items()):
        if not path.endswith('.swift') or os.path.exists(os.path.join(WGSL_DIR, path)):
            continue
        for build_file in re.findall(r'^\t\t([0-9A-F]{24}) /\*[^*]*\*/ = \{isa = PBXBuildFile; fileRef = ' + reference, project.text, re.M):
            for owner in re.findall(r'^\t\t([0-9A-F]{24}) /\* [^*]* \*/ = \{\n\t\t\tisa = PBX\w+BuildPhase;', project.text, re.M):
                if build_file in project.members(owner, 'files'):
                    project.remove_member(owner, 'files', build_file)
            project.delete(build_file)
        for group in [WGSL_GROUP] + list(groups.values()):
            if reference in project.members(group, 'children'):
                project.remove_member(group, 'children', reference)
        project.delete(reference)
        del files[path]
    for directory, group in sorted(groups.items(), key=lambda item: -item[0].count('/')):
        if os.path.isdir(os.path.join(WGSL_DIR, directory)) or project.members(group, 'children'):
            continue
        parent = groups.get(os.path.dirname(directory), WGSL_GROUP)
        project.remove_member(parent, 'children', group)
        project.delete(group)
        del groups[directory]

    entries = []
    project.generator_phase(target)
    generated = new_id('build:%s/%s' % (XCODE_TARGET, GENERATED_SOURCE))
    if not project.has(generated):
        project.add('PBXBuildFile', '\t\t%s /* TypeDeclarations.swift in Sources */ = {isa = PBXBuildFile; fileRef = %s /* TypeDeclarations.swift */; };\n' % (generated, GENERATED_REFERENCE))
    entries.append((generated, 'TypeDeclarations.swift in Sources'))
    stub = new_id('build:%s/%s' % (XCODE_TARGET, STUB))
    if not project.has(stub):
        project.add('PBXBuildFile', '\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n' % (stub, STUB, files[STUB], STUB))
    entries.append((stub, '%s in Sources' % STUB))
    for source in sources:
        name = os.path.basename(source)
        reference = files.get(source)
        if not reference:
            reference = new_id('ref:WGSL/' + source)
            project.add('PBXFileReference', '\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = %s; sourceTree = "<group>"; };\n' % (reference, name, plist_string(name)))
            directory = os.path.dirname(source)
            project.append_member(group_for(project, groups, directory) if directory else WGSL_GROUP, 'children', (reference, name))
        build_file = new_id('build:%s/%s' % (XCODE_TARGET, source))
        if not project.has(build_file):
            project.add('PBXBuildFile', '\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n' % (build_file, name, reference, name))
        entries.append((build_file, '%s in Sources' % name))

    for build_file in project.members(phase, 'files'):
        if build_file not in [entry[0] for entry in entries]:
            project.delete(build_file)
    project.set_members(phase, 'files', entries)


def write_if_changed(path, text):
    with open(path) as file:
        if file.read() == text:
            return False
    with open(path, 'w') as file:
        file.write(text)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--check', action='store_true', help='compare only; exit 1 on a difference')
    parser.add_argument('--wgsl-dir', default=SCRIPT_WGSL_DIR, help='where to find the sources')
    arguments = parser.parse_args()
    global WGSL_DIR
    WGSL_DIR = os.path.abspath(arguments.wgsl_dir)
    source_root = os.path.dirname(os.path.dirname(os.path.dirname(WGSL_DIR)))

    sources = module_sources()
    tests = test_sources(os.path.join(source_root, TESTS_RELATIVE_DIR))
    with open(CMAKE_LISTS) as file:
        cmake_text = file.read()
    with open(TESTS_CMAKE) as file:
        tests_cmake_text = file.read()
    with open(PROJECT) as file:
        project = Project(file.read())
    goldens = golden_files(os.path.join(source_root, TESTS_RELATIVE_DIR))
    with open(TESTS_PROJECT) as file:
        tests_project_text = file.read()
    tests_project_sets = ((TESTS_PROJECT_SOURCES, tests), (TESTS_PROJECT_GOLDENS, goldens))

    if arguments.check:
        problems = []
        cmake_sources = cmake_listed(cmake_text)
        for source in sorted(set(sources) - set(cmake_sources)):
            problems.append('CMakeLists.txt %s: missing %s' % (CMAKE_LIST, source))
        for source in sorted(set(cmake_sources) - set(sources)):
            problems.append('CMakeLists.txt %s: not a module source: %s' % (CMAKE_LIST, source))
        begin, end = cmake_block_span(cmake_text)
        if not problems and cmake_text[begin:end] != cmake_block(sources):
            problems.append('CMakeLists.txt %s: not in the generated form' % CMAKE_LIST)
        tests_listed = tests_cmake_listed(tests_cmake_text)
        tests_problems = []
        for source in sorted(set(tests) - set(tests_listed)):
            tests_problems.append('PlatformCocoa.cmake %s: missing %s' % (TESTS_CMAKE_LIST, source))
        for source in sorted(set(tests_listed) - set(tests)):
            tests_problems.append('PlatformCocoa.cmake %s: not a test source: %s' % (TESTS_CMAKE_LIST, source))
        begin, end = tests_cmake_block_span(tests_cmake_text)
        if not tests_problems and tests_cmake_text[begin:end] != tests_cmake_block(tests):
            tests_problems.append('PlatformCocoa.cmake %s: not in the generated form' % TESTS_CMAKE_LIST)
        problems += tests_problems
        for (object_id, prefix), names in tests_project_sets:
            listed = exceptions_listed(tests_project_text, object_id, prefix)
            label = 'TestWebKitAPI.xcodeproj exception set %s' % object_id
            set_problems = ['%s: missing %s%s' % (label, prefix, name) for name in sorted(set(names) - set(listed))]
            set_problems += ['%s: not a TestWGSL file: %s%s' % (label, prefix, name) for name in sorted(set(listed) - set(names))]
            begin, end = exceptions_span(tests_project_text, object_id)
            if not set_problems and tests_project_text[begin:end] != exceptions_block(prefix, names):
                set_problems.append('%s: not in the generated form' % label)
            problems += set_problems
        xcode_sources, xcode_runs_generator_mode = xcode_listed(project, project.target(XCODE_TARGET))
        expected = sorted(sources + [GENERATED_SOURCE, STUB])
        for source in sorted(set(expected) - set(xcode_sources)):
            problems.append('%s Sources phase: missing %s' % (XCODE_TARGET, source))
        for source in sorted(set(xcode_sources) - set(expected)):
            problems.append('%s Sources phase: not a module source: %s' % (XCODE_TARGET, source))
        if len(xcode_sources) != len(set(xcode_sources)):
            problems.append('%s Sources phase: duplicate entries' % XCODE_TARGET)
        if not xcode_runs_generator_mode:
            problems.append('%s "%s" script phase: the generator does not run with %s' % (XCODE_TARGET, GENERATOR_PHASE, GENERATOR_MODE))
        for problem in problems:
            print('generate-wgsl-source-lists.py --check: %s' % problem)
        if problems:
            print('generate-wgsl-source-lists.py --check: run Source/WebGPU/WGSL/Scripts/generate-wgsl-source-lists.py')
            return 1
        return 0

    begin, end = cmake_block_span(cmake_text)
    if write_if_changed(CMAKE_LISTS, cmake_text[:begin] + cmake_block(sources) + cmake_text[end:]):
        print('generate-wgsl-source-lists.py: updated %s' % CMAKE_LISTS)
    begin, end = tests_cmake_block_span(tests_cmake_text)
    if write_if_changed(TESTS_CMAKE, tests_cmake_text[:begin] + tests_cmake_block(tests) + tests_cmake_text[end:]):
        print('generate-wgsl-source-lists.py: updated %s' % TESTS_CMAKE)
    for (object_id, prefix), names in tests_project_sets:
        begin, end = exceptions_span(tests_project_text, object_id)
        tests_project_text = tests_project_text[:begin] + exceptions_block(prefix, names) + tests_project_text[end:]
    if write_if_changed(TESTS_PROJECT, tests_project_text):
        print('generate-wgsl-source-lists.py: updated %s' % TESTS_PROJECT)
    update_project(project, sources)
    with open(PROJECT) as file:
        before = file.read()
    if write_if_changed(PROJECT, project.text):
        subprocess.check_call([os.path.join(source_root, 'Tools', 'Scripts', 'sort-Xcode-project-file'), PROJECT])
        with open(PROJECT) as file:
            if file.read() != before:
                print('generate-wgsl-source-lists.py: updated %s' % PROJECT)
    return 0


if __name__ == '__main__':
    sys.exit(main())
