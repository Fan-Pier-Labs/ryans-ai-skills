"""Shared file discovery for the code-quality-audit scripts. Pure read.

Uses `git ls-files` (tracked + untracked-but-not-ignored) when the root is a git repo so
build output and vendored trees that are gitignored never count; falls back to os.walk.
Vendored / generated / binary files are excluded either way.
"""
import os, re, subprocess

VENDOR_DIRS = {
    "node_modules", "vendor", "dist", "build", "out", ".next", ".nuxt", ".svelte-kit", "coverage",
    "__pycache__", ".venv", "venv", "env", ".git", ".hg", ".tox", ".mypy_cache", ".pytest_cache",
    ".ruff_cache", "target", "obj", ".terraform", ".idea", ".vscode", "site-packages", ".cache",
    "storybook-static", ".turbo", ".parcel-cache", "Pods", "DerivedData", ".gradle", ".dart_tool",
    "third_party", "thirdparty", "external", "bower_components", "jspm_packages", ".yarn",
}
GENERATED_HINTS = (".min.js", ".min.css", ".map", ".lock", "-lock.json", "-lock.yaml", ".snap",
                   ".pb.go", "_pb2.py", "_pb2_grpc.py", ".generated.", ".g.dart", ".d.ts",
                   "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Cargo.lock", "poetry.lock",
                   "Gemfile.lock", "composer.lock", "go.sum")
LANG_BY_EXT = {
    ".py": "python", ".pyi": "python",
    ".ts": "typescript", ".tsx": "typescript", ".mts": "typescript", ".cts": "typescript",
    ".js": "javascript", ".jsx": "javascript", ".mjs": "javascript", ".cjs": "javascript",
    ".vue": "javascript", ".svelte": "javascript",
    ".go": "go", ".rs": "rust", ".rb": "ruby", ".java": "java", ".kt": "kotlin", ".kts": "kotlin",
    ".cs": "csharp", ".php": "php", ".swift": "swift", ".scala": "scala", ".ex": "elixir",
    ".exs": "elixir", ".c": "c", ".h": "c", ".cc": "cpp", ".cpp": "cpp", ".hpp": "cpp",
    ".m": "objc", ".dart": "dart", ".sh": "shell", ".bash": "shell", ".zsh": "shell",
    ".sql": "sql", ".tf": "terraform",
}
SOURCE_EXT = {e for e, l in LANG_BY_EXT.items() if l not in ("shell", "sql", "terraform")}
TEST_DIR_PARTS = {"test", "tests", "__tests__", "spec", "specs", "e2e", "integration", "integration_tests",
                  "cypress", "playwright", "testing", "fixtures", "__mocks__", "features"}
TEST_FILE_RE = re.compile(r"(^|[._-])(test|tests|spec|specs)([._-]|$)|^test_|_test\.(go|py|rb|rs|ts|js)$|\.e2e\.|^conftest\.py$", re.I)
MAX_BYTES = 2 * 1024 * 1024


def _git_files(root):
    p = subprocess.run(["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                       capture_output=True)
    if p.returncode != 0:
        return None
    return [f for f in p.stdout.decode("utf-8", "replace").split("\0") if f]


def list_files(root, extra_exclude=()):
    """Relative paths (posix separators) of every non-vendored, non-generated regular file."""
    root = os.path.abspath(root)
    excl = set(VENDOR_DIRS) | set(extra_exclude)
    rel = _git_files(root)
    if rel is None:
        rel = []
        for d, dirs, files in os.walk(root):
            dirs[:] = [x for x in dirs if x not in excl]
            for f in files:
                rel.append(os.path.relpath(os.path.join(d, f), root).replace(os.sep, "/"))
    out = []
    for f in sorted(set(rel)):
        parts = f.split("/")
        if any(p in excl for p in parts[:-1]):
            continue
        if any(h in parts[-1] for h in GENERATED_HINTS):
            continue
        full = os.path.join(root, f)
        try:
            st = os.stat(full)
        except OSError:
            continue
        if not os.path.isfile(full) or st.st_size > MAX_BYTES:
            continue
        out.append(f)
    return out


def language_of(path):
    return LANG_BY_EXT.get(os.path.splitext(path)[1].lower())


def is_source(path):
    return os.path.splitext(path)[1].lower() in SOURCE_EXT


def is_test(path):
    parts = path.split("/")
    if any(p.lower() in TEST_DIR_PARTS for p in parts[:-1]):
        return True
    return bool(TEST_FILE_RE.search(parts[-1]))


def read_text(root, rel):
    try:
        with open(os.path.join(root, rel), "rb") as fh:
            b = fh.read()
        if b"\0" in b[:4096]:
            return None
        return b.decode("utf-8", "replace")
    except OSError:
        return None
