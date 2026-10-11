## Why
Whole-note embeddings truncate long input. Keyword evidence expansion does not establish semantic recall of paraphrased tail evidence.

## What Changes
Add a synthetic experiment with a fixed model digest, provider version, tokenizer artifact, and corpus hash. Compare current keyword and whole-note hybrid recall before evaluating a bounded passage prototype. Record injected evidence, stale and irrelevant sources, actual tokenizer counts, indexing cost, truncation, and latency.

## Impact
Evaluation artifacts only. Production search, indexing, accepted knowledge, and proposal approval remain unchanged.
