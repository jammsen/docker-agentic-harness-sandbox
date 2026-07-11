// @ts-check

const lightCodeTheme = require('prism-react-renderer').themes.github;
const darkCodeTheme = require('prism-react-renderer').themes.dracula;

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Agentic Harness Sandbox',
  tagline: 'Run agentic coding tools against your own OpenAI-compatible model endpoint',
  url: 'https://jammsen.github.io',
  baseUrl: '/docker-agentic-harness-sandbox/',
  organizationName: 'jammsen',
  projectName: 'docker-agentic-harness-sandbox',
  trailingSlash: false,
  onBrokenLinks: 'throw',
  markdown: {
    hooks: {
      onBrokenMarkdownLinks: 'warn',
    },
  },
  presets: [
    [
      'classic',
      {
        docs: {
          sidebarPath: require.resolve('./sidebars.js'),
          editUrl:
            'https://github.com/jammsen/docker-agentic-harness-sandbox/edit/main/',
        },
        blog: false,
        theme: {
          customCss: require.resolve('./src/css/custom.css'),
        },
      },
    ],
  ],
  themeConfig: {
    navbar: {
      title: 'Agentic Harness Sandbox',
      items: [
        {type: 'docSidebar', sidebarId: 'docsSidebar', label: 'Docs', position: 'left'},
        {
          href: 'https://github.com/jammsen/docker-agentic-harness-sandbox',
          label: 'GitHub',
          position: 'right',
        },
      ],
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Documentation',
          items: [
            {label: 'Get started', to: '/docs/getting-started'},
            {label: 'Configuration', to: '/docs/configuration'},
          ],
        },
        {
          title: 'Project',
          items: [
            {
              label: 'GitHub repository',
              href: 'https://github.com/jammsen/docker-agentic-harness-sandbox',
            },
          ],
        },
      ],
      copyright: `Copyright © ${new Date().getFullYear()} Agentic Harness Sandbox contributors.`,
    },
    prism: {theme: lightCodeTheme, darkTheme: darkCodeTheme},
  },
};

module.exports = config;
