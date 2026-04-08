#!/usr/bin/env node
// plugins/dso/scripts/recipe-adapters/ts-morph-normalize-imports.mjs
// Sorts and deduplicates TypeScript import statements using ts-morph organizeImports.
// Input: RECIPE_PARAM_FILE or RECIPE_PARAM_DIR (env vars)
// Output: JSON to stdout

import { createRequire } from 'module';
import path from 'path';
import { existsSync } from 'fs';

const require = createRequire(import.meta.url);

// Find ts-morph in working dir node_modules or globally
const workingDir = process.env.RECIPE_WORKING_DIR || process.cwd();
let Project;
try {
    const tsMorphPath = path.join(workingDir, 'node_modules', 'ts-morph');
    if (existsSync(tsMorphPath)) {
        ({ Project } = require(tsMorphPath));
    } else {
        ({ Project } = require('ts-morph'));
    }
} catch (e) {
    process.stdout.write(JSON.stringify({
        files_changed: [], transforms_applied: 0,
        errors: [`ts-morph not found: ${e.message}`], exit_code: 1,
        degraded: false, engine_name: 'ts-morph'
    }) + '\n');
    process.exit(1);
}

const targetFile = process.env.RECIPE_PARAM_FILE;
const targetDir = process.env.RECIPE_PARAM_DIR;

if (!targetFile && !targetDir) {
    process.stdout.write(JSON.stringify({
        files_changed: [], transforms_applied: 0,
        errors: ['RECIPE_PARAM_FILE or RECIPE_PARAM_DIR is required'],
        exit_code: 1, degraded: false, engine_name: 'ts-morph'
    }) + '\n');
    process.exit(1);
}

try {
    const tsConfigPath = path.join(workingDir, 'tsconfig.json');
    const project = existsSync(tsConfigPath)
        ? new Project({ tsConfigFilePath: tsConfigPath, skipAddingFilesFromTsConfig: false })
        : new Project();

    let sourceFiles;
    if (targetFile) {
        const sf = existsSync(targetFile)
            ? project.addSourceFileAtPath(targetFile)
            : project.addSourceFileAtPathIfExists(targetFile);
        sourceFiles = sf ? [sf] : [];
    } else {
        project.addSourceFilesAtPaths(path.join(targetDir, '**/*.ts'));
        sourceFiles = project.getSourceFiles();
    }

    const filesChanged = [];
    let transformCount = 0;

    for (const sf of sourceFiles) {
        const before = sf.getFullText();
        sf.organizeImports();
        const after = sf.getFullText();
        if (before !== after) {
            filesChanged.push(path.relative(workingDir, sf.getFilePath()));
            transformCount++;
        }
    }

    await project.save();

    process.stdout.write(JSON.stringify({
        files_changed: filesChanged,
        transforms_applied: transformCount,
        errors: [],
        exit_code: 0,
        degraded: false,
        engine_name: 'ts-morph'
    }) + '\n');
} catch (e) {
    process.stdout.write(JSON.stringify({
        files_changed: [], transforms_applied: 0,
        errors: [e.message], exit_code: 1,
        degraded: false, engine_name: 'ts-morph'
    }) + '\n');
    process.exit(1);
}
