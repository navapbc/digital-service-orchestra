#!/usr/bin/env node
// plugins/dso/scripts/recipe-adapters/ts-morph-add-parameter.mjs
// Adds a parameter to a TypeScript function and updates all callers.
// Input: RECIPE_PARAM_FILE, RECIPE_PARAM_FUNCTION, RECIPE_PARAM_NAME, RECIPE_PARAM_TYPE, RECIPE_PARAM_DEFAULT (optional)
// Output: JSON to stdout

import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import path from 'path';
import { existsSync } from 'fs';

const require = createRequire(import.meta.url);

// Find ts-morph in working dir node_modules or globally
const workingDir = process.env.RECIPE_WORKING_DIR || process.cwd();
let Project, SyntaxKind;
try {
    const tsMorphPath = path.join(workingDir, 'node_modules', 'ts-morph');
    if (existsSync(tsMorphPath)) {
        ({ Project, SyntaxKind } = require(tsMorphPath));
    } else {
        ({ Project, SyntaxKind } = require('ts-morph'));
    }
} catch (e) {
    process.stdout.write(JSON.stringify({
        files_changed: [], transforms_applied: 0,
        errors: [`ts-morph not found: ${e.message}`], exit_code: 1,
        engine_name: 'ts-morph', degraded: true
    }) + '\n');
    process.exit(1);
}

const file = process.env.RECIPE_PARAM_FILE;
const funcName = process.env.RECIPE_PARAM_FUNCTION;
const paramName = process.env.RECIPE_PARAM_NAME;
const paramType = process.env.RECIPE_PARAM_TYPE || 'unknown';
const paramDefault = process.env.RECIPE_PARAM_DEFAULT;

if (!file || !funcName || !paramName) {
    process.stdout.write(JSON.stringify({
        files_changed: [], transforms_applied: 0,
        errors: ['RECIPE_PARAM_FILE, RECIPE_PARAM_FUNCTION, and RECIPE_PARAM_NAME are required'],
        exit_code: 1, engine_name: 'ts-morph', degraded: false
    }) + '\n');
    process.exit(1);
}

try {
    const project = new Project({
        tsConfigFilePath: path.join(workingDir, 'tsconfig.json'),
        skipAddingFilesFromTsConfig: false
    });
    const sourceFile = project.getSourceFileOrThrow(file);
    const func = sourceFile.getFunctionOrThrow(funcName);

    // Check idempotency: if param already exists, no-op
    const existingParam = func.getParameter(paramName);
    if (existingParam) {
        process.stdout.write(JSON.stringify({
            files_changed: [], transforms_applied: 0,
            errors: [], exit_code: 0, engine_name: 'ts-morph', degraded: false
        }) + '\n');
        process.exit(0);
    }

    // Add parameter
    const paramStructure = { name: paramName, type: paramType };
    if (paramDefault !== undefined) paramStructure.initializer = paramDefault;
    func.addParameter(paramStructure);

    // Find all call references and update them
    const refs = func.findReferencesAsNodes();
    let transformCount = 0;
    for (const ref of refs) {
        const callExpr = ref.getParentIfKind && ref.getParentIfKind(SyntaxKind.CallExpression);
        if (callExpr) {
            if (paramDefault === undefined) {
                callExpr.addArgument('undefined');
            }
            transformCount++;
        }
    }

    await project.save();
    const changedFiles = project.getSourceFiles()
        .filter(sf => !sf.wasForgotten())
        .map(sf => path.relative(workingDir, sf.getFilePath()));

    process.stdout.write(JSON.stringify({
        files_changed: changedFiles,
        transforms_applied: transformCount + 1,
        errors: [],
        exit_code: 0,
        engine_name: 'ts-morph',
        degraded: false
    }) + '\n');
} catch (e) {
    process.stdout.write(JSON.stringify({
        files_changed: [], transforms_applied: 0,
        errors: [e.message], exit_code: 1,
        engine_name: 'ts-morph', degraded: false
    }) + '\n');
    process.exit(1);
}
