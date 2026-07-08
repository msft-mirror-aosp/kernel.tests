#!/usr/bin/env python3
# Copyright 2026 The Android Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
diff_manifests.py

A lightweight CLI tool to compare two Android XML manifests and identify
Added, Removed, and Changed projects based on their revisions.
"""

import argparse
import json
import sys
import xml.etree.ElementTree as ET

BUILD_TYPE_PRIORITIES = {
    'pb': {
        'frameworks/base': 100,
        'frameworks/native': 90,
        'system/core': 85,
        'system/sepolicy': 80,
        'hardware/interfaces': 75,
        'art': 70,
        'bionic': 70,
    },
    'kb': {
        'common': 100,
        'common-modules/virtual-device': 90,
        'build/kernel': 80,
        'build/kleaf': 80,
    },
    'vkb': {
        'private/gs-google': 100,
        'private/msm-google': 100,
        'private/google-modules/display': 90,
        'private/google-modules/touch': 90,
        'private/google-modules/bms': 85,
        'private/google-modules/camera': 85,
        'common': 70,
    },
    'sb': {
        'system/sepolicy': 100,
        'system/core': 95,
        'frameworks/base': 90,
        'frameworks/native': 85,
        'hardware/interfaces': 80,
    }
}


def parse_manifest(filepath):
    """
    Parses an Android manifest XML and returns a dict mapping project paths to revisions.
    Handles fallback to <default> revision and prefers 'path' over 'name'.
    """
    try:
        tree = ET.parse(filepath)
    except Exception as e:
        sys.stderr.write(f"Error parsing {filepath}: {e}\n")
        sys.exit(1)

    root = tree.getroot()
    default_node = root.find('default')
    default_rev = default_node.get('revision') if default_node is not None else None

    projects = {}
    for p in root.findall('project'):
        # In Android manifests, 'path' is where it checks out. 'name' is the remote repo name.
        path = p.get('path') or p.get('name')
        rev = p.get('revision') or default_rev

        # We assume if it's explicitly removed by a child manifest, we shouldn't track it.
        # However, a standard manifest usually won't have <remove-project> in a flat output.
        # But we check for it just in case.
        if path and rev:
            projects[path] = rev

    # Handle remove-project if it exists (usually only in local_manifests, but good practice)
    for p in root.findall('remove-project'):
        name = p.get('name')
        if name in projects:
            del projects[name]

    return projects

def _is_path_ignored(path, ignore_prefixes):
    for prefix in ignore_prefixes:
        clean_prefix = prefix.rstrip('/')
        if path == clean_prefix or path.startswith(clean_prefix + '/'):
            return True
    return False


def diff_projects(good_projects, bad_projects, build_type=None, ignore_prefixes=None):
    """
    Compares two project dictionaries and returns a list of dictionaries with diff results.
    Returns: [{'status': 'CHANGED|ADDED|REMOVED|IGNORED', 'path': ..., 'good_rev': ..., 'bad_rev': ...}]
    """
    if ignore_prefixes is None:
        ignore_prefixes = []

    results = []

    # Check for CHANGED and ADDED
    for path, bad_rev in bad_projects.items():
        is_ignored = _is_path_ignored(path, ignore_prefixes)

        if path in good_projects:
            good_rev = good_projects[path]
            if good_rev != bad_rev:
                status = 'IGNORED' if is_ignored else 'CHANGED'
                results.append({
                    'status': status,
                    'path': path,
                    'good_rev': good_rev,
                    'bad_rev': bad_rev
                })
        else:
            if not is_ignored:
                results.append({
                    'status': 'ADDED',
                    'path': path,
                    'good_rev': 'None',
                    'bad_rev': bad_rev
                })

    # Check for REMOVED
    for path, good_rev in good_projects.items():
        if path not in bad_projects:
            is_ignored = _is_path_ignored(path, ignore_prefixes)
            if not is_ignored:
                results.append({
                    'status': 'REMOVED',
                    'path': path,
                    'good_rev': good_rev,
                    'bad_rev': 'None'
                })

    # Sort by priority, then alphabetically
    priority_map = BUILD_TYPE_PRIORITIES.get(build_type, {})
    results.sort(key=lambda x: (-priority_map.get(x['path'], 0), x['path']))
    return results


def print_table(results):
    if not results:
        print("No changes found.")
        return

    print(f"{'STATUS':<10} | {'PROJECT PATH':<40} | {'GOOD REVISION':<40} | {'BAD REVISION':<40}")
    print("-" * 138)
    for r in results:
        status = r['status']
        path = r['path']
        good = r['good_rev'][:40]
        bad = r['bad_rev'][:40]
        print(f"{status:<10} | {path:<40} | {good:<40} | {bad:<40}")


def print_parsable(results):
    for r in results:
        print(f"{r['status']}|{r['path']}|{r['good_rev']}|{r['bad_rev']}")


def print_json(results):
    print(json.dumps(results, indent=2))


def main():
    parser = argparse.ArgumentParser(description="Compare two Android repo manifests.")
    parser.add_argument("good_manifest", help="Path to the 'good' or older manifest XML")
    parser.add_argument("bad_manifest", help="Path to the 'bad' or newer manifest XML")
    parser.add_argument(
        "--format",
        choices=["table", "parsable", "json"],
        default="table",
        help="Output format. 'table' is human readable. 'parsable' is pipe-separated for scripts."
    )
    parser.add_argument("--build_type", help="Build type code (e.g. pb, kb) for sorting priorities.")
    parser.add_argument("--ignore", action="append", help="Prefix of project paths to ignore.", default=[])

    args = parser.parse_args()

    good_projects = parse_manifest(args.good_manifest)
    bad_projects = parse_manifest(args.bad_manifest)

    diff_results = diff_projects(good_projects, bad_projects, args.build_type, args.ignore)

    if args.format == "table":
        print_table(diff_results)
    elif args.format == "parsable":
        print_parsable(diff_results)
    elif args.format == "json":
        print_json(diff_results)


if __name__ == "__main__":
    main()
