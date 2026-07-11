#!/usr/bin/env node
"use strict";

const fs = require("fs");

function usage() {
  console.error("Usage: semantic_json_compare.js <expected.json> <actual.json>");
  process.exit(2);
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (error) {
    console.error(`Failed to read JSON ${file}: ${error.message}`);
    process.exit(2);
  }
}

function normalize(value) {
  if (Array.isArray(value)) return value.map(normalize);
  if (value && typeof value === "object") {
    const result = {};
    for (const key of Object.keys(value).sort()) result[key] = normalize(value[key]);
    return result;
  }
  return value;
}

function diff(expected, actual, path) {
  if (Object.is(expected, actual)) return null;

  const expectedArray = Array.isArray(expected);
  const actualArray = Array.isArray(actual);
  if (expectedArray || actualArray) {
    if (!expectedArray || !actualArray) return `${path}: type mismatch`;
    if (expected.length !== actual.length) return `${path}: array length ${expected.length} != ${actual.length}`;
    for (let i = 0; i < expected.length; i++) {
      const nested = diff(expected[i], actual[i], `${path}[${i}]`);
      if (nested) return nested;
    }
    return null;
  }

  const expectedObject = expected && typeof expected === "object";
  const actualObject = actual && typeof actual === "object";
  if (expectedObject || actualObject) {
    if (!expectedObject || !actualObject) return `${path}: type mismatch`;
    const expectedKeys = Object.keys(expected).sort();
    const actualKeys = Object.keys(actual).sort();
    if (expectedKeys.join("\n") !== actualKeys.join("\n")) {
      const missing = expectedKeys.filter((key) => !actualKeys.includes(key));
      const extra = actualKeys.filter((key) => !expectedKeys.includes(key));
      return `${path}: object keys differ missing=[${missing.join(",")}] extra=[${extra.join(",")}]`;
    }
    for (const key of expectedKeys) {
      const nested = diff(expected[key], actual[key], `${path}.${key}`);
      if (nested) return nested;
    }
    return null;
  }

  return `${path}: ${JSON.stringify(expected)} != ${JSON.stringify(actual)}`;
}

function main() {
  if (process.argv.length !== 4) usage();
  const expected = normalize(readJson(process.argv[2]));
  const actual = normalize(readJson(process.argv[3]));
  const mismatch = diff(expected, actual, "$");
  if (mismatch) {
    console.error(mismatch);
    process.exit(1);
  }
}

main();
