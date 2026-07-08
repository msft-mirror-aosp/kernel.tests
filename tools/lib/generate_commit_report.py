#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import os

def run_cmd(cmd, cwd):
    result = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, errors='replace')
    if result.returncode != 0:
        sys.stderr.write(f"Command failed: {' '.join(cmd)}\nError: {result.stderr}\n")
        return None
    return result.stdout.strip()

def main():
    parser = argparse.ArgumentParser(description="Extract commit metadata for AI analysis.")
    parser.add_argument("--repo_path", required=True, help="Path to the git repository.")
    parser.add_argument("--good_rev", required=True, help="The last known good commit.")
    parser.add_argument("--bad_rev", required=True, help="The first known bad commit.")
    parser.add_argument("--project_name", default="unknown", help="Name of the project.")
    parser.add_argument("--out_file", required=True, help="Path to the output JSON file.")

    args = parser.parse_args()

    if not os.path.isdir(args.repo_path):
        sys.stderr.write(f"Error: Repository path does not exist: {args.repo_path}\n")
        sys.exit(1)

    revision_range = f"{args.good_rev}..{args.bad_rev}"

    # We use a distinct delimiter to split safely.
    delimiter = "=====_END_OF_COMMIT_5a9b8c7====="
    git_log_cmd = [
        "git", "log", revision_range,
        f"--format=%H%n%an%n%aI%n%s%n%b%n{delimiter}"
    ]

    log_output = run_cmd(git_log_cmd, cwd=args.repo_path)
    if log_output is None:
        sys.exit(1)

    commits = []
    if log_output:
        raw_commits = log_output.split(delimiter)
        for raw in raw_commits:
            raw = raw.strip()
            if not raw:
                continue

            lines = raw.split('\n')
            if len(lines) < 4:
                continue

            commit_hash = lines[0]
            author = lines[1]
            date = lines[2]
            subject = lines[3]
            body = '\n'.join(lines[4:]).strip()

            # Get files changed for this specific commit
            files_cmd = ["git", "diff-tree", "--no-commit-id", "--name-status", "-r", commit_hash]
            files_output = run_cmd(files_cmd, cwd=args.repo_path)

            files_changed = []
            if files_output:
                for f_line in files_output.split('\n'):
                    if f_line.strip():
                        parts = f_line.split('\t', 1)
                        if len(parts) == 2:
                            files_changed.append({"status": parts[0].strip(), "file": parts[1].strip()})

            commits.append({
                "commit_hash": commit_hash,
                "author": author,
                "date": date,
                "subject": subject,
                "body": body,
                "files_changed": files_changed
            })

    report = {
        "project_name": args.project_name,
        "revision_range": revision_range,
        "commits": commits
    }

    with open(args.out_file, 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    print(f"Successfully generated commit report: {args.out_file}")

if __name__ == "__main__":
    main()
