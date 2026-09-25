# Rulesets

The repository rulesets, kept here so they are reviewed like code. GitHub does
not read these files; apply them with the API.

The first time:

```bash
gh api -X POST repos/willfarrell/local-agent-isolation/rulesets --input .github/rulesets/main.json
gh api -X POST repos/willfarrell/local-agent-isolation/rulesets --input .github/rulesets/develop.json
```

After a change, `PUT` to `rulesets/<id>`. Get the id from
`gh api repos/willfarrell/local-agent-isolation/rulesets`.

`main.json` is the only gate before release. `release.yml` publishes every
push to `main` without rerunning the checks, so the required checks listed
here must match the job names in `test-*.yml`.
