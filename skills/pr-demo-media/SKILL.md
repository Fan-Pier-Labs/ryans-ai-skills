---
name: pr-demo-media
description: Demo frontend pull requests — spin up each PR's app and capture the new feature as a Playwright-recorded video for interactive changes or screenshots (before/after when possible) for visual/static changes, then post the media on the PR with `gh pr comment --attach`. Driven by GitHub webhook deliveries through /pr-watcher rather than a timer; invoked on its own it runs one catch-up sweep of the open, non-draft frontend PRs in the current repo (or the repos/orgs given via REPOS/OWNERS) and stops. Use whenever the user asks to demo a PR, record or screenshot a feature, post a demo/video/picture to a PR, run the video agent, or wants demos across all open PRs.
---

# PR Demo Media Agent

Finds open, non-draft **frontend** PRs in the target repos (the current repo by
default) that don't yet have a demo for their latest commits, runs each PR's app, captures
the change as either a **video** or **screenshot(s)** — whichever demos it
better — and posts it as an embedded PR comment via `gh pr comment --attach`.

**If the target repo has its own
`.claude/skills/pr-demo-*` skill, read it and follow its repo-specific parts**
(launch commands, test credentials, iOS/CLI paths) — it knows things this
generic skill can't. This skill supplies the trigger, the media decision, and
the generic web flow. Uploads always go through step 6 below, whatever an
older repo skill says.

## Which repos

By default every script targets **the repo you are currently in** (resolved from
`git remote get-url origin`). It never enumerates the user's GitHub account. To
widen the scope, set `REPOS='owner/repo ...'` or `OWNERS='org user ...'` (owners
are expanded to their repos pushed within `DAYS`). If the script exits with
`could not determine the target repo`, **ask the user which repo(s) or org(s) to
target** and re-run with `REPOS` or `OWNERS` set — do not guess, and do not
scan their account.

## How it runs

**On PR events, never on a timer.** Continuous coverage is
`/pr-watcher run /pr-demo-media`: the watcher catches up on the PRs open now,
then queues each one again on its `push` / `pull_request` webhook delivery and
invokes this skill per PR through
[Single-PR invocation](#single-pr-invocation). Polling is the watcher's
fallback for a repo that will not grant a webhook, and it says so when it
degrades to it.

Invoked on its own (`/pr-demo-media`, no watcher), this is **one sweep, then
stop** — the catch-up half of the same work:

1. `scripts/find-demo-candidates.sh` — emits one JSON line per open, non-draft
   PR (with commits in the last 7 days) that touches frontend files and has no
   demo-marker comment newer than its last commit. Each line carries
   `matched_files` — the script's extension/path heuristic. (It is a wrapper
   that calls `skills/shared/find-pr-candidates.sh`, the sweep every PR skill
   runs, with this skill's frontend filter and markers — call the wrapper, not
   the shared script.) You make the final call: skip PRs where the "frontend" files are config,
   test, or generated churn, and skip backend PRs that slipped through. Genuinely
   nothing showable → say so in the summary, post nothing.

   **Only user-visible change is in scope.** The question for every PR is
   "what would a user see differently?" Ask it of the surfaces a user
   actually meets — the UI, the strings it renders, settings, CLI output —
   and if none of them moved, that is the answer. Skip the PR, post nothing,
   move on. Do not go spelunking through a refactor's diff hunting for
   something showable: module moves, type tightening, dedupe into a shared
   helper, deleted dead code, test restructuring and internal renames get no
   demo however large the diff. A PR whose own description is a list of
   internal cleanups is a skip you can make from the description alone.
2. Demo each real candidate (below).
3. Report what the sweep did and **stop**. Do not schedule another pass — say
   that `/pr-watcher run /pr-demo-media` is how to stay covered and let the
   user decide. The marker keeps every trigger idempotent per head SHA, so a
   sweep and a watcher never demo the same commit twice.

## Single-PR invocation

When handed one PR — by `/pr-watcher`, or by a user naming a PR — do not run
the sweep. The contract:

1. **Skip discovery.** `find-demo-candidates.sh` is for sweeps.
2. **Idempotency first.** A marker comment for this exact head means it is
   already demoed — stop and say so:

   ```bash
   gh api "repos/<repo>/issues/<N>/comments" --paginate      --jq '.[] | select(.body | contains("generic-coding-agents:pr-demo-media sha:<head_sha>")) | .id'
   ```
3. **Confirm the head.** `gh pr view <N> -R <repo> --json headRefOid,isDraft,files`.
   Draft → skip. Head moved → demo the *current* head and use its SHA.
4. **Apply the scope rule yourself** — the discovery script's frontend
   heuristic did not run, so the judgment is entirely yours: does anything a
   user meets change? Backend, refactor, config, test churn → skip, post
   nothing, say why in one line.
5. Run **Demoing one PR** as written.

## Dependency preflight — before the first checkout, not at capture time

Every demo this skill produces comes out of Playwright. Without the library there is no video,
and without a browser binary there is no screenshot either — and the place that fails today is
step 4, after a clone, a dependency install, an app launch and a capture script. That is the
whole cost of the PR paid for nothing.

So check **once, at the start of the sweep** (or once before a single-PR run), before the first
`gh repo clone`:

```bash
npx --no-install playwright --version 2>/dev/null || echo "playwright: not installed"
ls "${PLAYWRIGHT_BROWSERS_PATH:-$HOME/Library/Caches/ms-playwright}" 2>/dev/null | grep -q chromium || echo "chromium: not downloaded"
```

The library is installed **into each throwaway clone** (`bun add -d playwright`), which is not
the user's tree and needs no permission. The **browser binary** does: it is a ~150 MB download
into a machine-level cache that outlives every clone. That is the one thing to ask about:

```
Demos need Chromium for Playwright, which isn't on this machine yet:

  bunx playwright install chromium     (~150 MB, into ~/Library/Caches/ms-playwright,
                                        shared by every future demo — downloaded once)

Download it and demo the 3 PRs? (yes / no)
```

- **Yes** → download it once, up front, then run the sweep. Not once per PR.
- **No** → **stop. Demo nothing.** Say which PRs went undemoed and that they stay eligible —
  the marker is per head SHA, so nothing was consumed and the next run picks them all up. Never
  fall back to a screenshot of an error page, an ASCII description of the UI, or a comment
  saying what the feature would look like. A demo that is not a recording of the running app is
  not a demo.

**Dispatched by `/pr-watcher` with nobody watching**, there is no one to answer: do the same
check, and if Chromium is missing, post nothing, mark nothing, and report the missing
dependency as the reason the queue did not drain. A background agent that cannot produce its
artifact stops and says so — it does not post a placeholder. `../shared/dependency-preflight.md`
is the full contract.

## Demoing one PR

### 1. Understand the change

```bash
gh pr view <N> -R <repo> --json title,body,headRefName,files,url
gh pr diff <N> -R <repo>
```

Read the diff for real. Answer: *what user-visible behavior changed, and
what's the shortest flow that shows it?* Write the 3–6 beats before any code.

### 2. Choose the medium — this is the judgment call that matters

**Screenshot(s)** when the change is *how something looks*:
- styling, layout, spacing, colors, dark mode, responsive tweaks
- new static content: a page, section, empty state, copy change
- **before/after only when the old state is the point** — a layout that got
  denser, a card that was redesigned, spacing or colour a reviewer cannot
  recall. Capture the same view on the base branch and the PR branch, post
  both labeled. Skip the pair when the "before" is self-evident: an unticked
  checkbox, a renamed button, an element that simply wasn't there. Two images
  of an obvious difference read as padding, not evidence.

Neither, when nothing a user meets changed — see the scope rule in
[How it runs](#how-it-runs). Post nothing rather than dressing up a refactor.

**Video** when the change is *how something behaves*:
- multi-step flows (login, wizard, checkout), navigation changes
- anything animated, drag/drop, loading/async states, realtime updates
- interactions where the intermediate states are the feature

Mixed PRs: pick the primary story; one video **or** screenshots, never both.

**How much media — scale it to the change, not to what you captured.**

| The change | What to post |
| --- | --- |
| One simple surface: a setting, a copy change, an empty state, a restyled component | **one screenshot** |
| A surface whose new states aren't obvious from a single frame, or a layout whose shape changed | 2–3 screenshots |
| A flow: several steps, async states, animation | one 20–60 s video |

Default to one image and add a second only when it answers a question the
first cannot. Three is the ceiling for images, and reaching it should be rare.
A reviewer scrolling past four near-identical frames learns less than one
well-framed shot. Crop each image to the change — the card, the row, the
panel — rather than posting the whole window, and keep it under roughly 1000
pixels wide so the text stays legible once GitHub scales it.

### 3. Check out and launch

Never demo `main` when the PR is the subject:

```bash
dir=$(mktemp -d "${TMPDIR:-/tmp}/pr-demo.XXXXXX")
gh repo clone <repo> "$dir" -- --quiet && cd "$dir" && gh pr checkout <N>
```

Figure out how the app runs: repo-local skill first, then CLAUDE.md/README,
then `package.json` scripts (`dev`/`start`). Install with the lockfile's
package manager. Pick a free port (`curl -s localhost:<port>` first; override
with `PORT=` when taken). Wait until the app actually serves a real page
before capturing.

### 4. Capture with Playwright (the library, not playwright-cli)

Video recording requires `recordVideo` on a browser context, which only the
library exposes — this is the sanctioned exception to the playwright-cli rule.
Write the script inside the checkout so `import 'playwright'` resolves
(`bun add -d playwright` or `npm i -D playwright` if absent — the checkout is a
throwaway, so this needs no asking). Chromium was settled at the preflight; if
it is missing here, the preflight was skipped, and the answer is to stop and ask
rather than to download 150 MB mid-capture. Headless is deliberate: recording
needs no window, and headless can't steal focus.

```ts
import { chromium } from 'playwright';

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({
  viewport: { width: 1280, height: 720 },
  // video mode only:
  recordVideo: { dir: '/tmp/pr-demo-media', size: { width: 1280, height: 720 } },
});
const page = await context.newPage();

// Floating caption so the viewer knows what they're looking at.
// The DOM is wiped on navigation — call caption() again after every goto().
async function caption(text: string) {
  await page.evaluate((t) => {
    let el = document.getElementById('__demo_caption') as HTMLDivElement | null;
    if (!el) {
      el = document.createElement('div');
      el.id = '__demo_caption';
      Object.assign(el.style, {
        position: 'fixed', bottom: '24px', left: '50%', transform: 'translateX(-50%)',
        background: 'rgba(20,20,20,0.85)', color: '#fff', padding: '10px 18px',
        borderRadius: '8px', font: '600 16px system-ui', zIndex: '999999',
        pointerEvents: 'none',
      });
      document.body.appendChild(el);
    }
    el.textContent = t;
  }, text);
}
```

**Screenshot mode**: navigate/interact to the state that shows the feature,
then `await page.screenshot({ path, fullPage })` (or an element handle's
`.screenshot()` to crop to the component). For before/after, run the same
script twice — once against a server on the base branch, once on the PR — and
name the files `before.png` / `after.png`. Skip the caption overlay in
screenshots; put labels in the comment text instead.

**Video mode**: drive the 3–6 beats with 800–1500 ms pauses after every
meaningful step — automation-speed video is an unwatchable blur. Target
20–60 s. `context.close()` is what flushes the video file; read
`page.video().path()` before closing. Convert for GitHub:

```bash
ffmpeg -y -i demo.webm -c:v libx264 -pix_fmt yuv420p -movflags +faststart -crf 23 demo.mp4
```

(`yuv420p` is required — without it Safari and GitHub's player can refuse the
file. Stay far under the 100 MB cap; a 60 s 720p demo is a few MB.)

### 5. Verify before publishing — non-negotiable

The media is about to go on a PR; a blank page or error state must be caught
here. Look at every screenshot yourself. For video, extract frames and look:

```bash
ffmpeg -y -i demo.mp4 -vf fps=1 /tmp/pr-demo-frames/f%03d.png
```

If the feature isn't clearly visible, fix and re-capture. Also: **fake data
only** — never a real account, credential, or personal data on screen; use the
repo's test/demo fixtures.

### 6. Upload and post — `gh pr comment --attach`

`gh` ≥ 2.99 uploads images and video natively (`--attach` on `pr comment`,
`pr create`, `pr edit`; up to 50 files per command). Requires `gh --version`
2.99.0+ (`brew upgrade gh` if older) and a normal `gh auth status` login —
no browser session, no third-party tool.

**The comment is the media, nothing else.** No summary of what the PR does,
no explanation of the change, no list of beats — the PR description already
covers that, and the captions inside the video carry the context. The body is
the marker line plus a one-word heading; the only other text allowed is a
**Before** / **After** label on a screenshot pair.

```bash
gh pr comment <N> -R <owner>/<repo> \
  --body "<!-- generic-coding-agents:pr-demo-media sha:<head_sha> -->
🎬 **Demo**" \
  --attach demo.mp4
```

Files the body doesn't reference are appended to the end of the comment, so
for one video — or one screenshot, the usual case — the body is just the
marker + heading, with no label at all. For a before/after pair, reference the
files in the body so the labels sit next to the right image — `gh` rewrites each `![...](./file)` to the uploaded asset URL:

```bash
gh pr comment <N> -R <owner>/<repo> \
  --body "<!-- generic-coding-agents:pr-demo-media sha:<head_sha> -->
🎬 **Demo**

**Before**
![before](./before.png)

**After**
![after](./after.png)" \
  --attach ./before.png --attach ./after.png
```

The command
prints the comment URL — put it in your report. The marker line is what makes
the discovery script idempotent — never omit it.

If some attachments fail, `gh` still posts the comment with the ones that
worked and reports the failures — check the output, fix the file (usually
size, or a codec GitHub's player rejects: re-encode with the `ffmpeg` line in
step 4), and `gh pr comment <N> --edit-last --attach <file>` rather than
posting a second comment.

### 7. Clean up and report

Kill servers, `rm -rf "$dir"`. Report per PR (to the user, not on the PR):
medium chosen and why, the beats shown, and the comment URL.

## Special surfaces

If we are working on an iOS app or Android app you will have to fire up a simulator and control it with maestro to generate this video. 

- **iOS/Expo PRs**: simulator + `simctl recordVideo`, driven natively.
- **CLI/MCP PRs**: a verbatim terminal transcript beats a video of text; post
  with plain `gh pr comment`. (These aren't "frontend" candidates from the
  script, but the user may ask directly.)
- **Electron PRs**: same flow, different launcher. Build the app first (the
  repo's `npm run build` / `electron-vite build`), then drive the built main
  bundle with Playwright's Electron driver instead of `chromium.launch`:

  ```ts
  import { _electron as electron } from 'playwright';
  const app = await electron.launch({
    args: [join(process.cwd(), 'out', 'main', 'index.js')],
    env: { ...process.env, /* repo's scratch data dir + headless/demo flags */ },
    recordVideo: { dir: '/tmp/pr-demo-media', size: { width: 1280, height: 800 } },
  });
  const page = await app.firstWindow();
  await page.setViewportSize({ width: 1280, height: 800 });
  // ... beats as above; page.video().path() then app.close() to flush.
  ```

  Look for the repo's e2e fixtures (`tests/e2e/fixtures.ts` or similar) — they
  usually already know the data-dir env var, the headless flag, and a demo /
  fake-mailbox mode, which is also your fake-data source. `playwright` resolves
  transitively from `@playwright/test`; run the script with `npx tsx`.
