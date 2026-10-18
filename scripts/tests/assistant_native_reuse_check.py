#!/usr/bin/env python3
"""Small host checks of the production capacity and recurrent-prefix policy."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
include = root / 'Packages/QFLocalLLM/Sources/QFLocalLLM'
with tempfile.TemporaryDirectory(prefix='native-reuse-', dir=root / '.build') as folder:
    folder = Path(folder)
    source = folder / 'check.cpp'
    source.write_text(r'''
#include "QFInferenceReuse.h"
#include <cassert>
#include <iostream>
int main() {
 assert(qf_context_capacity(256, 384, 4096) == 1024);
 assert(qf_context_capacity(80, 32, 4096) == 512);
 assert(qf_context_capacity(3000, 384, 4096) == 4096);
 assert(qf_context_capacity(4090, 32, 4096) == 0);
 assert(qf_context_capacity(900, 192, 1024) == 0);
 std::vector<int> past{1, 2, 3}, next{1, 2, 3, 4, 5};
 assert(qf_can_append_context("user|home|zh|offline", "user|home|zh|offline", past, next, 512, 32, 2, 2));
 for (const char *scope : {"other|home|zh|offline", "user|other|zh|offline", "user|home|en|offline", "user|home|zh|online", ""})
  assert(!qf_can_append_context("user|home|zh|offline", scope, past, next, 512, 32, 2, 2));
 assert(!qf_can_append_context("s", "s", past, std::vector<int>{1, 8, 3, 4}, 512, 32, 2, 2));
 assert(!qf_can_append_context("s", "s", past, std::vector<int>{1, 2}, 512, 32, 2, 2));
 assert(!qf_can_append_context("s", "s", past, past, 512, 32, 2, 2));
 assert(!qf_can_append_context("s", "s", {}, next, 512, 32, 2, 2));
 assert(!qf_can_append_context("s", "s", past, next, 30, 32, 2, 2));
 assert(!qf_can_append_context("s", "s", past, next, 512, 32, 1, 2));
 std::cout << "PASS native capacity and append-only scope isolation\n";
}
''')
    binary = folder / 'check'
    subprocess.run(['xcrun', 'clang++', '-std=c++17', '-I', str(include), str(source), '-o', str(binary)], check=True, timeout=45)
    subprocess.run([str(binary)], check=True, timeout=10)
