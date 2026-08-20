#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DOCS_DIR="${1:-$ROOT_DIR/docs/knowledge-base}"
OUTPUT_DIR="${2:-$ROOT_DIR/tachyon/files/usr/lib/tachyon}"
OUTPUT_FILE="$OUTPUT_DIR/rag_index.json"

CHUNK_SIZE="${CHUNK_SIZE:-2000}"
CHUNK_OVERLAP="${CHUNK_OVERLAP:-200}"

mkdir -p "$OUTPUT_DIR"

python3 - "$DOCS_DIR" "$OUTPUT_FILE" "$CHUNK_SIZE" "$CHUNK_OVERLAP" <<'PYTHON_SCRIPT'
import sys
import os
import json
import re

docs_dir = sys.argv[1]
output_file = sys.argv[2]
chunk_size = int(sys.argv[3])
chunk_overlap = int(sys.argv[4])

def extract_headings(text):
    headings = []
    for line in text.split('\n'):
        m = re.match(r'^(#{1,4})\s+(.*)', line)
        if m:
            headings.append((len(m.group(1)), m.group(2).strip()))
    return headings

def get_section_heading(headings, pos, text):
    best = ""
    current_pos = 0
    for level, title in headings:
        idx = text.find(title, current_pos)
        if idx == -1:
            continue
        if idx <= pos:
            best = title
        current_pos = idx + len(title)
    return best

def chunk_text(text, file_name, chunk_size, chunk_overlap):
    chunks = []
    lines = text.split('\n')
    current_chunk = []
    current_len = 0
    last_heading = ""

    for line in lines:
        m = re.match(r'^(#{1,4})\s+(.*)', line)
        if m:
            last_heading = m.group(2).strip()

        current_chunk.append(line)
        current_len += len(line) + 1

        if current_len >= chunk_size:
            chunk_text_str = '\n'.join(current_chunk).strip()
            if chunk_text_str:
                chunks.append({
                    'text': chunk_text_str,
                    'file': file_name,
                    'heading': last_heading
                })

            overlap_lines = []
            overlap_len = 0
            for prev_line in reversed(current_chunk):
                overlap_lines.insert(0, prev_line)
                overlap_len += len(prev_line) + 1
                if overlap_len >= chunk_overlap:
                    break

            current_chunk = overlap_lines
            current_len = overlap_len

    if current_chunk:
        chunk_text_str = '\n'.join(current_chunk).strip()
        if chunk_text_str:
            chunks.append({
                'text': chunk_text_str,
                'file': file_name,
                'heading': last_heading
            })

    return chunks

all_chunks = []
md_files = sorted([f for f in os.listdir(docs_dir) if f.endswith('.md')])

for fname in md_files:
    fpath = os.path.join(docs_dir, fname)
    with open(fpath, 'r', encoding='utf-8') as f:
        content = f.read()

    file_chunks = chunk_text(content, fname, chunk_size, chunk_overlap)
    all_chunks.extend(file_chunks)
    print(f"  {fname}: {len(file_chunks)} chunks", file=sys.stderr)

index = {
    'version': 1,
    'chunk_size': chunk_size,
    'chunk_overlap': chunk_overlap,
    'total_chunks': len(all_chunks),
    'files': md_files,
    'chunks': [
        {
            'id': i,
            'file': c['file'],
            'heading': c['heading'],
            'text': c['text'],
            'embedding': []
        }
        for i, c in enumerate(all_chunks)
    ]
}

with open(output_file, 'w', encoding='utf-8') as f:
    json.dump(index, f, ensure_ascii=False, indent=None)

total_chars = sum(len(c['text']) for c in all_chunks)
print(f"\nRAG index: {len(all_chunks)} chunks, {total_chars} chars -> {output_file}", file=sys.stderr)
PYTHON_SCRIPT

echo "RAG index built: $OUTPUT_FILE"
