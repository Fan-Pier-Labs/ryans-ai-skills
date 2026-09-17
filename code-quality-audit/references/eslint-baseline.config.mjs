// ─────────────────────────────────────────────────────────────────────────────
// Baseline ESLint config — the rule set Q16 measures a repo against.
//
// This file is a REFERENCE, not the lint config for this repo (which is bash,
// python and markdown). It is the flat config from a production TypeScript
// monorepo, with the project-specific paths and product references removed.
// Q16 in `quality-checklist.md` asks what percent of the rules below the repo
// under review has enabled. Recommended: 100%.
//
// Why these rules and not "eslint:recommended plus taste": almost every rule
// here catches code that COMPILES, RUNS, and does something other than what it
// reads as. `.sort()` without a comparator, `.filter(p)[0]`, a floating
// promise, an `await` on a non-thenable, `'${x}'` in single quotes, a `for…in`
// over an array, spreading a Map into an object. tsc accepts all of it. Style
// rules are left to a formatter (prettier or biome); nothing here argues about
// commas.
//
// The type-aware rules (everything needing `projectService`) are the reason
// this set is worth adopting. They are also the reason lint needs every
// package's dependencies installed: a missing node_modules degrades imports to
// `any` and the type-aware rules silently stop seeing anything. A rule that
// matches nothing is indistinguishable from a clean repo, which is why the
// adoption method below insists on canaries.
//
// ── How to adopt it without a 4,000-violation wall ──────────────────────────
// The wave method, which is how this set was built:
//   1. Turn a candidate rule on alone and count: `eslint . --rule '{"x":"error"}'`.
//   2. If it reports ZERO violations, it costs nothing — but do not trust the
//      zero yet. Plant a violation the rule must catch (a canary), confirm it
//      fires, remove it. Now the zero is evidence rather than a silent no-op.
//   3. Commit every zero-violation rule as a ratchet. They cost no code changes
//      today and stop the first instance from ever arriving.
//   4. What is left has real violations. Fix per rule, smallest count first,
//      one PR per rule so review stays about the code and not the config.
//      Baseline what you cannot fix yet (`--max-warnings`, a scoped override)
//      with a tracking issue, never a blanket `off`.
// A rule set built this way is green on day one and stays green, which is the
// only version of this that survives contact with a deadline.
//
// ── Adapting it ────────────────────────────────────────────────────────────
// Search for ADAPT: below — five places need this repo's own paths. Anything
// marked DECISION is a deliberate narrowing of a rule; keep the comment with
// the rule so the next person does not "fix" it. Plain JavaScript repos lose
// every `@typescript-eslint/*` rule and should treat the core rules as the
// baseline, which is a much weaker check — the finding is the missing
// TypeScript, not the missing rules.
//
// Peer deps: eslint, typescript-eslint, @eslint/js, globals,
// eslint-plugin-import-x, eslint-plugin-react-hooks (the last two only for the
// blocks that use them).
// ─────────────────────────────────────────────────────────────────────────────

import globals from "globals";
import pluginJs from "@eslint/js";
import tseslint from "typescript-eslint";
import importX from "eslint-plugin-import-x";
import reactHooks from "eslint-plugin-react-hooks";

export default [
  {
    // ADAPT: build output, vendored trees, generated code, and anything this
    // config should not see. Keep this list short and honest — every entry is
    // code nobody is linting.
    // DECISION: `**/*.js` and `*.config.*` are unlinted here because every
    // source file in the origin repo is TypeScript. In a mixed repo, drop the
    // `**/*.js` ignore and accept that the type-aware rules will not apply to
    // those files.
    ignores: [
      "dist/**",
      "build/**",
      "out/**",
      "coverage/**",
      "**/node_modules/**",
      "**/dist/**",
      ".claude/**",
      "*.config.*",
      "**/*.js",
    ],
  },
  { files: ["**/*.ts", "**/*.tsx"] },
  { languageOptions: { globals: globals.node } },
  pluginJs.configs.recommended,
  ...tseslint.configs.recommended,

  // Type-aware rules. The project service resolves each file against its
  // package's tsconfig, so lint (and CI) needs every package's deps installed —
  // a missing node_modules degrades imports to `any` and the rules below
  // silently stop seeing them.
  {
    files: ["**/*.ts", "**/*.tsx"],
    languageOptions: {
      parserOptions: {
        // DECISION: no allowDefaultProject escape hatch, so every TS file
        // belongs to a real tsconfig project and gets full type-aware linting.
        // A new file outside every tsconfig fails lint with "not found by the
        // project service" — the fix is to put it in a project, not exempt it.
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
    rules: {
      "@typescript-eslint/await-thenable": "error",
      // `indexOf(...) !== -1` and single-token regex tests read clearer as `.includes(...)`.
      "@typescript-eslint/prefer-includes": "error",
      // Referencing a class method without its receiver silently loses `this`.
      "@typescript-eslint/unbound-method": "error",
      // `str.match(re)` and `re.exec(str)` are identical for non-global
      // regexes, and exec is the clearer read; the rule declines to convert
      // /g patterns, where the two genuinely differ.
      "@typescript-eslint/prefer-regexp-exec": "error",
      // An async function that never awaits is either needlessly promise-typed
      // or missing the await it was written for; both deserve a look.
      "@typescript-eslint/require-await": "error",
      // `parseInt(s)` reads as "parse a decimal number", but the radix comes
      // from the string: "0x10" is 16, not 0. Every call says which base it meant.
      "radix": "error",
      // A `.map`/`.filter`/`.reduce` callback that falls off its end yields
      // `undefined` for that element and the array quietly fills with holes —
      // a callback run only for its side effects belongs in `.forEach`.
      "array-callback-return": "error",
      // A bare `.sort()` stringifies every element first, so numbers come out
      // [1, 10, 2] and Dates sort by their English text. Only an array that is
      // already string[] may sort without a comparator.
      "@typescript-eslint/require-array-sort-compare": "error",

      // ── Cheap correctness rules, all zero-violation in a clean codebase ────
      "@typescript-eslint/no-unnecessary-type-arguments": "error",
      "@typescript-eslint/no-unnecessary-boolean-literal-compare": "error",
      "@typescript-eslint/prefer-string-starts-ends-with": "error",
      "@typescript-eslint/no-implied-eval": "error",
      "@typescript-eslint/no-array-delete": "error",
      "@typescript-eslint/no-duplicate-type-constituents": "error",
      "@typescript-eslint/no-redundant-type-constituents": "error",
      "@typescript-eslint/prefer-reduce-type-parameter": "error",
      // `for…in` over an array iterates string indices, and the prototype chain.
      "@typescript-eslint/no-for-in-array": "error",
      "@typescript-eslint/no-meaningless-void-operator": "error",
      "@typescript-eslint/no-mixed-enums": "error",
      // `a && a.b` reads as `a?.b`. The rule only converts when truthiness
      // semantics are preserved, and downgrades to a suggestion when the
      // expression VALUE changes (null/'' vs undefined) — check those by hand.
      "@typescript-eslint/prefer-optional-chain": "error",
      // Type-aware: flags calls to anything @deprecated in its declaration.
      // Catches dependency renames the day you upgrade, not months later.
      "@typescript-eslint/no-deprecated": "error",
      // Private fields assigned only in the constructor/initializer are marked
      // readonly so mutation shows up in review.
      "@typescript-eslint/prefer-readonly": "error",
      "@typescript-eslint/no-unnecessary-type-assertion": "error",
      // `.filter(p)[0]` builds a whole array to keep one element — `.find(p)`.
      "@typescript-eslint/prefer-find": "error",
      // `x as T` where `T` is just the non-null of x reads clearer as `x!`.
      "@typescript-eslint/non-nullable-type-assertion-style": "error",
      // A template literal wrapping one string and nothing else is just quotes.
      "@typescript-eslint/no-unnecessary-template-expression": "error",
      // `.catch(err => …)` gets `unknown`, matching useUnknownInCatchVariables.
      "@typescript-eslint/use-unknown-in-catch-callback-variable": "error",
      // The single highest-value rule in this file: an unawaited promise loses
      // its rejection, and the failure surfaces as "nothing happened".
      "@typescript-eslint/no-floating-promises": "error",
      // Type-only imports vanish at compile time; marking them keeps a
      // bundler from pulling a module in (or keeping a side-effect edge) for
      // something that was only ever a type — stylistic for tsc, load-bearing
      // for bundlers. `inline-type-imports` merges into one statement instead
      // of splitting every import in two. `disallowTypeAnnotations: false`
      // keeps `typeof import(...)` legal.
      "@typescript-eslint/consistent-type-imports": ["error", {
        fixStyle: "inline-type-imports",
        disallowTypeAnnotations: false,
      }],
      // Companion to the rule above: when EVERY specifier is inline-`type`,
      // `verbatimModuleSyntax` still emits a runtime `import "./x"`, keeping
      // the module edge and its side effects alive for something that was only
      // ever a type. Hoisting the marker to the statement drops the edge.
      "@typescript-eslint/no-import-type-side-effects": "error",
      // DECISION: `attributes: false` allows the idiomatic async JSX handler
      // (onPress={handleSave}) — React ignores the returned promise, and the
      // alternative is wrapping every handler in `() => void f()` noise. All
      // other void positions (callbacks, setInterval, spreads) stay checked.
      "@typescript-eslint/no-misused-promises": ["error", {
        checksVoidReturn: { attributes: false },
      }],
      // DECISION: no runtime import() in product code — a static import says
      // what a module needs where every reader and every bundler can see it.
      // Load-bearing dynamic imports (cycle breakers, import-order
      // requirements, deliberate cold-start deferral) carry a line-level
      // disable with the reason. Test files are exempt below: they import
      // dynamically to control mock/module ordering.
      "no-restricted-syntax": ["error", {
        selector: "ImportExpression",
        message: "No runtime import() in product code — use a static import, or disable this line with a comment saying why the dynamic import is load-bearing.",
      }],
      // A non-primitive in a string position renders "[object Object]", which
      // ships to the user where real data should be.
      "@typescript-eslint/no-base-to-string": "error",
      // A void-returning call in value position (`return console.log(x)`,
      // `const y = arr.push(v)`) reads as if it produced something.
      // `ignoreArrowShorthand` keeps the idiomatic concise arrow
      // `() => doVoidThing()`.
      "@typescript-eslint/no-confusing-void-expression": ["error", { ignoreArrowShorthand: true }],
      // Throwing a non-Error loses the stack trace.
      "@typescript-eslint/only-throw-error": "error",
      "@typescript-eslint/prefer-promise-reject-errors": "error",
      // DECISION, and the most important comment in this file. Only the
      // object-typed `||` sites are flagged, where `??` is provably identical:
      // an object is always truthy, so `a || b` and `a ?? b` cannot diverge.
      // `ignorePrimitives` deliberately exempts string/number/boolean/bigint.
      // For a primitive the two operators differ exactly when the left side is
      // `''`, `0`, or `false`, and most codebases lean on that difference:
      // `name || "Unknown"` with an empty-string name yields `"Unknown"`, while
      // `??` yields `""` and writes a blank value into the record. Unconfigured
      // this rule reports hundreds of sites, each needing an individual
      // judgement about what an empty string means there — a data audit, not a
      // lint autofix. Narrow `ignorePrimitives` when someone takes that audit
      // on; until then the exemption is intent, not a gap.
      "@typescript-eslint/prefer-nullish-coalescing": ["error", {
        ignorePrimitives: { string: true, number: true, boolean: true, bigint: true },
      }],
      // `"total: " + n` where n is not a string is a silent coercion.
      "@typescript-eslint/restrict-plus-operands": "error",
      // Outside try/catch a `return await` is a pointless extra microtask;
      // inside, the await is load-bearing (it keeps the rejection in scope).
      "@typescript-eslint/return-await": ["error", "in-try-catch"],
      // DECISION: `considerDefaultExhaustiveForUnions` treats a switch with a
      // `default` as exhaustive, for codebases with deliberate fallbacks.
      // Switches WITHOUT a default must still name every union member. Drop
      // this option for the stricter behaviour: adding a union member then
      // breaks every switch that does not handle it, which is the point.
      "@typescript-eslint/switch-exhaustiveness-check": ["error", {
        considerDefaultExhaustiveForUnions: true,
      }],
      // Spreading a Map, Set, class instance, function or array into an object
      // produces something other than what it reads as — indices for an array,
      // an empty object for a Map. Classic cause of a silently empty options or
      // headers object.
      "@typescript-eslint/no-misused-spread": "error",
      // A promise executor's return value is discarded, so `new Promise(r =>
      // setTimeout(r, ms))` quietly throws away a timer handle — and the same
      // shorthand around an async call throws away the promise, leaving the
      // rejection unhandled and the executor's own resolve never reached.
      "no-promise-executor-return": "error",

      // ── Legacy and injection-shaped APIs ──────────────────────────────────
      // Usually already absent; the ban is so the first `eval`,
      // `new Function(userInput)` or `javascript:` URL has to be argued for in
      // review rather than merged. (`no-implied-eval` is on above.)
      "no-eval": "error",
      "no-new-func": "error",
      "no-script-url": "error",
      "no-proto": "error",
      "no-caller": "error",
      "no-extend-native": "error",
      "no-iterator": "error",
      "no-new-wrappers": "error",
      "no-new-native-nonconstructor": "error",
      "no-multi-str": "error",

      // ── Silent-failure shapes ─────────────────────────────────────────────
      // Each of these compiles, runs, and does something other than it reads as.
      "no-self-compare": "error",
      // A loop whose condition can never change, or whose body always exits on
      // the first pass — both are almost always an unfinished edit.
      "no-unmodified-loop-condition": "error",
      "no-unreachable-loop": "error",
      // `new Promise(async (resolve) => …)`: a throw inside the async executor
      // rejects nothing and the promise hangs forever.
      "no-async-promise-executor": "error",
      // `return` in a constructor silently discards the instance.
      "no-constructor-return": "error",
      // '${x}' in a plain-quoted string is a template literal someone forgot to
      // backtick — it ships the placeholder text to the user.
      "no-template-curly-in-string": "error",
      // Assignment and comma-sequences inside an expression read as comparison
      // and as arguments respectively.
      "no-return-assign": "error",
      "no-sequences": "error",
      "no-labels": "error",
      // `for…in` walks the prototype chain; the guard (or Object.keys) is the
      // difference between iterating your object and iterating whatever a
      // library put on Object.prototype.
      "guard-for-in": "error",
      // Reassigning a parameter makes the caller's argument and the local name
      // silently diverge halfway down a function.
      "no-param-reassign": "error",
      // A getter with no setter (or a pair defined far apart) reads as a
      // writable property and silently drops the write.
      "accessor-pairs": "error",
      "grouped-accessor-pairs": "error",
      // A `default` that is not last is dead code for every case after it.
      "default-case-last": "error",
      // `let x = undefined` defeats TDZ and reads as an intentional value.
      "no-undef-init": "error",

      // ── Modern equivalents that say the same thing more clearly ────────────
      "prefer-object-has-own": "error",
      "prefer-object-spread": "error",
      "prefer-regex-literals": "error",
      "prefer-exponentiation-operator": "error",
      "operator-assignment": "error",
      "no-useless-concat": "error",
      "no-useless-rename": "error",
      // An undescribed Symbol() is untraceable in a debugger.
      "symbol-description": "error",

      // ── TS-only footguns ──────────────────────────────────────────────────
      // Comparing an enum member to a raw literal type-checks and silently
      // stops matching the moment the enum's backing value changes.
      "@typescript-eslint/no-unsafe-enum-comparison": "error",
      // Bare `Function` accepts any signature and returns `any`.
      "@typescript-eslint/no-unsafe-function-type": "error",
      // `-someString` is NaN, not a number.
      "@typescript-eslint/no-unsafe-unary-minus": "error",
      // `void` outside a return position means "any value, ignored" — as a
      // parameter or union member it is almost always a mistake for
      // `undefined` or `never`.
      "@typescript-eslint/no-invalid-void-type": "error",
      "@typescript-eslint/no-useless-empty-export": "error",
      "@typescript-eslint/no-useless-constructor": "error",
      "@typescript-eslint/no-unnecessary-qualifier": "error",
      "@typescript-eslint/no-unnecessary-parameter-property-assignment": "error",
      // An optional parameter before a required one can never be omitted.
      "@typescript-eslint/default-param-last": "error",
      "@typescript-eslint/prefer-for-of": "error",
      "@typescript-eslint/prefer-function-type": "error",
      "@typescript-eslint/prefer-literal-enum-member": "error",
      "@typescript-eslint/prefer-return-this-type": "error",
      // A getter and setter for the same property that disagree on type let a
      // write round-trip into a different value than it came in as.
      "@typescript-eslint/related-getter-setter-pairs": "error",
      "@typescript-eslint/class-literal-property-style": "error",
      "@typescript-eslint/consistent-indexed-object-style": "error",
      // Re-exporting a type through a value export keeps the module edge alive
      // at runtime — the export side of consistent-type-imports above.
      "@typescript-eslint/consistent-type-exports": "error",
    },
  },

  // ADAPT: test files. Three of the rules above fight test runners whose
  // assertion matchers are typed as returning void while actually returning
  // promises that must be awaited (bun-types does this today). Under such a
  // runner, `await expect(x).rejects.toThrow()` trips await-thenable and
  // no-confusing-void-expression on every line, and every hit is load-bearing.
  // Verify the situation in your repo before copying these three `off`s: under
  // a runner with correct types they should all stay on.
  {
    files: ["**/*.test.ts", "**/*.test.tsx", "**/*.spec.ts", "**/__tests__/**"],
    rules: {
      "@typescript-eslint/await-thenable": "off",
      // Test mocks are declared async to match Promise-typed callback
      // signatures; an await-less async there is the point, not an accident.
      "@typescript-eslint/require-await": "off",
      "@typescript-eslint/no-confusing-void-expression": "off",
      // Tests import dynamically on purpose: a module mock must be installed
      // before the module under test loads.
      "no-restricted-syntax": "off",
    },
  },

  // Module-cycle detection. This is the enforcement half of Q8 (is the module
  // graph a DAG) — once the cycles are gone, this rule is what keeps them gone.
  //
  // ADAPT the `files` globs. The rule walks every import transitively and is
  // slow repo-wide, so scope it to the packages whose layering you care about
  // most and widen from there. Both settings are load-bearing: the resolver so
  // `./foo` finds `foo.ts`, and the parsers map so no-cycle can PARSE the
  // imported .ts files — without it the rule silently reports nothing. Verify
  // with a canary cycle; resolution alone is not enough.
  //
  // DECISION: only no-cycle from the resolving rules — `no-unresolved`
  // false-positives on runtime-provided specifiers (e.g. `bun:test`).
  {
    files: ["src/**/*.ts", "lib/**/*.ts", "shared/**/*.ts"],
    plugins: { "import-x": importX },
    settings: {
      "import-x/resolver": { typescript: true },
      "import-x/parsers": { "@typescript-eslint/parser": [".ts", ".tsx"] },
    },
    rules: {
      "import-x/no-cycle": "error",
      // A module importing itself, or exporting a `let`, is a bug that reads as
      // working code; the path rules keep `../../shared/x` from drifting into
      // three spellings of the same module.
      "import-x/no-self-import": "error",
      "import-x/no-mutable-exports": "error",
      "import-x/no-useless-path-segments": "error",
      "import-x/no-absolute-path": "error",
      "import-x/no-empty-named-blocks": "error",
    },
  },

  // ADAPT: React / React Native code only. Omit this block entirely if the repo
  // has no React.
  //
  // rules-of-hooks: a hook behind an `if` or inside a loop desynchronizes
  // React's hook order and crashes at runtime, and nothing else in the
  // toolchain — not tsc, not the tests — can see it.
  //
  // exhaustive-deps: an effect whose dep array omits a value it reads keeps
  // running the closure from the render that created it, so the callback it
  // calls, the draft it sends and the router it navigates with are all the OLD
  // ones — surfacing as a message that silently went nowhere, or a navigation
  // to a screen that no longer exists. The rule also flags the reverse (a dep
  // the hook never reads), which is a dep array that has drifted from its body.
  // Deliberately mount-only effects keep their array and carry a line-level
  // disable saying why.
  {
    files: ["app/**/*.tsx", "app/**/*.ts", "src/**/*.tsx", "components/**/*.tsx"],
    plugins: { "react-hooks": reactHooks },
    rules: {
      "react-hooks/rules-of-hooks": "error",
      "react-hooks/exhaustive-deps": "error",
    },
  },

  // Repo-wide floor. These four are the ones worth arguing for first if the
  // whole set is too much to adopt at once.
  {
    rules: {
      "@typescript-eslint/no-explicit-any": "error",
      // DECISION: underscore-prefixed parameters are deliberately unused — the
      // convention for mock and transport signatures that must match a shape.
      "@typescript-eslint/no-unused-vars": ["error", {
        args: "after-used",
        argsIgnorePattern: "^_",
        varsIgnorePattern: "^_",
        caughtErrorsIgnorePattern: "^_",
      }],
      "eqeqeq": ["error", "smart"],
      "prefer-const": "error",
      // The TS variant understands enums and type parameters; the core rule
      // false-positives on them.
      "no-shadow": "off",
      "@typescript-eslint/no-shadow": "error",
    },
  },
];
