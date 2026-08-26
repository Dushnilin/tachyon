#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const rootDir = path.resolve(__dirname, '..');
const docsDir = process.argv[2] ? path.resolve(process.argv[2]) : path.join(rootDir, 'docs', 'knowledge-base');
const outputFile = process.argv[3] ? path.resolve(process.argv[3]) : path.join(rootDir, 'tachyon', 'files', 'usr', 'lib', 'tachyon', 'rag_index.json');
const chunkSize = parseInt(process.env.CHUNK_SIZE || '2000', 10);
const chunkOverlap = parseInt(process.env.CHUNK_OVERLAP || '200', 10);

function chunkText(text, fileName, cSize, cOverlap) {
  const chunks = [];
  const lines = text.split('\n');
  let currentChunk = [];
  let currentLen = 0;
  let lastHeading = '';

  for (const line of lines) {
    const m = line.match(/^(#{1,4})\s+(.*)/);
    if (m) {
      lastHeading = m[2].trim();
    }

    currentChunk.push(line);
    currentLen += line.length + 1;

    if (currentLen >= cSize) {
      const chunkStr = currentChunk.join('\n').trim();
      if (chunkStr) {
        chunks.push({
          text: chunkStr,
          file: fileName,
          heading: lastHeading,
        });
      }

      const overlapLines = [];
      let overlapLen = 0;
      for (let i = currentChunk.length - 1; i >= 0; i--) {
        overlapLines.unshift(currentChunk[i]);
        overlapLen += currentChunk[i].length + 1;
        if (overlapLen >= cOverlap) {
          break;
        }
      }

      currentChunk = overlapLines;
      currentLen = overlapLen;
    }
  }

  if (currentChunk.length > 0) {
    const chunkStr = currentChunk.join('\n').trim();
    if (chunkStr) {
      chunks.push({
        text: chunkStr,
        file: fileName,
        heading: lastHeading,
      });
    }
  }

  return chunks;
}

const allChunks = [];
const mdFiles = fs.readdirSync(docsDir).filter((f) => f.endsWith('.md')).sort();

for (const fname of mdFiles) {
  const fpath = path.join(docsDir, fname);
  const content = fs.readFileSync(fpath, 'utf8');
  const fileChunks = chunkText(content, fname, chunkSize, chunkOverlap);
  allChunks.push(...fileChunks);
  process.stderr.write(`  ${fname}: ${fileChunks.length} chunks\n`);
}

const index = {
  version: 1,
  chunk_size: chunkSize,
  chunk_overlap: chunkOverlap,
  total_chunks: allChunks.length,
  files: mdFiles,
  chunks: allChunks.map((c, i) => ({
    id: i,
    file: c.file,
    heading: c.heading,
    text: c.text,
    embedding: [],
  })),
};

fs.mkdirSync(path.dirname(outputFile), { recursive: true });
fs.writeFileSync(outputFile, JSON.stringify(index), 'utf8');

const totalChars = allChunks.reduce((acc, c) => acc + c.text.length, 0);
process.stderr.write(`\nRAG index: ${allChunks.length} chunks, ${totalChars} chars -> ${outputFile}\n`);
console.log(`RAG index built: ${outputFile}`);
