// Copy for /changelog. The releases themselves are read from GitHub at build time.

export const changelogHero = {
  eyebrow: "Changelog",
  title: "What's new",
  intro:
    "Built in the open. Here's everything that changed in each release, and the people who made it happen.",
} as const;

export const changelogCopy = {
  description:
    "Everything that changed in each Tinycast release, and the people who built it.",
  jumpTo: "Versions",
  latest: "Latest",
  releaseNotes: "View on GitHub",
  compare: "View diff",
  showMore: (count: number) => `Show ${count} more`,
  contributors: (count: number) =>
    `Thanks to ${count} ${count === 1 ? "contributor" : "contributors"}`,
  earlier: {
    title: "Earlier releases",
    body: "From before we published release notes. Each one links to its download.",
  },
  unavailable: {
    title: "Changelog unavailable",
    body: "GitHub didn't respond when this page was built. Every release is still on GitHub.",
  },
  allReleases: "All releases on GitHub",
  install: "Get Tinycast",
} as const;
