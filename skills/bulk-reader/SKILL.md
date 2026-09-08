---
name: bulk-reader
description: "Delegate bulk file reading to a cheap headless Claude worker. Use when you need to read files >350 lines, answer questions across 3+ files, or summarize large diffs."
---

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/bulk-read --question "<question>" --paths <file1> [<file2> ...]
```

Each call is independent. To ask a follow-up, ask again with the same `--paths` — the
files go to the worker, never into your context, so re-sending them costs you nothing
here (it does cost a small delegated-model call each time).

Verify specific line numbers or exact values before using them in edits.
