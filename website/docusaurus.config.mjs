const repository = "https://github.com/psyb0t/docker-hybrids3";
const baseUrl = "/docker-hybrids3/";
const docsPath = "../docs";

export default {
  title: "HybridS3",
  tagline: "Object storage that speaks S3, plain HTTP and MCP",
  url: "https://psyb0t.github.io",
  baseUrl,
  trailingSlash: true,
  future: { faster: { rspackBundler: true, swcJsLoader: true } },
  organizationName: "psyb0t",
  projectName: "docker-hybrids3",
  onBrokenLinks: "throw",
  onBrokenAnchors: "throw",
  markdown: { format: "detect", hooks: { onBrokenMarkdownLinks: "throw" } },
  scripts: [{ src: "https://psyb0t.github.io/analytics.js", async: true }],
  presets: [
    ["classic", {
      blog: false,
      sitemap: { ignorePatterns: [baseUrl + "search", baseUrl + "search/"] },
      theme: { customCss: "./src/css/theme.css" },
      docs: {
        path: docsPath,
        routeBasePath: "/",
        sidebarPath: "./sidebars.mjs",
        editUrl: ({ docPath }) => repository + "/edit/main/docs/" + docPath,
      },
    }],
  ],
  themes: [
    ["@easyops-cn/docusaurus-search-local", {
      docsDir: docsPath,
      docsRouteBasePath: "/",
      indexBlog: false,
      hashed: true,
    }],
  ],
  themeConfig: {
    navbar: {
      items: [
        { href: "https://psyb0t.github.io/projects/", label: "All projects", position: "left" },
        { href: repository + "/blob/main/CHANGELOG.md", label: "Changelog", position: "right" },
        { href: repository, label: "GitHub", position: "right" },
      ],
    },
    colorMode: { defaultMode: "dark" },
  },
};
