# Docs and releases

- The documentation site is `docs/`, published by GitHub Pages from `main` at https://psyb0t.github.io/docker-hybrids3/ with the Just the Docs theme (`remote_theme` pinned in `docs/_config.yml`, colors in `docs/_sass/`, the shared tracker in `docs/_includes/head_custom.html`). Keep `docs/` flat; a file name is its URL.
- Every page has front matter with a unique `title` and a `description` of 50 to 170 characters, and exactly one `#` heading.
- Links between pages use the relative `.md` path. A link to a file outside `docs/` uses the full `https://github.com/psyb0t/docker-hybrids3/blob/main/<path>` URL. Wrap code blocks containing `{{` or `{%` in `<!-- {% raw %} -->` and `<!-- {% endraw %} -->`.
- After a docs change, run `make docs` and check the built site (the `DOCS_SITE` directory in the Makefile) before handing off.
- The README is the front door: what hybrids3 is, the quick start, and a Documentation section with full site URLs. Reference material goes in `docs/`. README links to repository files use full `https://github.com/psyb0t/docker-hybrids3/blob/main/...` URLs, because the README is also shown on Docker Hub.
- A behavior, setting or route change updates the matching docs page, `config.example.yaml`, the skill (`.agents/skills/hybrids3/`) and the plugin README in the same change.
- Prose: no em dashes, "directory" never "folder", no AI vocabulary, one paragraph per source line. Do not mention local scratch directories in committed text.
- CHANGELOG entries use a `## [vX.Y.Z], YYYY-MM-DD` heading and are written at release time. A release is an annotated `vX.Y.Z` tag on a commit whose `main` pipeline run passed; the pipeline promotes that run's image to the release tags, cuts the GitHub release and publishes the skill, the plugin and the MCP Registry entry.
- `.agents/.codex-plugin/plugin.json` carries the release version; update it with each release. `package.json`, `openclaw.plugin.json` and `server.json` keep `0.0.0`, which the publish workflows replace.
