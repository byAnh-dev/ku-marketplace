const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

// Each test gets isolated application modules and explicitly supplies any
// native or transport substitutes. The production TypeScript executes unchanged.
function createAppLoader({ modules, globals = {} }) {
  const context = vm.createContext({
    console, URL, Headers, Response, AbortController, setTimeout, clearTimeout, fetch,
    process: { env: { EXPO_PUBLIC_API_URL: 'http://marketplace.test:8080/' } },
    ...globals,
  });
  const cache = new Map();
  function load(file) {
    if (!path.extname(file)) file += fs.existsSync(`${file}.ts`) ? '.ts' : '.tsx';
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} };
    cache.set(file, module);
    const output = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
      fileName: file,
    }).outputText;
    const localRequire = name => {
      if (Object.hasOwn(modules, name)) return modules[name];
      if (name.startsWith('.')) return load(path.resolve(path.dirname(file), name));
      throw new Error(`Unapproved test substitution: ${name}`);
    };
    vm.runInContext(`(function(require, module, exports) {\n${output}\n})`, context, { filename: file })(localRequire, module, module.exports);
    return module.exports;
  }
  return load;
}

module.exports = { createAppLoader };
