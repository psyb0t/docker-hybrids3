# Docs and releases

- The documentation pages are `docs/`, built by the Docusaurus site in `website/` and published by `.github/workflows/docs.yml` from `main` at https://psyb0t.github.io/docker-hybrids3/. Keep `docs/` flat; a file name is its URL. A page's sidebar position is its entry in `website/sidebars.mjs`, and `website/static/llms.txt` lists every page, so add new pages to both.
- After a docs change, run `make docs`. It fails on a broken link or anchor. Changing `website/package.json` needs `make docs-lock`.
- README links to repository files use full `https://github.com/psyb0t/docker-hybrids3/blob/main/...` URLs, because the README is also shown on Docker Hub.
- A behavior, setting or route change updates the matching docs page, `config.example.yaml`, the skill (`.agents/skills/hybrids3/`) and the plugin README in the same change.
- CHANGELOG headings here are `## [vX.Y.Z], YYYY-MM-DD`. A release tag goes on a commit whose `main` pipeline run passed, because the pipeline promotes that run's image to the release tags, cuts the GitHub release and publishes the skill, the plugin and the MCP Registry entry.
- `.agents/.codex-plugin/plugin.json` carries the release version; update it with each release. `package.json`, `openclaw.plugin.json` and `server.json` keep `0.0.0`, which the publish workflows replace.
