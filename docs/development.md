---
sidebar_position: 8
title: Documentation development
---

# Documentation development

The documentation is a Docusaurus site stored at the repository root.

```bash
npm ci
npm start
```

The development server prints its local URL and reloads as files change. Validate the production output before opening a pull request:

```bash
npm run build
npm run serve
```

GitHub Actions builds the site and deploys the generated `build/` directory to GitHub Pages when changes reach `main`. In the repository settings, set **Pages → Build and deployment → Source** to **GitHub Actions**.
