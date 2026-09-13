---
name: pr-demo-media
description: Scan open, non-draft frontend pull requests across the Fan-Pier-Labs and ryanhugh GitHub accounts, spin up each PR's app, capture the new feature — a Playwright-recorded video for interactive changes or screenshots (before/after when possible) for visual/static changes — and post the media on the PR with `gh pr comment --attach`. Use whenever the user asks to demo a PR, record or screenshot a feature, post a demo/video/picture to a PR, run the video agent, or wants demos across all open PRs.
---

# PR Demo Media Agent

Finds open, non-draft **frontend** PRs in `Fan-Pier-Labs` and `ryanhugh` that
don't yet have a demo for their latest commits, runs each PR's app, captures
the change as either a **video** or **screenshot(s)** — whichever demos it
better — and posts it as an embedded PR comment via `gh pr comment --attach`.

This is the generalized successor of
`Fan-Pier-Labs/openrecord/.claude/skills/pr-demo-video` (vendored at
`references/openrecord-pr-demo-video.md`). **If the target repo has its own
`.claude/skills/pr-demo-*` skill, read it and follow its repo-specific parts**
(launch commands, test credentials, iOS/CLI paths) — it knows things this
generic skill can't. This skill supplies the loop, the media decision, and the
generic web flow. **Ignore any repo skill's upload instructions** (gh-attach,
browser sessions, `/upload/policies/assets`) — those predate `gh --attach`;
step 6 below is the upload path.

## The loop

1. `scripts/find-demo-candidates.sh` — emits one JSON line per open, non-draft
   PR (repos active in the last 7 days) that touches frontend files and has no
   demo-marker comment newer than its last commit. Each line carries
   `frontend_files` — the script's extension/path heuristic. You make the
   final call: skip PRs where the "frontend" files are config, test, or
   generated churn, and skip backend PRs that slipped through. Genuinely
   nothing showable → say so in the pass summary, post nothing.
2. Demo each real candidate (below).
3. When looping continuously, schedule the next pass 20–30 min out (`/loop` or
   `ScheduleWakeup`); the marker makes passes idempotent per head SHA.

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
- best form: **before/after** — capture the same view on the base branch and
  the PR branch, post both images labeled. A before/after pair is often the
  single most persuasive review artifact.

**Video** when the change is *how something behaves*:
- multi-step flows (login, wizard, checkout), navigation changes
- anything animated, drag/drop, loading/async states, realtime updates
- interactions where the intermediate states are the feature

Mixed PRs: pick the primary story; one video **or** 1–3 screenshots, not a
gallery. A 20–60s video or ≤3 images per comment.

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
(`bun add -d playwright` or `npm i -D playwright` if absent, plus
`bunx playwright install chromium` if Chromium is missing). Headless is
deliberate: recording needs no window, and headless can't steal focus.

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

```bash
gh pr comment <N> -R <owner>/<repo> \
  --body "<!-- generic-coding-agents:pr-demo-media sha:<head_sha> -->
🎬 **Automated demo** — <one line: what it shows and which flow it drives>" \
  --attach demo.mp4
```

Files the body doesn't reference are appended to the end of the comment, so
for a single video the body is just the marker + summary. For a before/after
pair, reference the files in the body so the labels sit next to the right
image — `gh` rewrites each `![...](./file)` to the uploaded asset URL:

```bash
gh pr comment <N> -R <owner>/<repo> \
  --body "<!-- generic-coding-agents:pr-demo-media sha:<head_sha> -->
🎬 **Automated demo** — <summary>

**Before**
![before](./before.png)

**After**
![after](./after.png)" \
  --attach ./before.png --attach ./after.png
```

Alt text for images goes after a `#` in the flag (`--attach './after.png#New
empty state'`); video renders as a player and takes no alt text. The command
prints the comment URL — put it in your report. The marker line is what makes
the discovery script idempotent — never omit it.

If some attachments fail, `gh` still posts the comment with the ones that
worked and reports the failures — check the output, fix the file (usually
size, or a codec GitHub's player rejects: re-encode with the `ffmpeg` line in
step 4), and `gh pr comment <N> --edit-last --attach <file>` rather than
posting a second comment.

### 7. Clean up and report

Kill servers, `rm -rf "$dir"`. Report per PR: what changed, medium chosen and
why, the beats shown, and the comment URL.

## Special surfaces

The vendored openrecord skill covers two paths worth reusing anywhere they
apply — read it when you hit them:
- **iOS/Expo PRs**: simulator + `simctl recordVideo`, driven natively.
- **CLI/MCP PRs**: a verbatim terminal transcript beats a video of text; post
  with plain `gh pr comment`. (These aren't "frontend" candidates from the
  script, but the user may ask directly.)
